# frozen_string_literal: true

RSpec.describe DiscourseActivityPub::Request do
  describe ".with_network_budget" do
    it "shares an exhausted budget across separate actor and webfinger requests and restores it" do
      remote = stub_request(:get, "https://remote.com/actor").to_return(status: 200, body: "{}")
      described_class.with_network_budget(seconds: 0) do |budget|
        expect(described_class.get_json_ld(uri: "https://remote.com/actor")).to be_nil
        expect(described_class.new(uri: "https://remote.com/actor").perform(:get)).to be_nil
        expect(budget[:failed]).to eq(true)
      end
      expect(remote).not_to have_been_requested
      expect(described_class.new(uri: "https://remote.com/actor").perform(:get).status).to eq(200)
    end

    it "restores a parent budget after a nested scope raises" do
      described_class.with_network_budget(seconds: 0) do |budget|
        expect do
          described_class.with_network_budget(seconds: 20) { raise ArgumentError }
        end.to raise_error(ArgumentError)
        expect(described_class.get_json_ld(uri: "https://remote.com/actor")).to be_nil
        expect(budget[:failed]).to eq(true)
      end
    end
  end

  describe "#get_json_ld" do
    it "caches a confirmed 410 without changing the allowed-errors contract" do
      uri = "https://remote.com/gone"
      tombstone = {
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => "Tombstone",
        "id" => uri,
      }
      remote = stub_request(:get, uri).to_return(status: 410, body: tombstone.to_json)

      expect(described_class.get_json_ld(uri: uri, allowed_errors: [410])).to eq(tombstone)
      expect(described_class.get_json_ld(uri: uri)).to be_nil
      expect(described_class.get_json_ld(uri: uri, allowed_errors: [410])).to eq(tombstone)
      expect(remote).to have_been_requested.once
      expect(
        Discourse.redis.ttl("activity_pub:gone:#{Digest::SHA256.hexdigest(uri)}"),
      ).to be_between(590, 600)

      freeze_time(11.minutes.from_now) do
        # Redis TTL uses wall time, so explicit expiry represents that boundary here.
        Discourse.redis.del("activity_pub:gone:#{Digest::SHA256.hexdigest(uri)}")
        described_class.get_json_ld(uri: uri, allowed_errors: [410])
      end
      expect(remote).to have_been_requested.twice
    end

    it "allows recovery after transient errors instead of caching them as Gone" do
      uri = "https://remote.com/recovering"
      remote =
        stub_request(:get, uri).to_return(status: 503).then.to_return(status: 200, body: "{}")
      described_class.with_network_budget(seconds: 10) do |budget|
        described_class.get_json_ld(uri: uri)
        expect(budget[:failed]).to eq(true)
      end
      expect(described_class.new(uri: uri).perform(:get).status).to eq(200)
      expect(remote).to have_been_requested.twice
    end
  end
end
