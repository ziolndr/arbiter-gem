# frozen_string_literal: true
module Arbiter
  # Normalizes only unambiguous score/ranking data. Unknown response formats raise.
  # Raw compare() responses remain available without normalization.
  module Ranking
    module_function

    def extract(response, candidates)
      raise InvalidResponse, "response must be a Hash" unless response.is_a?(Hash)
      raise InvalidInput, "candidate strings must be unique for ranking" unless candidates.uniq.length == candidates.length

      # Some integrations wrap the API body in { "result" => {...} }.
      body = response["result"].is_a?(Hash) ? response["result"] : response

      ["results", "ranking", "ranked", "ranked_candidates", "matches"].each do |field|
        next unless body[field].is_a?(Array)
        ranking = from_items(body[field], candidates)
        return ranking if ranking
      end
      if body["scores"].is_a?(Array) && body["scores"].length == candidates.length &&
         body["scores"].all? { |score| numeric?(score) }
        return candidates.each_with_index.map { |candidate, i| row(candidate, i, Float(body["scores"][i])) }
                         .sort_by { |item| [-item[:score], item[:index]] }
      end
      raise InvalidResponse, "unrecognized ARBITER ranking response; inspect raw compare() result"
    end

    def from_items(items, candidates)
      return nil if items.empty?
      used = {}
      rows = items.map do |item|
        idx, score = case item
                     when Hash
                       index = item["index"] || item["candidate_index"]
                       label = item["candidate"] || item["text"] || item["value"]
                       index = candidates.index(label) if index.nil? && label.is_a?(String)
                       [index, item["score"] || item["resonance"]]
                     when String
                       [candidates.index(item), nil]
                     when Integer
                       [item, nil]
                     else
                       return nil
                     end
        return nil unless idx.is_a?(Integer) && idx.between?(0, candidates.length - 1)
        return nil if used[idx]
        return nil unless score.nil? || numeric?(score)
        used[idx] = true
        row(candidates[idx], idx, score.nil? ? nil : Float(score))
      end
      # Prefer API order if it supplies ordered items; never re-sort returned rankings.
      rows
    end

    def row(candidate, index, score)
      { candidate: candidate, index: index, score: score }
    end

    def numeric?(value)
      (value.is_a?(Numeric) || value.is_a?(String)) && Float(value).finite?
    rescue ArgumentError, TypeError
      false
    end
  end
end
