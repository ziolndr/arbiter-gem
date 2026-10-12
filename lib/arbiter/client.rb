# frozen_string_literal: true
require "json"
require "net/http"
require "uri"
require "open3"
require "tempfile"

module Arbiter
  class Client
    PAID_BASE_URL = "https://api.grip.fyi".freeze
    PUBLIC_BASE_URL = "https://arbiter.grip.fyi".freeze
    DEFAULT_BASE_URL = PAID_BASE_URL
    attr_reader :base_url

    def initialize(api_key: ENV["ARBITER_API_KEY"] || ENV["GRIP_API_KEY"],
                   base_url: ENV["ARBITER_BASE_URL"],
                   open_timeout: 5, read_timeout: 30, transport: nil)
      @api_key = api_key
      # Keyless compare uses the public ARBITER free-allowance route.
      # Funded/owner API keys use the GRIP gateway.
      base_url ||= (@api_key && !@api_key.empty? ? PAID_BASE_URL : PUBLIC_BASE_URL)
      @base_url = base_url.to_s.sub(%r{/+$}, "")
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      unless transport.nil? || transport == :auto || transport == :net_http || transport == :curl || transport.respond_to?(:call)
        raise InvalidInput, "transport must be :auto, :curl, :net_http, or a callable"
      end
      @transport = transport || :auto
      validate_url!
    end

    def compare(query:, candidates:, top_k: nil)
      unless query.is_a?(String) && !query.strip.empty?
        raise InvalidInput, "query must be a nonempty String"
      end
      unless candidates.is_a?(Array) && candidates.length >= 2 &&
             candidates.all? { |c| c.is_a?(String) && !c.strip.empty? }
        raise InvalidInput, "candidates must be an Array of at least two nonempty Strings"
      end
      payload = { query: query, candidates: candidates }
      unless top_k.nil?
        unless top_k.is_a?(Integer) && top_k.between?(1, candidates.length)
          raise InvalidInput, "top_k must be an Integer between 1 and candidate count"
        end
        payload[:top_k] = top_k
      end
      request("/v1/compare", payload)
    end

    def embed(texts:)
      unless texts.is_a?(Array) && !texts.empty? &&
             texts.all? { |t| t.is_a?(String) && !t.strip.empty? }
        raise InvalidInput, "texts must be a nonempty Array of nonempty Strings"
      end
      request("/v1/embed", { texts: texts })
    end

    private

    def validate_url!
      uri = URI(@base_url)
      ok = uri.scheme == "https" && uri.host && !uri.host.empty? &&
           uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      # Plain HTTP may be used only for loopback development/test endpoints.
      ok ||= uri.scheme == "http" && ["localhost", "127.0.0.1", "::1"].include?(uri.host) &&
             uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      raise InvalidInput, "base_url requires HTTPS (or loopback HTTP)" unless ok
    rescue URI::InvalidURIError
      raise InvalidInput, "base_url is invalid"
    end

    def request(path, payload)
      uri = URI("#{@base_url}#{path}")
      headers = { "content-type" => "application/json", "accept" => "application/json" }
      headers["X-API-Key"] = @api_key if @api_key && !@api_key.empty?
      body = JSON.generate(payload)
      response = if @transport.respond_to?(:call)
                   @transport.call(uri, headers, body)
                 elsif @transport == :curl || (@transport == :auto && curl_available? && known_grip_host?(uri))
                   curl_post(uri, headers, body)
                 else
                   http_post(uri, headers, body)
                 end
      status = response.code.to_i
      case status
      when 200..299
        parsed = parse_json(response.body)
        raise InvalidResponse, "ARBITER response must contain a JSON object" unless parsed.is_a?(Hash)
        parsed
      when 402
        # Do not auto-sign or spend funds. Preserve challenge for a caller-controlled payment flow.
        challenge = response.each_header.to_h.select { |key, _| key.match?(/payment|x402/i) }
        raise PaymentRequired.new("ARBITER returned HTTP 402; configure credits or handle the payment challenge", challenge: challenge)
      when 401, 403
        raise Unauthorized, "ARBITER authentication or permission failed (HTTP #{status})"
      else
        raise HTTPError.new(status, "ARBITER HTTP #{status}: #{safe_detail(response.body)}")
      end
    rescue JSON::ParserError
      raise InvalidResponse, "ARBITER returned invalid JSON"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => e
      raise HTTPError.new(0, "ARBITER transport error (#{e.class})")
    end


    # The hosted GRIP gateway has rejected some default language HTTP clients
    # at Cloudflare's browser-signature layer. Prefer curl for GRIP hosts when
    # installed; never expose the API key in process argv, files, or exception
    # text. Caller-supplied endpoints continue to use Net::HTTP by default.
    def known_grip_host?(uri)
      uri.scheme == "https" && ["api.grip.fyi", "arbiter.grip.fyi"].include?(uri.host)
    end

    def curl_available?
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |part|
        File.executable?(File.join(part, "curl"))
      end
    end

    CurlResponse = Struct.new(:code, :body, :headers) do
      def each_header(&block)
        headers.each(&block)
      end
    end

    def curl_post(uri, headers, body)
      raise HTTPError.new(0, "curl not available") unless curl_available?
      Tempfile.create("arbiter-curl-payload") do |payload_file|
        Tempfile.create("arbiter-curl-headers") do |header_file|
          Tempfile.create("arbiter-curl-output") do |output_file|
            payload_file.write(body)
            payload_file.flush
            # X-API-Key is passed via STDIN, not command line arguments.
            headers.each_value do |value|
              raise InvalidInput, "header contains a line break" if value.match?(/[\r\n]/)
            end
            config = headers.map { |key, value| %(header = "#{curl_escape(key + ': ' + value)}") }.join("\n") + "\n"
            args = ["curl", "--config", "-", "--silent", "--show-error",
                    "--connect-timeout", @open_timeout.to_s,
                    "--max-time", (@open_timeout + @read_timeout).to_s,
                    "--request", "POST", "--url", uri.to_s,
                    "--data-binary", "@#{payload_file.path}",
                    "--dump-header", header_file.path,
                    "--output", output_file.path,
                    "--write-out", "%{http_code}"]
            stdout, _stderr, status = Open3.capture3(*args, stdin_data: config)
            raise HTTPError.new(0, "ARBITER transport error (curl)") unless status.success?
            code = stdout.strip
            raise InvalidResponse, "curl returned no HTTP status" unless code.match?(/\A[1-5][0-9]{2}\z/)
            lines = header_file.read.split(/\r?\n/)
            response_headers = lines.filter_map do |line|
              next if line.start_with?("HTTP/") || !line.include?(":")
              key, value = line.split(":", 2)
              [key.downcase.strip, value.to_s.strip]
            end.to_h
            CurlResponse.new(code, output_file.read, response_headers)
          end
        end
      end
    end

    def curl_escape(value)
      value.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
    end

    def http_post(uri, headers, body)
      req = Net::HTTP::Post.new(uri)
      headers.each { |key, value| req[key] = value }
      req.body = body
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(req)
      end
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    end

    def safe_detail(body)
      obj = JSON.parse(body.to_s)
      return "request failed" unless obj.is_a?(Hash)
      detail = obj["error"] || obj["message"] || "request failed"
      detail.is_a?(String) ? detail[0, 250] : "request failed"
    rescue JSON::ParserError
      "request failed"
    end
  end
end
