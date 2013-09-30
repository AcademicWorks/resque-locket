require "resque"

require "resque/plugins/locket/version"
require "resque/plugins/locket/locket"
require "resque/plugins/locket/worker"

Resque.send(:extend, Resque::Plugins::Locket)
Resque::Worker.send(:include, Resque::Plugins::Locket::Worker)