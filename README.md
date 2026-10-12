# ARBITER GEM

Deterministic ARBITER measurement in Ruby applications, using the remote ARBITER engine. No local ARBITER binary or model downloads.

```bash
gem install arbiter-gem
```

## Quickstart — 10 free comparisons per day

The public ARBITER endpoint advertises **10 successful measurements per day without a key**. That allowance is enforced by the service, not the gem. Free requests use `https://arbiter.grip.fyi/v1/compare`.

```ruby
require "arbiter"

Arbiter.configure(api_key: nil, base_url: "https://arbiter.grip.fyi")
results = Arbiter.rank(
  query: "Resolve a failed payment",
  candidates: ["Retry the payment", "Escalate to billing", "Notify the customer"]
)
results.each { |row| puts "#{row[:candidate]}: #{row[:score]}" }
```

For a direct HTTP trial (no Ruby required):

```bash
curl -sS https://arbiter.grip.fyi/v1/compare \
  -H 'Content-Type: application/json' \
  -d '{"query":"Resolve a failed payment","candidates":["Retry the payment","Escalate to billing","Notify the customer"]}'
```

**Free-allowance verification:** This route and policy originate from ARBITER's published CLI offering; if the live gateway returns 401, 403 or 402, check its current status before advertising the free tier as operational. No API key is needed for the published free tier.

## Funded API-key credits

For paid usage, start at https://grip.fyi and request a GRIP-issued funded API key. **A self-service key issuance or credit-pack checkout URL has not been independently verified.** Do not assume purchasing has completed until credits and a key are issued.

The working GRIP owner-access transport uses this header:

```http
X-API-Key: YOUR_GRIP_API_KEY
```

```bash
export GRIP_API_KEY="<the-key-issued-for-GRIP-credits>"
```

```ruby
require "arbiter"
Arbiter.configure(api_key: ENV.fetch("GRIP_API_KEY"), base_url: "https://api.grip.fyi")
puts Arbiter.compare(query: "Route incident", candidates: ["Escalate", "Restart service"])
```

**Rate:** advertised metered x402 charge of **$0.001 USDC per compare/embed call**. Credit-pack denominations and checkout are not confirmed in public documentation. RubyGems credentials are unrelated to API keys. The gem never signs wallet payments or authorizes spending automatically.

## API

All methods belong to the `Arbiter` module. `Arbiter.compare` and `Arbiter.embed` return decoded JSON; normalized rankings are obtained using `rank`.

```ruby
Arbiter.compare(query: "Current intent", candidates: ["A", "B"], top_k: 2)
Arbiter.embed(texts: ["A", "B"])
Arbiter.rank(query: "Current intent", candidates: ["A", "B"], top_k: 2)
```

`embed` is typically used with funded API access; verify public availability before relying on it without a key.

Actions require a `description` and callable `run`:

```ruby
actions = {
  retry: { description: "Retry the payment", run: -> { :retried } },
  escalate: { description: "Escalate to billing", run: -> { :escalated } },
  notify: { description: "Notify the customer", run: -> { :notified } }
}

allowed = ->(name, _action) { name != :retry }

# Measures only; no action is executed:
choice = Arbiter.decide(intent: "Resolve failed payment", actions: actions, permitted: allowed)
puts choice[:action]

# Explicitly executes a permitted callable, checking permission again before execution:
executed = Arbiter.dispatch(intent: "Resolve failed payment", actions: actions, permitted: allowed)
puts executed[:value]
```

`decide` and `dispatch` require **at least two permitted actions**. The application owns authorization; ranking cannot override it. `dispatch` sends another comparison request; it does not execute the earlier decision object.

## Error handling

```ruby
begin
  Arbiter.compare(query: "Resolve failed payment", candidates: ["Retry", "Escalate"])
rescue Arbiter::PaymentRequired => e
  warn "HTTP #{e.status} — obtain credits or handle the x402 challenge explicitly"
end
```

### Environment variables

- `ARBITER_API_KEY` or `GRIP_API_KEY`: optional API key, sent as `X-API-Key`.
- `ARBITER_BASE_URL`: optional override. Otherwise keyless calls use the public endpoint and authenticated calls use the GRIP API.

## Links

- Docs: https://arbiter-gem.grip.fyi
- RubyGems: https://rubygems.org/gems/arbiter-gem
- Source: https://github.com/ziolndr/arbiter-gem (requires public repository publication)
- GRIP: https://grip.fyi

## Tests

```bash
ruby -Ilib:test test/test_arbiter.rb
```

MIT © 2026 Actual General Intelligence, Inc.
