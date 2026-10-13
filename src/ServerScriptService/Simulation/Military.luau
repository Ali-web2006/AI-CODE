--!strict
--[[
	Military — authoritative military operations on campaign state.

	Formulas live in Shared/Rules/MilitaryRules and MovementRules; this module applies them:
	  * check*/apply* pairs for the army commands (raise, call all levies, move, stop, split,
	    merge, disband), shared by players and (in later phases) the AI. A check is pure and never
	    throws; an apply re-checks, computes first, mutates last, marks the journal, emits its event
	    and returns (true, data) or (false, check).
	  * processDay, the first daily system: armies arrive, gather and depart; every army accrues a
	    day of upkeep; every SupplyTickDays days supply, morale and starvation attrition are applied.
	  * processMonth, after Economy and before Diplomacy and the AI: levy and garrison pools refill.

	Movement: an army stores its remaining route and the day numbers of the current leg. Nothing
	changes while it marches, so it is marked dirty only when it departs, arrives or merges, and
	clients interpolate its position from legStartDay/legEndDay and the replicated day number.
	A sea leg needs enough free ships: the ships of the house's held provinces minus those carrying
	its armies already at sea. Without them the army waits (route set, both leg days nil) and tries
	again every day.

	Army changes that can alter the house view (troop totals, upkeep, ships in use) also mark the
	owning house; a supply tick that changes only supply, morale or the starving flag marks the
	army alone, so house panels do not redraw every few days.

	Gold is never touched here. Each day every army adds its monthly upkeep to
	house.armyUpkeepAccrued; Economy charges the accrued sum pro rata in the monthly ledger, so an
	army pays for exactly the days it was in the field. Disbanding refunds nothing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CharacterRules = require(ReplicatedStorage.Shared.Rules.CharacterRules)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local MovementRules = require(ReplicatedStorage.Shared.Rules.MovementRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local TableUtil = require(ReplicatedStorage.Shared.Util.TableUtil)
local CampaignState = require(script.Parent.CampaignState)
local SimContext = require(script.Parent.SimContext)

type SimContext = SimContext.SimContext
type ArmyState = GameTypes.ArmyState
type ProvinceState = GameTypes.ProvinceState

local Codes = Protocol.ResultCodes

-- Rounding up whole men or supply points must not turn 864.0000000000001 into 865.
local CEIL_EPSILON = 1e-9

-- One army raised by a call to arms, and its route to the rally province ({} for the rally itself).
export type RaisePlanEntry = {
	provinceId: string,
	route: { string },
}

export type MilitaryCheck = {
	ok: boolean,
	code: string,
	message: string,
	-- RaiseArmy and RaiseAllLevies: men raised. SplitArmy: men split off.
	troops: number?,
	-- MoveArmy: the new stops after the army's next stop, and the days until it arrives.
	path: { string }?,
	days: number?,
	-- RaiseAllLevies: the provinces that raise an army, rally province first.
	plan: { RaisePlanEntry }?,
}

local Military = {}

local function reject(code: string, message: string): MilitaryCheck
	return { ok = false, code = code, message = message }
end

local function ceilWhole(value: number): number
	return math.ceil(value - CEIL_EPSILON)
end

local function men(count: number): string
	return EventText.troops(count)
end

-- The house owns the province and no other house occupies it: it may raise levies there, and
-- the province's ships sail for it.
function Military.holdsProvince(province: ProvinceState, houseId: string): boolean
	return province.ownerHouseId == houseId and (province.occupierHouseId == nil or province.occupierHouseId == houseId)
end

-- The house controls the ground: its own unoccupied land, or land it occupies. Armies resupply there.
local function controls(province: ProvinceState, houseId: string): boolean
	if province.occupierHouseId ~= nil then
		return province.occupierHouseId == houseId
	end
	return province.ownerHouseId == houseId
end

-- Army status ----------------------------------------------------------------------------------

-- Marching along a leg (legStartDay/legEndDay set).
function Military.inTransit(army: ArmyState): boolean
	return army.legStartDay ~= nil
end

-- No orders: an empty route.
function Military.isIdle(army: ArmyState): boolean
	return #army.route == 0
end

-- In transit on a sea leg: the army is aboard ships.
function Military.atSea(army: ArmyState): boolean
	if army.legStartDay == nil or #army.route == 0 then
		return false
	end
	local definition = Content.provinces[army.locationId]
	return definition ~= nil and definition.adjacent[army.route[1]] == "sea"
end

-- Ships --------------------------------------------------------------------------------------

-- The house's fleet: ships of every province it holds.
function Military.shipsTotal(sim: SimContext, houseId: string): number
	local total = 0
	for _, province in CampaignState.ownedProvinces(sim.state, houseId) do
		if Military.holdsProvince(province, houseId) then
			total += MilitaryRules.ships(province.id, province.development)
		end
	end
	return total
end

-- Ships carrying the house's armies that are at sea right now.
function Military.shipsInUse(sim: SimContext, houseId: string): number
	local total = 0
	for _, army in CampaignState.armiesOf(sim.state, houseId) do
		if Military.atSea(army) then
			total += MilitaryRules.shipsNeeded(MilitaryRules.troops(army.units), sim.config.Military)
		end
	end
	return total
end

-- Commanders -----------------------------------------------------------------------------------

-- Characters already commanding an army (optionally ignoring one army).
local function commandersInUse(state: GameTypes.CampaignState, excludeArmyId: string?): { [string]: boolean }
	local taken = {}
	for armyId, army in state.armies do
		if armyId ~= excludeArmyId and army.commanderId ~= nil then
			taken[army.commanderId] = true
		end
	end
	return taken
end

-- a ranks above b as a commander: higher martial, then the ruler, then the smaller id.
local function outranks(a: GameTypes.CharacterState, b: GameTypes.CharacterState, rulerId: string?): boolean
	if a.skills.martial ~= b.skills.martial then
		return a.skills.martial > b.skills.martial
	end
	if (a.id == rulerId) ~= (b.id == rulerId) then
		return a.id == rulerId
	end
	return a.id < b.id
end

local function pickCommander(sim: SimContext, houseId: string, taken: { [string]: boolean }): string?
	local state = sim.state
	local house = state.houses[houseId]
	local rulerId = if house then house.rulerId else nil
	local best: GameTypes.CharacterState? = nil
	for _, characterId in TableUtil.sortedKeys(state.characters) do
		local character = state.characters[characterId]
		if character.alive
			and character.houseId == houseId
			and not taken[characterId]
			-- CharacterLike declares `bastard` optional; CharacterState always has it.
			and CharacterRules.age(character :: any, state.clock.date) >= sim.config.Military.MinCommanderAge
		then
			if best == nil or outranks(character, best, rulerId) then
				best = character
			end
		end
	end
	return if best then best.id else nil
end

--[[
	The best available commander of a house: an adult (MinCommanderAge) living member who does not
	already command an army (the army `excludeArmyId` does not count); highest martial first, ties
	to the ruler, then by character id. nil when nobody is available: the army is leaderless.
]]
function Military.bestCommander(sim: SimContext, houseId: string, excludeArmyId: string?): string?
	return pickCommander(sim, houseId, commandersInUse(sim.state, excludeArmyId))
end

-- Helpers --------------------------------------------------------------------------------------

local function houseCheck(sim: SimContext, houseId: string): MilitaryCheck?
	local house = sim.state.houses[houseId]
	if not house or house.extinct then
		return reject(Codes.NotAuthorized, "Your house no longer exists.")
	end
	return nil
end

-- The army, when it exists and belongs to the house; otherwise the rejection.
local function ownArmy(sim: SimContext, houseId: string, armyId: string): (ArmyState?, MilitaryCheck?)
	local army = sim.state.armies[armyId]
	if not army then
		return nil, reject(Codes.NotFound, "That army does not exist.")
	end
	if army.houseId ~= houseId then
		return nil, reject(Codes.NotOwner, `The {MilitaryRules.armyName(army)} does not answer to your house.`)
	end
	return army, nil
end

local function newArmy(sim: SimContext, armyId: string, houseId: string, provinceId: string, troops: number, commanderId: string?): ArmyState
	local config = sim.config.Military
	local units = MilitaryRules.splitMen(troops, MilitaryRules.composition(houseId))
	return {
		id = armyId,
		houseId = houseId,
		originId = provinceId,
		commanderId = commanderId,
		locationId = provinceId,
		units = units,
		morale = MilitaryRules.moraleStart(units, config),
		supply = config.SupplyMax,
		route = {},
		legStartDay = nil,
		legEndDay = nil,
		gather = false,
		starving = false,
	}
end

local function markArmy(sim: SimContext, army: ArmyState)
	sim.journal:markArmy(army.id)
	sim.journal:markHouse(army.houseId)
end

local function removeArmy(sim: SimContext, army: ArmyState)
	sim.state.armies[army.id] = nil
	sim.journal:markArmyRemoved(army.id)
	sim.journal:markHouse(army.houseId)
end

--[[
	Starts the next leg of an army that has a route but no leg running (just raised, just arrived,
	or waiting for ships) on `dayNumber`. Land legs always start; a sea leg starts only when the
	house has enough free ships. Returns true when a leg started. Mutates the army but does not
	mark it; callers do.
]]
function Military.tryDepart(sim: SimContext, army: ArmyState, dayNumber: number): boolean
	if #army.route == 0 or army.legStartDay ~= nil then
		return false
	end
	local config = sim.config.Military
	local nextId = army.route[1]
	local definition = Content.provinces[army.locationId]
	local kind = if definition then definition.adjacent[nextId] else nil
	local days = MilitaryRules.legDays(army.locationId, nextId, army.units, config)
	if kind == nil or days == nil then
		return false
	end
	if kind == "sea" then
		local free = Military.shipsTotal(sim, army.houseId) - Military.shipsInUse(sim, army.houseId)
		if free < MilitaryRules.shipsNeeded(MilitaryRules.troops(army.units), config) then
			return false
		end
	end
	army.legStartDay = dayNumber
	army.legEndDay = dayNumber + days
	return true
end

--[[
	Joins `army` into `target` (both idle, same house and province): units are summed, morale and
	supply become head-count-weighted averages, and the target keeps its commander unless the
	joining one has higher martial. `army` is removed. Returns the merged head count.
]]
local function mergeInto(sim: SimContext, army: ArmyState, target: ArmyState): number
	local state = sim.state
	local joining = MilitaryRules.troops(army.units)
	local staying = MilitaryRules.troops(target.units)
	local total = joining + staying
	local units = table.clone(target.units)
	for unitId, count in army.units do
		units[unitId] = (units[unitId] or 0) + count
	end
	local morale = math.floor((army.morale * joining + target.morale * staying) / total + 0.5)
	local supply = math.floor((army.supply * joining + target.supply * staying) / total + 0.5)
	local commanderId = target.commanderId
	local joiningCommander = if army.commanderId then state.characters[army.commanderId] else nil
	local targetCommander = if target.commanderId then state.characters[target.commanderId] else nil
	if joiningCommander and (targetCommander == nil or joiningCommander.skills.martial > targetCommander.skills.martial) then
		commanderId = joiningCommander.id
	end

	target.units = units
	target.morale = morale
	target.supply = supply
	target.starving = supply == 0
	target.commanderId = commanderId
	removeArmy(sim, army)
	markArmy(sim, target)
	SimContext.emitEvent(sim, "ArmiesMerged", "low", { target.houseId }, {
		houseId = target.houseId,
		armyId = target.id,
		mergedId = army.id,
		originId = target.originId,
		troops = total,
	})
	return total
end

-- Raise an army ----------------------------------------------------------------------------------

function Military.checkRaiseArmy(sim: SimContext, houseId: string, provinceId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local state = sim.state
	local province = state.provinces[provinceId]
	local definition = Content.provinces[provinceId]
	if not province or not definition then
		return reject(Codes.NotFound, "That province does not exist.")
	end
	if province.ownerHouseId ~= houseId then
		return reject(Codes.NotOwner, `{definition.name} does not belong to your house.`)
	end
	if not Military.holdsProvince(province, houseId) then
		return reject(Codes.NotOwner, `{definition.name} is occupied; its levies cannot be raised.`)
	end
	local config = sim.config.Military
	if province.levies < config.MinArmySize then
		return reject(
			Codes.NotEnoughTroops,
			`{definition.name} has {men(province.levies)} levies; at least {men(config.MinArmySize)} are needed to raise an army.`
		)
	end
	if #CampaignState.armiesOf(state, houseId) >= config.MaxArmiesPerHouse then
		return reject(Codes.LimitReached, `Your house already fields {config.MaxArmiesPerHouse} armies, the most it can keep.`)
	end
	return { ok = true, code = Codes.Ok, message = "", troops = province.levies }
end

-- Raises every available levy of a province into a new army led by the best free commander.
function Military.applyRaiseArmy(sim: SimContext, houseId: string, provinceId: string): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkRaiseArmy(sim, houseId, provinceId)
	if not check.ok then
		return false, check
	end
	local state = sim.state
	local troops = check.troops :: number
	local army = newArmy(sim, `army_{state.nextArmySerial}`, houseId, provinceId, troops, Military.bestCommander(sim, houseId))

	state.provinces[provinceId].levies = 0
	state.nextArmySerial += 1
	state.armies[army.id] = army

	sim.journal:markProvince(provinceId)
	markArmy(sim, army)
	SimContext.emitEvent(sim, "ArmyRaised", "normal", { houseId }, {
		houseId = houseId,
		armyId = army.id,
		provinceId = provinceId,
		troops = troops,
	})
	return true, {
		armyId = army.id,
		provinceId = provinceId,
		troops = troops,
		commanderId = army.commanderId,
	}
end

-- Call all levies --------------------------------------------------------------------------------

function Military.checkRaiseAllLevies(sim: SimContext, houseId: string, rallyProvinceId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local state = sim.state
	local rally = state.provinces[rallyProvinceId]
	local definition = Content.provinces[rallyProvinceId]
	if not rally or not definition then
		return reject(Codes.NotFound, "That province does not exist.")
	end
	if rally.ownerHouseId ~= houseId then
		return reject(Codes.NotOwner, `{definition.name} does not belong to your house.`)
	end
	if not Military.holdsProvince(rally, houseId) then
		return reject(Codes.NotOwner, `{definition.name} is occupied; your levies cannot gather there.`)
	end

	local config = sim.config.Military
	local ships = Military.shipsTotal(sim, houseId)
	-- The rally province raises first, so its army receives the best commander.
	local order = { rallyProvinceId }
	for _, province in CampaignState.ownedProvinces(state, houseId) do
		if province.id ~= rallyProvinceId then
			table.insert(order, province.id)
		end
	end

	local plan: { RaisePlanEntry } = {}
	local troops = 0
	local anyLevies = false
	for _, provinceId in order do
		local province = state.provinces[provinceId]
		if Military.holdsProvince(province, houseId) and province.levies >= config.MinArmySize then
			anyLevies = true
			local route: { string }? = {}
			if provinceId ~= rallyProvinceId then
				-- Without enough ships for the whole levy, a province reaches the rally by land or not at all.
				local units = MilitaryRules.splitMen(province.levies, MilitaryRules.composition(houseId))
				local canSail = ships >= MilitaryRules.shipsNeeded(province.levies, config)
				route = MovementRules.findPath(provinceId, rallyProvinceId, units, canSail, config)
			end
			if route then
				table.insert(plan, { provinceId = provinceId, route = route })
				troops += province.levies
			end
		end
	end
	if not anyLevies then
		return reject(Codes.NotEnoughTroops, `No province of your house has the {men(config.MinArmySize)} levies needed to raise an army.`)
	end
	if #plan == 0 then
		return reject(Codes.NotEnoughTroops, `None of your levies can reach {definition.name}.`)
	end
	local fielded = #CampaignState.armiesOf(state, houseId)
	if fielded + #plan > config.MaxArmiesPerHouse then
		return reject(
			Codes.LimitReached,
			`Calling every levy would raise {#plan} armies; your house can keep {config.MaxArmiesPerHouse} and already fields {fielded}.`
		)
	end
	return { ok = true, code = Codes.Ok, message = "", troops = troops, plan = plan }
end

--[[
	Raises an army in every held province with enough levies that can reach the rally province.
	The armies raised elsewhere march to the rally with `gather` set and merge on arrival.
]]
function Military.applyRaiseAllLevies(sim: SimContext, houseId: string, rallyProvinceId: string): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkRaiseAllLevies(sim, houseId, rallyProvinceId)
	if not check.ok then
		return false, check
	end
	local state = sim.state
	local plan = check.plan :: { RaisePlanEntry }
	local taken = commandersInUse(state, nil)
	local armies: { ArmyState } = {}
	local armyIds: { string } = {}
	for index, entry in plan do
		local commanderId = pickCommander(sim, houseId, taken)
		if commanderId then
			taken[commanderId] = true
		end
		local levies = state.provinces[entry.provinceId].levies
		local army = newArmy(sim, `army_{state.nextArmySerial + index - 1}`, houseId, entry.provinceId, levies, commanderId)
		army.route = table.clone(entry.route)
		army.gather = #entry.route > 0
		table.insert(armies, army)
		table.insert(armyIds, army.id)
	end

	local today = CampaignState.todayNumber(state)
	state.nextArmySerial += #armies
	for _, army in armies do
		state.provinces[army.originId].levies = 0
		state.armies[army.id] = army
		Military.tryDepart(sim, army, today)
		sim.journal:markProvince(army.originId)
		markArmy(sim, army)
	end
	local troops = check.troops :: number
	SimContext.emitEvent(sim, "LeviesCalled", "normal", { houseId }, {
		houseId = houseId,
		provinceId = rallyProvinceId,
		armies = #armies,
		troops = troops,
	})
	return true, {
		provinceId = rallyProvinceId,
		armies = #armies,
		troops = troops,
		armyIds = armyIds,
	}
end

-- Move and stop ----------------------------------------------------------------------------------

function Military.checkMoveArmy(sim: SimContext, houseId: string, armyId: string, provinceId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local army, armyProblem = ownArmy(sim, houseId, armyId)
	if not army then
		return armyProblem :: MilitaryCheck
	end
	local state = sim.state
	local definition = Content.provinces[provinceId]
	if not definition or not state.provinces[provinceId] then
		return reject(Codes.NotFound, "That province does not exist.")
	end
	local name = MilitaryRules.armyName(army)
	-- An army waiting for ships still stands where it is: sending it there is no march (Stop
	-- cancels the wait).
	if not Military.inTransit(army) and provinceId == army.locationId then
		return reject(Codes.InvalidTarget, `The {name} is already at {definition.name}.`)
	end
	local destination = if #army.route > 0 then army.route[#army.route] else army.locationId
	if provinceId == destination then
		if #army.route > 0 then
			return reject(Codes.InvalidTarget, `The {name} is already marching to {definition.name}.`)
		end
		return reject(Codes.InvalidTarget, `The {name} is already at {definition.name}.`)
	end

	-- An army on the road finishes its current leg first; the new route starts where it ends.
	local inTransit = Military.inTransit(army)
	local start = if inTransit then army.route[1] else army.locationId
	local config = sim.config.Military
	local needed = MilitaryRules.shipsNeeded(MilitaryRules.troops(army.units), config)
	local ships = Military.shipsTotal(sim, houseId)
	local canSail = ships >= needed
	local path, days = MovementRules.findPath(start, provinceId, army.units, canSail, config)
	if path == nil then
		if not canSail and MovementRules.findPath(start, provinceId, army.units, true, config) ~= nil then
			return reject(
				Codes.NotEnoughShips,
				`Only a voyage reaches {definition.name}: the {name} needs {needed} ships and your house has {ships}.`
			)
		end
		return reject(Codes.NoPath, `The {name} has no way to reach {definition.name}.`)
	end
	if inTransit then
		days += math.max(0, (army.legEndDay :: number) - CampaignState.todayNumber(state))
	end
	return { ok = true, code = Codes.Ok, message = "", path = path, days = days }
end

--[[
	Gives an army a new destination. In transit, the current leg is kept and the rest of the route
	replaced; otherwise the new route starts at once (a sea leg may have to wait for ships).
]]
function Military.applyMoveArmy(
	sim: SimContext,
	houseId: string,
	armyId: string,
	provinceId: string
): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkMoveArmy(sim, houseId, armyId, provinceId)
	if not check.ok then
		return false, check
	end
	local army = sim.state.armies[armyId]
	local path = check.path :: { string }
	if Military.inTransit(army) then
		local route = { army.route[1] }
		for _, stop in path do
			table.insert(route, stop)
		end
		army.route = route
	else
		army.route = table.clone(path)
		army.legStartDay = nil
		army.legEndDay = nil
		Military.tryDepart(sim, army, CampaignState.todayNumber(sim.state))
	end
	army.gather = false
	markArmy(sim, army)
	return true, {
		armyId = armyId,
		originId = army.originId,
		provinceId = provinceId,
		days = check.days,
		waiting = #army.route > 0 and not Military.inTransit(army),
	}
end

function Military.checkStopArmy(sim: SimContext, houseId: string, armyId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local army, armyProblem = ownArmy(sim, houseId, armyId)
	if not army then
		return armyProblem :: MilitaryCheck
	end
	if Military.isIdle(army) then
		return reject(Codes.InvalidTarget, `The {MilitaryRules.armyName(army)} has no orders to cancel.`)
	end
	return { ok = true, code = Codes.Ok, message = "" }
end

-- Cancels an army's orders: in transit it halts at the end of the current leg; waiting, it stays.
function Military.applyStopArmy(sim: SimContext, houseId: string, armyId: string): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkStopArmy(sim, houseId, armyId)
	if not check.ok then
		return false, check
	end
	local army = sim.state.armies[armyId]
	if Military.inTransit(army) then
		army.route = { army.route[1] }
	else
		army.route = {}
	end
	army.gather = false
	markArmy(sim, army)
	return true, {
		armyId = armyId,
		originId = army.originId,
		provinceId = if #army.route > 0 then army.route[1] else army.locationId,
	}
end

-- Split and merge --------------------------------------------------------------------------------

function Military.checkSplitArmy(sim: SimContext, houseId: string, armyId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local army, armyProblem = ownArmy(sim, houseId, armyId)
	if not army then
		return armyProblem :: MilitaryCheck
	end
	local name = MilitaryRules.armyName(army)
	if not Military.isIdle(army) then
		return reject(Codes.InvalidTarget, `The {name} cannot divide while it has orders to march.`)
	end
	local config = sim.config.Military
	local troops = MilitaryRules.troops(army.units)
	local _, split = MilitaryRules.halve(army.units)
	local splitTroops = MilitaryRules.troops(split)
	if troops < 2 * config.MinArmySize or splitTroops < config.MinArmySize then
		return reject(
			Codes.NotEnoughTroops,
			`The {name} has {men(troops)} men; each half must have at least {men(config.MinArmySize)}.`
		)
	end
	if #CampaignState.armiesOf(sim.state, houseId) >= config.MaxArmiesPerHouse then
		return reject(Codes.LimitReached, `Your house already fields {config.MaxArmiesPerHouse} armies, the most it can keep.`)
	end
	return { ok = true, code = Codes.Ok, message = "", troops = splitTroops }
end

-- Halves every unit of an idle army; the new half gets the next best free commander.
function Military.applySplitArmy(sim: SimContext, houseId: string, armyId: string): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkSplitArmy(sim, houseId, armyId)
	if not check.ok then
		return false, check
	end
	local state = sim.state
	local army = state.armies[armyId]
	local keep, split = MilitaryRules.halve(army.units)
	local half: ArmyState = {
		id = `army_{state.nextArmySerial}`,
		houseId = houseId,
		originId = army.originId,
		commanderId = Military.bestCommander(sim, houseId),
		locationId = army.locationId,
		units = split,
		morale = army.morale,
		supply = army.supply,
		route = {},
		legStartDay = nil,
		legEndDay = nil,
		gather = false,
		starving = army.starving,
	}

	army.units = keep
	state.nextArmySerial += 1
	state.armies[half.id] = half
	markArmy(sim, army)
	markArmy(sim, half)
	local troops = check.troops :: number
	SimContext.emitEvent(sim, "ArmySplit", "low", { houseId }, {
		houseId = houseId,
		armyId = armyId,
		newArmyId = half.id,
		originId = army.originId,
		troops = troops,
	})
	return true, {
		armyId = armyId,
		newArmyId = half.id,
		originId = army.originId,
		troops = troops,
		kept = MilitaryRules.troops(keep),
	}
end

function Military.checkMergeArmies(sim: SimContext, houseId: string, armyId: string, intoArmyId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local army, armyProblem = ownArmy(sim, houseId, armyId)
	if not army then
		return armyProblem :: MilitaryCheck
	end
	local target, targetProblem = ownArmy(sim, houseId, intoArmyId)
	if not target then
		return targetProblem :: MilitaryCheck
	end
	if army.id == target.id then
		return reject(Codes.InvalidTarget, "An army cannot merge with itself.")
	end
	if not Military.isIdle(army) or not Military.isIdle(target) then
		return reject(Codes.InvalidTarget, "Only armies without marching orders can merge.")
	end
	if army.locationId ~= target.locationId then
		return reject(Codes.InvalidTarget, "Armies can only merge in the same province.")
	end
	return { ok = true, code = Codes.Ok, message = "" }
end

-- Joins `armyId` into `intoArmyId`; `armyId` ceases to exist.
function Military.applyMergeArmies(
	sim: SimContext,
	houseId: string,
	armyId: string,
	intoArmyId: string
): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkMergeArmies(sim, houseId, armyId, intoArmyId)
	if not check.ok then
		return false, check
	end
	local target = sim.state.armies[intoArmyId]
	local troops = mergeInto(sim, sim.state.armies[armyId], target)
	return true, {
		armyId = intoArmyId,
		mergedId = armyId,
		originId = target.originId,
		troops = troops,
	}
end

-- Disband ----------------------------------------------------------------------------------------

function Military.checkDisbandArmy(sim: SimContext, houseId: string, armyId: string): MilitaryCheck
	local problem = houseCheck(sim, houseId)
	if problem then
		return problem
	end
	local army, armyProblem = ownArmy(sim, houseId, armyId)
	if not army then
		return armyProblem :: MilitaryCheck
	end
	return { ok = true, code = Codes.Ok, message = "" }
end

--[[
	Sends an army home. Its men refill the levy pools of the house's held provinces, shared by each
	pool's shortfall (largest remainder, never above the maximum); men beyond what the pools can take
	are lost. No gold is refunded.
]]
function Military.applyDisbandArmy(sim: SimContext, houseId: string, armyId: string): (boolean, MilitaryCheck | { [string]: any })
	local check = Military.checkDisbandArmy(sim, houseId, armyId)
	if not check.ok then
		return false, check
	end
	local state = sim.state
	local config = sim.config.Military
	local army = state.armies[armyId]
	local troops = MilitaryRules.troops(army.units)
	local deficits: { [string]: number } = {}
	local capacity = 0
	for _, province in CampaignState.ownedProvinces(state, houseId) do
		if Military.holdsProvince(province, houseId) then
			local deficit = MilitaryRules.provinceLevyMax(province, config) - province.levies
			if deficit > 0 then
				deficits[province.id] = deficit
				capacity += deficit
			end
		end
	end
	local shares = if troops >= capacity then deficits else MilitaryRules.splitMen(troops, deficits)

	local returned = 0
	for _, provinceId in TableUtil.sortedKeys(shares) do
		local added = math.min(shares[provinceId], deficits[provinceId])
		if added > 0 then
			state.provinces[provinceId].levies += added
			returned += added
			sim.journal:markProvince(provinceId)
		end
	end
	removeArmy(sim, army)
	SimContext.emitEvent(sim, "ArmyDisbanded", "low", { houseId }, {
		houseId = houseId,
		armyId = armyId,
		originId = army.originId,
		troops = troops,
		returned = returned,
	})
	return true, {
		armyId = armyId,
		originId = army.originId,
		troops = troops,
		returned = returned,
	}
end

-- Daily processing -------------------------------------------------------------------------------

-- The lowest-id idle army of the same house in the army's province, other than the army itself.
local function gatherTarget(state: GameTypes.CampaignState, army: ArmyState): ArmyState?
	for _, other in CampaignState.armiesIn(state, army.locationId) do
		if other.id ~= army.id and other.houseId == army.houseId and Military.isIdle(other) then
			return other
		end
	end
	return nil
end

-- Arrival at the end of a leg, then departure on the next one.
local function advanceArmy(sim: SimContext, army: ArmyState, dayNumber: number)
	local changed = false
	if army.legEndDay ~= nil and army.legEndDay <= dayNumber then
		army.locationId = table.remove(army.route, 1) :: string
		army.legStartDay = nil
		army.legEndDay = nil
		changed = true
		if #army.route == 0 then
			local gather = army.gather
			army.gather = false
			local target = if gather then gatherTarget(sim.state, army) else nil
			if target then
				mergeInto(sim, army, target)
				return
			end
			SimContext.emitEvent(sim, "ArmyArrived", "low", { army.houseId }, {
				houseId = army.houseId,
				armyId = army.id,
				originId = army.originId,
				provinceId = army.locationId,
			})
		end
	end
	if #army.route > 0 and army.legStartDay == nil and Military.tryDepart(sim, army, dayNumber) then
		changed = true
	end
	if changed then
		markArmy(sim, army)
	end
end

--[[
	Supply, morale and attrition for one army. Its ground is the leg's destination while marching,
	else its location. At sea nothing changes. On ground its house controls it resupplies and
	recovers morale; elsewhere it forages and loses supply, and at zero supply it starves: it loses
	ceil(men * AttritionStarving) men (spread over its units by head count) and MoraleLossStarving
	morale. An army reduced below half of MinArmySize deserts entirely.
]]
local function supplyTick(sim: SimContext, army: ArmyState)
	if Military.atSea(army) then
		return
	end
	local config = sim.config.Military
	local groundId = if Military.inTransit(army) then army.route[1] else army.locationId
	local ground = sim.state.provinces[groundId]
	local supply, morale = army.supply, army.morale
	local units = army.units
	if ground and controls(ground, army.houseId) then
		supply = math.min(config.SupplyMax, supply + config.SupplyGainHome)
		morale = math.min(config.MoraleMax, morale + config.MoraleRecoveryHome)
	else
		local terrain = Content.terrains[Content.provinces[groundId].terrainId]
		supply = math.max(0, supply - ceilWhole(config.SupplyLossForeign * terrain.supplyDrain))
		if supply == 0 then
			local lost = ceilWhole(MilitaryRules.troops(units) * config.AttritionStarving)
			if lost > 0 then
				units = table.clone(units)
				for unitId, count in MilitaryRules.splitMen(lost, army.units) do
					local left = units[unitId] - count
					units[unitId] = if left > 0 then left else nil
				end
			end
			morale = math.max(0, morale - config.MoraleLossStarving)
		end
	end
	local starving = supply == 0
	local remaining = MilitaryRules.troops(units)

	if remaining < config.MinArmySize / 2 then
		removeArmy(sim, army)
		SimContext.emitEvent(sim, "ArmyDesertion", "high", { army.houseId }, {
			houseId = army.houseId,
			armyId = army.id,
			originId = army.originId,
			provinceId = groundId,
			troops = remaining,
		})
		return
	end
	local startedStarving = starving and not army.starving
	if supply ~= army.supply or morale ~= army.morale or starving ~= army.starving or units ~= army.units then
		-- Only lost men change the house's troop totals and upkeep; supply and morale are army data.
		local lostMen = units ~= army.units
		army.supply = supply
		army.morale = morale
		army.starving = starving
		army.units = units
		if lostMen then
			markArmy(sim, army)
		else
			sim.journal:markArmy(army.id)
		end
	end
	if startedStarving then
		SimContext.emitEvent(sim, "ArmyStarving", "high", { army.houseId }, {
			houseId = army.houseId,
			armyId = army.id,
			originId = army.originId,
			provinceId = groundId,
		})
	end
end

--[[
	Daily system: movement for every army with orders, then a day of upkeep for every army, then
	(every SupplyTickDays days) supply. A day of upkeep adds the army's monthly upkeep to its
	house's accrued sum, which the monthly settlement divides by the days of the month; it is kept
	in hundredths of gold, so a save stores it exactly.
]]
function Military.processDay(sim: SimContext, dayNumber: number)
	local state = sim.state
	for _, armyId in TableUtil.sortedKeys(state.armies) do
		local army = state.armies[armyId]
		-- An army may have merged into another earlier in this pass.
		if army ~= nil and #army.route > 0 then
			advanceArmy(sim, army, dayNumber)
		end
	end
	for _, armyId in TableUtil.sortedKeys(state.armies) do
		local army = state.armies[armyId]
		local house = state.houses[army.houseId]
		if house then
			house.armyUpkeepAccrued = EconomyRules.roundGold(house.armyUpkeepAccrued + MilitaryRules.upkeep(army.units, sim.config.Military))
		end
	end
	if dayNumber % sim.config.Military.SupplyTickDays == 0 then
		for _, armyId in TableUtil.sortedKeys(state.armies) do
			local army = state.armies[armyId]
			if army ~= nil then
				supplyTick(sim, army)
			end
		end
	end
end

-- Monthly processing -----------------------------------------------------------------------------

--[[
	Monthly system: every unoccupied province refills ceil(maximum * LevyReplenishPerMonth) levies
	and ceil(maximum * GarrisonReplenishPerMonth) garrison troops, never above the maximum. Every
	pool is also clamped to its maximum, which a lower development would reduce.
]]
function Military.processMonth(sim: SimContext, _monthIndex: number)
	local state = sim.state
	local config = sim.config.Military
	for _, provinceId in Content.provinceIds do
		local province = state.provinces[provinceId]
		if province then
			local leviesMax = MilitaryRules.provinceLevyMax(province, config)
			local garrisonMax = MilitaryRules.provinceGarrisonMax(province, config)
			local levies = math.min(province.levies, leviesMax)
			local garrison = math.min(province.garrisonTroops, garrisonMax)
			if Military.holdsProvince(province, province.ownerHouseId) then
				levies = math.min(leviesMax, levies + ceilWhole(leviesMax * config.LevyReplenishPerMonth))
				garrison = math.min(garrisonMax, garrison + ceilWhole(garrisonMax * config.GarrisonReplenishPerMonth))
			end
			if levies ~= province.levies or garrison ~= province.garrisonTroops then
				province.levies = levies
				province.garrisonTroops = garrison
				sim.journal:markProvince(provinceId)
				sim.journal:markHouse(province.ownerHouseId)
			end
		end
	end
end

return Military
