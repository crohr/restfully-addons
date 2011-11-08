require 'net/ssh/gateway'
require 'net/scp'
require 'net/sftp'

module Restfully
  class Resource
    # Opens an SSH session on the resource's IP.
    # Returns the result of the last statement of the given block.
    def ssh(user = nil, opts = {}, &block)
      raise NotImplementedError unless uri.to_s =~ /\/computes\/\w+$/
      @ssh ||= SSH.new(session, self)
      if block
        @ssh.run(@ssh.ip, user, opts, &block)
      else
        @ssh
      end
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
      options[:keys_only] = if session.config[:keys_only]
        session.config[:keys_only]
      elsif options[:keys]
        true
      end
      gateway = session.config[:gateway]
      if gateway
        gateway_handler = Net::SSH::Gateway.new(gateway, session.config[:username], options)
        result = nil
        gateway_handler.ssh(fqdn, user, options) {|handler|
          result = block.call(handler)
        }
        gateway_handler.shutdown!
        result
      else
        result = nil
        Net::SSH.start(fqdn, user, options) {|handler|
          result = block.call(handler)
        }
        result
      end
    end
    
    def ip
      @ip ||= accessible?
    end
    
    def accessible?(options = {})
      return false if resource['nic'].empty?
      accessible_nic = resource['nic'].find{|nic|
        ip = nic['ip']
        if ip.nil? || ip =~ /^192.168/
          true
        else
          begin
            Timeout.timeout(10) do
              run(ip, 'root', options) {|s| s.exec!("hostname") }
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