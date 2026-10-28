# frozen_string_literal: true

module DiscourseActivityPub
  class InboxQueue
    MAX_PENDING = 200
    MAX_AGE = 24.hours.to_i
    PENDING_KEY = "activity_pub:pending_verification"

    RESERVE_SCRIPT = <<~LUA
      redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
      if redis.call('EXISTS', KEYS[2]) == 1 or redis.call('ZSCORE', KEYS[1], ARGV[2]) then
        return 0
      end
      if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[4]) then return -1 end
      redis.call('ZADD', KEYS[1], ARGV[3], ARGV[2])
      redis.call('EXPIRE', KEYS[1], ARGV[5])
      return 1
    LUA

    def self.reserve(token)
      result =
        Discourse.redis.eval(
          RESERVE_SCRIPT,
          keys: [
            Discourse.redis.namespace_key(PENDING_KEY),
            Discourse.redis.namespace_key(done_key(token)),
          ],
          argv: [Time.now.to_i, token, Time.now.to_i + MAX_AGE, MAX_PENDING, MAX_AGE],
        )
      { 1 => :reserved, 0 => :duplicate, -1 => :full }.fetch(result)
    end

    def self.completed?(token)
      Discourse.redis.get(done_key(token)).present?
    end

    def self.release(token, completed: false)
      Discourse.redis.multi do |transaction|
        transaction.setex(done_key(token), 10.minutes.to_i, "1") if completed
        transaction.zrem(PENDING_KEY, token)
      end
    end

    def self.done_key(token)
      "activity_pub:verified_inbox:#{token}"
    end
  end
end
