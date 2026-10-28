# frozen_string_literal: true

module DiscourseActivityPub
  module InboxVerification
    extend ActiveSupport::Concern

    MAX_BODY_BYTES = 512 * 1024

    def ensure_inbox_signature
      unless SiteSetting.activity_pub_async_inbox_verification
        ensure_verified_signature if require_signed_requests?
        return
      end
      return unless signed_request? || require_signed_requests?

      @inbox_signature_context = signature_verification_context
      unless @inbox_signature_context
        render_activity_pub_error(
          signature_verification_failure_reason,
          signature_verification_failure_code,
          signature_verification_failure_opts,
        )
      end
    end

    protected

    def set_raw_body
      @raw_body = request.body.read(MAX_BODY_BYTES + 1)
      render_activity_pub_error("inbox_too_large", 413) if @raw_body.bytesize > MAX_BODY_BYTES
    end

    def enqueue_inbox_json(delivered_to: nil)
      args = { json: @json, delivered_to: delivered_to }
      if SiteSetting.activity_pub_async_inbox_verification && @inbox_signature_context
        token =
          Digest::SHA256.hexdigest(
            [body_digest, delivered_to, @inbox_signature_context.to_json].to_json,
          )
        reservation = InboxQueue.reserve(token)
        if reservation == :full
          response.set_header("Retry-After", "60")
          render_activity_pub_error("inbox_busy", 503)
          return
        end
        return if reservation == :duplicate

        begin
          Jobs.enqueue(
            Jobs::DiscourseActivityPub::VerifyInbox,
            **args,
            signature_context: @inbox_signature_context,
            token: token,
            received_at: Time.now.to_i,
          )
        rescue StandardError
          InboxQueue.release(token)
          raise
        end
      else
        Jobs.enqueue(
          Jobs::DiscourseActivityPub::Process,
          **args,
          signed_actor_ap_id: signed_request_actor&.ap_id,
        )
      end
    end
  end
end
