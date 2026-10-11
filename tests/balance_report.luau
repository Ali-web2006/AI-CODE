--[[
	Balance report (Lune): runs an all-AI campaign and prints yearly treasury, income and
	development per house plus AI activity counts. A diagnostic tool for tuning GameConfig.

	Usage: lune run tests/balance_report.luau [years] [seed]
]]

local process = require("@lune/process")
local VirtualRoblox = require("./harness/VirtualRoblox")
local Fixtures = require("./harness/Fixtures")

local years = tonumber(process.args[1]) or 30
local seed = tonumber(process.args[2]) or 1337

local fx = Fixtures.new(VirtualRoblox.new(process.cwd))
local sim = fx.newSim({ seed = seed })

local counts = { ProvinceDeveloped = 0, RelationsImproved = 0 }
local houseIds = fx.CampaignState.sortedHouseIds(sim.state)

local function row(year)
	local parts = { string.format("%4d", year) }
	for _, houseId in houseIds do
		local house = sim.state.houses[houseId]
		local dev = 0
		for _, p in fx.CampaignState.ownedProvinces(sim.state, houseId) do
			dev += p.development
		end
		local last = house.ledger[#house.ledger]
		table.insert(parts, string.format("%9s %6.0f %+5.1f d%-3d", houseId, house.treasury, last and last.net or 0, dev))
	end
	print(table.concat(parts, " |"))
end

row(sim.state.clock.date.year)
for _ = 1, years do
	for _ = 1, 12 do
		sim:advanceToNextMonth()
		for _, event in sim.journal:flush().events do
			if counts[event.kind] then
				counts[event.kind] += 1
			end
		end
	end
	row(sim.state.clock.date.year)
end
print(`AI developments: {counts.ProvinceDeveloped}, envoys: {counts.RelationsImproved}`)
local relationLines = {}
for key, relation in sim.state.relations do
	if relation.score ~= relation.baseline then
		table.insert(relationLines, `{key}={relation.score}(base {relation.baseline})`)
	end
end
table.sort(relationLines)
print("relations off baseline: " .. table.concat(relationLines, ", "))
