require 'net/ssh/gateway'
require 'net/scp'
require 'net/sftp'

module Restfully
  class Resource
    def ssh(user = nil, opts = {}, &block)
      raise NotImplementedError unless uri.to_s =~ /\/computes\/\w+$/
      @ssh ||= SSH.new(session, self)
      @ssh.run(@ssh.ip, user, opts, &block) if block
      @ssh
    end
  end
  
  class SSH
    attr_reader :session, :resource

    def initialize(session, resource)
      @session = session
      @resource = resource
    end
    
    def run(fqdn, user, options = {}, &block)
      user ||= 'root'
      session.logger.info "Trying to SSH into #{user}@#{fqdn}..."
      options[:keys] ||= session.config[:keys]
      gateway = session.config[:gateway]
      if gateway
        gateway_handler = Net::SSH::Gateway.new(gateway, session.config[:username], options)
        gateway_handler.ssh(fqdn, user, options, &block)
        gateway_handler.shutdown!
      else
        Net::SSH.start(fqdn, user, options, &block)
      end
    end
    
    def ip
      @ip ||= accessible?
    end
    
    def accessible?
      return false if resource['nic'].empty?
      accessible_nic = resource['nic'].find{|nic|
        ip = nic['ip']
        if ip.nil? || ip =~ /^192.168/
          true
        else
          begin
            Timeout.timeout(10) do
              run(ip, 'root') {|s| s.exec!("hostname") }
            end
            true
          rescue Exception => e
            session.logger.info  "Can't SSH yet to #{ip}. Reason: #{e.class.name}, #{e.message}."
            false
          end
        end
      }
      accessible_nic && accessible_nic['ip']
    end
  end
end