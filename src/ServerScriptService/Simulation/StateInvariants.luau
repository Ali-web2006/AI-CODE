--!strict
--[[
	StateInvariants — checks that a campaign state is internally consistent.

	Used (1) after deserializing a save, before it can replace the live campaign, (2) by tests after
	every simulated scenario, and (3) cheaply after each command for the houses it touched.
	Military state (province levy and garrison pools, armies) is covered by the same check.
	Returns a list of human-readable violations; an empty list means the state is valid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local DeterministicRng = require(ReplicatedStorage.Shared.Util.DeterministicRng)
local DiplomacyRules = require(ReplicatedStorage.Shared.Rules.DiplomacyRules)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
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

-- Every route stop is a province adjacent to the one before it.
local function checkRoute(where: string, army: GameTypes.ArmyState, fail: (message: string) -> ())
	local count = 0
	for _ in army.route do
		count += 1
	end
	if count ~= #army.route then
		fail(`{where}: route is not a list`)
		return
	end
	local previous = army.locationId
	for index, stop in army.route do
		local from = Content.provinces[previous]
		if type(stop) ~= "string" or not Content.provinces[stop] then
			fail(`{where}: route stop {index} '{tostring(stop)}' is not a province`)
			return
		end
		if from and from.adjacent[stop] == nil then
			fail(`{where}: route stop {index} '{stop}' is not adjacent to '{previous}'`)
			return
		end
		previous = stop
	end
end

--[[
	Armies: id matches the key and ^army_%d+$ with a serial below nextArmySerial; the house exists
	and is not extinct; location and origin are provinces; units are known, positive integers and
	never empty; morale and supply are integers in range; the route is a chain of adjacent
	provinces; leg days are both set (integers, start < end, only with a route) or both nil; a
	commander is a living member of the house who commands no other army.
]]
function StateInvariants.checkArmies(state: GameTypes.CampaignState, config: InvariantConfig, fail: (message: string) -> ())
	if type(state.armies) ~= "table" then
		fail("armies are missing")
		return
	end
	if not isInteger(state.nextArmySerial) or state.nextArmySerial < 1 then
		fail(`army serial {tostring(state.nextArmySerial)} is invalid`)
		return
	end
	local military = config.Military
	local commanders: { [string]: string } = {}
	for _, armyId in TableUtil.sortedKeys(state.armies) do
		local army = state.armies[armyId]
		local where = `army '{armyId}'`
		if army.id ~= armyId then
			fail(`{where}: id field does not match its key`)
		end
		local serial = tonumber(string.match(armyId, "^army_(%d+)$"))
		if serial == nil then
			fail(`{where}: id is not of the form army_<serial>`)
		elseif serial >= state.nextArmySerial then
			fail(`{where}: serial is not below nextArmySerial {state.nextArmySerial}`)
		end
		local house = state.houses[army.houseId]
		if not house then
			fail(`{where}: house '{tostring(army.houseId)}' does not exist`)
		elseif house.extinct then
			fail(`{where}: house '{army.houseId}' is extinct`)
		end
		if not Content.provinces[army.locationId] then
			fail(`{where}: location '{tostring(army.locationId)}' is not a province`)
		end
		if not Content.provinces[army.originId] then
			fail(`{where}: origin '{tostring(army.originId)}' is not a province`)
		end
		if type(army.units) ~= "table" or next(army.units) == nil then
			fail(`{where}: has no units`)
		else
			for unitId, count in army.units do
				if not Content.units[unitId] then
					fail(`{where}: unknown unit '{tostring(unitId)}'`)
				elseif not isInteger(count) or count <= 0 then
					fail(`{where}: unit '{unitId}' has {tostring(count)} men`)
				end
			end
		end
		if not isInteger(army.morale) or army.morale < 0 or army.morale > military.MoraleMax then
			fail(`{where}: morale {tostring(army.morale)} is out of range`)
		end
		if not isInteger(army.supply) or army.supply < 0 or army.supply > military.SupplyMax then
			fail(`{where}: supply {tostring(army.supply)} is out of range`)
		end
		if type(army.route) ~= "table" then
			fail(`{where}: route is missing`)
		elseif Content.provinces[army.locationId] then
			checkRoute(where, army, fail)
		end
		local startDay, endDay = army.legStartDay, army.legEndDay
		if (startDay == nil) ~= (endDay == nil) then
			fail(`{where}: only one leg day is set`)
		elseif startDay ~= nil and endDay ~= nil then
			if type(army.route) == "table" and #army.route == 0 then
				fail(`{where}: has a leg but no route`)
			end
			if not isInteger(startDay) or not isInteger(endDay) or startDay >= endDay then
				fail(`{where}: leg days {tostring(startDay)}..{tostring(endDay)} are invalid`)
			end
		end
		if type(army.gather) ~= "boolean" or type(army.starving) ~= "boolean" then
			fail(`{where}: gather or starving flag is not a boolean`)
		end
		local commanderId = army.commanderId
		if commanderId ~= nil then
			local commander = state.characters[commanderId]
			if not commander then
				fail(`{where}: commander '{tostring(commanderId)}' does not exist`)
			elseif not commander.alive then
				fail(`{where}: commander '{commanderId}' is dead`)
			elseif commander.houseId ~= army.houseId then
				fail(`{where}: commander '{commanderId}' is not of house '{tostring(army.houseId)}'`)
			end
			if commanders[commanderId] then
				fail(`{where}: commander '{commanderId}' already commands '{commanders[commanderId]}'`)
			end
			commanders[commanderId] = armyId
		end
	end
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
		else
			local leviesMax = MilitaryRules.levyMax(provinceId, province.development, config.Military)
			if not isInteger(province.levies) or province.levies < 0 or province.levies > leviesMax then
				fail(`{where}: levies {tostring(province.levies)} are outside 0..{leviesMax}`)
			end
			local garrisonMax = MilitaryRules.garrisonMax(provinceId, province.development, config.Military)
			if not isInteger(province.garrisonTroops) or province.garrisonTroops < 0 or province.garrisonTroops > garrisonMax then
				fail(`{where}: garrison {tostring(province.garrisonTroops)} is outside 0..{garrisonMax}`)
			end
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

	StateInvariants.checkArmies(state, config, fail)

	return violations
end

return StateInvariants
