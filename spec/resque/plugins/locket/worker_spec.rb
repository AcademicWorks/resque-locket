require "spec_helper.rb"

describe Resque::Plugins::Locket::Worker do

  let(:all_queues) { %w(1 2) }
  let(:worker){ Resque::Worker.new("*") }

  before(:all) { class GoodJob; def self.perform; end; end }
  before(:each){ all_queues.map { |queue| Resque.watch_queue(queue) }}
  after(:each) {
    Resque.redis.flushdb
    Resque.instance_variable_set :@locket_enabled,      nil
    Resque.instance_variable_set :@locketed_queues,     nil
    Resque.instance_variable_set :@job_lock_duration,   nil
    Resque.instance_variable_set :@job_lock_proc,       nil
    Resque.instance_variable_set :@heartbeat_frequency, nil
    Resque.after_fork = nil
  }

  describe "#reserve" do

    context "enabled" do
      before(:each) { Resque.locket! }

      it "clears the lock counter if no job can be reserved" do
        Resque.redis.hset("locket:queue_lock_counters", all_queues.first, 1)

        worker.stub(:queues).and_return([])
        worker.reserve

        Resque.redis.exists("locket:queue_lock_counters").should be_false
      end

      it "doesn't clear the lock counter if a job was reserved" do
        Resque.redis.hset("locket:queue_lock_counters", all_queues.first, 1)
        fake_job = Resque::Job.new(:jobs, "class" => "GoodJob", "args" => "stuffs")

        Resque.stub(:reserve).and_return(fake_job)
        worker.reserve

        Resque.redis.exists("locket:queue_lock_counters").should be_true
      end
    end

  end

  describe "#queues" do

    context "disabled" do
      it "returns all known queues immediately" do
        worker.should_not_receive(:locked_queues)
        worker.queues.should eq all_queues
      end
    end

    context "enabled" do
      before(:each) { Resque.locket! }

      it "returns all known queues if none are locked" do
        worker.should_receive(:locked_queues).and_call_original
        worker.queues.should eq all_queues
      end

      it "does not return a queue if its lock counter is equivalent to its size" do
        Resque.redis.hset("locket:queue_lock_counters", all_queues.first, 2)

        Resque.enqueue_to(all_queues[0], GoodJob, "stuffs")
        Resque.enqueue_to(all_queues[0], GoodJob, "more_stuffs")

        worker.queues.should eq (all_queues - [all_queues.first])
      end
    end

  end

end