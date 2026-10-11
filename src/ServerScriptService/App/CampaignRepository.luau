--!strict
--[[
	CampaignRepository — reads and writes campaign save slots through a storage backend.

	Backend contract (implemented by DataStoreBackend in Services and InMemoryBackend here):
	  backend.name                            display name ("DataStore", "Server memory")
	  backend.persistent                      true if data survives server shutdown
	  backend:get(key) -> any                 may throw on transient failure
	  backend:update(key, transform) -> any   transform(current) returns the new value or nil to
	                                          cancel; may be invoked more than once; may throw

	Guarantees:
	  * Bounded retries with backoff for transient failures (Persistence.MaxAttempts/BackoffSeconds).
	  * Optimistic concurrency: every record carries a monotonically increasing `revision`. A write
	    succeeds only if the stored revision equals the revision this session last read or wrote;
	    otherwise it is cancelled inside the update transform and reported as a conflict, so an
	    older session can never overwrite newer data.
	  * Records larger than Persistence.MaxSerializedBytes are refused before any write.
	  * Failures never touch in-memory campaign state; callers decide what to do.
]]

local CampaignSerializer = require(script.Parent.CampaignSerializer)

export type Backend = {
	name: string,
	persistent: boolean,
	get: (self: any, key: string) -> any,
	update: (self: any, key: string, transform: (current: any) -> any) -> any,
}

export type Codec = {
	encode: (value: any) -> string,
}

type PersistenceConfig = {
	SlotKeyPrefix: string,
	MaxAttempts: number,
	BackoffSeconds: { number },
	MaxSerializedBytes: number,
}

export type ReadResult = {
	ok: boolean,
	code: string,
	message: string,
	record: CampaignSerializer.SaveRecord?,
}

export type WriteResult = {
	ok: boolean,
	code: string,
	message: string,
	revision: number?,
}

local CampaignRepository = {}
CampaignRepository.__index = CampaignRepository

type RepositoryData = {
	backend: Backend,
	codec: Codec,
	config: PersistenceConfig,
	sleep: (seconds: number) -> (),
	sessionId: string,
	knownRevisions: { [string]: number },
	log: (message: string) -> (),
}

export type CampaignRepository = typeof(setmetatable({} :: RepositoryData, CampaignRepository))

export type Options = {
	backend: Backend,
	codec: Codec,
	config: PersistenceConfig,
	sleep: (seconds: number) -> (),
	sessionId: string,
	log: ((message: string) -> ())?,
}

function CampaignRepository.new(options: Options): CampaignRepository
	return setmetatable({
		backend = options.backend,
		codec = options.codec,
		config = options.config,
		sleep = options.sleep,
		sessionId = options.sessionId,
		knownRevisions = {},
		log = options.log or function(_message: string) end,
	}, CampaignRepository)
end

function CampaignRepository.slotKey(self: CampaignRepository, userId: number): string
	return `{self.config.SlotKeyPrefix}{userId}`
end

-- Runs `operation` with bounded retries. Returns (true, value) or (false, lastError).
function CampaignRepository.withRetries(self: CampaignRepository, label: string, operation: () -> any): (boolean, any)
	local lastError: any = nil
	for attempt = 1, self.config.MaxAttempts do
		local ok, value = pcall(operation)
		if ok then
			return true, value
		end
		lastError = value
		self.log(`{label} attempt {attempt}/{self.config.MaxAttempts} failed: {tostring(value)}`)
		if attempt < self.config.MaxAttempts then
			local backoff = self.config.BackoffSeconds[attempt] or self.config.BackoffSeconds[#self.config.BackoffSeconds] or 1
			self.sleep(backoff)
		end
	end
	return false, lastError
end

function CampaignRepository.read(self: CampaignRepository, userId: number): ReadResult
	local key = self:slotKey(userId)
	local ok, value = self:withRetries(`read {key}`, function()
		return self.backend:get(key)
	end)
	if not ok then
		return { ok = false, code = "StorageUnavailable", message = `Could not reach {self.backend.name}.` }
	end
	if value == nil then
		self.knownRevisions[key] = 0
		return { ok = true, code = "NoSave", message = "No saved campaign.", record = nil }
	end
	if type(value) ~= "table" or value.format ~= CampaignSerializer.Format then
		return { ok = false, code = "InvalidSave", message = "The stored data is not a campaign save." }
	end
	self.knownRevisions[key] = if type(value.revision) == "number" then value.revision else 0
	return { ok = true, code = "Ok", message = "", record = value :: any }
end

function CampaignRepository.write(self: CampaignRepository, userId: number, record: CampaignSerializer.SaveRecord): WriteResult
	local key = self:slotKey(userId)

	local encodeOk, encoded = pcall(self.codec.encode, record)
	if not encodeOk then
		return { ok = false, code = "InvalidSave", message = "The campaign could not be serialized." }
	end
	if #encoded > self.config.MaxSerializedBytes then
		return { ok = false, code = "InvalidSave", message = `The save is too large ({#encoded} bytes).` }
	end

	-- A slot never read in this session must be read first so its revision is known.
	if self.knownRevisions[key] == nil then
		local readResult = self:read(userId)
		if not readResult.ok then
			return { ok = false, code = readResult.code, message = readResult.message }
		end
	end
	local expected = self.knownRevisions[key]

	local conflictRevision: number? = nil
	local writtenRevision: number? = nil
	local ok, err = self:withRetries(`write {key}`, function()
		return self.backend:update(key, function(current: any)
			conflictRevision = nil
			writtenRevision = nil
			local currentRevision = if type(current) == "table" and type(current.revision) == "number" then current.revision else 0
			if currentRevision ~= expected then
				conflictRevision = currentRevision
				return nil -- cancel the write: someone else saved since we last read
			end
			local stored = table.clone(record) :: any
			stored.revision = currentRevision + 1
			stored.writerSessionId = self.sessionId
			writtenRevision = stored.revision
			return stored
		end)
	end)
	if not ok then
		return { ok = false, code = "StorageUnavailable", message = `Could not reach {self.backend.name}: {tostring(err)}` }
	end
	if conflictRevision ~= nil then
		return {
			ok = false,
			code = "SaveConflict",
			message = `The save slot was changed by another server (revision {conflictRevision}). Load it before saving again.`,
		}
	end
	if writtenRevision == nil then
		return { ok = false, code = "StorageUnavailable", message = "The save was not written." }
	end
	self.knownRevisions[key] = writtenRevision
	return { ok = true, code = "Ok", message = "", revision = writtenRevision }
end

return CampaignRepository
