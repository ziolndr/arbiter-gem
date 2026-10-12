# frozen_string_literal: true
require "minitest/autorun"
require "json"
require "stringio"
require "socket"
require_relative "../lib/arbiter"

class TestArbiter < Minitest::Test
  class FakeResponse
    attr_reader :code, :body
    def initialize(code, body, headers = {})
      @code, @body, @headers = code.to_s, body, headers
    end
    def each_header(&block)
      @headers.each(&block)
    end
  end

  def setup
    @requests = []
    @response = FakeResponse.new(200, JSON.generate({ "results" => [
      { "candidate" => "Escalate", "score" => 0.6 },
      { "candidate" => "Retry", "score" => 0.4 }
    ] }))
    @client = Arbiter::Client.new(api_key: "test-token", transport: ->(url, headers, body) {
      @requests << {url: url.to_s, headers: headers, body: JSON.parse(body)}
      @response
    })
  end

  def test_compare_sends_canonical_query_and_field
    response = @client.compare(query: "payment failed", candidates: ["Retry", "Escalate"], top_k: 2)
    assert_equal "Escalate", response.dig("results", 0, "candidate")
    assert_equal "https://api.grip.fyi/v1/compare", @requests.first[:url]
    assert_equal({"query"=>"payment failed", "candidates"=>["Retry", "Escalate"], "top_k"=>2}, @requests.first[:body])
    assert_equal "test-token", @requests.first[:headers]["X-API-Key"]
    refute @requests.first[:headers].key?("authorization")
  end

  def test_keyless_uses_public_route
    client = Arbiter::Client.new(api_key: nil, transport: ->(url, headers, body) {
      @requests << {url: url.to_s, headers: headers, body: JSON.parse(body)}
      @response
    })
    client.compare(query: "payment failed", candidates: ["Retry", "Escalate"])
    assert_equal "https://arbiter.grip.fyi/v1/compare", @requests.first.fetch(:url)
    refute @requests.first.fetch(:headers).key?("X-API-Key")
  end


  def test_curl_transport_sends_key_and_returns_json
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = Queue.new
    worker = Thread.new do
      conn = server.accept
      begin
        header = +""
        while (line = conn.gets)
          header << line
          break if line == "\r\n"
        end
        content_length = header[/content-length:\s*(\d+)/i, 1].to_i
        body = conn.read(content_length)
        captured << [header, body]
        reply = '{"results":[{"candidate":"Escalate","score":0.6},{"candidate":"Retry","score":0.4}]}'
        conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
      ensure
        conn.close
      end
    end
    client = Arbiter::Client.new(api_key: "secret-key", base_url: "http://127.0.0.1:#{port}", transport: :curl)
    response = client.compare(query: "failed payment", candidates: ["Retry", "Escalate"])
    assert_equal "Escalate", response["results"][0]["candidate"]
    header, data = captured.pop
    assert_match(/x-api-key: secret-key/i, header)
    refute_match(/authorization: bearer/i, header)
    assert_equal "failed payment", JSON.parse(data)["query"]
  ensure
    worker&.join(2)
    worker&.kill if worker&.alive?
    server&.close
  end

  def test_embed_sends_texts_array
    @response = FakeResponse.new(200, '{"vectors":[]}')
    @client.embed(texts: ["first", "second"])
    assert_equal "https://api.grip.fyi/v1/embed", @requests.first[:url]
    assert_equal ["first", "second"], @requests.first[:body]["texts"]
  end

  def test_input_failures_do_not_hit_network
    assert_raises(Arbiter::InvalidInput) { @client.compare(query: "", candidates: ["a", "b"]) }
    assert_raises(Arbiter::InvalidInput) { @client.compare(query: "test", candidates: ["a"]) }
    assert_raises(Arbiter::InvalidInput) { @client.compare(query: "test", candidates: ["a", "b"], top_k: 3) }
    assert_raises(Arbiter::InvalidInput) { @client.embed(texts: ["ok", ""]) }
    assert_empty @requests
  end

  def test_402_preserves_challenge_but_never_pays
    @response = FakeResponse.new(402, '{"error":"payment required"}', {"payment-required"=>"challenge", "server"=>"cloudflare"})
    error = assert_raises(Arbiter::PaymentRequired) { @client.compare(query: "q", candidates: ["A", "B"]) }
    assert_equal 402, error.status
    assert_equal({"payment-required" => "challenge"}, error.challenge)
    assert_equal 1, @requests.length
  end

  def test_unauthorized_does_not_echo_secrets
    @response = FakeResponse.new(401, '{"error":"test-token rejected"}')
    error = assert_raises(Arbiter::Unauthorized) { @client.compare(query: "q", candidates: ["A", "B"]) }
    refute_includes error.message, "test-token"
  end

  def test_unknown_shape_fails_closed
    assert_raises(Arbiter::InvalidResponse) { Arbiter::Ranking.extract({"data"=>[]}, ["Retry", "Escalate"]) }
  end

  def test_number_scores_order_descending_preserves_index
    ranking = Arbiter::Ranking.extract({"scores" => [0.2, 0.8, 0.8]}, %w[A B C])
    assert_equal %w[B C A], ranking.map { |i| i.fetch(:candidate) }
  end

  def test_decide_does_not_execute_actions
    ran = []
    actions = {
      retry: {description: "Retry", run: -> { ran << :retry }},
      escalate: {description: "Escalate", run: -> { ran << :escalate }}
    }
    decision = Arbiter::Flow.decide(intent: "payment failed", actions: actions, client: @client)
    assert_equal :escalate, decision.fetch(:action)
    assert_empty ran
  end

  def test_dispatch_executes_only_returned_action
    ran = []
    actions = {
      retry: {description: "Retry", run: -> { ran << :retry; "retried" }},
      escalate: {description: "Escalate", run: -> { ran << :escalate; "sent" }}
    }
    decision = Arbiter::Flow.dispatch(intent: "payment failed", actions: actions, client: @client)
    assert_equal :escalate, decision.fetch(:action)
    assert_equal "sent", decision.fetch(:value)
    assert_equal [:escalate], ran
  end

  def test_dispatch_rechecks_authorization_at_commit_boundary
    ran = []
    checks = 0
    allowed = ->(_name, _action) { checks += 1; checks < 3 }
    actions = {
      retry: {description: "Retry", run: -> { ran << :retry }},
      escalate: {description: "Escalate", run: -> { ran << :escalate }}
    }
    assert_raises(Arbiter::ActionNotPermitted) do
      Arbiter::Flow.dispatch(intent: "payment failed", actions: actions, client: @client, permitted: allowed)
    end
    assert_empty ran
  end

  def test_duplicate_descriptions_fail_before_network
    actions = { a: {description: "Same", run: -> {}}, b: {description: "Same", run: -> {}} }
    assert_raises(Arbiter::InvalidInput) { Arbiter::Flow.decide(intent: "q", actions: actions, client: @client) }
    assert_empty @requests
  end

  def test_unrecognized_candidate_is_not_executed
    @response = FakeResponse.new(200, JSON.generate({"ranking" => [{"candidate" => "Something else", "score"=>9}]}))
    actions = { a: {description: "Retry", run: -> {raise "bad"}}, b: {description: "Escalate", run: -> {raise "bad"}} }
    assert_raises(Arbiter::InvalidResponse) { Arbiter::Flow.dispatch(intent: "q", actions: actions, client: @client) }
  end

  def test_rejects_unsafe_base_url
    assert_raises(Arbiter::InvalidInput) { Arbiter::Client.new(base_url: "http://example.com") }
    assert_raises(Arbiter::InvalidInput) { Arbiter::Client.new(base_url: "https://user:pass@example.com") }
    assert_equal "http://127.0.0.1:8000", Arbiter::Client.new(base_url: "http://127.0.0.1:8000").base_url
  end
end
