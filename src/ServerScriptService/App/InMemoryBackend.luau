--!strict
--[[
	InMemoryBackend — a storage backend that keeps saves in server memory for the lifetime of the
	server. Used when DataStoreService is unavailable (unpublished place, Studio API access off)
	and in automated tests.

	Values are stored ENCODED (JSON through the injected codec) and decoded on read, exactly like a
	DataStore round trip, so a save that works here has passed the same serialization constraints.
	The UI labels this backend as non-persistent; nothing survives a server restart.
]]

export type Codec = {
	encode: (value: any) -> string,
	decode: (text: string) -> any,
}

local InMemoryBackend = {}
InMemoryBackend.__index = InMemoryBackend

type InMemoryBackendData = {
	name: string,
	persistent: boolean,
	codec: Codec,
	store: { [string]: string },
}

export type InMemoryBackend = typeof(setmetatable({} :: InMemoryBackendData, InMemoryBackend))

function InMemoryBackend.new(codec: Codec): InMemoryBackend
	return setmetatable({
		name = "Server memory",
		persistent = false,
		codec = codec,
		store = {},
	}, InMemoryBackend)
end

function InMemoryBackend.get(self: InMemoryBackend, key: string): any
	local encoded = self.store[key]
	if encoded == nil then
		return nil
	end
	return self.codec.decode(encoded)
end

function InMemoryBackend.update(self: InMemoryBackend, key: string, transform: (current: any) -> any): any
	local current = self:get(key)
	local nextValue = transform(current)
	if nextValue == nil then
		return current
	end
	self.store[key] = self.codec.encode(nextValue)
	return self.codec.decode(self.store[key])
end

return InMemoryBackend
