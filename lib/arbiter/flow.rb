# frozen_string_literal: true
module Arbiter
  module Flow
    module_function

    # The caller supplies only authorized actions. A separate recheck runs just
    # before execution to catch changed permissions after measurement.
    #
    # actions: { retry: { description: 'Retry card', run: -> { ... } }, ... }
    # permitted: optional ->(name, action) { ... } policy callback
    def decide(intent:, actions:, client: Arbiter.client, permitted: nil)
      approved = validate_actions(actions, permitted)
      raise ActionNotPermitted, "at least two permitted actions required" if approved.length < 2
      descriptions = approved.values.map { |action| action.fetch(:description) }
      if descriptions.uniq.length != descriptions.length
        raise InvalidInput, "action descriptions must be unique"
      end
      raw = client.compare(query: intent, candidates: descriptions, top_k: approved.length)
      ranking = Ranking.extract(raw, descriptions)
      raise InvalidResponse, "ARBITER did not return a ranked candidate" if ranking.empty?
      id = approved.keys.fetch(ranking.first.fetch(:index))
      { action: id, ranking: ranking, raw: raw, permitted_actions: approved.keys }
    end

    def dispatch(intent:, actions:, client: Arbiter.client, permitted: nil)
      decision = decide(intent: intent, actions: actions, client: client, permitted: permitted)
      name = decision.fetch(:action)
      action = actions.fetch(name)
      # Revalidation at execution boundary. The caller's policy remains authoritative.
      if permitted && !permitted.call(name, action)
        raise ActionNotPermitted, "selected action is no longer permitted"
      end
      result = action.fetch(:run).call
      decision.merge(executed: true, value: result)
    end

    def validate_actions(actions, permitted)
      raise InvalidInput, "actions must be a Hash" unless actions.is_a?(Hash) && !actions.empty?
      unless permitted.nil? || permitted.respond_to?(:call)
        raise InvalidInput, "permitted must be a callable"
      end
      approved = {}
      actions.each do |name, action|
        unless (name.is_a?(Symbol) || name.is_a?(String)) && action.is_a?(Hash) &&
               action[:description].is_a?(String) && !action[:description].strip.empty? &&
               action[:run].respond_to?(:call)
          raise InvalidInput, "each action needs an id, description, and callable :run"
        end
        approved[name] = action if !permitted || permitted.call(name, action)
      end
      approved
    end
  end
end
