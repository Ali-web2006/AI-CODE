-- Scenario E — Development purchase: a valid purchase deducts the exact cost and raises
-- development (and future income); invalid purchases are rejected without changing state.

return function(t)
	local fx, expect = t.fx, t.expect
	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands
	local player = { kind = "player", userId = 1, houseId = "stark" }

	local function quietSim()
		-- AI disabled so only the player's actions change state.
		return fx.newSim({ config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 0 }), human = { stark = true } })
	end

	t.test("a valid purchase deducts the cost once and raises development", function()
		local sim = quietSim()
		local result = sim:submit(player, Commands.DevelopProvince, { provinceId = "winterfell" })
		expect.result(result, Codes.Ok)
		expect.equal(result.data.cost, 44, "cost from 20 * 1.3^3")
		expect.equal(sim.state.houses.stark.treasury, 140 - 44)
		expect.equal(sim.state.provinces.winterfell.development, 5)
		expect.truthy(sim.journal.changes.provinces.winterfell, "province marked for replication")
		expect.truthy(sim.journal.changes.houses.stark, "house marked for replication")
	end)

	t.test("development increases the next month's income by the formula's amount", function()
		local baseline = quietSim()
		baseline:advanceToNextMonth()
		local developed = quietSim()
		developed:submit(player, Commands.DevelopProvince, { provinceId = "winterfell" })
		developed:advanceToNextMonth()
		local incomeGain = developed.state.houses.stark.ledger[1].income - baseline.state.houses.stark.ledger[1].income
		-- One level adds 0.2 * 4.5 base tax, scaled by Eddard's tax multiplier (1.155).
		expect.near(incomeGain, 0.2 * 4.5 * 1.155, 0.011)
		local expenseGain = developed.state.houses.stark.ledger[1].expenses - baseline.state.houses.stark.ledger[1].expenses
		expect.near(expenseGain, fx.GameConfig.Economy.AdministrationPerDevelopment, 0.011)
	end)

	t.test("an unaffordable purchase is rejected without modifying state", function()
		local sim = quietSim()
		sim.state.houses.stark.treasury = 43
		local before = fx.TableUtil.deepCopy(sim.state)
		local result = sim:submit(player, Commands.DevelopProvince, { provinceId = "winterfell" })
		expect.result(result, Codes.InsufficientFunds)
		expect.deepEqual(sim.state, before)
	end)

	t.test("developing another house's province is rejected without modifying state", function()
		local sim = quietSim()
		local before = fx.TableUtil.deepCopy(sim.state)
		expect.result(sim:submit(player, Commands.DevelopProvince, { provinceId = "casterly_rock" }), Codes.NotOwner)
		expect.deepEqual(sim.state, before)
	end)

	t.test("an occupied province cannot be developed by its owner", function()
		local sim = quietSim()
		sim.state.provinces.moat_cailin.occupierHouseId = "frey"
		local before = fx.TableUtil.deepCopy(sim.state)
		expect.result(sim:submit(player, Commands.DevelopProvince, { provinceId = "moat_cailin" }), Codes.NotOwner)
		expect.deepEqual(sim.state, before)
	end)

	t.test("maximum development is enforced", function()
		local sim = quietSim()
		sim.state.provinces.winterfell.development = fx.GameConfig.Economy.MaxDevelopment
		sim.state.houses.stark.treasury = 100000
		local before = fx.TableUtil.deepCopy(sim.state)
		expect.result(sim:submit(player, Commands.DevelopProvince, { provinceId = "winterfell" }), Codes.MaxDevelopment)
		expect.deepEqual(sim.state, before)
	end)

	t.test("unknown provinces and malformed payloads are rejected", function()
		local sim = quietSim()
		local before = fx.TableUtil.deepCopy(sim.state)
		expect.result(sim:submit(player, Commands.DevelopProvince, { provinceId = "atlantis" }), Codes.NotFound)
		expect.result(sim:submit(player, Commands.DevelopProvince, { provinceId = 42 }), Codes.InvalidPayload)
		expect.result(sim:submit(player, Commands.DevelopProvince, nil), Codes.InvalidPayload)
		expect.deepEqual(sim.state, before)
	end)

	t.test("costs escalate with each level and spending stops at zero", function()
		local sim = quietSim()
		sim.state.houses.stark.treasury = 500
		local costs = {}
		while true do
			local result = sim:submit(player, Commands.DevelopProvince, { provinceId = "white_harbor" })
			if not result.ok then
				expect.truthy(result.code == Codes.InsufficientFunds or result.code == Codes.MaxDevelopment)
				break
			end
			table.insert(costs, result.data.cost)
		end
		for i = 2, #costs do
			expect.truthy(costs[i] > costs[i - 1], "each level costs more than the last")
		end
		expect.truthy(sim.state.houses.stark.treasury >= 0, "never negative")
	end)
end
