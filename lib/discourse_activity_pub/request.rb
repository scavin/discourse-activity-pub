# frozen_string_literal: true

module DiscourseActivityPub
  class Request
    include JsonLd

    SUCCESS_CODES = [200, 201, 202]
    REDIRECT_CODES = [301, 302, 307, 308]
    ALLOWED_ERRORS = [410]

    TIMEOUT = 60
    MAX_REDIRECTS = 3
    REQUEST_TARGET_HEADER = "(request-target)"
    CREATED_HEADER = "(created)"
    EXPIRES_HEADER = "(expires)"
    SIGNATURE_ALGORITHM = "hs2019"

    attr_accessor :uri, :headers, :body, :expects, :middlewares, :allowed_errors
    attr_writer :actor

    def initialize(actor_id: nil, uri: "", headers: {}, body: nil, allowed_errors: [])
      @actor = DiscourseActivityPubActor.find_by(id: actor_id) if actor_id
      @uri = DiscourseActivityPub::URI.parse(uri)
      @headers = default_headers.merge(headers)
      @body = body
      @allowed_errors = allowed_errors
    end

    def get_json_ld
      # Share one foreground network budget across JSON-LD redirects.
      appinn_previous_deadline = @appinn_read_deadline
      if Thread.current["discourse.processing_request"]
        @appinn_read_deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0
      end
      @headers.merge!({ "Accept" => content_type_header })
      @expects = SUCCESS_CODES + REDIRECT_CODES + allowed_errors

      response = nil
      (MAX_REDIRECTS + 1).times do
        response = perform(:get)
        break unless redirect_response?(response)
        break unless follow_redirect(response)
        response = nil
      end

      response ? validate_json_ld(response.body) : nil
    ensure
      @appinn_read_deadline = appinn_previous_deadline
    end

    def post_json_ld
      @body = @body.to_json
      @headers.merge!(
        {
          "Digest" => "SHA-256=#{Digest::SHA256.base64digest(@body)}",
          "Content-Type" => content_type_header,
        },
      )
      @expects = SUCCESS_CODES

      response = perform(:post)
      response ? true : false
    end

    def self.with_network_budget(seconds:)
      previous = Thread.current[:activity_pub_network_budget]
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      deadline = [deadline, previous[:deadline]].min if previous
      budget = { deadline: deadline, failed: false }
      Thread.current[:activity_pub_network_budget] = budget
      yield budget
    ensure
      previous[:failed] ||= budget[:failed] if previous && budget
      Thread.current[:activity_pub_network_budget] = previous
    end

    def perform(verb)
      budget = Thread.current[:activity_pub_network_budget] if verb == :get
      deadline = budget && budget[:deadline]
      if verb == :get && Thread.current["discourse.processing_request"]
        foreground_deadline =
          @appinn_read_deadline || (Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5.0)
        deadline = [deadline, foreground_deadline].compact.min
      end

      cache_key = "activity_pub:gone:#{Digest::SHA256.hexdigest(uri.to_s)}" if verb == :get
      cached = Discourse.redis.get(cache_key) if cache_key
      if cached
        response = Excon::Response.new(JSON.parse(cached).symbolize_keys)
      else
        if deadline
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            budget[:failed] = true if budget
            return
          end
          request_uri = Timeout.timeout([2.0, remaining].min) { safe_request_uri }
        else
          request_uri = safe_request_uri
        end
        return unless request_uri

        options = { headers: final_headers(verb), read_timeout: TIMEOUT, write_timeout: TIMEOUT }
        options[:middlewares] = middlewares if middlewares.present?
        options[:body] = body if body.present?
        if deadline
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            budget[:failed] = true if budget
            return
          end
          options.merge!(
            connect_timeout: [2.0, remaining].min,
            read_timeout: remaining,
            write_timeout: remaining,
            timeout: remaining,
          )
        end
        options[:ssl_verify_peer_host] = uri.host
        response = Excon.send(verb, request_uri.to_s, options)
        unless response
          budget[:failed] = true if budget
          return
        end

        # Cache only a confirmed Gone response; never mark stored actors as deleted.
        if cache_key && response.status == 410 && response.body.to_s.bytesize <= 16_384
          Discourse.redis.setex(
            cache_key,
            10.minutes.to_i,
            { status: 410, headers: {}, body: response.body }.to_json,
          )
        end
      end
      if budget && ([408, 429].include?(response.status) || response.status.between?(500, 599))
        budget[:failed] = true
      end

      if expects.present? && expects.exclude?(response.status)
        raise Excon::Error.new(response.body.to_s[0..200])
      end

      response
    rescue Excon::Error, Timeout::Error => e
      budget[:failed] = true if budget && !response
      DiscourseActivityPub::Logger.warn(
        I18n.t(
          "discourse_activity_pub.request.error.request_to_failed",
          method: verb.upcase,
          uri: uri.to_s,
          message: e.message,
        ),
      )
      # TODO (future): selectively raise expectation failures, e.g. to Deliver job.
      nil
    end

    def actor
      @actor || DiscourseActivityPubActor.application
    end

    def self.build_signature(
      verb: nil,
      path: nil,
      key_id: nil,
      keypair: nil,
      headers: {},
      custom_params: {}
    )
      request_target = "#{verb} #{path}"
      created = Time.now.to_i
      # TODO: is this expiry right?
      expires = 1.hour.from_now.to_i

      headers = headers.without("User-Agent", "Accept-Encoding", "Content-Type", "Accept")
      pseudo_headers = {
        REQUEST_TARGET_HEADER => request_target,
        CREATED_HEADER => created,
        EXPIRES_HEADER => expires,
      }
      combined_headers = headers.merge(pseudo_headers)

      signing_str = combined_headers.map { |key, value| "#{key.downcase}: #{value}" }.join("\n")
      signed_str = keypair.sign(OpenSSL::Digest.new("SHA256"), signing_str)
      signature = Base64.strict_encode64(signed_str)

      params = {
        "keyId" => key_id,
        "algorithm" => SIGNATURE_ALGORITHM,
        "headers" => combined_headers.keys.join(" ").downcase,
        "signature" => signature,
        "created" => created,
        "expires" => expires,
      }.merge(custom_params)

      params
        .select { |key, value| value.present? }
        .map { |key, value| "#{key}=\"#{value}\"" }
        .join(",")
    end

    def self.get_json_ld(uri: "", headers: {}, allowed_errors: [])
      self.new(uri: uri, headers: headers, allowed_errors: allowed_errors).get_json_ld
    end

    def self.post_json_ld(actor_id: nil, uri: "", headers: {}, body: nil)
      body[:to] = uri
      self.new(actor_id: actor_id, uri: uri, headers: headers, body: body).post_json_ld
    end

    protected

    def default_headers
      headers = { "Host" => uri.host, "Date" => Time.now.utc.httpdate }
      if SiteSetting.activity_pub_send_user_agent
        headers[
          "User-Agent"
        ] = "Discourse-ActivityPub/#{Discourse::VERSION::STRING} (+#{Discourse.base_url})"
      end
      headers
    end

    def final_headers(verb)
      @headers["Host"] = uri.host
      @headers["Date"] = Time.now.utc.httpdate
      @headers.delete("Signature")

      @headers["Signature"] = self.class.build_signature(
        verb: verb,
        path: uri.path,
        key_id: signature_key_id(actor),
        keypair: actor.keypair,
        headers: headers,
      ) if sign_request?

      @headers
    end

    def sign_request?
      actor.present? && actor.keypair.present?
    end

    def redirect_response?(response)
      response && REDIRECT_CODES.include?(response.status)
    end

    def follow_redirect(response)
      location = response.headers["Location"] || response.headers["location"]
      return false if location.blank?

      @uri = uri.join(location)
      DiscourseActivityPub::URI.valid_url?(uri)
    rescue Addressable::URI::InvalidURIError
      false
    end

    def safe_request_uri
      return unless DiscourseActivityPub::URI.valid_url?(uri)
      return if uri.host.blank? || disallowed_ip?(uri.host)

      resolved_ip = FinalDestination::SSRFDetector.lookup_and_filter_ips(uri.host).first
      return if resolved_ip.blank? || disallowed_ip?(resolved_ip)

      safe_uri = uri.dup

      safe_uri.host = resolved_ip unless Rails.env.test?

      safe_uri
    rescue FinalDestination::SSRFDetector::LookupFailedError, SocketError, Timeout::Error
      budget = Thread.current[:activity_pub_network_budget]
      budget[:failed] = true if budget
      nil
    rescue FinalDestination::SSRFDetector::DisallowedIpError, IPAddr::InvalidAddressError
      nil
    end

    def disallowed_ip?(host)
      !FinalDestination::SSRFDetector.ip_allowed?(IPAddr.new(host))
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
