require "resque"

module Resque
  module Plugins
    module Locket

      # Check if a queue's jobs should be unique across workers.
      def locketed_queue?(queue)
        case
        when !locket_enabled?     then false
        when locketed_queues.nil? then true
        else                           locketed_queues.include?(queue)
        end
      end

      # List all locketed queues.
      def locketed_queues
        @locketed_queues
      end

      # Set which queues jobs should be unique across workers.
      def locketed_queues=(queues)
        @locketed_queues = queues
      end

      # Has resque-locket been enabled?
      def locket_enabled?
        @locket_enabled
      end

      # Enable locket. Set all queues to be watched, and register the after_fork hook.
      def locket!
        Resque.after_fork { |job| locket_or_requeue(job) } unless locket_enabled?

        @locket_enabled = true
      end

      # When a queue is removed, we also need to remove its lock counters and tell locket
      # to stop tracking it.
      def remove_queue(queue)
        super(queue)
        redis.hdel("locket:queue_lock_counters", queue)
      end

      # Adjust how often the job will call to redis to extend the job lock.
      def heartbeat_frequency=(seconds)
        if seconds == 0
          raise ArgumentError, "The heartbeat frequency cannot be 0 seconds"
        end

        @heartbeat_frequency = seconds
      end

      def heartbeat_frequency
        @heartbeat_frequency || 30
      end

      # Adjust how long the duration of the lock will be set to. The heartbeat should
      # refresh the lock at a rate faster than its expiration.
      def job_lock_duration=(seconds)
        if seconds == 0 || !seconds.is_a?(Integer)
          raise ArgumentError, "The job lock duration must be an integer greater than 0"
        end

        @job_lock_duration = seconds
      end

      def job_lock_duration
        @job_lock_duration || 35
      end

      # Override Resque.reserve, which a worker uses to try and obtain a job from a queue.
      # We want to short-circuit this in the event that all jobs in a queue have been
      # locked, else lower-priority queues wille experience starvation.
      def reserve(queue)
        return nil if locket_enabled? && queue_unreservable?(queue)
        super(queue)
      end

      def job_lock_key=(job_lock_proc)
        @job_lock_proc = job_lock_proc
      end

    private

      def queue_unreservable?(queue)
        locked_jobs_count = redis.hget("locket:queue_lock_counters", queue).to_i

        return false if locked_jobs_count == 0

        queue_length = size(queue)

        locked_jobs_count >= queue_length
      end

      # Check if a queue is locketed, and if so, validate the job of that queue's
      # availability for locking.
      def locket_or_requeue(job)
        return unless locketed_queue?(job.queue)

        obtain_job_lock(job) ? retain_job_lock(job) : requeue_job(job)
      end

      # If a lock doesn't exist for a job, set an expiring lock. If it does, we can't
      # obtain the lock, and this will return nil.
      def obtain_job_lock(job)
        lock_key = job_lock_key(job)

        set_expiring_key(job) unless redis.get(lock_key)
      end

      # WHEN A JOB IS LOCKED --------------------------------------------------------------------------------
      #
      # Requeue the locked job and increment our lock counter.

      def requeue_job(job)
        attach_before_perform_exception(job)
        Resque.enqueue(job.payload_class, job.args)
        increment_queue_lock(job)
      end

      def increment_queue_lock(job)
        redis.hincrby "locket:queue_lock_counters", job.queue, 1
      end

      def attach_before_perform_exception(job)
        job.payload_class.singleton_class.class_eval do
          define_method(:before_perform_raise_exception) do |*args|
            raise Resque::Job::DontPerform
          end
        end
      end

      # WHEN A JOB IS NOT LOCKED ----------------------------------------------------------------------------
      #
      # Clear our queue lock counters, begin a thread to start a heartbeat to redis that
      # will hold the lock as long as we're active, and dynamically attach an
      # after_perform hook that will manually remove the lock.

      def retain_job_lock(job)
        validate_timing
        redis.del "locket:queue_lock_counters"
        spawn_heartbeat_thread(job)
        attach_after_perform_expiration(job)
      end

      def spawn_heartbeat_thread(job)
        Thread.new do
          loop do
            sleep(heartbeat_frequency)
            set_expiring_key(job)
          end
        end
      end

      def attach_after_perform_expiration(job)
        lock_key = job_lock_key(job)

        job.payload_class.singleton_class.class_eval do
          # TODO : should we use around_perform with begin/ensure/end so we expire this on failure?
          define_method(:after_perform_remove_lock) do |*args|
            Resque.redis.del(lock_key)
          end
        end
      end

      def validate_timing
        if job_lock_duration < heartbeat_frequency
          raise "A job's heartbeat must be more frequent than its lock expiration."
        end
      end

      # INDIVIDUAL JOB LOCK CONVENIENCES --------------------------------------------------------------------
      #
      # A couple quickies to make our life easier when dealing with setting a lock for a
      # job that is currently being processed.

      def set_expiring_key(job)
        lock_key = job_lock_key(job)
        redis.setex(lock_key, job_lock_duration, "")
      end

      def job_lock_key(job)
        if @job_lock_proc
          @job_lock_proc.call(job)
        else
          "locket:job_locks:#{job.payload.to_s}"
        end
      end

    end
  end
end

Resque.send(:extend, Resque::Plugins::Locket)