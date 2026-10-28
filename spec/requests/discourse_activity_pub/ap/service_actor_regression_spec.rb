# frozen_string_literal: true

RSpec.describe DiscourseActivityPub::AP::FollowersController do
  describe "#index" do
    it "returns a remote Service follower with its original type and id" do
      actor = Fabricate(:discourse_activity_pub_actor_group)
      follower = Fabricate(:discourse_activity_pub_actor_service)
      Fabricate(:discourse_activity_pub_follow, follower: follower, followed: actor)
      toggle_activity_pub(actor.model)
      SiteSetting.activity_pub_require_signed_requests = false

      get_followers(actor)

      expect(response.status).to eq(200)
      expect(parsed_body["orderedItems"].map { |item| item.slice("id", "type") }).to eq(
        [{ "id" => follower.ap_id, "type" => "Service" }],
      )
    end
  end
end

RSpec.describe DiscourseActivityPub::AP::OutboxesController do
  describe "#index" do
    it "returns an accepted follow made by a remote Service actor" do
      actor = Fabricate(:discourse_activity_pub_actor_group)
      follower = Fabricate(:discourse_activity_pub_actor_service)
      follow = Fabricate(:discourse_activity_pub_activity_follow, actor: follower, object: actor)
      Fabricate(:discourse_activity_pub_activity, ap_type: "Accept", actor: actor, object: follow)
      toggle_activity_pub(actor.model)
      SiteSetting.activity_pub_require_signed_requests = false

      get_from_outbox(actor)

      expect(response.status).to eq(200)
      expect(parsed_body["orderedItems"].first.dig("object", "actor").slice("id", "type")).to eq(
        { "id" => follower.ap_id, "type" => "Service" },
      )
    end
  end
end
