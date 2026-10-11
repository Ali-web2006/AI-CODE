--[[
	House report (Lune): prints each house's starting position in the default bookmark (provinces,
	development, treasury, projected income, expenses and net). Used to keep docs/GAME_DESIGN.md
	accurate and to review balance after content changes.

	Usage: lune run tests/house_report.luau
]]

local process = require("@lune/process")
local VirtualRoblox = require("./harness/VirtualRoblox")
local Fixtures = require("./harness/Fixtures")

local vr = VirtualRoblox.new(process.cwd)
local fx = Fixtures.new(vr)
local Economy = vr.require("ServerScriptService.Simulation.Economy")
local CharacterRules = vr.require("ReplicatedStorage.Shared.Rules.CharacterRules")
local sim = fx.newSim()

print("| House | Tier | Ruler | Provinces | Dev | Treasury | Income | Expenses | Net/month |")
print("|---|---|---|---|---|---|---|---|---|")
for _, houseId in fx.CampaignState.sortedHouseIds(sim.state) do
	local house = sim.state.houses[houseId]
	local definition = fx.Content.houses[houseId]
	local budget = Economy.budgetFor(sim:context(), houseId)
	local development = 0
	local owned = fx.CampaignState.ownedProvinces(sim.state, houseId)
	for _, province in owned do
		development += province.development
	end
	local ruler = sim.state.characters[house.rulerId]
	print(string.format("| %s | %s | %s | %d | %d | %d | %.1f | %.1f | %+.1f |", definition.name, definition.tier,
		CharacterRules.displayName(ruler), #owned, development, house.treasury, budget.taxIncome, budget.expenses, budget.net))
end
