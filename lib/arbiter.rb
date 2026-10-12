# frozen_string_literal: true
require_relative "arbiter/version"
require_relative "arbiter/errors"
require_relative "arbiter/client"
require_relative "arbiter/ranking"
require_relative "arbiter/flow"

module Arbiter
  class << self
    attr_writer :client

    def client
      @client ||= Client.new
    end

    def configure(**settings)
      self.client = Client.new(**settings)
    end

    def compare(**args)
      client.compare(**args)
    end

    def embed(**args)
      client.embed(**args)
    end

    def rank(query:, candidates:, top_k: nil)
      response = compare(query: query, candidates: candidates, top_k: top_k)
      Ranking.extract(response, candidates)
    end

    def decide(**args)
      Flow.decide(**args)
    end

    def dispatch(**args)
      Flow.dispatch(**args)
    end
  end
end
