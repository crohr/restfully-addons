require 'rubygems'
require 'restfully'
require 'restfully/addons/bonfire'

SERVER_IMAGE_NAME = "BonFIRE Debian Squeeze v2"
WAN_NAME = "BonFIRE WAN"

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

session = Restfully::Session.new(
  :configuration_file => "~/.restfully/api.bonfire-project.eu",
  :gateway => "ssh.bonfire.grid5000.fr",
  :keys => ["~/.ssh/id_rsa"],
  :cache => false,
  :logger => logger
)

experiment = nil

begin
  # Find an existing running experiment with the same name or submit a new
  # one. This allows re-using an experiment when developing a new script.
  experiment = session.root.experiments.find{|e|
    e['name'] == "Demo SSH" && e['status'] == "running"
  } || session.root.experiments.submit(
    :name => "Demo SSH",
    :description => "SSH demo using Restfully - #{Time.now.to_s}",
    :status => "waiting",
    :walltime => 8*3600 # 8 hours
  )

  # Create shortcuts for location resources:
  inria = session.root.locations[:'fr-inria']
  fail "Can't select the fr-inria location" if inria.nil?

  session.logger.info "Launching VM..."
  # Find an existing server in the experiment, or set up a new one:
  server = experiment.computes.find{|vm|
    vm['name'] == "VM-experiment#{experiment['id']}"
  } || experiment.computes.submit(
    :name => "VM-experiment#{experiment['id']}",
    :instance_type => "small",
    :disk => [{
      :storage => inria.storages.find{|s|
        s['name'] == SERVER_IMAGE_NAME
      },
      :type => "OS"
    }],
    :nic => [
      {:network => inria.networks.find{|n| n['name'] == WAN_NAME}}
    ],
    :location => inria
  )
  server_ip = server['nic'][0]['ip']
  session.logger.info "SERVER IP=#{server_ip}"

  # Pass the experiment status to running.
  # If it was already running this has no effect.
  experiment.update(:status => "running")

  # Wait until all VMs are ACTIVE and ssh-able.
  # Fail if one of them has FAILED.
  until [server].all?{|vm|
    vm.reload['state'] == 'ACTIVE' && vm.ssh.accessible?
  } do
    fail "One of the VM has failed" if [server].any?{|vm|
      vm['state'] == 'FAILED'
    }
    session.logger.info "One of the VMs is not ready. Waiting..."
    sleep 20
  end

  session.logger.info "VMs are now READY!"
  # Display VM IPs
  session.logger.info "*** Server IP: #{server['nic'][0]['ip']}"

  server.ssh do |ssh|
    session.logger.info "Uploading content..."
    # Here is how you would upload a file:
    # ssh.scp.upload!("/path/to/file", '/tmp/file.log')
    # Here is how you can upload some in-memory data:
    ssh.scp.upload!(StringIO.new('some data'), '/tmp/file.log')
    # See <http://net-ssh.github.com/scp/v1/api/index.html> for more details.

    session.logger.info "Content of uploaded file:"
    puts ssh.exec!("cat /tmp/file.log")

    session.logger.info "Installing things..."
    output = ssh.exec!("apt-get install curl -y")
    session.logger.debug output

    session.logger.info "Running query against API..."
    puts ssh.exec!("source /etc/default/bonfire && curl -k $BONFIRE_URI/locations/$BONFIRE_PROVIDER/computes/$BONFIRE_RESOURCE_ID -u $BONFIRE_CREDENTIALS")
  end

  session.logger.warn "Success! Will delete experiment in 10 seconds. Hit CTRL-C now to keep your VMs..."
  sleep 10
  experiment.delete

rescue Exception => e
  session.logger.error "#{e.class.name}: #{e.message}"
  session.logger.error e.backtrace.join("\n")
  session.logger.warn "Cleaning up in 30 seconds. Hit CTRL-C now to keep your VMs..."
  sleep 30
  experiment.delete unless experiment.nil?
end
