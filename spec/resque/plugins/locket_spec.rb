require "spec_helper.rb"

describe Resque::Plugins::Locket do

  class JobLoblaw

  end

  it "should pass the plugin linter" do
    Resque::Plugin.lint(Resque::Plugins::Locket)
  end

  it "sets an expiring lock key before dequeueing a job" do

  end

  context "when a job is locked" do

    it "increments a locked job counter"

    it "requeues the job"

    it "moves to the next queue if all jobs in that queue are locked"

  end

  context "when a job is not locked" do

    it "destroys the locked job counter"

    context "a child process" do

      it "extends the expiring lock key every 30 seconds"

    end

    it "deletes the lock key after the job completes"

  end

end