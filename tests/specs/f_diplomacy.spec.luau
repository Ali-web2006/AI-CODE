-- Scenario F — Diplomacy: Improve Relations changes the right symmetric relation by the explained
-- amount, charges once, respects cooldowns, and rejects invalid targets.

return function(t)
	local fx, expect = t.fx, t.expect
	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands
	local stark = { kind = "player", userId = 1, houseId = "stark" }

	local function quietSim()
		return fx.newSim({ config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 0 }), human = { stark = true } })
	end

	t.test("improving relations applies the explained gain and charges the cost once", function()
		local sim = quietSim()
		local result = sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" })
		expect.result(result, Codes.Ok)
		-- Envoy 8 + Eddard's diplomacy 8 * 0.5 = 4 + Honest 2 + recipient Tywin is Proud -2 = 12.
		expect.equal(result.data.gain, 12)
		expect.equal(result.data.before, -10)
		expect.equal(result.data.score, 2)
		expect.equal(sim.state.houses.stark.treasury, 140 - 25)
		local relation = fx.CampaignState.relation(sim.state, "lannister", "stark")
		expect.equal(relation.score, 2, "both perspectives read the same symmetric relation")
		expect.equal(relation.baseline, -10, "baseline unchanged")
		-- Unrelated relations are untouched.
		expect.equal(fx.CampaignState.relation(sim.state, "stark", "tully").score, 45)
	end)

	t.test("the preview formula matches the applied gain", function()
		local sim = quietSim()
		local gain, lines = fx.DiplomacyRules.improveRelationsGain(
			fx.CampaignState.ruler(sim.state, "stark"),
			fx.CampaignState.ruler(sim.state, "lannister"),
			fx.GameConfig.Diplomacy
		)
		local sum = 0
		for _, line in lines do
			sum += line.value
		end
		expect.equal(gain, 12)
		expect.equal(sum, gain, "breakdown lines add up to the gain")
	end)

	t.test("repeated requests hit the cooldown and do not charge again", function()
		local sim = quietSim()
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" }), Codes.Ok)
		local before = fx.TableUtil.deepCopy(sim.state)
		for _ = 1, 5 do
			expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" }), Codes.OnCooldown)
		end
		expect.deepEqual(sim.state, before, "no further change while on cooldown")
	end)

	t.test("the cooldown expires after the configured number of months", function()
		local sim = quietSim()
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" }), Codes.Ok)
		local months = fx.GameConfig.Diplomacy.ImproveRelations.CooldownMonths
		for _ = 1, months - 1 do
			sim:advanceToNextMonth()
		end
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" }), Codes.OnCooldown)
		sim:advanceToNextMonth()
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" }), Codes.Ok)
	end)

	t.test("relations drift back toward the baseline by one point per month", function()
		local sim = quietSim()
		sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" })
		local relation = fx.CampaignState.relation(sim.state, "stark", "lannister")
		local score = relation.score
		for month = 1, 3 do
			sim:advanceToNextMonth()
			expect.equal(relation.score, score - month * fx.GameConfig.Diplomacy.DriftPerMonth)
		end
	end)

	t.test("invalid targets are rejected without modifying state", function()
		local sim = quietSim()
		sim.state.houses.bolton.extinct = true
		local before = fx.TableUtil.deepCopy(sim.state)
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "stark" }), Codes.InvalidTarget, "self")
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "targaryen" }), Codes.NotFound, "unknown")
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "bolton" }), Codes.InvalidTarget, "extinct")
		expect.result(sim:submit(stark, Commands.ImproveRelations, { target = "lannister" }), Codes.InvalidPayload, "wrong field")
		expect.deepEqual(sim.state, before)
	end)

	t.test("insufficient funds and maximum relations are enforced", function()
		local sim = quietSim()
		sim.state.houses.stark.treasury = 24
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "lannister" }), Codes.InsufficientFunds)
		sim.state.houses.stark.treasury = 500
		fx.CampaignState.relation(sim.state, "stark", "tully").score = fx.GameConfig.Diplomacy.MaxRelation
		expect.result(sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "tully" }), Codes.MaxRelation)
		-- A gain that would overshoot is clamped to the maximum.
		fx.CampaignState.relation(sim.state, "stark", "arryn").score = 95
		local result = sim:submit(stark, Commands.ImproveRelations, { targetHouseId = "arryn" })
		expect.result(result, Codes.Ok)
		expect.equal(result.data.score, 100)
		expect.equal(result.data.gain, 5)
	end)
end
