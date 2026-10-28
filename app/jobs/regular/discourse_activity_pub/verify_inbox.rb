# frozen_string_literal: true

module Jobs
  module DiscourseActivityPub
    class VerifyInbox < ::Jobs::Base
      include ::DiscourseActivityPub::SignatureVerification
      include ::DiscourseActivityPub::DomainVerification

      sidekiq_options queue: "low", retry: 5

      sidekiq_retries_exhausted do |job|
        args = job.fetch("args").first
        RailsMultisite::ConnectionManagement.with_connection(args.fetch("current_site_id")) do
          ::DiscourseActivityPub::InboxQueue.release(args.fetch("token"))
          ::DiscourseActivityPub::Logger.warn("Inbox signature verification exhausted its retries")
        end
      end

      class NetworkFailure < StandardError
      end

      def execute(args)
        token = args.fetch(:token)
        return if ::DiscourseActivityPub::InboxQueue.completed?(token)
        if Time.now.to_i - args.fetch(:received_at) > ::DiscourseActivityPub::InboxQueue::MAX_AGE
          ::DiscourseActivityPub::InboxQueue.release(token)
          return
        end

        actor = nil
        ::DiscourseActivityPub::Request.with_network_budget(seconds: 10) do |budget|
          actor = signed_actor_from_context(args.fetch(:signature_context))
          if !actor && budget[:failed]
            raise NetworkFailure, "ActivityPub signature lookup failed temporarily"
          end
        end

        if actor
          Jobs.enqueue(
            Jobs::DiscourseActivityPub::Process,
            json: args.fetch(:json),
            delivered_to: args[:delivered_to],
            signed_actor_ap_id: actor.ap_id,
          )
        else
          ::DiscourseActivityPub::Logger.warn(
            "Inbox signature rejected: #{signature_verification_failure_reason}",
          )
        end
        ::DiscourseActivityPub::InboxQueue.release(token, completed: true)
      end
    end
  end
end
