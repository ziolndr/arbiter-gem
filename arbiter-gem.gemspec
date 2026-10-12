# frozen_string_literal: true
require_relative "lib/arbiter/version"

Gem::Specification.new do |spec|
  spec.name          = "arbiter-gem"
  spec.version       = Arbiter::VERSION
  spec.authors       = ["Actual General Intelligence, Inc."]
  spec.summary       = "Deterministic decision, ranking and action selection in Ruby; ARBITER API, MCP and x402"
  spec.description   = "Measure and rank candidate actions with the ARBITER API from Ruby. Includes compare, embed, rank, decide and dispatch; MCP interoperability and x402 payment challenges. No native engine."
  spec.homepage      = "https://arbiter-gem.grip.fyi"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ziolndr/arbiter-gem"
  spec.metadata["documentation_uri"] = "https://arbiter-gem.grip.fyi/#methods"
  spec.metadata["changelog_uri"] = "https://github.com/ziolndr/arbiter-gem/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/ziolndr/arbiter-gem/issues"
end
