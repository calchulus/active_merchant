begin
  require "oauth"
rescue LoadError
  raise "You need to have the oauth gem installed in order to use the ActiveMerchant QuickbooksGateway adapter."
end

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class QuickbooksGateway < Gateway
      self.test_url = 'https://sandbox.api.intuit.com'
      self.live_url = 'https://api.intuit.com'

      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover, :diners]

      self.homepage_url = 'http://payments.intuit.com'
      self.display_name = 'QuickBooks Payments'
      ENDPOINT =  "/quickbooks/v4/payments/charges"
      OAUTH_ENDPOINTS = {
        site: 'https://oauth.intuit.com',
        request_token_path: '/oauth/v1/get_request_token',
        authorize_url: 'https://appcenter.intuit.com/Connect/Begin',
        access_token_path: '/oauth/v1/get_access_token'
      }

      # https://developer.intuit.com/docs/0150_payments/0300_developer_guides/error_handling

      STANDARD_ERROR_CODE_MAPPING = {
        # Fraud Warnings
        'PMT-1000' => STANDARD_ERROR_CODE[:processing_error],   # payment was accepted, but refund was unsuccessful
        'PMT-1001' => STANDARD_ERROR_CODE[:invalid_cvc],        # payment processed, but cvc was invalid
        'PMT-1002' => STANDARD_ERROR_CODE[:incorrect_address],  # payment processed, incorrect address info
        'PMT-1003' => STANDARD_ERROR_CODE[:processing_error],   # payment processed, address info couldn't be validated

        # Fraud Errors
        'PMT-2000' => STANDARD_ERROR_CODE[:incorrect_cvc],      # Incorrect CVC
        'PMT-2001' => STANDARD_ERROR_CODE[:invalid_cvc],        # CVC check unavaliable
        'PMT-2002' => STANDARD_ERROR_CODE[:incorrect_address],  # Incorrect address
        'PMT-2003' => STANDARD_ERROR_CODE[:incorrect_address],  # Address info unavailable

        'PMT-3000' => STANDARD_ERROR_CODE[:processing_error],   # Merchant account could not be validated

        # Invalid Request
        'PMT-4000' => STANDARD_ERROR_CODE[:processing_error],   # Object is invalid
        'PMT-4001' => STANDARD_ERROR_CODE[:processing_error],   # Object not found
        'PMT-4002' => STANDARD_ERROR_CODE[:processing_error],   # Object is required

        # Transaction Declined
        'PMT-5000' => STANDARD_ERROR_CODE[:card_declined],      # Request was declined
        'PMT-5001' => STANDARD_ERROR_CODE[:card_declined],      # Merchant does not support given payment method

        # System Error
        'PMT-6000' => STANDARD_ERROR_CODE[:processing_error],   # A temporary Issue prevented this request from being processed.
      }

      FRAUD_WARNING_CODES = ['PMT-1000','PMT-1001','PMT-1002','PMT-1003']

      def initialize(options = {})
        requires!(options, :consumer_key, :consumer_secret, :access_token, :token_secret, :realm)
        @options = options
        super
      end

      def purchase(money, payment, options = {})
        post = {}
        add_amount(post, money, options)
        add_charge_data(post, payment, options)
        post[:capture] = "true"

        commit(ENDPOINT, post)
      end

      def authorize(money, payment, options = {})
        post = {}
        add_amount(post, money, options)
        add_charge_data(post, payment, options)
        post[:capture] = "false"

        commit(ENDPOINT, post)
      end

      def capture(money, authorization, options = {})
        capture_uri = "#{ENDPOINT}/#{CGI.escape(authorization)}/capture"

        commit(capture_uri)
      end

      def refund(money, authorization, options = {})
        post = {}
        refund_uri = "#{ENDPOINT}/#{CGI.escape(authorization)}/refunds"

        commit(refund_uri, post)
      end

      def verify(credit_card, options = {})
        authorize(1.00, credit_card, options)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((realm=\")\w+), '\1[FILTERED]').
          gsub(%r((oauth_consumer_key=\")\w+), '\1[FILTERED]').
          gsub(%r((oauth_nonce=\")\w+), '\1[FILTERED]').
          gsub(%r((oauth_signature=\")[a-zA-Z%0-9]+), '\1[FILTERED]').
          gsub(%r((oauth_token=\")\w+), '\1[FILTERED]').
          gsub(%r((\"card\":{\"number\":\")\d+), '\1[FILTERED]').
          gsub(%r((\"cvc\":\")\d+), '\1[FILTERED]')
      end

      private

      def add_charge_data(post, payment, options = {})
        add_payment(post, payment, options)
        add_address(post, options)
      end

      def add_address(post, options)
        return unless post[:card] && post[:card].kind_of?(Hash)

        card_address = {}
        if address = options[:billing_address] || options[:address]
          card_address[:streetAddress] = address[:address1]
          card_address[:city] = address[:city]
          card_address[:region] = address[:state] || address[:region]
          card_address[:country] = address[:country]
          card_address[:postalCode] = address[:zip] if address[:zip]
        end
        post[:card][:address] = card_address
      end

      def add_amount(post, money, options = {})
        currency = options[:currency] || currency(money)
        post[:amount] = localized_amount(money, currency)
        post[:currency] = currency.upcase
      end

      def add_payment(post, payment, options = {})
        add_creditcard(post, payment, options)
      end

      def add_creditcard(post, creditcard, options = {})
        card = {}
        card[:number] = creditcard.number
        card[:expMonth] = "%02d" % creditcard.month
        card[:expYear] = creditcard.year
        card[:cvc] = creditcard.verification_value if creditcard.verification_value?
        card[:name] = creditcard.name if creditcard.name
        card[:commercialCardCode] = options[:card_code] if options[:card_code]

        post[:card] = card
      end

      def parse(body)
        JSON.parse(body)
      end

      def commit(uri, body = {}, method = :post)
        endpoint = gateway_url + uri
        response = case method
        when :post
          ssl_post(endpoint, post_data(body), headers(:post, endpoint))
        when :get
          ssl_request(:get, endpoint, nil, headers(:get, endpoint))
        else
          raise ArgumentError, "Invalid HTTP method: #{method}. Valid methods are :post and :get"
        end

        response_object(response)
      end

      def response_object(raw_response)
        parsed_response = parse(raw_response)

        Response.new(
          success?(parsed_response),
          message_from(parsed_response),
          parsed_response,
          authorization: authorization_from(parsed_response),
          test: test?,
          cvv_result: cvv_code_from(parsed_response),
          error_code: errors_from(parsed_response),
          fraud_review: fraud_review_status_from(parsed_response)
        )
      end

      def gateway_url
        test? ? test_url : live_url
      end

      def post_data(data = {})
        data.to_json
      end

      def headers(method, uri)
        request_uri = URI.parse(uri)

        request_class = case method
        when :post
          Net::HTTP::Post
        when :get
          Net::HTTP::Get
        else
          raise ArgumentError, "Invalid HTTP method: #{method}. Valid methods are :post and :get"
        end

        # required for Ruby 1.9 backwards compatibilty
        begin
          request_object = request_class.new(request_uri)
        rescue
          request_object = request_class.new(uri)
        end

        consumer = OAuth::Consumer.new(
          @options[:consumer_key],
          @options[:consumer_secret],
          OAUTH_ENDPOINTS)
        access_token = OAuth::AccessToken.new(
          consumer,
          @options[:access_token],
          @options[:token_secret])
        client_helper = OAuth::Client::Helper.new(
          request_object,
          consumer: consumer,
          token: access_token,
          realm: @options[:realm],
          request_uri: request_uri)
        oauth_header = client_helper.header

        {
          "Content-type" => "application/json",
          "Request-Id" => generate_unique_id,
          "Authorization" => oauth_header
        }
      end

      def cvv_code_from(response)
        if response['errors'].present?
          FRAUD_WARNING_CODES.include?(response['errors'].first['code']) ? 'I' : ''
        elsif
          success?(response) ? 'M' : ''
        end
      end

      def success?(response)
        response['errors'].present? ? FRAUD_WARNING_CODES.concat(['0']).include?(response['errors'].first['code']) : true
      end

      def message_from(response)
        response['errors'].present? ? response["errors"].map {|error_hash| error_hash["message"] }.join(" ") : "Transaction Approved"
      end

      def errors_from(response)
        response['errors'].present? ? STANDARD_ERROR_CODE_MAPPING[response["errors"].first["code"]] : ""
      end

      def authorization_from(response)
        response['id']
      end

      def fraud_review_status_from(response)
        response['errors'] && FRAUD_WARNING_CODES.include?(response['errors'].first['code'])
      end
    end
  end
end
