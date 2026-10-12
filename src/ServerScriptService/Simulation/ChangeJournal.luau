--!strict
--[[
	ChangeJournal — records which entities changed and which game events occurred since the last
	replication flush.

	Domain operations mark entities dirty instead of pushing network messages themselves. The
	replication layer flushes the journal on a fixed interval (or immediately after a player
	command) and sends only the changed entities. This keeps simulation code independent of
	networking, and lets future systems (wars, schemes) replicate without new plumbing.

	Armies are the one collection whose entities disappear (merged, disbanded, deserted). A removal
	is recorded separately in `removedArmies` (and cancels any pending update of that army) because
	a delta can only carry views of entities that still exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)

export type Changes = {
	clock: boolean,
	session: boolean,
	resync: boolean,
	houses: { [string]: boolean },
	provinces: { [string]: boolean },
	relations: { [string]: boolean },
	characters: { [string]: boolean },
	armies: { [string]: boolean },
	removedArmies: { [string]: boolean },
	events: { GameTypes.GameEvent },
}

local function empty(): Changes
	return {
		clock = false,
		session = false,
		resync = false,
		houses = {},
		provinces = {},
		relations = {},
		characters = {},
		armies = {},
		removedArmies = {},
		events = {},
	}
end

local ChangeJournal = {}
ChangeJournal.__index = ChangeJournal

export type ChangeJournal = typeof(setmetatable({} :: { changes: Changes }, ChangeJournal))

function ChangeJournal.new(): ChangeJournal
	return setmetatable({ changes = empty() }, ChangeJournal)
end

function ChangeJournal.markClock(self: ChangeJournal)
	self.changes.clock = true
end

function ChangeJournal.markSession(self: ChangeJournal)
	self.changes.session = true
end

-- Clients must discard their replica and request a full snapshot (e.g. after a campaign load).
function ChangeJournal.markResync(self: ChangeJournal)
	self.changes.resync = true
end

function ChangeJournal.markHouse(self: ChangeJournal, houseId: string)
	self.changes.houses[houseId] = true
end

function ChangeJournal.markProvince(self: ChangeJournal, provinceId: string)
	self.changes.provinces[provinceId] = true
end

function ChangeJournal.markRelation(self: ChangeJournal, relationKey: string)
	self.changes.relations[relationKey] = true
end

function ChangeJournal.markCharacter(self: ChangeJournal, characterId: string)
	self.changes.characters[characterId] = true
end

function ChangeJournal.markArmy(self: ChangeJournal, armyId: string)
	self.changes.armies[armyId] = true
end

-- The army no longer exists; clients must delete it.
function ChangeJournal.markArmyRemoved(self: ChangeJournal, armyId: string)
	self.changes.armies[armyId] = nil
	self.changes.removedArmies[armyId] = true
end

function ChangeJournal.pushEvent(self: ChangeJournal, event: GameTypes.GameEvent)
	table.insert(self.changes.events, event)
end

function ChangeJournal.hasChanges(self: ChangeJournal): boolean
	local c = self.changes
	return c.clock
		or c.session
		or c.resync
		or next(c.houses) ~= nil
		or next(c.provinces) ~= nil
		or next(c.relations) ~= nil
		or next(c.characters) ~= nil
		or next(c.armies) ~= nil
		or next(c.removedArmies) ~= nil
		or #c.events > 0
end

function ChangeJournal.flush(self: ChangeJournal): Changes
	local flushed = self.changes
	self.changes = empty()
	return flushed
end

return ChangeJournal
