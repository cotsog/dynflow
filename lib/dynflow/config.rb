# frozen_string_literal: true
require 'socket'

module Dynflow
  class Config
    include Algebrick::TypeCheck

    def self.config_attr(name, *types, &default)
      self.send(:define_method, "validate_#{ name }!") do |value|
        Type! value, *types unless types.empty?
      end
      self.send(:define_method, name) do
        var_name = "@#{ name }"
        if instance_variable_defined?(var_name)
          return instance_variable_get(var_name)
        else
          return default
        end
      end
      self.send(:attr_writer, name)
    end

    class ForWorld
      attr_reader :world, :config

      def initialize(config, world)
        @config = config
        @world  = world
        @cache  = {}
      end

      def validate
        @config.validate(self)
      end

      def queues
        @queues ||= @config.queues.finalized_config(self)
      end

      def method_missing(name)
        return @cache[name] if @cache.key?(name)
        value = @config.send(name)
        value = value.call(@world, self) if value.is_a? Proc
        validation_method = "validate_#{ name }!"
        @config.send(validation_method, value) if @config.respond_to?(validation_method)
        @cache[name] = value
      end
    end

    class QueuesConfig
      attr_reader :queues

      def initialize
        @queues = {:default => {}}
      end

      # Add a new queue to the configuration
      #
      # @param [Hash] queue_options
      # @option queue_options :pool_size The amount of workers available for the queue.
      #   By default, it uses global pool_size config option.
      def add(name, queue_options = {})
        Utils.validate_keys!(queue_options, :pool_size)
        name = name.to_sym
        raise ArgumentError, "Queue #{name} is already defined" if @queues.key?(name)
        @queues[name] = queue_options
      end

      def finalized_config(config_for_world)
        @queues.values.each do |queue_options|
          queue_options[:pool_size] ||= config_for_world.pool_size
        end
        @queues
      end
    end

    def queues
      @queues ||= QueuesConfig.new
    end

    config_attr :logger_adapter, LoggerAdapters::Abstract do
      LoggerAdapters::Simple.new
    end

    config_attr :transaction_adapter, TransactionAdapters::Abstract do
      TransactionAdapters::None.new
    end

    config_attr :persistence_adapter, PersistenceAdapters::Abstract do
      PersistenceAdapters::Sequel.new('sqlite:/')
    end

    config_attr :coordinator_adapter, CoordinatorAdapters::Abstract do |world|
      CoordinatorAdapters::Sequel.new(world)
    end

    config_attr :pool_size, Integer do
      5
    end

    config_attr :executor do |world, config|
      Executors::Parallel::Core
    end

    def validate_executor!(value)
      accepted_executors = [Executors::Parallel::Core]
      accepted_executors << Executors::Sidekiq::Core if defined? Executors::Sidekiq::Core
      if value && !accepted_executors.include?(value)
        raise ArgumentError, "Executor #{value} is expected to be one of #{accepted_executors.inspect}"
      end
    end

    # does the work represent some process-wide role (important for sidekiq-based deployments)
    config_attr :process_role do |world, config|
      nil
    end

    def validate_process_role(value)
      accepted_roles = [:orchestrator, :worker]
      if value && !accepted_roles.include?(value)
        raise ArgumentError, "Process role #{value} is expected to be one of #{accepted_roles.inspect}"
      end
    end

    config_attr :executor_semaphore, Semaphores::Abstract, FalseClass do |world, config|
      Semaphores::Dummy.new
    end

    config_attr :executor_heartbeat_interval, Integer do
      15
    end

    config_attr :ping_cache_age, Integer do
      60
    end

    config_attr :connector, Connectors::Abstract do |world|
      Connectors::Direct.new(world)
    end

    config_attr :auto_rescue, Algebrick::Types::Boolean do
      true
    end

    config_attr :auto_validity_check, Algebrick::Types::Boolean do |world, config|
      !!config.executor
    end

    config_attr :validity_check_timeout, Numeric do
      30
    end

    config_attr :exit_on_terminate, Algebrick::Types::Boolean do
      true
    end

    config_attr :auto_terminate, Algebrick::Types::Boolean do
      true
    end

    config_attr :termination_timeout, Numeric do
      60
    end

    config_attr :auto_execute, Algebrick::Types::Boolean do
      true
    end

    config_attr :silent_dead_letter_matchers, Array do
      # By default suppress dead letters sent by Clock
      [
        DeadLetterSilencer::Matcher.new(::Dynflow::Clock)
      ]
    end

    config_attr :delayed_executor, DelayedExecutors::Abstract, NilClass do |world|
      options = { :poll_interval => 15,
                  :time_source => -> { Time.now.utc } }
      DelayedExecutors::Polling.new(world, options)
    end

    config_attr :throttle_limiter, ::Dynflow::ThrottleLimiter do |world|
      ::Dynflow::ThrottleLimiter.new(world)
    end

    config_attr :execution_plan_cleaner, ::Dynflow::Actors::ExecutionPlanCleaner, NilClass do |world|
      nil
    end

    config_attr :action_classes do
      Action.all_children
    end

    config_attr :meta do |world, config|
      { 'hostname' => Socket.gethostname, 'pid' => Process.pid }
    end

    config_attr :backup_deleted_plans, Algebrick::Types::Boolean do
      false
    end

    config_attr :backup_dir, String, NilClass do
      './backup'
    end

    config_attr :telemetry_adapter, ::Dynflow::TelemetryAdapters::Abstract do |world|
      ::Dynflow::TelemetryAdapters::Dummy.new
    end

    def validate(config_for_world)
      if defined? ::ActiveRecord::Base
        begin
          ar_pool_size = ::ActiveRecord::Base.connection_pool.instance_variable_get(:@size)
          if (config_for_world.pool_size / 2.0) > ar_pool_size
            config_for_world.world.logger.warn 'Consider increasing ActiveRecord::Base.connection_pool size, ' +
                                               "it's #{ar_pool_size} but there is #{config_for_world.pool_size} " +
                                               'threads in Dynflow pool.'
          end
        rescue ActiveRecord::ConnectionNotEstablished # rubocop:disable Lint/HandleExceptions
          # If in tests or in an environment where ActiveRecord doesn't have a
          # real DB connection, we want to skip AR configuration altogether
        end
      end
    end
  end
end
