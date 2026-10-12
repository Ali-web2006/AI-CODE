--!strict
--[[
	Snapshot — builds the client-facing views of campaign state.

	Views contain only replicable plain data and derived numbers the UI needs (budgets, costs).
	Static identity (names, colours, geography) is NOT sent: the client reads it from the shared
	Content module by id.

	Visibility: Phase 1 campaign state is fully public, except events, which are filtered by
	audience. Every view is built per viewer through these functions, so later phases can hide
	information (secrets, enemy treasuries, armies in the fog of war) by changing only this module.

	Armies replicate their route and the day numbers of the current leg, never a position: the
	client interpolates movement from those and clockView.dayNumber. Removed armies are listed in
	the delta's `removedArmies` (sorted ids), because a delta can only carry views of entities that
	still exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local CampaignState = require(script.Parent.CampaignState)
local ChangeJournal = require(script.Parent.ChangeJournal)
local Economy = require(script.Parent.Economy)
local Military = require(script.Parent.Military)
local SimContext = require(script.Parent.SimContext)

type SimContext = SimContext.SimContext

local Snapshot = {}

local roundGold = EconomyRules.roundGold

local function roundLines(lines: { EconomyRules.BreakdownLine }): { EconomyRules.BreakdownLine }
	local rounded = {}
	for _, line in lines do
		table.insert(rounded, { label = line.label, value = math.floor(line.value * 1000 + 0.5) / 1000 })
	end
	return rounded
end

function Snapshot.clockView(state: GameTypes.CampaignState): { [string]: any }
	return {
		date = CalendarDate.clone(state.clock.date),
		speed = state.clock.speed,
		paused = state.clock.paused,
		lastProcessedMonthIndex = state.clock.lastProcessedMonthIndex,
		-- CalendarDate.toDayNumber(date): the time base of army legStartDay/legEndDay.
		dayNumber = CalendarDate.toDayNumber(state.clock.date),
	}
end

-- Troop totals of a house (head counts). Levies and garrisons count only provinces the house
-- holds (owned and not occupied by another house), like its ships.
local function militaryView(sim: SimContext, houseId: string): { [string]: any }
	local config = sim.config.Military
	local armies = CampaignState.armiesOf(sim.state, houseId)
	local raised = 0
	for _, army in armies do
		raised += MilitaryRules.troops(army.units)
	end
	local levies, leviesMax, garrisons, garrisonsMax = 0, 0, 0, 0
	for _, province in CampaignState.ownedProvinces(sim.state, houseId) do
		if Military.holdsProvince(province, houseId) then
			levies += province.levies
			leviesMax += MilitaryRules.levyMax(province.id, province.development, config)
			garrisons += province.garrisonTroops
			garrisonsMax += MilitaryRules.garrisonMax(province.id, province.development, config)
		end
	end
	return {
		raised = raised,
		levies = levies,
		leviesMax = leviesMax,
		garrisons = garrisons,
		garrisonsMax = garrisonsMax,
		total = raised + levies + garrisons,
		ships = Military.shipsTotal(sim, houseId),
		shipsInUse = Military.shipsInUse(sim, houseId),
		armies = #armies,
	}
end

function Snapshot.houseView(sim: SimContext, houseId: string): { [string]: any }
	local house = sim.state.houses[houseId]
	local budget = Economy.budgetFor(sim, houseId)
	local provinceIds = {}
	local totalDevelopment = 0
	for _, province in CampaignState.ownedProvinces(sim.state, houseId) do
		table.insert(provinceIds, province.id)
		totalDevelopment += province.development
	end
	return {
		id = house.id,
		treasury = house.treasury,
		rulerId = house.rulerId,
		extinct = house.extinct,
		provinceIds = provinceIds,
		totalDevelopment = totalDevelopment,
		ledger = TableUtil.deepCopy(house.ledger),
		budget = {
			grossProvinceIncome = roundGold(budget.grossProvinceIncome),
			taxMultiplier = math.floor(budget.taxMultiplier * 1000 + 0.5) / 1000,
			taxMultiplierLines = roundLines(budget.taxMultiplierLines),
			taxIncome = roundGold(budget.taxIncome),
			courtUpkeepBase = budget.courtUpkeepBase,
			courtMultiplierLines = roundLines(budget.courtMultiplierLines),
			courtUpkeep = roundGold(budget.courtUpkeep),
			garrisonUpkeep = roundGold(budget.garrisonUpkeep),
			administration = roundGold(budget.administration),
			armyUpkeep = roundGold(budget.armyUpkeep),
			expenses = roundGold(budget.expenses),
			net = roundGold(budget.net),
		},
		military = militaryView(sim, houseId),
	}
end

function Snapshot.provinceView(sim: SimContext, provinceId: string): { [string]: any }
	local province = sim.state.provinces[provinceId]
	local economy = sim.config.Economy
	local military = sim.config.Military
	local garrison, administration = EconomyRules.provinceUpkeep(provinceId, province.development, economy)
	return {
		id = province.id,
		ownerHouseId = province.ownerHouseId,
		occupierHouseId = province.occupierHouseId,
		development = province.development,
		income = roundGold(EconomyRules.provinceIncome(provinceId, province.development, economy)),
		nextIncome = if province.development < economy.MaxDevelopment
			then roundGold(EconomyRules.provinceIncome(provinceId, province.development + 1, economy))
			else nil,
		developmentCost = EconomyRules.developmentCost(provinceId, province.development, economy),
		-- Gold upkeep of the garrison (not its men: see garrisonTroops).
		garrison = roundGold(garrison),
		administration = roundGold(administration),
		levies = province.levies,
		leviesMax = MilitaryRules.levyMax(provinceId, province.development, military),
		garrisonTroops = province.garrisonTroops,
		garrisonMax = MilitaryRules.garrisonMax(provinceId, province.development, military),
		ships = MilitaryRules.ships(provinceId, province.development),
	}
end

function Snapshot.armyView(sim: SimContext, army: GameTypes.ArmyState): { [string]: any }
	local config = sim.config.Military
	local commander = if army.commanderId then sim.state.characters[army.commanderId] else nil
	return {
		id = army.id,
		houseId = army.houseId,
		originId = army.originId,
		commanderId = army.commanderId,
		locationId = army.locationId,
		units = table.clone(army.units),
		troops = MilitaryRules.troops(army.units),
		morale = army.morale,
		supply = army.supply,
		route = table.clone(army.route),
		legStartDay = army.legStartDay,
		legEndDay = army.legEndDay,
		gather = army.gather,
		starving = army.starving,
		strength = MilitaryRules.strength(army.units, if commander then commander.skills.martial else nil, config),
		upkeep = MilitaryRules.upkeep(army.units, config),
		speed = MilitaryRules.armySpeed(army.units),
	}
end

function Snapshot.relationView(relation: GameTypes.RelationState): { [string]: any }
	return {
		key = relation.key,
		a = relation.a,
		b = relation.b,
		score = relation.score,
		baseline = relation.baseline,
		cooldowns = table.clone(relation.cooldowns),
	}
end

function Snapshot.characterView(character: GameTypes.CharacterState): { [string]: any }
	return TableUtil.deepCopy(character) :: any
end

-- Full campaign view for a viewer (house id may be nil while in the lobby).
function Snapshot.campaignFull(sim: SimContext, _viewerHouseId: string?): { [string]: any }
	local state = sim.state
	local houses, provinces, relations, characters, armies = {}, {}, {}, {}, {}
	for houseId in state.houses do
		houses[houseId] = Snapshot.houseView(sim, houseId)
	end
	for provinceId in state.provinces do
		provinces[provinceId] = Snapshot.provinceView(sim, provinceId)
	end
	for key, relation in state.relations do
		relations[key] = Snapshot.relationView(relation)
	end
	for characterId, character in state.characters do
		characters[characterId] = Snapshot.characterView(character)
	end
	for armyId, army in state.armies do
		armies[armyId] = Snapshot.armyView(sim, army)
	end
	return {
		campaignId = state.campaignId,
		bookmarkId = state.bookmarkId,
		clock = Snapshot.clockView(state),
		houses = houses,
		provinces = provinces,
		relations = relations,
		characters = characters,
		armies = armies,
	}
end

-- Incremental campaign view containing only entities marked in `changes`. Returns nil when no
-- campaign entity changed.
function Snapshot.campaignDelta(sim: SimContext, changes: ChangeJournal.Changes, _viewerHouseId: string?): { [string]: any }?
	local state = sim.state
	local delta: { [string]: any } = {}
	local any = false
	if changes.clock then
		delta.clock = Snapshot.clockView(state)
		any = true
	end
	local function collect(field: string, dirty: { [string]: boolean }, build: (id: string) -> { [string]: any }?)
		local out = {}
		local found = false
		for id in dirty do
			local view = build(id)
			if view then
				out[id] = view
				found = true
			end
		end
		if found then
			delta[field] = out
			any = true
		end
	end
	collect("houses", changes.houses, function(id)
		return if state.houses[id] then Snapshot.houseView(sim, id) else nil
	end)
	collect("provinces", changes.provinces, function(id)
		return if state.provinces[id] then Snapshot.provinceView(sim, id) else nil
	end)
	collect("relations", changes.relations, function(key)
		local relation = state.relations[key]
		return if relation then Snapshot.relationView(relation) else nil
	end)
	collect("characters", changes.characters, function(id)
		local character = state.characters[id]
		return if character then Snapshot.characterView(character) else nil
	end)
	collect("armies", changes.armies, function(id)
		local army = state.armies[id]
		return if army then Snapshot.armyView(sim, army) else nil
	end)
	if next(changes.removedArmies) ~= nil then
		delta.removedArmies = TableUtil.sortedKeys(changes.removedArmies)
		any = true
	end
	return if any then delta else nil
end

function Snapshot.filterEvents(events: { GameTypes.GameEvent }, viewerHouseId: string?): { GameTypes.GameEvent }
	local visible = {}
	for _, event in events do
		local audience = event.audience
		if audience == nil or (viewerHouseId ~= nil and table.find(audience, viewerHouseId) ~= nil) then
			table.insert(visible, {
				kind = event.kind,
				priority = event.priority,
				date = CalendarDate.clone(event.date),
				data = TableUtil.deepCopy(event.data),
			})
		end
	end
	return visible
end

return Snapshot
