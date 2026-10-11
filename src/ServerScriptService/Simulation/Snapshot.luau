--!strict
--[[
	Snapshot — builds the client-facing views of campaign state.

	Views contain only replicable plain data and derived numbers the UI needs (budgets, costs).
	Static identity (names, colours, geography) is NOT sent: the client reads it from the shared
	Content module by id.

	Visibility: Phase 1 campaign state is fully public, except events, which are filtered by
	audience. Every view is built per viewer through these functions, so later phases can hide
	information (secrets, enemy treasuries) by changing only this module.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local CampaignState = require(script.Parent.CampaignState)
local ChangeJournal = require(script.Parent.ChangeJournal)
local Economy = require(script.Parent.Economy)
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
			expenses = roundGold(budget.expenses),
			net = roundGold(budget.net),
		},
	}
end

function Snapshot.provinceView(sim: SimContext, provinceId: string): { [string]: any }
	local province = sim.state.provinces[provinceId]
	local economy = sim.config.Economy
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
		garrison = roundGold(garrison),
		administration = roundGold(administration),
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
	local houses, provinces, relations, characters = {}, {}, {}, {}
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
	return {
		campaignId = state.campaignId,
		bookmarkId = state.bookmarkId,
		clock = Snapshot.clockView(state),
		houses = houses,
		provinces = provinces,
		relations = relations,
		characters = characters,
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
