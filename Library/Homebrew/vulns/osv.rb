# typed: strict
# frozen_string_literal: true

require "json"
require "utils/curl"

module Homebrew
  module Vulns
    # Client for https://google.github.io/osv.dev/api/.
    module OSV
      API_BASE = "https://api.osv.dev/v1"
      BATCH_SIZE = 1000

      class Error < RuntimeError; end
      class ApiError < Error; end

      # POST /v1/querybatch. Returns one array of vuln hashes per input package,
      # in the same order.
      sig {
        params(packages: T::Array[{ repo_url: String, version: String }])
          .returns(T::Array[T::Array[T::Hash[String, T.untyped]]])
      }
      def self.query_batch(packages)
        return [] if packages.empty?

        results = Array.new(packages.size) { [] }

        packages.each_slice(BATCH_SIZE).with_index do |batch, batch_index|
          queries = batch.map do |pkg|
            {
              package: { name: pkg.fetch(:repo_url), ecosystem: "GIT" },
              version: pkg.fetch(:version),
            }
          end

          response = post("#{API_BASE}/querybatch", { queries: })
          Array(response["results"]).each_with_index do |result, index|
            results[(batch_index * BATCH_SIZE) + index] = Array(result["vulns"])
          end
        end

        results
      end

      # GET /v1/vulns/{id}.
      sig { params(id: String).returns(T::Hash[String, T.untyped]) }
      def self.vulnerability(id)
        get("#{API_BASE}/vulns/#{ERB::Util.url_encode(id)}")
      end

      sig { params(url: String, payload: T::Hash[T.untyped, T.untyped]).returns(T::Hash[String, T.untyped]) }
      private_class_method def self.post(url, payload)
        request(url, "--json", JSON.generate(payload), "--request", "POST")
      end

      sig { params(url: String).returns(T::Hash[String, T.untyped]) }
      private_class_method def self.get(url)
        request(url)
      end

      sig { params(url: String, extra_args: String).returns(T::Hash[String, T.untyped]) }
      private_class_method def self.request(url, *extra_args)
        result = Utils::Curl.curl_output("--fail", "--location", "--silent", *extra_args, url)
        unless result.success?
          raise ApiError, "OSV API request to #{url} failed (curl exit #{result.exit_status}): #{result.stderr}"
        end

        JSON.parse(result.stdout)
      rescue JSON::ParserError => e
        raise ApiError, "Invalid JSON from OSV API at #{url}: #{e.message}"
      end
    end
  end
end
