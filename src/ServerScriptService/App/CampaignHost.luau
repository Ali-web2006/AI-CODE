--!strict
--[[
	CampaignHost — the application layer between Roblox adapters and the simulation.

	Responsibilities:
	  * owns the running Simulation and the SessionRegistry
	  * routes every client request: type checks -> rate limit -> session authorization ->
	    session command or CommandProcessor (game commands)
	  * enforces the clock permission policy (GameConfig.Sessions)
	  * save / load / autosave through a CampaignRepository
	  * builds per-player, sequenced replication payloads from the ChangeJournal

	It never touches Instances, RemoteEvents or DataStoreService; the Services folder adapts it to
	Roblox. That makes the complete request pipeline testable headlessly (tests/specs).

	The acting house of a game command is ALWAYS taken from the server-side session, never from
	the payload, so a client cannot act for a house it does not control.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)

local SimulationFolder = script.Parent.Parent.Simulation
local CampaignState = require(SimulationFolder.CampaignState)
local CommandProcessor = require(SimulationFolder.CommandProcessor)
local ContentValidator = require(SimulationFolder.ContentValidator)
local Diagnostics = require(SimulationFolder.Diagnostics)
local PayloadSchema = require(SimulationFolder.PayloadSchema)
local RateLimiter = require(SimulationFolder.RateLimiter)
local SimContext = require(SimulationFolder.SimContext)
local Simulation = require(SimulationFolder.Simulation)
local Snapshot = require(SimulationFolder.Snapshot)
local StateInvariants = require(SimulationFolder.StateInvariants)

local CampaignRepository = require(script.Parent.CampaignRepository)
local CampaignSerializer = require(script.Parent.CampaignSerializer)
local SessionRegistry = require(script.Parent.SessionRegistry)

local Codes = Protocol.ResultCodes
local Commands = Protocol.Commands

type Config = SimContext.Config
type Result = GameTypes.CommandResult

export type PersistenceStatus = {
	available: boolean,
	backendName: string,
	persistent: boolean,
	reason: string?,
}

export type Options = {
	config: Config,
	environment: "development" | "production",
	seed: number,
	campaignId: string,
	bookmarkId: string?,
	now: () -> number, -- monotonic seconds (os.clock)
	wallClock: () -> number, -- unix seconds for save timestamps (os.time)
	diagnostics: Diagnostics.Diagnostics,
	repository: CampaignRepository.CampaignRepository?,
	persistence: PersistenceStatus,
}

export type ReplicationMessage = {
	userId: number,
	payload: { [string]: any },
}

-- Payload schemas for session commands (game command schemas live with their commands).
local SESSION_SCHEMAS: { [string]: PayloadSchema.Schema } = {
	[Commands.SelectHouse] = { houseId = "id" },
	[Commands.SetSpeed] = { speed = "speed" },
	[Commands.SetPaused] = { paused = "boolean" },
	[Commands.GetSaveInfo] = {},
	[Commands.SaveCampaign] = {},
	[Commands.LoadCampaign] = {},
	[Commands.DebugAdvanceMonth] = {},
}

local CampaignHost = {}
CampaignHost.__index = CampaignHost

type CampaignHostData = {
	config: Config,
	environment: "development" | "production",
	now: () -> number,
	wallClock: () -> number,
	diagnostics: Diagnostics.Diagnostics,
	repository: CampaignRepository.CampaignRepository?,
	persistence: PersistenceStatus,
	sessions: SessionRegistry.SessionRegistry,
	rateLimiter: RateLimiter.RateLimiter,
	sim: Simulation.Simulation,
	playerSeq: { [number]: number },
	lastReplicationAt: number,
	flushRequested: boolean,
	saving: boolean,
	dirtySinceSave: boolean,
}

export type CampaignHost = typeof(setmetatable({} :: CampaignHostData, CampaignHost))

local function ok(message: string, data: { [string]: any }?): Result
	return { ok = true, code = Codes.Ok, message = message, data = data }
end

local function reject(code: string, message: string): Result
	return { ok = false, code = code, message = message }
end

local function validateContent(config: Config, bookmark: GameTypes.BookmarkDefinition, diagnostics: Diagnostics.Diagnostics)
	local raw = Content.raw
	local report = ContentValidator.validate({
		terrains = raw.terrains,
		holdingKinds = raw.holdingKinds,
		regions = raw.regions,
		provinces = raw.provinces,
		houses = raw.houses,
		traits = raw.traits,
		cultures = raw.cultures,
		faiths = raw.faiths,
		map = Content.map,
	}, bookmark, config)
	for _, warning in report.warnings do
		diagnostics:warn("Content", warning)
	end
	if #report.errors > 0 then
		for _, problem in report.errors do
			diagnostics:error("Content", problem)
		end
		error(`[IronThrone][Content] {#report.errors} content error(s) in bookmark '{bookmark.id}'; the campaign cannot start. See the log above.`)
	end
end

function CampaignHost.new(options: Options): CampaignHost
	local config = options.config
	local bookmarkId = options.bookmarkId or config.DefaultBookmarkId
	local bookmark = Content.getBookmark(bookmarkId)
	if not bookmark then
		error(`[IronThrone][Campaign] unknown bookmark '{bookmarkId}'`)
	end
	validateContent(config, bookmark, options.diagnostics)

	local self = setmetatable({
		config = config,
		environment = options.environment,
		now = options.now,
		wallClock = options.wallClock,
		diagnostics = options.diagnostics,
		repository = options.repository,
		persistence = options.persistence,
		sessions = SessionRegistry.new(config.Sessions, options.now),
		rateLimiter = RateLimiter.new(config.Network.RateLimit.Capacity, config.Network.RateLimit.RefillPerSecond, options.now),
		sim = nil :: any,
		playerSeq = {},
		lastReplicationAt = -math.huge,
		flushRequested = false,
		saving = false,
		dirtySinceSave = false,
	}, CampaignHost)

	local state = CampaignState.createFromBookmark(bookmark, {
		seed = options.seed,
		campaignId = options.campaignId,
		schemaVersion = config.SchemaVersion,
		clockConfig = config.Clock,
		aiConfig = config.AI,
	})
	local violations = StateInvariants.check(state, config)
	if #violations > 0 then
		for _, violation in violations do
			options.diagnostics:error("Campaign", violation)
		end
		error("[IronThrone][Campaign] the initial campaign state is inconsistent; see the log above.")
	end
	self:installState(state)
	options.diagnostics:info(
		"Campaign",
		`started '{bookmark.name}' ({bookmark.id}) at {CalendarDate.format(state.clock.date)} with seed {options.seed} [{options.environment}]`
	)
	return self
end

-- Replaces the running simulation (new campaign or loaded save).
function CampaignHost.installState(self: CampaignHost, state: GameTypes.CampaignState)
	local sessions = self.sessions
	self.sim = Simulation.new({
		state = state,
		config = self.config,
		diagnostics = self.diagnostics,
		isHumanControlled = function(houseId: string)
			return sessions:isHumanControlled(houseId)
		end,
	})
	self.sim.journal:markResync()
	self.flushRequested = true
end

-- Sessions ------------------------------------------------------------------------------------

function CampaignHost.isHouseClaimable(self: CampaignHost, houseId: string): (boolean, string?)
	local house = self.sim.state.houses[houseId]
	local definition = Content.houses[houseId]
	if not house or not definition then
		return false, "That house does not exist in this campaign."
	end
	if not definition.playable then
		return false, `{definition.name} cannot be played.`
	end
	if house.extinct then
		return false, `{definition.name} is extinct.`
	end
	return true, nil
end

function CampaignHost.playerJoined(self: CampaignHost, userId: number, name: string)
	self.sessions:join(userId, name)
	self.playerSeq[userId] = 0
	local reserved = self.sessions:reservedHouseFor(userId)
	if reserved then
		local claim = self.sessions:claimHouse(userId, reserved, function(houseId)
			return self:isHouseClaimable(houseId)
		end)
		if claim.ok then
			self.diagnostics:info("Session", `{name} ({userId}) reclaimed reserved house '{reserved}'`)
		end
	end
	self.sim.journal:markSession()
	self.flushRequested = true
end

function CampaignHost.playerLeft(self: CampaignHost, userId: number)
	local session = self.sessions:session(userId)
	if not session then
		return
	end
	local houseId = session.houseId
	self.sessions:leave(userId)
	self.playerSeq[userId] = nil
	self.rateLimiter:forget(`u:{userId}`)
	self.rateLimiter:forget(`p:{userId}`)
	self.rateLimiter:forget(`i:{userId}`)
	if houseId then
		SimContext.emitEvent(self.sim:context(), "PlayerLeft", "normal", nil, { houseId = houseId, playerName = session.name })
	end
	if self.sessions:claimedCount() == 0 and not self.sim.state.clock.paused then
		self.sim:setPaused(true)
		self.diagnostics:info("Clock", "paused automatically: no connected player leads a house")
	end
	self.sim.journal:markSession()
	self.flushRequested = true
end

function CampaignHost.sessionView(self: CampaignHost, userId: number): { [string]: any }
	local hostUserId = self.sessions:hostUserId()
	local players = {}
	for _, session in self.sessions:list() do
		table.insert(players, {
			userId = session.userId,
			name = session.name,
			houseId = session.houseId,
			isHost = session.userId == hostUserId,
		})
	end
	local reserved = {}
	for _, houseId in Content.houseIds do
		if self.sessions:isReserved(houseId) then
			table.insert(reserved, houseId)
		end
	end
	return {
		userId = userId,
		houseId = self.sessions:houseOf(userId),
		isHost = hostUserId == userId,
		hostUserId = hostUserId,
		players = players,
		reservedHouseIds = reserved,
		environment = self.environment,
		anyPlayerMayPause = self.config.Sessions.AnyPlayerMayPause,
		persistence = {
			available = self.persistence.available,
			backendName = self.persistence.backendName,
			persistent = self.persistence.persistent,
			reason = self.persistence.reason,
		},
	}
end

-- Entry point for the Sync remote: a rate-limited full snapshot. Returns nil (and logs) when the
-- user is unknown or rate limited; the client retries after a delay.
function CampaignHost.requestSync(self: CampaignHost, userId: number): { [string]: any }?
	if not self.sessions:session(userId) then
		return nil
	end
	if not self.rateLimiter:tryConsume(`u:{userId}`) then
		self.diagnostics:throttled(`syncratelimit:{userId}`, "warn", "Remote", `user {userId} is requesting snapshots too often`)
		return nil
	end
	return self:syncPayload(userId)
end

function CampaignHost.syncPayload(self: CampaignHost, userId: number): { [string]: any }
	local houseId = self.sessions:houseOf(userId)
	return {
		seq = self.playerSeq[userId] or 0,
		campaign = Snapshot.campaignFull(self.sim:context(), houseId),
		session = self:sessionView(userId),
	}
end

-- Request routing ----------------------------------------------------------------------------

local function payloadLimits(config: Config): PayloadSchema.Limits
	return {
		maxIdLength = config.Network.MaxIdLength,
		maxPayloadKeys = config.Network.MaxPayloadKeys,
		speedCount = #config.Clock.SecondsPerDay,
	}
end

function CampaignHost.handleSelectHouse(self: CampaignHost, userId: number, payload: any): Result
	local claim = self.sessions:claimHouse(userId, payload.houseId, function(houseId)
		return self:isHouseClaimable(houseId)
	end)
	if not claim.ok then
		return reject(claim.code, claim.message)
	end
	local session = self.sessions:session(userId) :: SessionRegistry.Session
	local houseName = Content.houses[payload.houseId].name
	self.diagnostics:info("Session", `{session.name} ({userId}) now leads {houseName}`)
	SimContext.emitEvent(self.sim:context(), "HouseClaimed", "normal", nil, { houseId = payload.houseId, playerName = session.name })
	self.sim.journal:markSession()
	return ok(`You now lead {houseName}.`, { houseId = payload.houseId })
end

function CampaignHost.handleSetPaused(self: CampaignHost, userId: number, payload: any): Result
	local isHost = self.sessions:isHost(userId)
	local leadsHouse = self.sessions:houseOf(userId) ~= nil
	if payload.paused then
		if not (isHost or (self.config.Sessions.AnyPlayerMayPause and leadsHouse)) then
			return reject(Codes.NotAuthorized, "Only the host may pause the campaign.")
		end
	else
		if not isHost then
			return reject(Codes.NotAuthorized, "Only the host may resume the campaign.")
		end
		if self.sessions:claimedCount() == 0 then
			return reject(Codes.CampaignNotRunning, "Choose a house before starting the clock.")
		end
	end
	self.sim:setPaused(payload.paused)
	return ok(if payload.paused then "Campaign paused." else "Campaign resumed.", { paused = payload.paused })
end

function CampaignHost.handleSetSpeed(self: CampaignHost, userId: number, payload: any): Result
	if not self.sessions:isHost(userId) then
		return reject(Codes.NotAuthorized, "Only the host may change the campaign speed.")
	end
	self.sim:setSpeed(payload.speed)
	return ok(`Speed set to {payload.speed}.`, { speed = payload.speed })
end

function CampaignHost.handleDebugAdvanceMonth(self: CampaignHost, userId: number): Result
	if self.environment ~= "development" then
		return reject(Codes.NotAuthorized, "Debug commands are disabled on live servers.")
	end
	if not self.sessions:isHost(userId) then
		return reject(Codes.NotAuthorized, "Only the host may use debug commands.")
	end
	if self.sessions:claimedCount() == 0 then
		return reject(Codes.CampaignNotRunning, "Choose a house first.")
	end
	local days = self.sim:advanceToNextMonth()
	self.dirtySinceSave = true
	return ok(`Advanced {days} days to {CalendarDate.format(self.sim.state.clock.date)}.`, { days = days })
end

local function persistenceGuard(self: CampaignHost, userId: number, requireHost: boolean): Result?
	if not self.repository or not self.persistence.available then
		return reject(Codes.StorageUnavailable, `Saving is unavailable: {self.persistence.reason or "no storage backend"}.`)
	end
	if requireHost and not self.sessions:isHost(userId) then
		return reject(Codes.NotAuthorized, "Only the host may save or load the campaign.")
	end
	if self.saving then
		return reject(Codes.SaveInProgress, "A save or load is already in progress.")
	end
	local ready, remaining = self.rateLimiter:tryCooldown(`p:{userId}`, self.config.Network.PersistenceCooldownSeconds)
	if not ready then
		return reject(Codes.RateLimited, `Please wait {math.ceil(remaining)} s before using storage again.`)
	end
	return nil
end

function CampaignHost.handleGetSaveInfo(self: CampaignHost, userId: number): Result
	if not self.repository or not self.persistence.available then
		return reject(Codes.StorageUnavailable, `Saving is unavailable: {self.persistence.reason or "no storage backend"}.`)
	end
	local ready, remaining = self.rateLimiter:tryCooldown(`i:{userId}`, self.config.Network.SaveInfoCooldownSeconds)
	if not ready then
		return reject(Codes.RateLimited, `Please wait {math.ceil(remaining)} s before checking the save again.`)
	end
	local repository = self.repository :: CampaignRepository.CampaignRepository
	local read = repository:read(userId)
	if not read.ok then
		return reject(read.code, read.message)
	end
	local record = read.record
	if not record then
		return ok("No saved campaign.", { exists = false })
	end
	return ok("", {
		exists = true,
		summary = record.summary,
		savedAt = record.savedAt,
		revision = record.revision,
		schemaVersion = record.schemaVersion,
	})
end

-- Saves the campaign into the host's slot. Used by the Save command, autosave and shutdown.
function CampaignHost.saveForHost(self: CampaignHost, reason: string): Result
	local hostUserId = self.sessions:hostUserId()
	if not hostUserId then
		return reject(Codes.CampaignNotRunning, "No host is connected.")
	end
	if not self.repository or not self.persistence.available then
		return reject(Codes.StorageUnavailable, "No storage backend.")
	end
	local repository = self.repository :: CampaignRepository.CampaignRepository
	-- Serialize synchronously so the snapshot is consistent even though the write may yield.
	local record = CampaignSerializer.serialize(self.sim.state, self.wallClock(), self.sessions:houseOf(hostUserId))
	self.saving = true
	local writeOk, result = pcall(function()
		return repository:write(hostUserId, record)
	end)
	self.saving = false
	if not writeOk then
		self.diagnostics:error("Persistence", `{reason} save crashed: {tostring(result)}`)
		return reject(Codes.InternalError, "The save failed unexpectedly.")
	end
	local write = result :: CampaignRepository.WriteResult
	if not write.ok then
		self.diagnostics:warn("Persistence", `{reason} save failed ({write.code}): {write.message}`)
		return reject(write.code, write.message)
	end
	self.dirtySinceSave = false
	self.diagnostics:info("Persistence", `{reason} save written (revision {write.revision}) at {CalendarDate.format(record.summary.date)}`)
	SimContext.emitEvent(self.sim:context(), "CampaignSaved", "low", nil, {
		date = CalendarDate.clone(record.summary.date),
		revision = write.revision,
		backend = self.persistence.backendName,
	})
	return ok(`Campaign saved ({self.persistence.backendName}).`, { revision = write.revision, date = record.summary.date })
end

function CampaignHost.handleSave(self: CampaignHost, userId: number): Result
	local blocked = persistenceGuard(self, userId, true)
	if blocked then
		return blocked
	end
	return self:saveForHost("manual")
end

function CampaignHost.handleLoad(self: CampaignHost, userId: number): Result
	local blocked = persistenceGuard(self, userId, true)
	if blocked then
		return blocked
	end
	local repository = self.repository :: CampaignRepository.CampaignRepository
	self.saving = true
	local readOk, readResult = pcall(function()
		return repository:read(userId)
	end)
	self.saving = false
	if not readOk then
		self.diagnostics:error("Persistence", `load crashed: {tostring(readResult)}`)
		return reject(Codes.InternalError, "The load failed unexpectedly.")
	end
	local read = readResult :: CampaignRepository.ReadResult
	if not read.ok then
		return reject(read.code, read.message)
	end
	if not read.record then
		return reject(Codes.NoSave, "You have no saved campaign.")
	end
	local result = CampaignSerializer.deserialize(read.record, self.config)
	for _, warning in result.warnings do
		self.diagnostics:warn("Persistence", warning)
	end
	if not result.ok or not result.state then
		for _, problem in result.errors do
			self.diagnostics:error("Persistence", `load rejected: {problem}`)
		end
		-- The live campaign is untouched.
		return reject(Codes.InvalidSave, `The save could not be loaded: {result.errors[1] or "unknown error"}.`)
	end

	local state = result.state :: GameTypes.CampaignState
	self:installState(state)
	self.dirtySinceSave = false

	-- Restore the host to the house they led when saving, if nobody else holds it.
	local summary = read.record.summary
	local hostHouseId = summary and summary.hostHouseId
	if hostHouseId and self.sessions:houseOf(userId) ~= hostHouseId then
		self.sessions:release(userId)
		self.sessions:claimHouse(userId, hostHouseId, function(houseId)
			return self:isHouseClaimable(houseId)
		end)
	end
	self.sim.journal:markSession()
	SimContext.emitEvent(self.sim:context(), "CampaignLoaded", "high", nil, {
		date = CalendarDate.clone(state.clock.date),
		revision = read.record.revision,
	})
	self.diagnostics:info("Persistence", `campaign loaded at {CalendarDate.format(state.clock.date)} (revision {tostring(read.record.revision)})`)
	return ok(`Campaign loaded: {CalendarDate.format(state.clock.date)}.`, { date = state.clock.date })
end

function CampaignHost.dispatch(self: CampaignHost, userId: number, commandName: string, payload: any): Result
	if commandName == Commands.SelectHouse then
		return self:handleSelectHouse(userId, payload)
	elseif commandName == Commands.SetPaused then
		return self:handleSetPaused(userId, payload)
	elseif commandName == Commands.SetSpeed then
		return self:handleSetSpeed(userId, payload)
	elseif commandName == Commands.GetSaveInfo then
		return self:handleGetSaveInfo(userId)
	elseif commandName == Commands.SaveCampaign then
		return self:handleSave(userId)
	elseif commandName == Commands.LoadCampaign then
		return self:handleLoad(userId)
	elseif commandName == Commands.DebugAdvanceMonth then
		return self:handleDebugAdvanceMonth(userId)
	end

	-- Game command: the acting house comes from the session, never from the payload.
	local houseId = self.sessions:houseOf(userId)
	if not houseId then
		return reject(Codes.NoHouse, "Choose a house first.")
	end
	local result = self.sim:submit({ kind = "player", userId = userId, houseId = houseId }, commandName, payload)
	if result.ok then
		self.dirtySinceSave = true
	end
	return result
end

-- Entry point for every client request. Never throws.
function CampaignHost.handleRequest(self: CampaignHost, userId: number, commandName: any, payload: any): Result
	if type(commandName) ~= "string" or #commandName == 0 or #commandName > self.config.Network.MaxCommandNameLength then
		self.diagnostics:throttled(`badname:{userId}`, "warn", "Remote", `user {userId} sent an invalid command name`)
		return reject(Codes.InvalidPayload, "The request was malformed.")
	end
	if not self.sessions:session(userId) then
		return reject(Codes.NotAuthorized, "You are not connected to this campaign.")
	end
	if not self.rateLimiter:tryConsume(`u:{userId}`) then
		self.diagnostics:throttled(`ratelimit:{userId}`, "warn", "Remote", `user {userId} is rate limited ({commandName})`)
		return reject(Codes.RateLimited, "Too many requests. Slow down.")
	end

	local sessionSchema = SESSION_SCHEMAS[commandName]
	if sessionSchema then
		local valid, reason = PayloadSchema.validate(sessionSchema, payload, payloadLimits(self.config))
		if not valid then
			self.diagnostics:throttled(`payload:{userId}:{commandName}`, "warn", "Remote", `{commandName} from user {userId} rejected: {reason}`)
			return reject(Codes.InvalidPayload, "The request was malformed.")
		end
	elseif not CommandProcessor.isGameCommand(commandName) then
		self.diagnostics:throttled(`unknown:{userId}`, "warn", "Remote", `user {userId} sent unknown command '{string.sub(commandName, 1, 48)}'`)
		return reject(Codes.UnknownCommand, "Unknown action.")
	end

	local succeeded, result = pcall(self.dispatch, self, userId, commandName, payload)
	if not succeeded then
		self.diagnostics:error("Remote", `{commandName} from user {userId} crashed: {tostring(result)}`)
		return reject(Codes.InternalError, "The server failed to process the request. It has been logged.")
	end
	self.flushRequested = true
	return result :: Result
end

-- Simulation & replication -------------------------------------------------------------------

function CampaignHost.update(self: CampaignHost, elapsedSeconds: number)
	local days = self.sim:update(elapsedSeconds)
	if days > 0 then
		self.dirtySinceSave = true
	end
end

-- Builds the replication messages due now. Pass force = true to flush regardless of the interval.
function CampaignHost.collectReplication(self: CampaignHost, force: boolean?): { ReplicationMessage }
	local now = self.now()
	local due = force or self.flushRequested or (now - self.lastReplicationAt >= self.config.Network.ReplicationInterval)
	if not due or not self.sim.journal:hasChanges() then
		return {}
	end
	self.lastReplicationAt = now
	self.flushRequested = false

	local sim = self.sim:context()
	local changes = sim.journal:flush()
	local messages: { ReplicationMessage } = {}
	for _, session in self.sessions:list() do
		local payload: { [string]: any } = {}
		local hasContent = false
		if changes.resync then
			payload.resync = true
			hasContent = true
		else
			local campaign = Snapshot.campaignDelta(sim, changes, session.houseId)
			if campaign then
				payload.campaign = campaign
				hasContent = true
			end
		end
		local events = Snapshot.filterEvents(changes.events, session.houseId)
		if #events > 0 then
			payload.events = events
			hasContent = true
		end
		if changes.session or changes.resync then
			payload.session = self:sessionView(session.userId)
			hasContent = true
		end
		if hasContent then
			local seq = (self.playerSeq[session.userId] or 0) + 1
			self.playerSeq[session.userId] = seq
			payload.seq = seq
			table.insert(messages, { userId = session.userId, payload = payload })
		end
	end
	return messages
end

function CampaignHost.shouldAutosave(self: CampaignHost): boolean
	return self.dirtySinceSave
		and not self.saving
		and self.repository ~= nil
		and self.persistence.available
		and self.sessions:hostUserId() ~= nil
		and self.sessions:claimedCount() > 0
end

return CampaignHost
