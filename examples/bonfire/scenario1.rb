require 'rubygems'
require 'restfully'
require 'restfully/addons/bonfire'

CLIENT_IMAGE_NAME = "VM-iperf"
SERVER_IMAGE_NAME = "VM-iperf"
AGGREGATOR_IMAGE_NAME = "BonFIRE Zabbix Aggregator v4"
WAN_NAME = "BonFIRE WAN"

session = Restfully::Session.new(
  :configuration_file => "~/.restfully/api.bonfire-project.eu",
  :cache => false,
  :gateway => "ssh.bonfire.grid5000.fr",
  :keys => ["~/.ssh/id_rsa"]
)
session.logger.level = Logger::INFO

experiment = nil

begin
  # Find an existing running experiment with the same name or submit a new
  # one. This allows re-using an experiment when developing a new script.
  experiment = session.root.experiments.find{|e|
    e['name'] == "Demo ONE" && e['status'] == "running"
  } || session.root.experiments.submit(
    :name => "Demo ONE",
    :description => "ONE demo using Restfully - #{Time.now.to_s}",
    :status => "waiting",
    :walltime => 8*3600 # 8 hours
  )

  # Create shortcuts for location resources:
  inria = session.root.locations[:'fr-inria']
  fail "Can't select the fr-inria location" if inria.nil?
  hlrs = session.root.locations[:'de-hlrs']
  fail "Can't select the de-hlrs location" if hlrs.nil?
  epcc = session.root.locations[:'uk-epcc']
  fail "Can't select the uk-epcc location" if epcc.nil?

  # In this array we'll store the clients launched at each site:
  locations = [[epcc,[]], [hlrs,[]], [inria,[]]]

  session.logger.info "Launching aggregator..."
  # Find an existing server in the experiment, or set up a new one:
  aggregator = experiment.computes.find{|vm|
    vm['name'] == "BonFIRE-monitor-experiment#{experiment['id']}"
  } || experiment.computes.submit(
    :name => "BonFIRE-monitor-experiment#{experiment['id']}",
    :instance_type => "small",
    :disk => [{
      :storage => inria.storages.find{|s|
        s['name'] == AGGREGATOR_IMAGE_NAME
      }, :type => "OS"
    }],
    :nic => [{
      :network => inria.networks.find{|n|
        n['name'] == WAN_NAME
      }
    }],
    :location => inria
  )
  aggregator_ip = aggregator['nic'][0]['ip']
  session.logger.info "AGGREGATOR IP=#{aggregator_ip}"

  session.logger.info "Launching server..."
  # Find an existing server in the experiment, or set up a new one:
  server = experiment.computes.find{|vm|
    vm['name'] == "server-experiment#{experiment['id']}"
  } || experiment.computes.submit(
    :name => "server-experiment#{experiment['id']}",
    :instance_type => "small",
    :disk => [{
      :storage => hlrs.storages.find{|s|
        s['name'] == SERVER_IMAGE_NAME
      },
      :type => "OS"
    }],
    :nic => [
      {:network => hlrs.networks.find{|n| n['name'] == WAN_NAME}}
    ],
    :location => hlrs,
    :context => {
      'aggregator_ip' => aggregator_ip,
      # Register metric on the server
      'metrics' => XML::Node.new_cdata('<metric>iperf.server-bw,fgrep ",-" /root/iperf_server_log.txt | cut -d "," -f9 | tail -1</metric>')
    }
  )
  server_ip = server['nic'][0]['ip']
  session.logger.info "SERVER IP=#{server_ip}"

  # Procedure to create a client VM in a round-robin fashion on each location:
  def create_client(session, experiment, locations, context = {})
    # Sort locations by number of clients already running
    placement = locations.sort{|loc1,loc2|
      loc1[1].size <=> loc2[1].size
    }.first
    location, vms = placement
    session.logger.info "Deploying client image on #{location['name']}..."
    vms.push experiment.computes.submit(
      :name => "#{location['name']}-#{vms.size}-client-e#{experiment['id']}",
      :instance_type => "small",
      :disk => [{
        :storage => location.storages.find{|s|
          s['name'] == CLIENT_IMAGE_NAME
        }, :type => "OS"
      }],
      :nic => [
        {:network => location.networks.find{|n| n['name'] == WAN_NAME}}
      ],
      :location => location,
      :context => context.merge(
        'metrics' => XML::Node.new_cdata('<metric>iperf.client-bw,fgrep ",-" /root/iperf_clients_log.txt | cut -d "," -f9 | tail -1</metric>')
      )
    )
    vms.last
  end

  # Select clients that were potentially already existing
  # (in case of an experiment reuse).
  locations.each do |(location,vms)|
    vms.push(*location.computes.select{|vm|
      vm['name'] =~ /client-e#{experiment['id']}$/
    })
  end
  clients = locations.map{|(l,vms)| vms}.flatten

  # Create two client if no existing clients:
  clients = 2.times.map{ create_client(session, experiment, locations, {
    'aggregator_ip' => aggregator_ip,
    'iperf_server' => server_ip
  })} if clients.empty?

  # Pass the experiment status to running.
  # If it was already running this has no effect.
  experiment.update(:status => "running")

  # Wait until all VMs are ACTIVE and ssh-able.
  # Fail if one of them has FAILED.
  until [aggregator, server, *clients].all?{|vm|
    vm.reload['state'] == 'ACTIVE' && vm.ssh.accessible?
  } do
    fail "One of the VM has failed" if [aggregator, server, *clients].any?{|vm| vm['state'] == 'FAILED'}
    session.logger.info "One of the VMs is not ready. Waiting..."
    sleep 20
  end

  session.logger.info "VMs are now READY!"
  # Display VM IPs
  session.logger.info "*** Aggregator IP: #{aggregator_ip}"
  session.logger.info "*** Server IP: #{server['nic'][0]['ip']}"
  session.logger.info "*** Client IPs: #{clients.map{|vm| vm['nic'][0]['ip']}.inspect}"

  # Control loop, until the experiment is done.
  until ['terminated', 'canceled'].include?(experiment.reload['status']) do
    case experiment['status']
    when 'running'
      session.logger.info "Experiment is running. Monitoring elasticity rule..."
      session.logger.info "Clients: #{locations.map{|(l,vms)| "#{l['name']}: #{vms.map{|vm| vm['name']}.inspect}"}.join("; ")}."

      # Check a metric values:
      values = experiment.zabbix.metric('system.cpu.util[,system,avg1]', :type => :numeric, :hosts => server).values
      avg3, avg5 = [values[0..3].avg, values[0..5].avg]

      session.logger.info "Metric: values=#{values.inspect}, avg3=#{avg3}, avg5=#{avg5}."
      clients_count = locations.map{|(l,vms)| vms}.flatten.length

      # Here if the CPU usage of the iperf server is too low, we'll spawn a
      # new client. If it's too high, we'll shut a client down.
      if clients_count <= 10 && values.length >= 3 && avg3 <= 20
        session.logger.warn "Scaling UP (avg=#{avg3})!"
        vm = create_client(session, experiment, locations, {
          'aggregator_ip' => aggregator_ip,
          'iperf_server' => server_ip
        })
        sleep(10) until vm.ssh.accessible?
      elsif clients_count > 1 && values.length >= 5 && avg5 >= 22
        session.logger.warn "Scaling DOWN (avg=#{avg5})!"
        # Delete the first client of the location which has the most clients:
        locations.sort{|loc1,loc2|
          loc2[1].size <=> loc1[1].size
        }.first[1].shift.delete
      else
        session.logger.info "Nothing to do."
      end

      sleep 60
    when 'terminating'
      session.logger.info "Experiment is terminating. Here you could save images, retrieve data, etc."
      sleep 30
    else
      session.logger.info "Experiment is #{experiment['status']}. Nothing to do yet."
      sleep 60
    end
  end

  session.logger.warn "Experiment terminated!"

rescue Exception => e
  session.logger.error "#{e.class.name}: #{e.message}"
  session.logger.error e.backtrace.join("\n")
  session.logger.warn "Cleaning up in 30 seconds. Hit CTRL-C now to keep your VMs..."
  sleep 30
  experiment.delete unless experiment.nil?
end
