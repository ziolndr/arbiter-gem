# frozen_string_literal: true
require "arbiter"

# Demonstration of The Last Conditional concept.
# Business rules, permissions, and hard limits are checked independently.
actions = {
  retry: { description: "Retry a temporarily failed card payment", run: -> { puts "retry" } },
  escalate: { description: "Escalate unresolved payment to billing", run: -> { puts "escalate" } },
  notify: { description: "Notify customer that payment could not complete", run: -> { puts "notify" } }
}

allowed = ->(id, _action) { id != :retry || ENV["ALLOW_RETRY"] == "1" }

decision = Arbiter.decide(intent: "Resolve a payment failure without charging twice", actions: actions, permitted: allowed)
puts decision.fetch(:action)
# To execute the selected action, use Arbiter.dispatch(...), which rechecks allowed.
