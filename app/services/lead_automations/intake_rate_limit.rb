require 'digest'
module LeadAutomations
  class IntakeRateLimit
    SCRIPT = <<~LUA.freeze
      local n = redis.call('INCR', KEYS[1])
      if n == 1 then redis.call('EXPIRE', KEYS[1], 60) end
      return n
    LUA
    def self.allowed?(key, limit)
      $velma.with { |redis| redis.eval(SCRIPT, keys: ["lead_intake:#{Digest::SHA256.hexdigest(key)}"]) } <= limit
    end
  end
end
