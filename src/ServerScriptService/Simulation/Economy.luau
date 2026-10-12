--!strict
--[[
	Economy — authoritative economic operations on campaign state.

	Formulas live in Shared/Rules/EconomyRules; this module applies them:
	  * processMonth: once per completed month, for every active house in id order:
	      1. compute income from controlled holdings, 2. compute recurring expenses (court,
	         garrisons, administration and army upkeep),
	      3. apply the net change to the treasury, 4. record a ledger entry and diagnostic,
	      5. mark the house dirty for replication.
	  * checkDevelop / develop: the validated "invest in province development" operation shared
	    by players and the AI (through the DevelopProvince command).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local CampaignState = require(script.Parent.CampaignState)
local SimContext = require(script.Parent.SimContext)

type SimContext = SimContext.SimContext

local Codes = Protocol.ResultCodes

local Economy = {}

-- Monthly gold upkeep of every army of a house (summed in army id order).
function Economy.armyUpkeep(sim: SimContext, houseId: string): number
	local total = 0
	for _, army in CampaignState.armiesOf(sim.state, houseId) do
		total += MilitaryRules.upkeep(army.units, sim.config.Military)
	end
	return EconomyRules.roundGold(total)
end

function Economy.budgetFor(sim: SimContext, houseId: string): EconomyRules.HouseBudget
	local state = sim.state
	return EconomyRules.computeHouseBudget(
		houseId,
		CampaignState.ownedProvinces(state, houseId) :: any,
		CampaignState.ruler(state, houseId),
		sim.config.Economy,
		Economy.armyUpkeep(sim, houseId)
	)
end

function Economy.processMonth(sim: SimContext, monthIndex: number)
	local state = sim.state
	local roundGold = EconomyRules.roundGold
	for _, houseId in CampaignState.activeHouseIds(state) do
		local house = state.houses[houseId]
		local budget = Economy.budgetFor(sim, houseId)
		local income = roundGold(budget.taxIncome)
		local expenses = roundGold(budget.expenses)
		local net = roundGold(income - expenses)
		local before = house.treasury
		house.treasury = roundGold(before + net)

		table.insert(house.ledger, {
			monthIndex = monthIndex,
			income = income,
			expenses = expenses,
			net = net,
			treasuryAfter = house.treasury,
		})
		while #house.ledger > sim.config.Economy.LedgerLength do
			table.remove(house.ledger, 1)
		end

		sim.journal:markHouse(houseId)
		SimContext.emitEvent(sim, "MonthlyReport", "low", { houseId }, {
			houseId = houseId,
			monthIndex = monthIndex,
			income = income,
			expenses = expenses,
			net = net,
			treasury = house.treasury,
		})
		if before >= 0 and house.treasury < 0 then
			SimContext.emitEvent(sim, "TreasuryCrisis", "high", { houseId }, {
				houseId = houseId,
				treasury = house.treasury,
			})
		end
		if sim.config.Debug.LogMonthlyLedger then
			sim.diagnostics:info(
				"Economy",
				`{CalendarDate.formatMonthIndex(monthIndex)} {houseId}: +{income} -{expenses} = {net} -> {house.treasury}`
			)
		end
	end
end

export type DevelopCheck = {
	ok: boolean,
	code: string,
	message: string,
	cost: number?,
}

-- Validates a development purchase without changing anything.
function Economy.checkDevelop(sim: SimContext, houseId: string, provinceId: string): DevelopCheck
	local state = sim.state
	local house = state.houses[houseId]
	if not house or house.extinct then
		return { ok = false, code = Codes.NotAuthorized, message = "Your house no longer exists." }
	end
	local province = state.provinces[provinceId]
	local definition = Content.provinces[provinceId]
	if not province or not definition then
		return { ok = false, code = Codes.NotFound, message = "That province does not exist." }
	end
	if province.ownerHouseId ~= houseId then
		return { ok = false, code = Codes.NotOwner, message = `{definition.name} does not belong to your house.` }
	end
	if province.occupierHouseId ~= nil and province.occupierHouseId ~= houseId then
		return { ok = false, code = Codes.NotOwner, message = `{definition.name} is occupied and cannot be developed.` }
	end
	local cost = EconomyRules.developmentCost(provinceId, province.development, sim.config.Economy)
	if cost == nil then
		return { ok = false, code = Codes.MaxDevelopment, message = `{definition.name} is already fully developed.` }
	end
	if house.treasury < cost then
		return {
			ok = false,
			code = Codes.InsufficientFunds,
			message = `Developing {definition.name} costs {cost} gold; the treasury holds {string.format("%.1f", house.treasury)}.`,
			cost = cost,
		}
	end
	return { ok = true, code = Codes.Ok, message = "", cost = cost }
end

-- Applies a development purchase. Callers must have run checkDevelop in the same step; this
-- re-checks to keep the invariant local (no state is mutated on failure).
function Economy.develop(sim: SimContext, houseId: string, provinceId: string): (boolean, DevelopCheck | { [string]: any })
	local check = Economy.checkDevelop(sim, houseId, provinceId)
	if not check.ok then
		return false, check
	end
	local cost = check.cost :: number
	local state = sim.state
	local house = state.houses[houseId]
	local province = state.provinces[provinceId]

	house.treasury = EconomyRules.roundGold(house.treasury - cost)
	province.development += 1

	sim.journal:markHouse(houseId)
	sim.journal:markProvince(provinceId)
	SimContext.emitEvent(sim, "ProvinceDeveloped", "normal", nil, {
		houseId = houseId,
		provinceId = provinceId,
		development = province.development,
		cost = cost,
	})
	return true, {
		provinceId = provinceId,
		development = province.development,
		cost = cost,
		treasury = house.treasury,
	}
end

return Economy
