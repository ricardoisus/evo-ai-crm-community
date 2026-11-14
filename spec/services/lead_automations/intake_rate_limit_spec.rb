require 'rails_helper'
require 'digest'
RSpec.describe LeadAutomations::IntakeRateLimit do
  it 'uses an atomic shared Redis counter and gives it a 60 second TTL' do
    original_pool = $velma
    $velma = ConnectionPool.new(size: 2) { Redis::Namespace.new('velma', redis: Redis.new(url: ENV.fetch('REDIS_URL'))) }
    key = "synthetic:#{SecureRandom.uuid}"
    redis_key = "lead_intake:#{Digest::SHA256.hexdigest(key)}"
    20.times { expect(described_class.allowed?(key, 20)).to be(true) }
    expect(described_class.allowed?(key, 20)).to be(false)
    ttl = $velma.with { |redis| redis.ttl(redis_key) }
    expect(ttl).to be_between(1, 60)
  ensure
    $velma.with { |redis| redis.del(redis_key) } if redis_key
    $velma.shutdown { |client| client.redis.close }
    $velma = original_pool
  end
end
