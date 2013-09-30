require "spec_helper.rb"

describe Resque::Plugins::Locket do

  after(:each) {
    Resque.redis.flushdb
    Resque.instance_variable_set :@locket_enabled,      nil
    Resque.instance_variable_set :@locketed_queues,     nil
    Resque.instance_variable_set :@job_lock_duration,   nil
    Resque.instance_variable_set :@job_lock_proc,       nil
    Resque.instance_variable_set :@heartbeat_frequency, nil
    Resque.after_fork = nil
  }

  it "passes the plugin linter" do
    Resque::Plugin.lint(Resque::Plugins::Locket)
  end

  context "#locket_enabled?" do

    it "is false by default" do
      Resque.locket_enabled?.should be_false
    end

    it "is true when resque-locket has been manually enabled" do
      Resque.locket!
      Resque.locket_enabled?.should be_true
    end

  end

  context "not enabled" do
    context "#locketed_queue?" do
      it "returns false" do
        Resque.locketed_queue?("5").should be_false
      end
    end
  end

  context "enabled" do
    let(:all_queues) { %w(1 2 3 4 5) }
    before(:each) do
      all_queues.map { |queue| Resque.watch_queue(queue) }
      Resque.locket!
    end

    context "#heartbeat_frequency" do
      it "has a default value that can be overridden" do
        Resque.heartbeat_frequency.should_not be_nil
        Resque.heartbeat_frequency = 30
        Resque.heartbeat_frequency.should be 30
      end

      it "validates a heartbeat frequency is set" do
        expect { Resque.heartbeat_frequency = 0 }.to raise_exception
      end
    end

    context "#job_lock_duration" do
      it "has a default value that can be overridden" do
        Resque.job_lock_duration.should_not be_nil
        Resque.job_lock_duration = 30
        Resque.job_lock_duration.should be 30
      end

      it "validates a job lock expiration is set" do
        expect { Resque.job_lock_duration = 0 }.to raise_exception
        expect { Resque.job_lock_duration = 4.3 }.to raise_exception
      end
    end

    context "#job_lock_key" do
      it "takes a proc that will be evaluated to determine the job lock key" do
        Resque.job_lock_key = Proc.new { |job| job.payload_class_name }

        my_job = Resque::Job.new(:jobs, "class" => "GoodJob", "args" => "stuffs")

        Resque.send(:job_lock_key, my_job).should eq "GoodJob"
      end
    end

    context "#locketed_queues" do
      it "accepts a list of queues that should be locked" do
        locked_queues = %w(1 2 3)
        Resque.locketed_queues = locked_queues
        Resque.locketed_queues.should eq locked_queues
      end
    end

    context "#locketed_queue?" do
      it "returns true if locketed_queues were not set" do
        Resque.locketed_queue?("5").should be_true
      end

      it "knows when a queue was manually locketed" do
        Resque.locketed_queues = %w(1 2)
        Resque.locketed_queue?("1").should be_true
      end

      it "knows when a queue was not manually locketed" do
        Resque.locketed_queues = %w(1 2 3)
        Resque.locketed_queue?("5").should be_false
      end
    end

    context "#remove_queue" do
      it "removes the queue" do
        Resque.remove_queue(all_queues.first)

        Resque.redis.smembers(:queues).should_not include(all_queues.first)
      end

      it "removes the locked job counter for a given queue" do
        Resque.redis.hincrby "locket:queue_lock_counters", all_queues.first, 1

        Resque.remove_queue(all_queues.first)

        Resque.redis.hexists("locket:queue_lock_counters", all_queues.first).should be_false
      end
    end

    context "#locket!" do
      it "only registers a single after_fork hook" do
        Resque.locket!
        Resque.locket!
        Resque.locket!
        Resque.locket!

        job    = Resque::Job.new(all_queues.first, {"class" => "GoodJob", "args" => "stuffs"})
        worker = Resque::Worker.new(all_queues.first)

        worker.run_hook :after_fork, job

        job.after_hooks.length.should be 1
      end
    end

    context "#after_fork" do

      context "in an unlocketed queue" do

        let(:job) { Resque::Job.new(:jobs, "class" => "BadJob", "args" => "stuffs") }
        let(:worker){ Resque::Worker.new(:jobs) }

        it "does not attempt to obtain a lock for a non-locketed queue" do
          Resque.locketed_queues = %w(1 2 3)
          Resque.should_not_receive(:obtain_job_lock)

          worker.run_hook :after_fork, job
        end

      end

      context "in a locketed queue" do

        let(:payload) { {"class" => "GoodJob", "args" => "stuffs"} }
        let(:job)     { Resque::Job.new(all_queues.first, payload) }
        let(:worker)  { Resque::Worker.new(all_queues.first) }

        before(:all) {
          class GoodJob
            @queue = "1" # TODO : hate that i have this hard-coded

            def self.perform(*args); end
          end
        }

        it "sets an expiring lock key for a job if one doesn't already exist" do
          worker.run_hook :after_fork, job

          Resque.redis.get("locket:job_locks:#{payload.to_s}").should_not be_nil
          Resque.redis.ttl("locket:job_locks:#{payload.to_s}").should be > 0
        end

        context "with an unlocked job" do

          class GoodJob; end

          before(:each){ Resque.stub(:obtain_job_lock) { true }}

          it "validates the job's heartbeat is shorter than its lock's expiration" do
            Resque.job_lock_duration   = 40
            Resque.heartbeat_frequency = 60

            expect { worker.run_hook :after_fork, job }.to raise_exception
          end

          it "destroys the locked job counter" do
            Resque.redis.hincrby "locket:queue_lock_counters", all_queues.first, 1
            Resque.redis.exists("locket:queue_lock_counters").should be_true

            worker.run_hook :after_fork, job

            Resque.redis.exists("locket:queue_lock_counters").should be_false
          end

          it "spawns a thread that extends the lock repeatedly" do
            lock_duration = 5

            Resque.heartbeat_frequency = 0.01
            Resque.job_lock_duration   = lock_duration

            Resque.should_receive(:sleep).with(0.01).twice.and_call_original
            Resque.redis.should_receive(:setex).with("locket:job_locks:#{job.payload.to_s}", lock_duration, "").twice

            worker.run_hook :after_fork, job
            sleep(0.025)
          end

          it "deletes the lock key after the job completes" do
            Resque.redis.setex "locket:job_locks:#{payload.to_s}", 35, ""

            worker.run_hook :after_fork, job
            job.after_hooks.each { |hook| job.payload_class.send(hook, job.args || []) }

            Resque.redis.exists("locket:job_locks:#{payload.to_s}").should be_false
          end
        end

        context "with a locked job" do

          before(:each){ Resque.stub(:obtain_job_lock) { false }}

          it "doesn't actually run the job" do
            worker.run_hook :after_fork, job

            job.perform.should be_false
          end

          it "requeues a job if it cannot obtain a look for it" do
            Resque.should_receive(:enqueue).with(job.payload_class, job.args).and_call_original

            worker.run_hook :after_fork, job

            last_payload = Resque.decode(Resque.redis.rpop("queue:#{job.queue}"))

            last_payload["args"].should eq [job.args]
            last_payload["class"].should eq job.payload_class_name
          end

          it "increments a locked job counter" do
            job_2 = Resque::Job.new(all_queues.first, payload)

            Resque.redis.hget("locket:queue_lock_counters", job.queue).should be_nil

            worker.run_hook :after_fork, job
            Resque.redis.hget("locket:queue_lock_counters", job.queue).should eq "1"

            worker.run_hook :after_fork, job_2
            Resque.redis.hget("locket:queue_lock_counters", job.queue).should eq "2"
          end
        end

      end

    end

  end

end