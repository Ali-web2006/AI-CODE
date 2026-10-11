-- Scenario C — Province inspection: views carry the right owner, development and economic values
-- for several provinces, and static identity resolves through shared Content.

return function(t)
	local fx, expect, vr = t.fx, t.expect, t.vr
	local Snapshot = vr.require("ServerScriptService.Simulation.Snapshot")

	local cases = {
		-- id, owner, development, expected monthly income (base * dev * terrain * holding)
		{ "winterfell", "stark", 4, 4.5 * 1.6 * 1.0 * 1.0, "Winterfell", "Plains", "Castle" },
		{ "kings_landing", "baratheon", 7, 7.5 * 2.2 * 1.05 * 1.2, "King's Landing", "Coast", "City" },
		{ "the_arbor", "tyrell", 4, 3.5 * 1.6 * 0.9 * 1.15, "The Arbor", "Island", "Port" },
		{ "moat_cailin", "stark", 1, 1.2 * 1.0 * 0.7 * 0.8, "Moat Cailin", "Marsh", "Fortress" },
		{ "the_twins", "frey", 4, 3.5 * 1.6 * 1.0 * 1.0, "The Twins", "Plains", "Castle" },
	}

	t.test("province views report owner, development and income for several provinces", function()
		local sim = fx.newSim()
		for _, case in cases do
			local id, owner, development, income, name, terrain, holding = table.unpack(case)
			local view = Snapshot.provinceView(sim:context(), id)
			expect.equal(view.ownerHouseId, owner, `{id} owner`)
			expect.equal(view.development, development, `{id} development`)
			expect.near(view.income, income, 0.006, `{id} income`)
			local definition = fx.Content.provinces[id]
			expect.equal(definition.name, name, `{id} name`)
			expect.equal(fx.Content.terrains[definition.terrainId].name, terrain, `{id} terrain`)
			expect.equal(fx.Content.holdingKinds[definition.holding.kind].name, holding, `{id} holding`)
		end
	end)

	t.test("development cost and next-level income are exposed for the province panel", function()
		local sim = fx.newSim()
		local view = Snapshot.provinceView(sim:context(), "winterfell")
		-- 20 * 1.3^(4-1) * 1.0 (plains) = 43.94 -> 44
		expect.equal(view.developmentCost, 44)
		expect.near(view.nextIncome, 4.5 * 1.8, 0.006)
		sim.state.provinces.winterfell.development = fx.GameConfig.Economy.MaxDevelopment
		local maxed = Snapshot.provinceView(sim:context(), "winterfell")
		expect.equal(maxed.developmentCost, nil, "no cost at maximum development")
		expect.equal(maxed.nextIncome, nil)
	end)

	t.test("the full sync payload contains a view for every province", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		local campaign = host:syncPayload(1).campaign
		for _, provinceId in fx.Content.provinceIds do
			local view = campaign.provinces[provinceId]
			expect.truthy(view, `view for {provinceId}`)
			expect.truthy(fx.Content.houses[view.ownerHouseId], `owner of {provinceId} resolves to a house`)
		end
	end)

	t.test("house budget equals the sum of its province lines", function()
		local sim = fx.newSim()
		local Economy = vr.require("ServerScriptService.Simulation.Economy")
		local budget = Economy.budgetFor(sim:context(), "stark")
		local gross = 0
		for _, line in budget.provinceLines do
			gross += line.income
		end
		expect.near(budget.grossProvinceIncome, gross, 1e-9)
		-- Eddard: stewardship 7 (+10.5%) and the Just trait (+5%).
		expect.near(budget.taxMultiplier, 1 + 7 * 0.015 + 0.05, 1e-9)
		expect.near(budget.taxIncome, gross * budget.taxMultiplier, 1e-9)
		expect.near(budget.net, budget.taxIncome - budget.expenses, 1e-9)
	end)
end
