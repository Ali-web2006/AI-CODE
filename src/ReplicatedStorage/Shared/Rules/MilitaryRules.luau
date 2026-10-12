--!strict
--[[
	MilitaryRules — the pure military formulas (GameConfig.Military, docs/GAME_DESIGN.md §Military).

	These functions never mutate anything. The server's Military module applies them to the
	authoritative state; the client uses the same functions to preview orders and explain numbers
	it received, so both always agree.

	All functions take the military config explicitly so tests can run alternative tunings. Static
	data comes from Content (provinces, terrains, holdings, regions and the unit table). Unit maps
	are { [unitId]: men } with positive integer counts; every sum over a unit map runs in sorted
	unit id order so floating-point results are identical on every machine and after a save.
]]

local Content = require(script.Parent.Parent.Data.Content)
local EconomyRules = require(script.Parent.EconomyRules)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local TableUtil = require(script.Parent.Parent.Util.TableUtil)

export type MilitaryConfig = typeof(GameConfig.Military)

-- unitId -> men (integers > 0).
export type Units = { [string]: number }

-- Anything that names an army: ArmyState and the replicated army view both qualify.
export type ArmyLike = {
	originId: string,
}

-- Travel-day results are integers; this absorbs floating-point noise such as 10.000000000000002
-- so a leg that is exactly N days is never rounded up to N + 1.
local DAY_EPSILON = 1e-9

local MilitaryRules = {}

local function roundTo(value: number, step: number): number
	return math.floor(value / step + 0.5) * step
end

-- Levy maximum of a province: the men it can raise when its pool is full.
function MilitaryRules.levyMax(provinceId: string, development: number, config: MilitaryConfig): number
	local definition = Content.provinces[provinceId]
	local holding = Content.holdingKinds[definition.holding.kind]
	local terrain = Content.terrains[definition.terrainId]
	local region = Content.regions[definition.regionId]
	local raw = (config.LevyBase + config.LevyPerDevelopment * development)
		* holding.levyMultiplier
		* terrain.manpower
		* region.manpower
	return roundTo(raw, config.LevyRounding)
end

-- Garrison maximum of a province: the men who hold its walls and never march.
function MilitaryRules.garrisonMax(provinceId: string, development: number, config: MilitaryConfig): number
	local definition = Content.provinces[provinceId]
	local holding = Content.holdingKinds[definition.holding.kind]
	return roundTo(holding.garrisonBase + holding.garrisonPerDevelopment * development, config.GarrisonRounding)
end

-- Ships a province contributes to its owner's fleet.
function MilitaryRules.ships(provinceId: string, development: number): number
	local definition = Content.provinces[provinceId]
	local holding = Content.holdingKinds[definition.holding.kind]
	local terrain = Content.terrains[definition.terrainId]
	local region = Content.regions[definition.regionId]
	return math.floor((terrain.shipsPerDevelopment + holding.shipsPerDevelopment) * development * region.naval + 0.5)
end

-- Share of each unit in the levies a house raises. Phase 5 hook: buildings will modify it.
function MilitaryRules.composition(houseId: string): { [string]: number }
	return Content.military.compositions[houseId] or Content.military.defaultComposition
end

