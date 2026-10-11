--!strict
--[[
	EconomyRules — the pure economic formulas (documented in docs/GAME_DESIGN.md §Economy).

	These functions never mutate anything. The server's Economy module applies them to the
	authoritative state; the client uses the same functions only to explain numbers it received.

	All functions take the economy config explicitly so tests can run alternative tunings.
]]

local Content = require(script.Parent.Parent.Data.Content)
local GameTypes = require(script.Parent.Parent.Types.GameTypes)
local TraitRules = require(script.Parent.TraitRules)

export type EconomyConfig = {
	DevelopmentIncomePerLevel: number,
	StewardshipIncomeBonus: number,
	AdministrationPerDevelopment: number,
	DevelopmentCostBase: number,
	DevelopmentCostGrowth: number,
	MinDevelopment: number,
	MaxDevelopment: number,
	LedgerLength: number,
}

export type BreakdownLine = {
	label: string,
	value: number,
}

export type ProvinceLine = {
	provinceId: string,
	income: number,
	garrison: number,
	administration: number,
	occupied: boolean,
}

export type HouseBudget = {
	provinceLines: { ProvinceLine },
	grossProvinceIncome: number,
	taxMultiplier: number,
	taxMultiplierLines: { BreakdownLine },
	taxIncome: number,
	courtUpkeepBase: number,
	courtMultiplier: number,
	courtMultiplierLines: { BreakdownLine },
	courtUpkeep: number,
	garrisonUpkeep: number,
	administration: number,
	expenses: number,
	net: number,
}

export type CharacterLike = {
	skills: GameTypes.Skills,
	traits: { string },
}

export type ProvinceLike = {
	id: string,
	ownerHouseId: string,
	occupierHouseId: string?,
	development: number,
}

local EconomyRules = {}

-- Rounds gold amounts to hundredths so floating-point noise never accumulates in treasuries.
function EconomyRules.roundGold(value: number): number
	return math.floor(value * 100 + 0.5) / 100
end

-- Monthly income of a province before house-level modifiers.
function EconomyRules.provinceIncome(provinceId: string, development: number, config: EconomyConfig): number
	local definition = Content.provinces[provinceId]
	local terrain = Content.terrains[definition.terrainId]
	local holding = Content.holdingKinds[definition.holding.kind]
	local developmentMultiplier = 1 + config.DevelopmentIncomePerLevel * (development - 1)
	return definition.baseTax * developmentMultiplier * terrain.taxMultiplier * holding.taxMultiplier
end

function EconomyRules.provinceIncomeBreakdown(provinceId: string, development: number, config: EconomyConfig): { BreakdownLine }
	local definition = Content.provinces[provinceId]
	local terrain = Content.terrains[definition.terrainId]
	local holding = Content.holdingKinds[definition.holding.kind]
	return {
		{ label = "Base tax", value = definition.baseTax },
		{ label = `Development {development}`, value = 1 + config.DevelopmentIncomePerLevel * (development - 1) },
		{ label = `Terrain: {terrain.name}`, value = terrain.taxMultiplier },
		{ label = `Holding: {holding.name}`, value = holding.taxMultiplier },
	}
end

-- Monthly costs a province imposes on its owner.
function EconomyRules.provinceUpkeep(provinceId: string, development: number, config: EconomyConfig): (number, number)
	local definition = Content.provinces[provinceId]
	local holding = Content.holdingKinds[definition.holding.kind]
	return holding.garrisonUpkeep, config.AdministrationPerDevelopment * development
end

-- Cost to raise a province from `development` to `development + 1`; nil when already at the cap.
function EconomyRules.developmentCost(provinceId: string, development: number, config: EconomyConfig): number?
	if development >= config.MaxDevelopment then
		return nil
	end
	local definition = Content.provinces[provinceId]
	local terrain = Content.terrains[definition.terrainId]
	local raw = config.DevelopmentCostBase
		* config.DevelopmentCostGrowth ^ (development - 1)
		* terrain.developmentCostMultiplier
	return math.max(1, math.floor(raw + 0.5))
end

