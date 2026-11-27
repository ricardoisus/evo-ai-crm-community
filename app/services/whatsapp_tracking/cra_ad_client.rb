# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module WhatsappTracking
  class CraAdClient
    ACCOUNT_ID = '1645900983590550'
    ID = /\A[0-9]{1,30}\z/
    FIELDS = 'id,name,account_id,effective_status,adset{id,name,optimization_goal,destination_type,targeting{publisher_platforms}},' \
             'campaign{id,name,objective},creative{id,name,object_type,instagram_permalink_url}'
    IG_PERMALINK = %r{\Ahttps://(?:www\.)?instagram\.com/[A-Za-z0-9_./-]{1,200}\z}

    def initialize(token:)
      @token = token
    end

    def fetch(ad_id)
      raise ArgumentError, 'invalid CRA ad ID' unless ID.match?(ad_id) && @token.present?

      uri = URI::HTTPS.build(host: MetaClient::GRAPH_HOST, path: "/#{MetaClient::GRAPH_VERSION}/#{ad_id}",
                             query: URI.encode_www_form(fields: FIELDS))
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{@token}"
      Net::HTTP.start(uri.host, uri.port, nil, use_ssl: true, open_timeout: 5, read_timeout: 10, write_timeout: 5, max_retries: 0) do |http|
        receipt = nil
        http.request(request) { |response| receipt = parse(response, ad_id) }
        receipt
      end
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::ProtocolError
      { status: 'retry', cooldown: false }
    end

    private

    def parse(response, ad_id)
      code = response.code.to_i
      data = +''
      response.read_body do |chunk|
        return { status: 'retry', cooldown: true } if data.bytesize + chunk.bytesize > 32_768

        data << chunk
      end
      body = JSON.parse(data)
      return { status: 'retry', cooldown: true } unless body.is_a?(Hash)

      error = body['error'].is_a?(Hash) ? body['error']['code'] : nil
      cooldown = usage_limit?(response) || code == 429 || [4, 17, 32, 613, 80_004].include?(error)
      return success(body, ad_id).merge(cooldown: cooldown) if code == 200
      return { status: 'not_found', cooldown: cooldown } if code == 404 || error == 100
      return { status: 'forbidden', cooldown: cooldown } if code == 403 || [10, 190, 200].include?(error)

      { status: 'retry', cooldown: cooldown }
    rescue JSON::ParserError
      { status: 'retry', cooldown: true }
    end

    def success(body, ad_id)
      return { status: 'conflict' } unless body['id'] == ad_id && body['account_id'] == ACCOUNT_ID

      adset = body['adset']
      campaign = body['campaign']
      return { status: 'retry' } unless adset.is_a?(Hash) && campaign.is_a?(Hash)
      return { status: 'retry' } unless [adset['id'], campaign['id']].all? { |id| id.is_a?(String) && ID.match?(id) }
      return { status: 'retry' } unless [body['name'], adset['name'], campaign['name']].all? { |name| safe_string(name) }

      resolution = { 'ad_id' => ad_id, 'ad_name' => body['name'], 'adset_id' => adset['id'], 'adset_name' => adset['name'],
                     'campaign_id' => campaign['id'], 'campaign_name' => campaign['name'] }
      { status: 'resolved', resolution: resolution.merge(optional_fields(body, adset, campaign)) }
    end

    def optional_fields(body, adset, campaign)
      creative = body['creative'].is_a?(Hash) ? body['creative'] : {}
      targeting = adset['targeting'].is_a?(Hash) ? adset['targeting'] : {}
      platforms = Array(targeting['publisher_platforms']).grep(/\A[a-z_]{1,30}\z/).join(',')
      permalink = creative['instagram_permalink_url']
      creative_id = creative['id']
      {
        'campaign_objective' => safe_string(campaign['objective'], 60), 'adset_destination' => safe_string(adset['destination_type'], 60),
        'adset_goal' => safe_string(adset['optimization_goal'], 60), 'ad_status' => safe_string(body['effective_status'], 40),
        'creative_id' => creative_id.is_a?(String) && ID.match?(creative_id) ? creative_id : nil,
        'creative_name' => safe_string(creative['name']), 'creative_type' => safe_string(creative['object_type'], 40),
        'creative_link' => permalink.is_a?(String) && IG_PERMALINK.match?(permalink) ? permalink : nil,
        'platforms' => safe_string(platforms, 100)
      }.compact
    end

    def safe_string(value, max = 255)
      value if value.is_a?(String) && value.length.between?(1, max) && !/[\x00-\x1f\x7f]/.match?(value)
    end

    def usage_limit?(response)
      %w[x-app-usage x-ad-account-usage x-business-use-case-usage].any? do |header|
        value = response[header]
        value && usage_high?(JSON.parse(value))
      end
    rescue JSON::ParserError
      true
    end

    def usage_high?(entry)
      case entry
      when Array then entry.any? { |value| usage_high?(value) }
      when Hash
        entry.any? do |key, value|
          (key.match?(/call_count|total_cputime|total_time|acc_id_util_pct/) && (Float(value, exception: false) || 0) >= 90) || usage_high?(value)
        end
      else false
      end
    end
  end
end
