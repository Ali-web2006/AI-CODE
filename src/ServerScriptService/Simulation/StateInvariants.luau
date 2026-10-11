--!strict
--[[
	StateInvariants — checks that a campaign state is internally consistent.

	Used (1) after deserializing a save, before it can replace the live campaign, (2) by tests after
	every simulated scenario, and (3) cheaply after each command for the houses it touched.
	Returns a list of human-readable violations; an empty list means the state is valid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local DeterministicRng = require(ReplicatedStorage.Shared.Util.DeterministicRng)
local DiplomacyRules = require(ReplicatedStorage.Shared.Rules.DiplomacyRules)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local SimContext = require(script.Parent.SimContext)

type InvariantConfig = SimContext.Config

local StateInvariants = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: any): boolean
	return isFiniteNumber(value) and math.floor(value) == value
end

-- Cheap check for a single house: used after every command that spends gold.
function StateInvariants.checkHouseTreasury(house: GameTypes.HouseState): string?
	if not isFiniteNumber(house.treasury) then
		return `house '{house.id}': treasury is not a finite number`
	end
	return nil
end

function StateInvariants.check(state: GameTypes.CampaignState, config: InvariantConfig): { string }
	local violations: { string } = {}
	local function fail(message: string)
		table.insert(violations, message)
	end

	if state.schemaVersion ~= config.SchemaVersion then
		fail(`schemaVersion {tostring(state.schemaVersion)} does not match {config.SchemaVersion}`)
	end
	if not Content.bookmarks[state.bookmarkId] then
		fail(`unknown bookmark '{tostring(state.bookmarkId)}'`)
	end
	if type(state.rng) ~= "table" or not DeterministicRng.isValidState(state.rng.state) then
		fail("rng state is invalid")
	end

	-- Clock: the last processed month must be exactly the month before the current one. Anything
	-- else means a month was skipped or would be processed twice.
	local clock = state.clock
	if type(clock) ~= "table" or not CalendarDate.isValid(clock.date) then
		fail("clock date is invalid")
	else
		if not isInteger(clock.speed) or clock.speed < 1 or clock.speed > #config.Clock.SecondsPerDay then
			fail(`clock speed {tostring(clock.speed)} is out of range`)
		end
		if type(clock.paused) ~= "boolean" then
			fail("clock paused flag is not a boolean")
		end
		if clock.lastProcessedMonthIndex ~= CalendarDate.monthIndex(clock.date) - 1 then
			fail(`clock lastProcessedMonthIndex {tostring(clock.lastProcessedMonthIndex)} is inconsistent with the current date`)
		end
	end

	for houseId, house in state.houses do
		local where = `house '{houseId}'`
		if house.id ~= houseId then
			fail(`{where}: id field does not match its key`)
		end
		if not Content.houses[houseId] then
			fail(`{where}: not defined in content`)
		end
		local treasuryViolation = StateInvariants.checkHouseTreasury(house)
		if treasuryViolation then
			fail(treasuryViolation)
		end
		local ruler = state.characters[house.rulerId]
		if not house.extinct then
			if not ruler then
				fail(`{where}: ruler '{tostring(house.rulerId)}' does not exist`)
			elseif not ruler.alive then
				fail(`{where}: ruler '{house.rulerId}' is dead`)
			end
		end
		if type(house.ledger) ~= "table" or #house.ledger > config.Economy.LedgerLength then
			fail(`{where}: ledger is invalid or too long`)
		end
		if type(house.ai) ~= "table" or not isInteger(house.ai.nextEvaluationMonth) then
			fail(`{where}: ai schedule is invalid`)
		end
	end

	for _, provinceId in Content.provinceIds do
		local province = state.provinces[provinceId]
		local where = `province '{provinceId}'`
		if not province then
			fail(`{where}: missing from campaign state`)
			continue
		end
		if not state.houses[province.ownerHouseId] then
			fail(`{where}: owner '{tostring(province.ownerHouseId)}' does not exist`)
		end
		if province.occupierHouseId ~= nil and not state.houses[province.occupierHouseId] then
			fail(`{where}: occupier '{tostring(province.occupierHouseId)}' does not exist`)
		end
		if not isInteger(province.development)
			or province.development < config.Economy.MinDevelopment
			or province.development > config.Economy.MaxDevelopment then
			fail(`{where}: development {tostring(province.development)} is out of range`)
		end
	end
	for provinceId in state.provinces do
		if not Content.provinces[provinceId] then
			fail(`province '{provinceId}': not defined in content`)
		end
	end

	for characterId, character in state.characters do
		local where = `character '{characterId}'`
		if character.id ~= characterId then
			fail(`{where}: id field does not match its key`)
		end
		if not Content.houses[character.houseId] then
			fail(`{where}: unknown house '{tostring(character.houseId)}'`)
		end
		if not CalendarDate.isValid(character.birthDate) then
			fail(`{where}: invalid birthDate`)
		end
		if character.alive ~= (character.deathDate == nil) then
			fail(`{where}: alive flag disagrees with deathDate`)
		end
	end

	for key, relation in state.relations do
		local where = `relation '{key}'`
		if relation.key ~= key or DiplomacyRules.relationKey(relation.a, relation.b) ~= key or relation.a >= relation.b then
			fail(`{where}: key is not canonical`)
		end
		if not state.houses[relation.a] or not state.houses[relation.b] then
			fail(`{where}: references a house that does not exist`)
		end
		for _, field in { "score", "baseline" } do
			local value = (relation :: any)[field]
			if not isFiniteNumber(value) or value < config.Diplomacy.MinRelation or value > config.Diplomacy.MaxRelation then
				fail(`{where}: {field} {tostring(value)} is out of range`)
			end
		end
		for houseId, month in relation.cooldowns do
			if (houseId ~= relation.a and houseId ~= relation.b) or not isInteger(month) then
				fail(`{where}: invalid cooldown entry for '{tostring(houseId)}'`)
			end
		end
	end

	return violations
end

return StateInvariants
