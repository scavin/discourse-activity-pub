# frozen_string_literal: true

RSpec.describe DiscourseActivityPub::InboxQueue do
  describe ".reserve" do
    it "reserves capacity once, releases failed enqueueing, and deduplicates completed deliveries" do
      expect(described_class.reserve("delivery")).to eq(:reserved)
      expect(described_class.reserve("delivery")).to eq(:duplicate)
      described_class.release("delivery")
      expect(described_class.reserve("delivery")).to eq(:reserved)
      described_class.release("delivery", completed: true)
      expect(described_class.reserve("delivery")).to eq(:duplicate)
      expect(Discourse.redis.zcard(described_class::PENDING_KEY)).to eq(0)
    end

    it "reclaims expired reservations" do
      described_class.reserve("abandoned")
      freeze_time(described_class::MAX_AGE.seconds.from_now + 1.second) do
        expect(described_class.reserve("abandoned")).to eq(:reserved)
      end
    end
  end
end
