# resque-locket

A Resque plugin to ensure unique workers while preventing queue starvation. While a job is being processed, duplicate jobs are locked from being simultaneously processed, and Locket intelligently avoids starvation in priority queueing situations.

### Usage

Here is the simplest possible Locket configuration:

    # in your Gemfile
    gem "resque-locket"

    # somewhere in your application initialization:
    Resque.unique_queues!
    Resque.locketed_queues = ["unique", "queues"] # optional configuration, and Locket defaults to all queues

Easy enough. All queues will be guaranteed unique across workers, locks will expire after 35 seconds of inactivity, while a job is working, its key will be refreshed every 30 seconds and the entire payload will be used as the lock key. In the next section, we'll introduce other options as we discuss them.

### How It Works

At a high level, before processing a job, Locket will attempt to obtain a **job lock** for said job. If it *can* obtain a lock, it will spawn a child thread that continually extends the lock while the job is being processed. If it *can't* obtain a lock, it will requeue the job and increment a **queue lock counter** to determine if all jobs in that queue are locked. If they are, that queue will be temporarily removed from the worker's queues list.

So a lock is implemented at both the job level and the queue level—if a job is being processed, it is locked. If all jobs in a queue are being processed, the queue is locked. But whether a job is locked is the starting point for both types of lock.

#### When A Job is Not Locked

When Resque forks a child process, Locket will check (in the parent process) if a lock exists in Redis for the job that's about to be processed. It will find one doesn't, then it will:

1. *Set an expiring lock for the current job.* This should be unique for a given job, and once it is put in place, if a workers attempts to perform an identical job, the lock will prevent that from being possible. Both the key name and the expiration are configurable, as detailed below, and it's the expiration that protects us in the event of a worker dying a quick death without calling its failure hooks.
2. *Destroy the queue lock queue counter.* When obtaining a lock fails, a hash key is incremented that is a counter for that queue. If the number of locked jobs reaches the queue's size, the queue is no longer fit for pulling jobs from. We have to do this in the parent process (as opposed to in an `after_*` hook in the job process) because the job process could have died abruptly and left its queue's counter in place. So when work can be done, we set right the state of the world by clearing the counter.
3. *Spawn a child thread that will continually extend the expiration of the lock key.* As shown below, this frequency is also configurable. But this serves as a heartbeat so as long as a Resque process lives and performs a job, its lock is continually extended.
4. *Attach `after_perform` and `after_failure` [hooks](https://github.com/resque/resque/blob/master/docs/HOOKS.md) to clean up after the job.* These will destroy a job's lock and the queue lock counter upon completion of a job, which ensures a new identical job could be processed quickly and that a queue will not remain locked if a job from a locked queue completes and its queue grows before jobs from unlocked queues are performed.

Knowing what we know now, we can discuss new configuration options:

    # how often the spawned child thread will extend the lock key
    Resque.heartbeat_frequency = 30

    # how long the lock key will remain good for in the absence of explicit extension/deletion
    Resque.job_lock_duration = 35

    # a proc that will be passed the job to create the key that will be used as the lock for
    # a job. the default is the entire payload, but let's say you inserted a timestamp in your
    # payload that was the start time of a job. you'd need to exclude this from your lock, as
    # that would result in every lock being unique, and no lock check would ever return false
    Resque.job_lock_key = Proc.new { |job| "locket:job_locks:#{job.payload.to_s}" }

#### When a Job is Locked

The process is much simpler if Locket cannot obtain a lock for a job.

1. *The job is requeued.* Fairly obvious, we don't want lost jobs.
2. *A lock counter is increased for that queue.* A hash key is incremented that tracks the number of locked jobs in a queue.

That lock counter works in tandem with another mechanism for determining what a worker should do next:

When a worker attempts to pull a job off of the queues it is watching, it will first do a simple operation: check the queue lock counter hash, and if that queue's count is equal to or greater than its length, skip it.

This prevents lower-priority queues from being starved, but it also means a queue could be locked, the job that caused the queue lock could abruptly die, and the lock would remain in place without clearing the counter hash. So any time no job can be reserved, we go ahead and and clear the queue lock counter.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
