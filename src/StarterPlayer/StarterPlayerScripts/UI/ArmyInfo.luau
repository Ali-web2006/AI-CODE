--!strict
--[[
	ArmyInfo — how the interface describes an army: its status, orders, arrival estimate,
	commander and tooltip. The map tokens (ArmyLayer), the Military tab (ArmyPanel) and the province
	panel all use it, so every screen words an army the same way.

	It reads only the replicated army view (Snapshot.armyView) and the store. The arrival estimate
	uses MovementRules, the same rules the server uses to time the march, and nextCommander mirrors
	the server's choice of commander (Military.bestCommander), so previews match what happens.

	Army states, from the replicated fields:
	  idle      the route is empty
	  marching  legStartDay and legEndDay are set: on the road from locationId to route[1]
	  waiting   a route but no leg: in port at locationId until enough ships are free
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterRules = require(ReplicatedStorage.Shared.Rules.CharacterRules)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local MovementRules = require(ReplicatedStorage.Shared.Rules.MovementRules)
local ReplicaStore = require(script.Parent.Parent.Controllers.ReplicaStore)
local Format = require(script.Parent.Format)

export type Status = "idle" | "marching" | "waiting"

type View = { [string]: any }

local ArmyInfo = {}

function ArmyInfo.provinceName(provinceId: string?): string
	local definition = provinceId and Content.provinces[provinceId]
	return if definition then definition.name else "?"
end

function ArmyInfo.name(army: View): string
	return MilitaryRules.armyName(army :: any)
end

function ArmyInfo.status(army: View): Status
	if #army.route == 0 then
		return "idle"
	end
	if army.legStartDay ~= nil and army.legEndDay ~= nil then
		return "marching"
	end
	return "waiting"
end

-- The province the army is heading for, or the one it stands in when idle.
function ArmyInfo.destination(army: View): string
	return if #army.route > 0 then army.route[#army.route] else army.locationId
end

-- The replicated campaign day number (nil before the first snapshot).
function ArmyInfo.today(store: ReplicaStore.ReplicaStore): number?
	local clock = store.campaign.clock
	return if clock then clock.dayNumber else nil
end

--[[
	Days until the army reaches its destination (0 when idle). Marching: the rest of the current
	leg plus the remaining legs; waiting for ships: the whole route from the port, once it sails.
]]
function ArmyInfo.daysToArrive(army: View, today: number?): number
	local route: { string } = army.route
	if #route == 0 then
		return 0
	end
	local config = GameConfig.Military
	if army.legStartDay ~= nil and army.legEndDay ~= nil then
		local rest = table.move(route, 2, #route, 1, {})
		local remaining = math.max(0, army.legEndDay - (today or army.legStartDay))
		return remaining + MovementRules.routeDays(route[1], rest, army.units, config)
	end
	return MovementRules.routeDays(army.locationId, route, army.units, config)
end

local function dayCount(days: number): string
	return if days == 1 then "1 day" else `{days} days`
end

-- "Idle at Winterfell", "Marching to Moat Cailin — arrives in 27 days",
-- "Gathering at Winterfell — arrives in 6 days", "Waiting for ships at Pyke".
function ArmyInfo.ordersText(army: View, today: number?): string
	local status = ArmyInfo.status(army)
	local here = ArmyInfo.provinceName(army.locationId)
	if status == "idle" then
		return `Idle at {here}`
	elseif status == "waiting" then
		return `Waiting for ships at {here}`
	end
	local days = ArmyInfo.daysToArrive(army, today)
	local verb = if army.gather then "Gathering at" else "Marching to"
	local arrival = if days <= 0 then "arrives today" else `arrives in {dayCount(days)}`
	return `{verb} {ArmyInfo.provinceName(ArmyInfo.destination(army))} — {arrival}`
end

function ArmyInfo.commander(store: ReplicaStore.ReplicaStore, army: View): View?
	local commanderId = army.commanderId
	return if commanderId then store:character(commanderId) else nil
end

-- "Eddard Stark" or "Leaderless".
function ArmyInfo.commanderName(store: ReplicaStore.ReplicaStore, army: View): string
	local character = ArmyInfo.commander(store, army)
	return if character then CharacterRules.displayName(character :: any) else "Leaderless"
end

-- "Eddard Stark (martial 13)" or "Leaderless".
function ArmyInfo.commanderText(store: ReplicaStore.ReplicaStore, army: View): string
	local character = ArmyInfo.commander(store, army)
	if not character then
		return "Leaderless"
	end
	return `{CharacterRules.displayName(character :: any)} (martial {character.skills.martial})`
end

-- a ranks above b as a commander: higher martial, then the ruler, then the smaller id.
local function outranks(a: View, b: View, rulerId: string?): boolean
	if a.skills.martial ~= b.skills.martial then
		return a.skills.martial > b.skills.martial
	end
	if (a.id == rulerId) ~= (b.id == rulerId) then
		return a.id == rulerId
	end
	return a.id < b.id
end

--[[
	The character the server would appoint to the house's next army (Military.bestCommander): a
	living adult of the house who leads no army, with the highest martial; ties go to the ruler,
	then to the smaller id. nil when nobody is free (the army would be leaderless).
]]
function ArmyInfo.nextCommander(store: ReplicaStore.ReplicaStore, houseId: string): View?
	local clock = store.campaign.clock
	if not clock then
		return nil
	end
	local taken: { [string]: boolean } = {}
	for _, army in store.campaign.armies or {} do
		if army.commanderId then
			taken[army.commanderId] = true
		end
	end
	local house = store:house(houseId)
	local rulerId = if house then house.rulerId else nil
	local best: View? = nil
	for characterId, character in store.campaign.characters or {} do
		if character.alive
			and character.houseId == houseId
			and not taken[characterId]
			and CharacterRules.age(character :: any, clock.date) >= GameConfig.Military.MinCommanderAge
		then
			if best == nil or outranks(character, best, rulerId) then
				best = character
			end
		end
	end
	return best
end

--[[
	Everything the panels show of an army except its morale and supply, as one string. A supply
	tick (every few days) changes only those two, so a panel compares keys to tell a tick, which
	it updates in place, from a change it must redraw for. Tooltips read the live view anyway.
]]
function ArmyInfo.structuralKey(army: View): string
	local unitIds = {}
	for unitId in army.units do
		table.insert(unitIds, unitId)
	end
	table.sort(unitIds)
	local units = {}
	for _, unitId in unitIds do
		table.insert(units, `{unitId}={army.units[unitId]}`)
	end
	return table.concat({
		army.houseId,
		army.originId,
		army.locationId,
		table.concat(army.route, ","),
		tostring(army.legStartDay),
		tostring(army.legEndDay),
		tostring(army.gather),
		tostring(army.commanderId),
		table.concat(units, ","),
		tostring(army.starving),
		tostring(army.strength),
		tostring(army.upkeep),
		tostring(army.speed),
	}, "|")
end

-- Rich-text tooltip of an army token: name, house, men, commander, orders, morale and supply.
function ArmyInfo.tooltip(store: ReplicaStore.ReplicaStore, army: View): string
	local house = Content.houses[army.houseId]
	local lines = {
		`<b>{Format.escape(ArmyInfo.name(army))}</b> · {Format.escape(if house then house.name else "?")}`,
		`{Format.troops(army.troops)} men · Commander: {Format.escape(ArmyInfo.commanderText(store, army))}`,
		Format.escape(ArmyInfo.ordersText(army, ArmyInfo.today(store))),
		`Morale {army.morale} · Supply {army.supply}{if army.starving then " · <b>starving</b>" else ""}`,
	}
	if army.houseId == store:myHouseId() then
		table.insert(lines, "Click to command it; with it selected, right-click land to march there.")
	end
	return table.concat(lines, "\n")
end

return ArmyInfo
