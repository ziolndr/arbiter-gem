# frozen_string_literal: true
module Arbiter
  class Error < StandardError; end
  class InvalidInput < Error; end
  class InvalidResponse < Error; end
  class Unauthorized < Error; end
  class PaymentRequired < Error
    attr_reader :status, :challenge
    def initialize(message = "ARBITER payment required", challenge: {})
      @status = 402
      @challenge = challenge.freeze
      super(message)
    end
  end
  class HTTPError < Error
    attr_reader :status
    def initialize(status, message)
      @status = status
      super(message)
    end
  end
  class ActionNotPermitted < Error; end
end