-- House-level tax multiplier from the ruler's stewardship and traits.
function EconomyRules.taxMultiplier(ruler: CharacterLike?, config: EconomyConfig): (number, { BreakdownLine })
	local lines: { BreakdownLine } = {}
	local multiplier = 1
	if ruler then
		local stewardshipBonus = ruler.skills.stewardship * config.StewardshipIncomeBonus
		multiplier += stewardshipBonus
		table.insert(lines, { label = `Ruler stewardship {ruler.skills.stewardship}`, value = stewardshipBonus })
		local _, sources = TraitRules.sumModifier(ruler.traits, "taxIncome")
		for _, source in sources do
			multiplier += source.value
			table.insert(lines, { label = `Trait: {source.label}`, value = source.value })
		end
	end
	return math.max(0, multiplier), lines
end

function EconomyRules.courtMultiplier(ruler: CharacterLike?): (number, { BreakdownLine })
	local lines: { BreakdownLine } = {}
	local multiplier = 1
	if ruler then
		local _, sources = TraitRules.sumModifier(ruler.traits, "courtUpkeep")
		for _, source in sources do
			multiplier += source.value
			table.insert(lines, { label = `Trait: {source.label}`, value = source.value })
		end
	end
	return math.max(0, multiplier), lines
end

--[[
	Full monthly budget of a house.
	ownedProvinces: every province whose ownerHouseId is the house (any order; output is sorted).
	Occupied provinces (occupierHouseId set to another house) yield no income and cost no upkeep.
]]
function EconomyRules.computeHouseBudget(
	houseId: string,
	ownedProvinces: { ProvinceLike },
	ruler: CharacterLike?,
	config: EconomyConfig
): HouseBudget
	local houseDefinition = Content.houses[houseId]

	local sorted = table.clone(ownedProvinces)
	table.sort(sorted, function(a: ProvinceLike, b: ProvinceLike)
		return a.id < b.id
	end)

	local lines: { ProvinceLine } = {}
	local gross, garrisonTotal, administrationTotal = 0, 0, 0
	for _, province in sorted do
		local occupied = province.occupierHouseId ~= nil and province.occupierHouseId ~= houseId
		local income, garrison, administration = 0, 0, 0
		if not occupied then
			income = EconomyRules.provinceIncome(province.id, province.development, config)
			garrison, administration = EconomyRules.provinceUpkeep(province.id, province.development, config)
		end
		gross += income
		garrisonTotal += garrison
		administrationTotal += administration
		table.insert(lines, {
			provinceId = province.id,
			income = income,
			garrison = garrison,
			administration = administration,
			occupied = occupied,
		})
	end

	local taxMultiplier, taxLines = EconomyRules.taxMultiplier(ruler, config)
	local courtMultiplier, courtLines = EconomyRules.courtMultiplier(ruler)
	local taxIncome = gross * taxMultiplier
	local courtUpkeep = houseDefinition.courtUpkeep * courtMultiplier
	local expenses = courtUpkeep + garrisonTotal + administrationTotal

	return {
		provinceLines = lines,
		grossProvinceIncome = gross,
		taxMultiplier = taxMultiplier,
		taxMultiplierLines = taxLines,
		taxIncome = taxIncome,
		courtUpkeepBase = houseDefinition.courtUpkeep,
		courtMultiplier = courtMultiplier,
		courtMultiplierLines = courtLines,
		courtUpkeep = courtUpkeep,
		garrisonUpkeep = garrisonTotal,
		administration = administrationTotal,
		expenses = expenses,
		net = taxIncome - expenses,
	}
end

-- Change in a house's monthly net income if the province gains one development level.
function EconomyRules.developmentNetGain(provinceId: string, development: number, ruler: CharacterLike?, config: EconomyConfig): number
	if development >= config.MaxDevelopment then
		return 0
	end
	local taxMultiplier = EconomyRules.taxMultiplier(ruler, config)
	local incomeGain = EconomyRules.provinceIncome(provinceId, development + 1, config)
		- EconomyRules.provinceIncome(provinceId, development, config)
	return incomeGain * taxMultiplier - config.AdministrationPerDevelopment
end

return EconomyRules
