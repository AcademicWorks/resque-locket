module Resque
  module Plugins
    module Locket
      module Worker

        def self.included(receiver)
          receiver.class_eval do
            alias queues_without_lock queues
            alias queues queues_with_lock

            alias reserve_and_clear_without_counter reserve
            alias reserve reserve_and_clear_counter
          end
        end

        # overwrite our original queues method with a new method that will check which
        # of said queues were locked and not reserve jobs from those
        def queues_with_lock
          return queues_without_lock unless Resque.locket_enabled?

          queues_without_lock - locked_queues
        end

        def reserve_and_clear_counter
          return reserve_and_clear_without_counter unless Resque.locket_enabled?

          job = reserve_and_clear_without_counter

          redis.del("locket:queue_lock_counters") if job == nil

          job
        end

      private

        def locked_queues
          locked_queues = Resque.redis.hkeys("locket:queue_lock_counters")

          return [] if locked_queues.nil?

          locked_queues.to_a.map do |key|
            locked_count = Resque.redis.hget("locket:queue_lock_counters", key).to_i
            queue_size   = Resque.size(key)

            key if locked_count >= queue_size
          end.compact
        end

      end
    end
  end
end