require 'rubygems'
require 'restfully'
require 'restfully/addons/bonfire'

CLIENT_IMAGE_NAME = "BonFIRE Debian Squeeze 2G v2"
SERVER_IMAGE_NAME = "BonFIRE Debian Squeeze 2G v2"
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
    e['name'] == "Demo VW" && e['status'] == "running"
  } || session.root.experiments.submit(
    :name => "Demo VW",
    :description => "VW demo using Restfully - #{Time.now.to_s}",
    :status => "waiting",
    :walltime => 8*3600 # 8 hours
  )

  # Create shortcuts for location resources:
  inria = session.root.locations[:'fr-inria']
  fail "Can't select the fr-inria location" if inria.nil?
  ibbt = session.root.locations[:'be-ibbt']
  fail "Can't select the de-hlrs location" if ibbt.nil?

  # In this array we'll store the clients launched at each site:
  locations = [[ibbt,[]]]
  
  private_network = experiment.networks.submit(
    :location => ibbt,
    :name => "network-experiment#{experiment['id']}",
    :bandwidth => 1000,
    :latency => 0,
    :size => 24,
    :lossrate => 0,
    # You MUST specify the address:
    :address => "192.168.0.0"
  )

  session.logger.info "Launching aggregator..."
  aggregator = experiment.computes.find{|vm|
    vm['name'] == "BonFIRE-monitor-experiment#{experiment['id']}"
  } || experiment.computes.submit(
    :name => "BonFIRE-monitor-experiment#{experiment['id']}",
    :instance_type => "small",
    :disk => [
      {
        :storage => inria.storages.find{|s|
          s['name'] == AGGREGATOR_IMAGE_NAME
        },
        :type => "OS"
      }
    ],
    :nic => [
      {
        :network => inria.networks.find{|n|
          n['name'] == WAN_NAME
        }
      }
    ],
    :location => inria
  )
  aggregator_ip = aggregator['nic'][0]['ip']
  session.logger.info "AGGREGATOR IP=#{aggregator_ip}"

  session.logger.info "Launching server..."
  # Set up server
  server = experiment.computes.find{|vm|
    vm['name'] == "server-experiment#{experiment['id']}"
  } || experiment.computes.submit(
    :name => "server-experiment#{experiment['id']}",
    :instance_type => "small",
    :disk => [
      {
        :storage => ibbt.storages.find{|s|
          s['name'] == SERVER_IMAGE_NAME
        },
        :type => "OS"
      }
    ],
    :nic => [
      {:network => ibbt.networks.find{|n| n['name'] == WAN_NAME}},
      {:network => private_network, :ip => '192.168.0.2'}
    ],
    :location => ibbt,
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
    private_ip = "192.168.0.#{vms.size+3}"
    vms.push experiment.computes.submit(
      :name => "#{location['name']}-#{vms.size}-client-e#{experiment['id']}",
      :instance_type => "small",
      :disk => [
        {
          :storage => location.storages.find{|s|
            s['name'] == CLIENT_IMAGE_NAME
          },
          :type => "OS"
        }
      ],
      :nic => [
        {:network => location.networks.find{|n| n['name'] == WAN_NAME}},
        {:network => context.delete(:private_network), :ip => private_ip}
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
    'iperf_server' => '192.168.0.2',
    :private_network => private_network
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
      session.logger.info "Experiment is running..."
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
