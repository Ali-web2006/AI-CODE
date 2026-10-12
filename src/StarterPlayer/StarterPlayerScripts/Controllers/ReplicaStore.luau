--!strict
--[[
	ReplicaStore — the client's read-only copy of server state.

	The server sends one full snapshot (Sync) and then sequenced deltas (StateDelta). This store
	applies them and reports what changed so UI components refresh only the affected parts.

	applyDelta returns:
	  "applied"   the delta was merged
	  "stale"     already applied (seq <= current); ignored
	  "gap"       a delta was missed; the caller must request a full snapshot
	  "resync"    the server replaced the campaign (e.g. a load); the caller must request a snapshot
	  "notready"  no snapshot yet; the caller should buffer the delta

	The store never computes game outcomes: every number in it came from the server. It is pure
	Luau (no Roblox services) so tests can drive it with the real server pipeline.

	Armies are the one collection whose entities disappear: a delta lists them in `removedArmies`,
	and the store deletes them and reports their ids in ChangeSet.armies like any other change.
	campaign.armies always exists once a snapshot has been applied (empty when the server sent none).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DiplomacyRules = require(ReplicatedStorage.Shared.Rules.DiplomacyRules)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type ChangeSet = {
	full: boolean,
	clock: boolean,
	session: boolean,
	houses: { [string]: boolean },
	provinces: { [string]: boolean },
	relations: { [string]: boolean },
	characters: { [string]: boolean },
	-- Armies added, changed or removed (a removed id is no longer in campaign.armies).
	armies: { [string]: boolean },
	events: { any },
}

local ReplicaStore = {}
ReplicaStore.__index = ReplicaStore

type ReplicaStoreData = {
	seq: number,
	ready: boolean,
	campaign: { [string]: any },
	session: { [string]: any },
	eventLog: { any },
	changed: Signal.Signal,
}

export type ReplicaStore = typeof(setmetatable({} :: ReplicaStoreData, ReplicaStore))

local function emptyChangeSet(full: boolean): ChangeSet
	return {
		full = full,
		clock = full,
		session = full,
		houses = {},
		provinces = {},
		relations = {},
		characters = {},
		armies = {},
		events = {},
	}
end

function ReplicaStore.new(): ReplicaStore
	return setmetatable({
		seq = 0,
		ready = false,
		campaign = {},
		session = {},
		eventLog = {},
		changed = Signal.new(),
	}, ReplicaStore)
end

function ReplicaStore.applyFull(self: ReplicaStore, payload: { [string]: any })
	self.seq = payload.seq or 0
	self.campaign = payload.campaign or {}
	if type(self.campaign.armies) ~= "table" then
		self.campaign.armies = {}
	end
	self.session = payload.session or {}
	self.ready = true
	self.changed:Fire(emptyChangeSet(true))
end

local function mergeEntities(target: { [string]: any }?, updates: { [string]: any }?, marks: { [string]: boolean }): { [string]: any }
	local merged = target or {}
	if updates then
		for id, view in updates do
			merged[id] = view
			marks[id] = true
		end
	end
	return merged
end

function ReplicaStore.applyDelta(self: ReplicaStore, payload: { [string]: any }): string
	if not self.ready then
		return "notready"
	end
	local seq = payload.seq
	if type(seq) ~= "number" or seq <= self.seq then
		return "stale"
	end
	if seq > self.seq + 1 then
		return "gap"
	end
	self.seq = seq

	local changes = emptyChangeSet(false)
	if payload.events then
		for _, event in payload.events do
			table.insert(self.eventLog, event)
			table.insert(changes.events, event)
		end
		while #self.eventLog > GameConfig.Network.ClientEventLogLength do
			table.remove(self.eventLog, 1)
		end
	end
	if payload.resync then
		-- Events still reach the chronicle; entity data will come with the new snapshot.
		if #changes.events > 0 then
			self.changed:Fire(changes)
		end
		return "resync"
	end

	local campaign = payload.campaign
	if campaign then
		if campaign.clock then
			self.campaign.clock = campaign.clock
			changes.clock = true
		end
		self.campaign.houses = mergeEntities(self.campaign.houses, campaign.houses, changes.houses)
		self.campaign.provinces = mergeEntities(self.campaign.provinces, campaign.provinces, changes.provinces)
		self.campaign.relations = mergeEntities(self.campaign.relations, campaign.relations, changes.relations)
		self.campaign.characters = mergeEntities(self.campaign.characters, campaign.characters, changes.characters)
		local armies = mergeEntities(self.campaign.armies, campaign.armies, changes.armies)
		for _, armyId in campaign.removedArmies or {} do
			armies[armyId] = nil
			changes.armies[armyId] = true
		end
		self.campaign.armies = armies
	end
	if payload.session then
		self.session = payload.session
		changes.session = true
	end
	self.changed:Fire(changes)
	return "applied"
end

-- Convenience accessors -----------------------------------------------------------------------

function ReplicaStore.myHouseId(self: ReplicaStore): string?
	return self.session.houseId
end

function ReplicaStore.house(self: ReplicaStore, houseId: string): { [string]: any }?
	return self.campaign.houses and self.campaign.houses[houseId]
end

function ReplicaStore.province(self: ReplicaStore, provinceId: string): { [string]: any }?
	return self.campaign.provinces and self.campaign.provinces[provinceId]
end

function ReplicaStore.character(self: ReplicaStore, characterId: string): { [string]: any }?
	return self.campaign.characters and self.campaign.characters[characterId]
end

function ReplicaStore.relation(self: ReplicaStore, houseA: string, houseB: string): { [string]: any }?
	return self.campaign.relations and self.campaign.relations[DiplomacyRules.relationKey(houseA, houseB)]
end

function ReplicaStore.army(self: ReplicaStore, armyId: string): { [string]: any }?
	return self.campaign.armies and self.campaign.armies[armyId]
end

local function sortedArmies(self: ReplicaStore, field: string, value: string): { { [string]: any } }
	local armies: { [string]: any } = self.campaign.armies or {}
	local ids: { string } = {}
	for armyId, army in armies do
		if army[field] == value then
			table.insert(ids, armyId)
		end
	end
	table.sort(ids)
	local list = {}
	for _, armyId in ids do
		table.insert(list, armies[armyId])
	end
	return list
end

-- Armies of a house, sorted by id.
function ReplicaStore.armiesOf(self: ReplicaStore, houseId: string): { { [string]: any } }
	return sortedArmies(self, "houseId", houseId)
end

-- Armies located in a province (an army on the road is in the province it left), sorted by id.
function ReplicaStore.armiesIn(self: ReplicaStore, provinceId: string): { { [string]: any } }
	return sortedArmies(self, "locationId", provinceId)
end

-- The player (or empty) controlling a house, from the replicated session roster.
function ReplicaStore.playerForHouse(self: ReplicaStore, houseId: string): { [string]: any }?
	for _, player in self.session.players or {} do
		if player.houseId == houseId then
			return player
		end
	end
	return nil
end

return ReplicaStore
