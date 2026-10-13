--!strict
--[[
	CampaignState — creates the authoritative mutable campaign state from a bookmark and provides
	read accessors.

	Authoritative fields (see docs/ARCHITECTURE.md §State):
	  clock.date / clock.lastProcessedMonthIndex   campaign time and the monthly-processing guard
	  houses[id].treasury                           gold; changed only by Economy and commands
	  houses[id].armyUpkeepAccrued                  accrued daily by Military, charged by Economy
	  provinces[id].ownerHouseId / occupierHouseId  legal owner vs. military occupier
	  provinces[id].development                     changed only by the DevelopProvince operation
	  relations[key].score                          changed only by Diplomacy
	  provinces[id].levies / garrisonTroops         changed only by Military (raise, disband, refill)
	  armies[id], nextArmySerial                    changed only by Military

	Nothing in here touches Roblox APIs, Instances or the network.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local DeterministicRng = require(ReplicatedStorage.Shared.Util.DeterministicRng)
local DiplomacyRules = require(ReplicatedStorage.Shared.Rules.DiplomacyRules)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)

type CampaignState = GameTypes.CampaignState

export type CreateOptions = {
	seed: number,
	campaignId: string,
	schemaVersion: number,
	clockConfig: { DefaultSpeed: number, StartPaused: boolean },
	aiConfig: { EvaluationIntervalMonths: number },
	-- Sizes the starting levy and garrison pools (every pool starts full).
	militaryConfig: MilitaryRules.MilitaryConfig,
}

local CampaignState = {}

-- AI evaluations are staggered per house by a stable hash so all houses do not decide in the
-- same month. The offset depends only on the house id, keeping the schedule deterministic.
function CampaignState.initialAIOffset(houseId: string, intervalMonths: number): number
	if intervalMonths <= 1 then
		return 0
	end
	return DeterministicRng.hashString(houseId) % intervalMonths
end

function CampaignState.newCharacterState(definition: GameTypes.CharacterDefinition): GameTypes.CharacterState
	return {
		id = definition.id,
		givenName = definition.givenName,
		houseId = definition.houseId,
		sex = definition.sex,
		birthDate = CalendarDate.clone(definition.birthDate),
		deathDate = if definition.deathDate then CalendarDate.clone(definition.deathDate) else nil,
		alive = definition.deathDate == nil,
		fatherId = definition.fatherId,
		motherId = definition.motherId,
		spouseId = definition.spouseId,
		cultureId = definition.cultureId,
		faithId = definition.faithId,
		skills = TableUtil.deepCopy(definition.skills),
		traits = table.clone(definition.traits),
		epithet = definition.epithet,
		bastard = definition.bastard == true,
	}
end

function CampaignState.newRelationState(houseA: string, houseB: string, baseline: number): GameTypes.RelationState
	local a, b = houseA, houseB
	if b < a then
		a, b = b, a
	end
	return {
		key = DiplomacyRules.relationKey(a, b),
		a = a,
		b = b,
		score = baseline,
		baseline = baseline,
		cooldowns = {},
	}
end

function CampaignState.createFromBookmark(bookmark: GameTypes.BookmarkDefinition, options: CreateOptions): CampaignState
	local startMonthIndex = CalendarDate.monthIndex(bookmark.startDate)

	local houses: { [string]: GameTypes.HouseState } = {}
	for houseId, setup in bookmark.houses do
		houses[houseId] = {
			id = houseId,
			treasury = setup.treasury,
			rulerId = setup.rulerId,
			extinct = false,
			ledger = {},
			armyUpkeepAccrued = 0,
			ai = {
				-- First evaluation happens at the end of the first month at the earliest.
				nextEvaluationMonth = startMonthIndex + CampaignState.initialAIOffset(houseId, options.aiConfig.EvaluationIntervalMonths),
			},
		}
	end

	local provinces: { [string]: GameTypes.ProvinceState } = {}
	for _, provinceId in Content.provinceIds do
		local setup = bookmark.provinces[provinceId]
		local province: GameTypes.ProvinceState = {
			id = provinceId,
			ownerHouseId = setup.ownerHouseId,
			occupierHouseId = nil,
			development = setup.development,
			levies = 0,
			garrisonTroops = 0,
		}
		-- Pools start full.
		province.levies = MilitaryRules.provinceLevyMax(province, options.militaryConfig)
		province.garrisonTroops = MilitaryRules.provinceGarrisonMax(province, options.militaryConfig)
		provinces[provinceId] = province
	end

	local characters: { [string]: GameTypes.CharacterState } = {}
	for _, definition in bookmark.characters do
		characters[definition.id] = CampaignState.newCharacterState(definition)
	end

	local baselines: { [string]: number } = {}
	for _, relation in bookmark.relations do
		baselines[DiplomacyRules.relationKey(relation.a, relation.b)] = relation.value
	end
	local relations: { [string]: GameTypes.RelationState } = {}
	local houseIds = TableUtil.sortedKeys(houses)
	for i = 1, #houseIds do
		for j = i + 1, #houseIds do
			local key = DiplomacyRules.relationKey(houseIds[i], houseIds[j])
			relations[key] = CampaignState.newRelationState(houseIds[i], houseIds[j], baselines[key] or 0)
		end
	end

	return {
		schemaVersion = options.schemaVersion,
		campaignId = options.campaignId,
		bookmarkId = bookmark.id,
		seed = options.seed,
		rng = DeterministicRng.new(options.seed),
		clock = {
			date = CalendarDate.clone(bookmark.startDate),
			speed = options.clockConfig.DefaultSpeed,
			paused = options.clockConfig.StartPaused,
			-- The month before the start has, by definition, already been settled.
			lastProcessedMonthIndex = startMonthIndex - 1,
		},
		houses = houses,
		provinces = provinces,
		characters = characters,
		relations = relations,
		armies = {},
		nextArmySerial = 1,
	}
end

-- Accessors -----------------------------------------------------------------------------------

function CampaignState.sortedHouseIds(state: CampaignState): { string }
	return TableUtil.sortedKeys(state.houses)
end

function CampaignState.activeHouseIds(state: CampaignState): { string }
	local ids = {}
	for _, houseId in CampaignState.sortedHouseIds(state) do
		if not state.houses[houseId].extinct then
			table.insert(ids, houseId)
		end
	end
	return ids
end

-- Provinces legally owned by a house, sorted by id.
function CampaignState.ownedProvinces(state: CampaignState, houseId: string): { GameTypes.ProvinceState }
	local owned = {}
	for _, provinceId in Content.provinceIds do
		local province = state.provinces[provinceId]
		if province and province.ownerHouseId == houseId then
			table.insert(owned, province)
		end
	end
	return owned
end

function CampaignState.ruler(state: CampaignState, houseId: string): GameTypes.CharacterState?
	local house = state.houses[houseId]
	if not house then
		return nil
	end
	return state.characters[house.rulerId]
end

function CampaignState.relation(state: CampaignState, houseA: string, houseB: string): GameTypes.RelationState?
	return state.relations[DiplomacyRules.relationKey(houseA, houseB)]
end

-- Other houses that own a province adjacent to one of this house's provinces.
function CampaignState.neighbouringHouses(state: CampaignState, houseId: string): { [string]: boolean }
	local neighbours = {}
	for _, province in CampaignState.ownedProvinces(state, houseId) do
		for adjacentId in Content.provinces[province.id].adjacent do
			local adjacent = state.provinces[adjacentId]
			if adjacent and adjacent.ownerHouseId ~= houseId then
				neighbours[adjacent.ownerHouseId] = true
			end
		end
	end
	return neighbours
end

function CampaignState.currentMonthIndex(state: CampaignState): number
	return CalendarDate.monthIndex(state.clock.date)
end

-- Day number of the current date (CalendarDate.toDayNumber): the clock of army movement.
function CampaignState.todayNumber(state: CampaignState): number
	return CalendarDate.toDayNumber(state.clock.date)
end

local function sortedArmies(state: CampaignState, include: (army: GameTypes.ArmyState) -> boolean): { GameTypes.ArmyState }
	local armies = {}
	for _, armyId in TableUtil.sortedKeys(state.armies) do
		local army = state.armies[armyId]
		if include(army) then
			table.insert(armies, army)
		end
	end
	return armies
end

-- Armies of a house, sorted by id.
function CampaignState.armiesOf(state: CampaignState, houseId: string): { GameTypes.ArmyState }
	return sortedArmies(state, function(army)
		return army.houseId == houseId
	end)
end

-- Armies (of any house) whose location is a province, sorted by id. An army in transit is
-- located in the province it left until it arrives.
function CampaignState.armiesIn(state: CampaignState, provinceId: string): { GameTypes.ArmyState }
	return sortedArmies(state, function(army)
		return army.locationId == provinceId
	end)
end

return CampaignState
