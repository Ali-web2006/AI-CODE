--!strict
--[[
	CampaignSerializer — versioned conversion between live campaign state and a save record.

	Save record schema (schemaVersion 2, documented in docs/ARCHITECTURE.md §Persistence):
	{
	  format        = "IronThroneCampaign",
	  schemaVersion = 2,
	  savedAt       = unix seconds (number),
	  summary       = { campaignId, bookmarkId, date = {year,month,day}, hostHouseId? },
	  campaign      = {
	    campaignId, bookmarkId, seed, rngState, nextArmySerial,
	    clock      = { date, speed, lastProcessedMonthIndex },     -- loads paused
	    houses     = { [houseId] = { treasury, rulerId, extinct, ledger, aiNextEvaluationMonth,
	                                 armyUpkeepAccrued? } },
	    provinces  = { [provinceId] = { ownerHouseId, occupierHouseId?, development, levies,
	                                    garrisonTroops } },
	    characters = { [characterId] = { ...full character record... } },
	    relations  = { [relationKey] = { score, baseline, cooldowns } },
	    armies     = { [armyId] = { houseId, originId, commanderId?, locationId, units, morale,
	                                supply, route, legStartDay?, legEndDay?, gather, starving } },
	  },
	}
	The repository adds `revision` and `writerSessionId` for concurrency control.

	Every field is written and read explicitly (never by blind table copy), so runtime-only data
	can never leak into a save and malformed saves are rejected field by field.

	Content drift: entities present in the bookmark but missing from the save (content added after
	the save was made) are initialised from the bookmark and reported as warnings. Entities in the
	save that no longer exist in content are errors: the save is rejected and the live campaign is
	left untouched. Armies are not content: the saved set replaces the (empty) bookmark set, and an
	army that references an unknown province, unit, house or character fails the load.
	Balance drift: when a retune has lowered a maximum since the save was made, a saved levy or
	garrison pool above its province's current maximum, or an army's morale or supply above
	MoraleMax or SupplyMax, is lowered to that maximum with a warning (Military.processMonth does
	the same to pools in play). Negative or fractional values are still errors.
	armyUpkeepAccrued did not exist in the first schema 2 saves: absent, it loads as 0.

	Migrations: MIGRATIONS[n] upgrades a campaign table from version n to n + 1.
	  1 -> 2  adds armies (none) and the army id counter. Province levy and garrison pools did not
	          exist in schema 1: they load full at the saved development, without a warning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local DeterministicRng = require(ReplicatedStorage.Shared.Util.DeterministicRng)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local CampaignState = require(script.Parent.Parent.Simulation.CampaignState)
local SimContext = require(script.Parent.Parent.Simulation.SimContext)
local StateInvariants = require(script.Parent.Parent.Simulation.StateInvariants)

type Config = SimContext.Config

local CampaignSerializer = {}

CampaignSerializer.Format = "IronThroneCampaign"

local MIGRATIONS: { [number]: (campaign: { [string]: any }) -> { [string]: any } } = {}

-- Schema 1 -> 2: armies did not exist. The campaign table is still unvalidated here (deserialize
-- checks it afterwards), so this touches only top-level keys and never indexes a subtable.
MIGRATIONS[1] = function(campaign: { [string]: any }): { [string]: any }
	campaign.armies = {}
	campaign.nextArmySerial = 1
	return campaign
end

export type SaveSummary = {
	campaignId: string,
	bookmarkId: string,
	date: GameTypes.Date,
	hostHouseId: string?,
}

export type SaveRecord = {
	format: string,
	schemaVersion: number,
	savedAt: number,
	summary: SaveSummary,
	campaign: { [string]: any },
	revision: number?,
	writerSessionId: string?,
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value: any): boolean
	return isFiniteNumber(value) and math.floor(value) == value
end

local function optionalString(value: any): string?
	return if type(value) == "string" then value else nil
end

function CampaignSerializer.serialize(state: GameTypes.CampaignState, savedAt: number, hostHouseId: string?): SaveRecord
	local houses = {}
	for houseId, house in state.houses do
		local ledger = {}
		for _, entry in house.ledger do
			table.insert(ledger, {
				monthIndex = entry.monthIndex,
				income = entry.income,
				expenses = entry.expenses,
				net = entry.net,
				treasuryAfter = entry.treasuryAfter,
			})
		end
		houses[houseId] = {
			treasury = house.treasury,
			rulerId = house.rulerId,
			extinct = house.extinct,
			ledger = ledger,
			aiNextEvaluationMonth = house.ai.nextEvaluationMonth,
			armyUpkeepAccrued = house.armyUpkeepAccrued,
		}
	end

	local provinces = {}
	for provinceId, province in state.provinces do
		provinces[provinceId] = {
			ownerHouseId = province.ownerHouseId,
			occupierHouseId = province.occupierHouseId,
			development = province.development,
			levies = province.levies,
			garrisonTroops = province.garrisonTroops,
		}
	end

	local armies = {}
	for armyId, army in state.armies do
		armies[armyId] = {
			houseId = army.houseId,
			originId = army.originId,
			commanderId = army.commanderId,
			locationId = army.locationId,
			units = table.clone(army.units),
			morale = army.morale,
			supply = army.supply,
			route = table.clone(army.route),
			legStartDay = army.legStartDay,
			legEndDay = army.legEndDay,
			gather = army.gather,
			starving = army.starving,
		}
	end

	local characters = {}
	for characterId, character in state.characters do
		characters[characterId] = {
			givenName = character.givenName,
			houseId = character.houseId,
			sex = character.sex,
			birthDate = CalendarDate.clone(character.birthDate),
			deathDate = if character.deathDate then CalendarDate.clone(character.deathDate) else nil,
			fatherId = character.fatherId,
			motherId = character.motherId,
			spouseId = character.spouseId,
			cultureId = character.cultureId,
			faithId = character.faithId,
			skills = TableUtil.deepCopy(character.skills),
			traits = table.clone(character.traits),
			epithet = character.epithet,
			bastard = character.bastard,
		}
	end

	local relations = {}
	for key, relation in state.relations do
		relations[key] = {
			score = relation.score,
			baseline = relation.baseline,
			cooldowns = table.clone(relation.cooldowns),
		}
	end

	return {
		format = CampaignSerializer.Format,
		schemaVersion = state.schemaVersion,
		savedAt = savedAt,
		summary = {
			campaignId = state.campaignId,
			bookmarkId = state.bookmarkId,
			date = CalendarDate.clone(state.clock.date),
			hostHouseId = hostHouseId,
		},
		campaign = {
			campaignId = state.campaignId,
			bookmarkId = state.bookmarkId,
			seed = state.seed,
			rngState = state.rng.state,
			nextArmySerial = state.nextArmySerial,
			clock = {
				date = CalendarDate.clone(state.clock.date),
				speed = state.clock.speed,
				lastProcessedMonthIndex = state.clock.lastProcessedMonthIndex,
			},
			houses = houses,
			provinces = provinces,
			characters = characters,
			relations = relations,
			armies = armies,
		},
	}
end

export type DeserializeResult = {
	ok: boolean,
	state: GameTypes.CampaignState?,
	errors: { string },
	warnings: { string },
}

local function readCharacter(id: string, data: any, errors: { string }): GameTypes.CharacterState?
	local where = `character '{id}'`
	if type(data) ~= "table" then
		table.insert(errors, `{where}: not a table`)
		return nil
	end
	local skills = data.skills
	if type(skills) ~= "table" then
		table.insert(errors, `{where}: skills missing`)
		return nil
	end
	for _, skill in { "diplomacy", "martial", "stewardship", "intrigue", "learning", "prowess" } do
		if not isFiniteNumber(skills[skill]) then
			table.insert(errors, `{where}: skill '{skill}' invalid`)
			return nil
		end
	end
	if type(data.traits) ~= "table" then
		table.insert(errors, `{where}: traits missing`)
		return nil
	end
	local traits = {}
	for _, traitId in data.traits do
		if type(traitId) ~= "string" or not Content.traits[traitId] then
			table.insert(errors, `{where}: unknown trait '{tostring(traitId)}'`)
			return nil
		end
		table.insert(traits, traitId)
	end
	if type(data.givenName) ~= "string" or type(data.houseId) ~= "string" or (data.sex ~= "male" and data.sex ~= "female") then
		table.insert(errors, `{where}: identity fields invalid`)
		return nil
	end
	if not CalendarDate.isValid(data.birthDate) or (data.deathDate ~= nil and not CalendarDate.isValid(data.deathDate)) then
		table.insert(errors, `{where}: dates invalid`)
		return nil
	end
	if not Content.cultures[data.cultureId] or not Content.faiths[data.faithId] then
		table.insert(errors, `{where}: unknown culture or faith`)
		return nil
	end
	return {
		id = id,
		givenName = data.givenName,
		houseId = data.houseId,
		sex = data.sex,
		birthDate = CalendarDate.clone(data.birthDate),
		deathDate = if data.deathDate then CalendarDate.clone(data.deathDate) else nil,
		alive = data.deathDate == nil,
		fatherId = optionalString(data.fatherId),
		motherId = optionalString(data.motherId),
		spouseId = optionalString(data.spouseId),
		cultureId = data.cultureId,
		faithId = data.faithId,
		skills = {
			diplomacy = skills.diplomacy,
			martial = skills.martial,
			stewardship = skills.stewardship,
			intrigue = skills.intrigue,
			learning = skills.learning,
			prowess = skills.prowess,
		},
		traits = traits,
		epithet = optionalString(data.epithet),
		bastard = data.bastard == true,
	}
end

--[[
	Reads one saved army. References are checked against content and the already loaded houses and
	characters; ranges, adjacency and commander rules are left to StateInvariants.
]]
local function readArmy(id: string, data: any, state: GameTypes.CampaignState, errors: { string }): GameTypes.ArmyState?
	local where = `army '{id}'`
	local function invalid(problem: string): GameTypes.ArmyState?
		table.insert(errors, `{where}: {problem}`)
		return nil
	end
	if string.match(id, "^army_%d+$") == nil then
		return invalid("id is not of the form army_<serial>")
	end
	if type(data) ~= "table" then
		return invalid("not a table")
	end
	if type(data.houseId) ~= "string" or not state.houses[data.houseId] then
		return invalid(`unknown house '{tostring(data.houseId)}'`)
	end
	for _, field in { "originId", "locationId" } do
		local provinceId = data[field]
		if type(provinceId) ~= "string" or not Content.provinces[provinceId] then
			return invalid(`unknown province '{tostring(provinceId)}' in {field}`)
		end
	end
	if data.commanderId ~= nil and (type(data.commanderId) ~= "string" or not state.characters[data.commanderId]) then
		return invalid(`unknown commander '{tostring(data.commanderId)}'`)
	end
	if type(data.units) ~= "table" then
		return invalid("units missing")
	end
	local units: { [string]: number } = {}
	for unitId, count in data.units do
		if type(unitId) ~= "string" or not Content.units[unitId] then
			return invalid(`unknown unit '{tostring(unitId)}'`)
		end
		if not isInteger(count) then
			return invalid(`unit '{unitId}' has an invalid head count`)
		end
		units[unitId] = count
	end
	if not isInteger(data.morale) or not isInteger(data.supply) then
		return invalid("morale or supply invalid")
	end
	if type(data.route) ~= "table" then
		return invalid("route missing")
	end
	local count = 0
	for _ in data.route do
		count += 1
	end
	local route: { string } = {}
	for index = 1, count do
		local stop = data.route[index]
		if type(stop) ~= "string" or not Content.provinces[stop] then
			return invalid(`route stop {index} '{tostring(stop)}' is not a province`)
		end
		table.insert(route, stop)
	end
	for _, field in { "legStartDay", "legEndDay" } do
		if data[field] ~= nil and not isInteger(data[field]) then
			return invalid(`{field} invalid`)
		end
	end
	if type(data.gather) ~= "boolean" or type(data.starving) ~= "boolean" then
		return invalid("flags invalid")
	end
	return {
		id = id,
		houseId = data.houseId,
		originId = data.originId,
		commanderId = data.commanderId,
		locationId = data.locationId,
		units = units,
		morale = data.morale,
		supply = data.supply,
		route = route,
		legStartDay = data.legStartDay,
		legEndDay = data.legEndDay,
		gather = data.gather,
		starving = data.starving,
	}
end

function CampaignSerializer.deserialize(record: any, config: Config): DeserializeResult
	local errors: { string } = {}
	local warnings: { string } = {}
	local function fail(message: string): DeserializeResult
		table.insert(errors, message)
		return { ok = false, state = nil, errors = errors, warnings = warnings }
	end

	if type(record) ~= "table" or record.format ~= CampaignSerializer.Format then
		return fail("not an Iron Throne campaign save")
	end
	if not isInteger(record.schemaVersion) then
		return fail("save has no schema version")
	end
	if record.schemaVersion > config.SchemaVersion then
		return fail(`save uses schema {record.schemaVersion}, newer than this server's {config.SchemaVersion}`)
	end
	local campaign = record.campaign
	if type(campaign) ~= "table" then
		return fail("save has no campaign data")
	end
	local version = record.schemaVersion
	-- Province levy and garrison pools exist from schema 2 on; older saves load them full.
	local poolsSaved = version >= 2
	while version < config.SchemaVersion do
		local migrate = MIGRATIONS[version]
		if not migrate then
			return fail(`no migration from schema {version}`)
		end
		campaign = migrate(campaign)
		version += 1
	end

	local bookmark = Content.bookmarks[campaign.bookmarkId]
	if not bookmark then
		return fail(`unknown bookmark '{tostring(campaign.bookmarkId)}'`)
	end
	if not isInteger(campaign.seed) or type(campaign.campaignId) ~= "string" then
		return fail("campaign identity is invalid")
	end
	if not DeterministicRng.isValidState(campaign.rngState) then
		return fail("rng state is invalid")
	end

	-- Start from the bookmark so content added after the save is initialised sensibly, then
	-- overlay every saved entity.
	local state = CampaignState.createFromBookmark(bookmark, {
		seed = campaign.seed,
		campaignId = campaign.campaignId,
		schemaVersion = config.SchemaVersion,
		clockConfig = config.Clock,
		aiConfig = config.AI,
		militaryConfig = config.Military,
	})
	state.rng.state = campaign.rngState

	local clock = campaign.clock
	if type(clock) ~= "table" or not CalendarDate.isValid(clock.date) or not isInteger(clock.speed)
		or not isInteger(clock.lastProcessedMonthIndex) then
		return fail("clock is invalid")
	end
	state.clock.date = CalendarDate.clone(clock.date)
	state.clock.speed = clock.speed
	state.clock.lastProcessedMonthIndex = clock.lastProcessedMonthIndex
	-- A loaded campaign always starts paused so every player can orient themselves.
	state.clock.paused = true

	if type(campaign.characters) ~= "table" then
		return fail("characters are missing")
	end
	local savedCharacters = {}
	for characterId, data in campaign.characters do
		if type(characterId) ~= "string" then
			return fail("character table has a non-string key")
		end
		local character = readCharacter(characterId, data, errors)
		if not character then
			return { ok = false, state = nil, errors = errors, warnings = warnings }
		end
		savedCharacters[characterId] = true
		state.characters[characterId] = character
	end
	for characterId in state.characters do
		if not savedCharacters[characterId] then
			table.insert(warnings, `character '{characterId}' was not in the save; initialised from the bookmark`)
		end
	end

	if type(campaign.houses) ~= "table" then
		return fail("houses are missing")
	end
	for houseId, data in campaign.houses do
		local house = state.houses[houseId]
		if not house then
			return fail(`house '{tostring(houseId)}' is not part of bookmark '{bookmark.id}'`)
		end
		if type(data) ~= "table" or not isFiniteNumber(data.treasury) or type(data.rulerId) ~= "string"
			or type(data.extinct) ~= "boolean" or not isInteger(data.aiNextEvaluationMonth) or type(data.ledger) ~= "table" then
			return fail(`house '{houseId}' is malformed`)
		end
		local accrued = if data.armyUpkeepAccrued == nil then 0 else data.armyUpkeepAccrued
		if not isFiniteNumber(accrued) or accrued < 0 then
			return fail(`house '{houseId}' has invalid accrued army upkeep`)
		end
		local ledger = {}
		for _, entry in data.ledger do
			if type(entry) ~= "table" or not isInteger(entry.monthIndex) or not isFiniteNumber(entry.income)
				or not isFiniteNumber(entry.expenses) or not isFiniteNumber(entry.net) or not isFiniteNumber(entry.treasuryAfter) then
				return fail(`house '{houseId}' has a malformed ledger entry`)
			end
			table.insert(ledger, {
				monthIndex = entry.monthIndex,
				income = entry.income,
				expenses = entry.expenses,
				net = entry.net,
				treasuryAfter = entry.treasuryAfter,
			})
		end
		house.treasury = data.treasury
		house.rulerId = data.rulerId
		house.extinct = data.extinct
		house.ledger = ledger
		house.armyUpkeepAccrued = accrued
		house.ai.nextEvaluationMonth = data.aiNextEvaluationMonth
	end
	for houseId in state.houses do
		if campaign.houses[houseId] == nil then
			table.insert(warnings, `house '{houseId}' was not in the save; initialised from the bookmark`)
		end
	end

	if type(campaign.provinces) ~= "table" then
		return fail("provinces are missing")
	end
	for provinceId, data in campaign.provinces do
		local province = state.provinces[provinceId]
		if not province then
			return fail(`province '{tostring(provinceId)}' no longer exists in the world map`)
		end
		if type(data) ~= "table" or type(data.ownerHouseId) ~= "string" or not isInteger(data.development)
			or (data.occupierHouseId ~= nil and type(data.occupierHouseId) ~= "string") then
			return fail(`province '{provinceId}' is malformed`)
		end
		province.ownerHouseId = data.ownerHouseId
		province.occupierHouseId = data.occupierHouseId
		province.development = data.development
		local leviesMax = MilitaryRules.provinceLevyMax(province, config.Military)
		local garrisonMax = MilitaryRules.provinceGarrisonMax(province, config.Military)
		local levies, garrisonTroops = data.levies, data.garrisonTroops
		if not poolsSaved and levies == nil and garrisonTroops == nil then
			levies, garrisonTroops = leviesMax, garrisonMax
		elseif not isInteger(levies) or not isInteger(garrisonTroops) then
			return fail(`province '{provinceId}' is malformed`)
		end
		-- Balance drift: a maximum lowered since the save was made.
		if levies > leviesMax then
			table.insert(warnings, `province '{provinceId}': levies {levies} lowered to the current maximum {leviesMax}`)
			levies = leviesMax
		end
		if garrisonTroops > garrisonMax then
			table.insert(warnings, `province '{provinceId}': garrison {garrisonTroops} lowered to the current maximum {garrisonMax}`)
			garrisonTroops = garrisonMax
		end
		province.levies = levies
		province.garrisonTroops = garrisonTroops
	end
	for provinceId in state.provinces do
		if campaign.provinces[provinceId] == nil then
			table.insert(warnings, `province '{provinceId}' was not in the save; initialised from the bookmark`)
		end
	end

	if type(campaign.relations) ~= "table" then
		return fail("relations are missing")
	end
	for key, data in campaign.relations do
		local relation = state.relations[key]
		if not relation then
			return fail(`relation '{tostring(key)}' does not match any pair of houses`)
		end
		if type(data) ~= "table" or not isFiniteNumber(data.score) or not isFiniteNumber(data.baseline) or type(data.cooldowns) ~= "table" then
			return fail(`relation '{key}' is malformed`)
		end
		local cooldowns = {}
		for houseId, month in data.cooldowns do
			if type(houseId) ~= "string" or not isInteger(month) then
				return fail(`relation '{key}' has a malformed cooldown`)
			end
			cooldowns[houseId] = month
		end
		relation.score = data.score
		relation.baseline = data.baseline
		relation.cooldowns = cooldowns
	end

	-- Armies replace the bookmark's (empty) set: an army absent from the save no longer exists.
	if type(campaign.armies) ~= "table" then
		return fail("armies are missing")
	end
	if not isInteger(campaign.nextArmySerial) then
		return fail("the army id counter is invalid")
	end
	local armies: { [string]: GameTypes.ArmyState } = {}
	for armyId, data in campaign.armies do
		if type(armyId) ~= "string" then
			return fail("army table has a non-string key")
		end
		local army = readArmy(armyId, data, state, errors)
		if not army then
			return { ok = false, state = nil, errors = errors, warnings = warnings }
		end
		-- Balance drift: a MoraleMax or SupplyMax lowered since the save was made.
		if army.morale > config.Military.MoraleMax then
			table.insert(warnings, `army '{armyId}': morale {army.morale} lowered to the current maximum {config.Military.MoraleMax}`)
			army.morale = config.Military.MoraleMax
		end
		if army.supply > config.Military.SupplyMax then
			table.insert(warnings, `army '{armyId}': supply {army.supply} lowered to the current maximum {config.Military.SupplyMax}`)
			army.supply = config.Military.SupplyMax
		end
		armies[armyId] = army
	end
	state.armies = armies
	state.nextArmySerial = campaign.nextArmySerial

	local violations = StateInvariants.check(state, config)
	if #violations > 0 then
		for _, violation in violations do
			table.insert(errors, violation)
		end
		return { ok = false, state = nil, errors = errors, warnings = warnings }
	end
	return { ok = true, state = state, errors = errors, warnings = warnings }
end

return CampaignSerializer
