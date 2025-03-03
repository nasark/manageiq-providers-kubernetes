class ManageIQ::Providers::Kubernetes::ContainerManager::RefreshWorker::WatchThread
  include Vmdb::Logging

  HTTP_UNAUTHORIZED = 401
  HTTP_GONE         = 410

  def self.start!(ems, queue, entity_type, resource_version)
    new(ems.connect_options, ems.class, queue, entity_type, resource_version).tap(&:start!)
  end

  def initialize(connect_options, ems_klass, queue, entity_type, resource_version)
    @connect_options = connect_options
    @ems_klass       = ems_klass
    @entity_type     = entity_type
    @finish          = Concurrent::AtomicBoolean.new
    @queue           = queue

    self.resource_version = resource_version
  end

  def alive?
    thread&.alive?
  end

  def start!
    self.thread = Thread.new { collector_thread }
  end

  def stop!(join_limit = 10.seconds)
    return unless alive?

    finish.make_true
    watch&.finish
    thread&.join(join_limit)
  end

  protected

  attr_accessor :resource_version, :thread, :watch

  private

  attr_reader :connect_options, :ems_klass, :entity_type, :finish, :queue

  def collector_thread
    retry_connection = true

    while running?
      begin
        _log.debug { "Starting watch thread for #{entity_type} from version [#{resource_version}]" }
        self.watch = connection(entity_type).send("watch_#{entity_type}", :resource_version => resource_version)

        # reset the connection retry flag after a successful connection
        retry_connection = true

        watch.each do |notice|
          if notice.type == "ERROR"
            message = notice.object&.message
            code    = notice.object&.code
            reason  = notice.object&.reason

            # If we get a 410 Gone then restart with a resourceVersion of nil
            # to start over from the current state
            self.resource_version = nil if code == HTTP_GONE

            _log.warn("Received an error watching #{entity_type}: [#{code} #{reason}], [#{message}]")
            break
          end

          current_resource_version = notice.object&.metadata&.resourceVersion
          self.resource_version    = current_resource_version if current_resource_version.present?

          next if noop?(notice)

          queue.push(notice)
        end
      rescue Kubeclient::HttpError => err
        # If our authentication token has expired then restart the watch at the current
        # resource version.
        raise unless err.error_code == HTTP_UNAUTHORIZED && retry_connection

        _log.debug { "Restarting watch #{entity_type} after #{err.error_code} #{err.message}" }

        retry_connection = false
        retry
      end
    end

    _log.debug { "Exiting watch thread #{entity_type}" }
  rescue => err
    _log.error("Watch thread for #{entity_type} failed: #{err}")
    _log.log_backtrace(err)
  end

  def noop?(notice)
    notice.object&.kind == "Endpoints" && filter_endpoint?(notice.object)
  end

  def connection(_entity_type = nil)
    hostname, port = connect_options.values_at(:hostname, :port)
    connect_options[:service] ||= "kubernetes"

    ems_klass.raw_connect(hostname, port, connect_options)
  end

  def filter_endpoint?(endpoint)
    # The base kubernetes parser uses the endpoint subset addresses and targetRefs
    # to build "container_groups_refs" in order to link pods to container_services
    #
    # If an endpoint doesn't have any subsets then it is a pointless update
    endpoint.subsets.blank?
  end

  def running?
    finish.false?
  end
end