--[[
	Splits `total` men by `fractions` (unitId -> share) with the largest-remainder method: every
	unit gets the floor of its exact share, and the men left over go one each to the largest
	remainders, ties broken by unit id. The result sums exactly to `total` (a non-negative integer;
	fractions are normalised by their sum) and omits units that receive nobody.
]]
function MilitaryRules.splitMen(total: number, fractions: { [string]: number }): Units
	local result: Units = {}
	total = math.max(0, math.floor(total))
	local ids: { string } = {}
	local sum = 0
	for _, unitId in TableUtil.sortedKeys(fractions) do
		local fraction = fractions[unitId]
		if fraction > 0 then
			table.insert(ids, unitId)
			sum += fraction
		end
	end
	if total == 0 or #ids == 0 then
		return result
	end

	local remainders: { [string]: number } = {}
	local assigned = 0
	for _, unitId in ids do
		local exact = total * fractions[unitId] / sum
		local whole = math.floor(exact)
		result[unitId] = whole
		remainders[unitId] = exact - whole
		assigned += whole
	end
	local order = table.clone(ids)
	table.sort(order, function(a: string, b: string): boolean
		if remainders[a] ~= remainders[b] then
			return remainders[a] > remainders[b]
		end
		return a < b
	end)
	-- Normalised shares leave fewer than #ids men over; the modulo only guards rounding noise.
	for index = 1, total - assigned do
		local unitId = order[(index - 1) % #order + 1]
		result[unitId] += 1
	end
	for _, unitId in ids do
		if result[unitId] <= 0 then
			result[unitId] = nil
		end
	end
	return result
end

-- Total men in a unit map.
function MilitaryRules.troops(units: Units): number
	local total = 0
	for _, count in units do
		total += count
	end
	return total
end

--[[
	Splits every unit in two: floor(count / 2) men go to the split-off part and the rest stay, so
	keep + split equals `units` exactly. Returns (keep, split) without zero entries.
]]
function MilitaryRules.halve(units: Units): (Units, Units)
	local keep: Units, split: Units = {}, {}
	for unitId, count in units do
		local leaving = math.floor(count / 2)
		if count - leaving > 0 then
			keep[unitId] = count - leaving
		end
		if leaving > 0 then
			split[unitId] = leaving
		end
	end
	return keep, split
end

-- An army marches at the pace of its slowest unit (1 for an empty unit map).
function MilitaryRules.armySpeed(units: Units): number
	local speed = math.huge
	for unitId, count in units do
		local unit = Content.units[unitId]
		if unit and count > 0 then
			speed = math.min(speed, unit.speed)
		end
	end
	return if speed == math.huge then 1 else speed
end

--[[
	Days to travel from one province to an adjacent one; nil when they are not adjacent.
	Land: distance / MarchUnitsPerDay * ConnectionCost[kind] * destination terrain.movementCost
	      / army speed. Sea: distance / SailUnitsPerDay (terrain and unit speed do not matter).
	Both are rounded up to whole days, at least 1. distance is the Euclidean distance between the
	two provinces' map positions.
]]
function MilitaryRules.legDays(fromId: string, toId: string, units: Units, config: MilitaryConfig): number?
	local from = Content.provinces[fromId]
	local to = Content.provinces[toId]
	if not from or not to then
		return nil
	end
	local kind = from.adjacent[toId]
	if kind == nil then
		return nil
	end
	local dx = to.position.x - from.position.x
	local dy = to.position.y - from.position.y
	local distance = math.sqrt(dx * dx + dy * dy)
	local days
	if kind == "sea" then
		days = distance / config.SailUnitsPerDay
	else
		local connectionCosts: { [string]: number } = config.ConnectionCost :: any
		local terrain = Content.terrains[to.terrainId]
		days = distance / config.MarchUnitsPerDay
			* connectionCosts[kind]
			* terrain.movementCost
			/ MilitaryRules.armySpeed(units)
	end
	return math.ceil(math.max(1, days) - DAY_EPSILON)
end

-- Monthly gold upkeep of an army.
function MilitaryRules.upkeep(units: Units, config: MilitaryConfig): number
	local factor = 0
	for _, unitId in TableUtil.sortedKeys(units) do
		local unit = Content.units[unitId]
		if unit then
			factor += units[unitId] / 1000 * unit.upkeep
		end
	end
	return EconomyRules.roundGold(factor * config.UpkeepPerThousandPerMonth)
end

--[[
	Display rating of an army: thousands of men weighted by their mean attack and defence, scaled
	by the commander's martial skill (no commander: unscaled). Rounded to one decimal. Combat in
	later phases uses the unit stats directly. `config` defaults to GameConfig.Military because
	the rating is presentation only.
]]
function MilitaryRules.strength(units: Units, commanderMartial: number?, config: MilitaryConfig?): number
	local settings = config or GameConfig.Military
	local rating = 0
	for _, unitId in TableUtil.sortedKeys(units) do
		local unit = Content.units[unitId]
		if unit then
			rating += units[unitId] * (unit.attack + unit.defense) / 2
		end
	end
	local multiplier = 1
	if commanderMartial ~= nil then
		multiplier = math.max(0, 1 + settings.StrengthPerMartial * (commanderMartial - settings.CommanderMartialBaseline))
	end
	return math.floor(rating / 1000 * multiplier * 10 + 0.5) / 10
end

-- Starting morale of a newly raised army: the base plus the head-count-weighted unit bonus.
function MilitaryRules.moraleStart(units: Units, config: MilitaryConfig): number
	local men, weighted = 0, 0
	for _, unitId in TableUtil.sortedKeys(units) do
		local unit = Content.units[unitId]
		if unit then
			men += units[unitId]
			weighted += units[unitId] * unit.morale
		end
	end
	local bonus = if men > 0 then weighted / men else 0
	return math.clamp(math.floor(config.MoraleBase + bonus + 0.5), 0, config.MoraleMax)
end

-- Ships needed to carry `troops` men by sea.
function MilitaryRules.shipsNeeded(troops: number, config: MilitaryConfig): number
	return math.ceil(math.max(0, troops) / config.ShipCapacity)
end

-- "Army of Winterfell": armies are named after the holding they were raised at.
function MilitaryRules.armyName(army: ArmyLike): string
	local origin = Content.provinces[army.originId]
	if not origin then
		return "Army"
	end
	return `Army of {origin.holding.name}`
end

return MilitaryRules
