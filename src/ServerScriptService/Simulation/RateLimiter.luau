--!strict
--[[
	RateLimiter — per-key token buckets plus per-key cooldowns.

	Each request costs one token; tokens refill continuously up to the capacity. This allows short
	bursts of legitimate clicking while bounding sustained spam. Time is injected so tests can
	control it precisely.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = {
	tokens: number,
	updatedAt: number,
}

type RateLimiterData = {
	capacity: number,
	refillPerSecond: number,
	now: () -> number,
	buckets: { [string]: Bucket },
	cooldowns: { [string]: number },
}

export type RateLimiter = typeof(setmetatable({} :: RateLimiterData, RateLimiter))

function RateLimiter.new(capacity: number, refillPerSecond: number, now: () -> number): RateLimiter
	return setmetatable({
		capacity = capacity,
		refillPerSecond = refillPerSecond,
		now = now,
		buckets = {},
		cooldowns = {},
	}, RateLimiter)
end

-- Consumes one token for `key`; returns false when the bucket is empty.
function RateLimiter.tryConsume(self: RateLimiter, key: string): boolean
	local now = self.now()
	local bucket = self.buckets[key]
	if not bucket then
		bucket = { tokens = self.capacity, updatedAt = now }
		self.buckets[key] = bucket
	end
	local elapsed = math.max(0, now - bucket.updatedAt)
	bucket.tokens = math.min(self.capacity, bucket.tokens + elapsed * self.refillPerSecond)
	bucket.updatedAt = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- Returns true and starts the cooldown if `key` is not cooling down; otherwise returns false
-- and the seconds remaining.
function RateLimiter.tryCooldown(self: RateLimiter, key: string, seconds: number): (boolean, number)
	local now = self.now()
	local readyAt = self.cooldowns[key]
	if readyAt and now < readyAt then
		return false, readyAt - now
	end
	self.cooldowns[key] = now + seconds
	return true, 0
end

function RateLimiter.forget(self: RateLimiter, prefix: string)
	for key in self.buckets do
		if string.sub(key, 1, #prefix) == prefix then
			self.buckets[key] = nil
		end
	end
	for key in self.cooldowns do
		if string.sub(key, 1, #prefix) == prefix then
			self.cooldowns[key] = nil
		end
	end
end

return RateLimiter
