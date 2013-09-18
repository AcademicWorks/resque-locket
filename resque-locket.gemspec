# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'resque/plugins/locket/version'

Gem::Specification.new do |spec|
  spec.name          = "resque-locket"
  spec.version       = Resque::Plugins::Locket::VERSION
  spec.authors       = ["Joshua Cody"]
  spec.email         = ["josh@joshuacody.net"]
  spec.summary       = "A Resque plugin to ensure unique workers while preventing queue starvation"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "resque"

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "pry"
end
