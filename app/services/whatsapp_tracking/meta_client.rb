# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module WhatsappTracking
  class MetaClient
    GRAPH_HOST = 'graph.facebook.com'
    GRAPH_VERSION = 'v25.0'
    MAX_RECEIPT_BYTES = 16_384

    def initialize(dataset_id:, token:)
      raise ArgumentError, 'invalid dataset id' unless /\A[0-9]{1,30}\z/.match?(dataset_id)
      raise ArgumentError, 'missing Meta credential' if token.to_s.empty?

      @uri = URI::HTTPS.build(host: GRAPH_HOST, path: "/#{GRAPH_VERSION}/#{dataset_id}/events")
      @token = token
    end

    # The outbox must claim the event before calling this method.
    def deliver(event, test_code: nil)
      request = Net::HTTP::Post.new(@uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      body = { data: [event] }
      body[:test_event_code] = test_code if test_code
      request.body = JSON.generate(body)

      Net::HTTP.start(@uri.host, @uri.port, nil, use_ssl: true, open_timeout: 5, read_timeout: 10,
                                                              write_timeout: 5, max_retries: 0) do |http|
        parsed_receipt = nil
        http.request(request) { |response| parsed_receipt = parse_response(response) }
        parsed_receipt
      end
    rescue Net::OpenTimeout, SocketError, Errno::ECONNREFUSED
      { status: :retryable, http_status: nil }
    rescue Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::ProtocolError
      { status: :uncertain, http_status: nil }
    end

    private

    def parse_response(response)
      http_status = response.code.to_i
      content = String.new
      response.read_body do |chunk|
        return receipt(http_status, {}) if content.bytesize + chunk.bytesize > MAX_RECEIPT_BYTES

        content << chunk
      end
      parsed = JSON.parse(content)
      receipt(http_status, parsed.is_a?(Hash) ? parsed : {})
    rescue JSON::ParserError
      receipt(http_status, {})
    end

    def receipt(http_status, body)
      error = body['error']
      {
        status: disposition(http_status, body),
        http_status: http_status,
        error_code: integer_field(error, 'code'),
        error_subcode: integer_field(error, 'error_subcode')
      }
    end

    def disposition(http_status, body)
      return :accepted if (200..299).cover?(http_status) && body['events_received'] == 1
      return :retryable if http_status == 429
      return :uncertain if (200..299).cover?(http_status) || http_status == 408 || http_status >= 500

      :rejected
    end

    def integer_field(object, key)
      return unless object.is_a?(Hash)

      value = object[key]
      value if value.is_a?(Integer)
    end
  end
end
