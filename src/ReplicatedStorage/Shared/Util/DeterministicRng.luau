--!strict
--[[
	DeterministicRng — a seeded xorshift32 generator whose entire state is a single integer.

	Roblox's Random object cannot be serialized, so it cannot be saved with a campaign or used to
	reproduce a bug. This generator's state lives in the campaign state (rngState), which makes
	every random simulation outcome reproducible from a seed and survives save/load.

	Statistical quality is adequate for gameplay (not for cryptography).
]]

export type Rng = {
	state: number,
}

local DeterministicRng = {}

local UINT32 = 4294967296

local function normalizeSeed(seed: number): number
	local s = math.floor(math.abs(seed)) % UINT32
	if s == 0 then
		-- xorshift has a fixed point at zero; substitute an arbitrary non-zero constant.
		s = 0x9E3779B9
	end
	return s
end

function DeterministicRng.new(seed: number): Rng
	return { state = normalizeSeed(seed) }
end

function DeterministicRng.isValidState(state: any): boolean
	return type(state) == "number" and state == state and state >= 1 and state < UINT32 and math.floor(state) == state
end

-- Advances the generator and returns a uint32.
function DeterministicRng.nextUInt32(rng: Rng): number
	local x = rng.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	rng.state = x
	return x
end

-- Uniform float in [0, 1).
function DeterministicRng.nextFloat(rng: Rng): number
	return DeterministicRng.nextUInt32(rng) / UINT32
end

-- Uniform integer in [min, max] (inclusive).
function DeterministicRng.nextInt(rng: Rng, min: number, max: number): number
	assert(max >= min, "DeterministicRng.nextInt: max < min")
	return min + math.floor(DeterministicRng.nextFloat(rng) * (max - min + 1))
end

function DeterministicRng.chance(rng: Rng, probability: number): boolean
	return DeterministicRng.nextFloat(rng) < probability
end

-- Stable 32-bit hash of a string (djb2 variant). Used for deterministic per-entity offsets, such
-- as staggering AI evaluations, without consuming generator state.
function DeterministicRng.hashString(text: string): number
	local hash = 5381
	for i = 1, #text do
		hash = bit32.band(hash * 33 + string.byte(text, i), 0xFFFFFFFF)
	end
	return hash
end

return DeterministicRng
