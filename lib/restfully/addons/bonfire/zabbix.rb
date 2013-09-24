require 'json'

class Array
  def sum
    inject(:+)
  end

  def avg
    sum.to_f / size
  end

  def median
    sorted = sort
    (sorted[size/2] + sorted[(size+1)/2]) / 2
  end
end

module Restfully
  class Resource
    def zabbix
      raise NotImplementedError unless uri.to_s =~ /\/experiments\/[0-9]+$/
      @zabbix ||= Zabbix.new(session, self)
    end
  end

  class Zabbix
    attr_reader :session, :experiment
    def initialize(session, experiment, opts = {})
      @session = session
      @username = opts[:username] || "Admin"
      @password = opts[:password] || experiment['aggregator_password']
      @experiment = experiment
      @token, @request_id = nil, 0
      @uri = @experiment.uri.to_s+"/zabbix"
      @max_attempts = 5
    end

    def request(method, params = {})
      begin
        authenticate if @token.nil? && method != "user.authenticate"
        @request_id += 1
        q = { "jsonrpc" => "2.0", "auth" => @token, "id" => @request_id,
              "method" => method, "params" => params }
        resource = @session.post(@uri,
          JSON.dump(q),
          :head => {
            'Content-Type' => 'application/json',
            'Accept' => 'application/json'
          }
        )

        # That fucking zabbix API returns "text/plain" as content-type...
        h = JSON.parse(resource.response.body)

        if h['error']
          if h['error']['data'] == "Not authorized"
            @token = nil
            request(method, params)
          else
            raise StandardError, "Received error: #{h.inspect}" if h['error']
          end
        else
          h['result']
        end
      rescue Restfully::HTTP::Error => e
        # retry ad vitam eternam
        sleep 5
        retry
      end
    end

    def authenticate
      @token = request("user.authenticate", {"user" => @username, "password" => @password})
    end

    def metric(name, options = {})
      hosts = [options.delete(:hosts) || []].flatten.map{|h|
        [h['name'], h['id']].join("-")
      }
      items = request("item.get", {
        :filter => {
          "host" => hosts[0],
          "key_" => name.to_s
        },
        "output" => "extend"
      }).map{|i| i['itemid']}

      options[:type] = case options[:type]
      when Fixnum
        options[:type]
      when :numeric
        0
      else
        nil
      end

      # Most recent last
      now = Time.now.to_i
      payload = {
        "itemids" => items[0..1],
        # FIX once we can correctly specify metric type
        "output" => "extend",
        "time_from" => options[:from] || now-3600,
        "time_till" => options[:till] || now
      }
      payload["history"] = options[:type] unless options[:type].nil?
      results = request("history.get", payload)

      Metric.new(name, results, options)
    end

    class Metric
      def initialize(name, results, opts = {})
        @name = name
        @results = results
        @opts = opts
      end

      def values
        @results.map{|r|
          case @opts[:type]
          when :numeric, 0, 3
            r['value'].to_f
          else
            r['value']
          end
        }.reverse
      end
    end

  end

end

