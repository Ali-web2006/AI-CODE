-- Scenario G — AI: NPC houses act through the validated command path, never overspend, leave
-- player houses alone and are deterministic for a given seed.

return function(t)
	local fx, expect, vr = t.fx, t.expect, t.vr
	local AIDirector = vr.require("ServerScriptService.Simulation.AIDirector")

	local function runMonths(sim, months: number, perMonth: ((number) -> ())?)
		for month = 1, months do
			sim:advanceToNextMonth()
			if perMonth then
				perMonth(month)
			end
		end
	end

	t.test("twenty years of AI play keep every treasury non-negative and state valid", function()
		local sim, lines = fx.newSim({ seed = 4242 })
		local startDevelopment = 0
		for _, province in sim.state.provinces do
			startDevelopment += province.development
		end
		runMonths(sim, 240, function(month)
			for houseId, house in sim.state.houses do
				if house.treasury < 0 then
					error(`{houseId} went negative ({house.treasury}) in month {month}`)
				end
			end
		end)
		expect.deepEqual(fx.StateInvariants.check(sim.state, fx.GameConfig), {}, "invariants after 20 years")
		local endDevelopment = 0
		for _, province in sim.state.provinces do
			endDevelopment += province.development
		end
		expect.truthy(endDevelopment > startDevelopment, "the AI invested in development")
		for _, line in lines do
			expect.falsy(string.find(line, "was rejected", 1, true), `AI submitted an invalid action: {line}`)
			expect.falsy(string.find(line, "error:", 1, true), `simulation error: {line}`)
		end
	end)

	t.test("the AI uses Improve Relations through the command processor", function()
		local sim = fx.newSim({ seed = 99 })
		local events = {}
		runMonths(sim, 36, function()
			for _, event in sim.journal:flush().events do
				table.insert(events, event)
			end
		end)
		local improved, developed = 0, 0
		for _, event in events do
			if event.kind == "RelationsImproved" then
				improved += 1
			elseif event.kind == "ProvinceDeveloped" then
				developed += 1
			end
		end
		expect.truthy(improved > 0, "some AI house improved relations")
		expect.truthy(developed > 0, "some AI house developed a province")
	end)

	t.test("AI spending respects the cash reserve", function()
		local sim = fx.newSim({ seed = 7 })
		local context = sim:context()
		for _, houseId in fx.CampaignState.activeHouseIds(sim.state) do
			local candidates, _, spendable = AIDirector.candidates(context, houseId)
			for _, candidate in candidates do
				expect.truthy(candidate.cost <= spendable, `{houseId} candidate within spendable gold`)
			end
		end
	end)

	t.test("houses led by players are never governed by the AI", function()
		local sim = fx.newSim({ seed = 4242, human = { stark = true } })
		local developmentBefore = {}
		for _, province in fx.CampaignState.ownedProvinces(sim.state, "stark") do
			developmentBefore[province.id] = province.development
		end
		runMonths(sim, 60)
		for _, province in fx.CampaignState.ownedProvinces(sim.state, "stark") do
			expect.equal(province.development, developmentBefore[province.id], `{province.id} untouched`)
		end
		for _, relation in sim.state.relations do
			expect.equal(relation.cooldowns.stark, nil, "Stark sent no envoys")
		end
	end)

	t.test("the same seed reproduces the same campaign; personalities come from traits", function()
		local a = fx.newSim({ seed = 2024 })
		local b = fx.newSim({ seed = 2024 })
		runMonths(a, 60)
		runMonths(b, 60)
		expect.deepEqual(a.state, b.state, "identical seeds give identical campaigns")

		local personality = AIDirector.personality(a:context(), "frey")
		-- Walder Frey is Greedy (+3 reserve) and Deceitful (+0.1 diplomacy).
		expect.near(personality.reserveMonths, fx.GameConfig.AI.BasePersonality.reserveMonths + 3, 1e-9)
		expect.near(personality.diplomacy, fx.GameConfig.AI.BasePersonality.diplomacy + 0.1, 1e-9)
	end)

	t.test("the evaluation budget caps AI work per month", function()
		local sim = fx.newSim({ config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 3 }) })
		local month = sim.state.clock.lastProcessedMonthIndex + 1
		sim:advanceToNextMonth()
		local evaluated = 0
		for _, house in sim.state.houses do
			if house.ai.nextEvaluationMonth > month then
				evaluated += 1
			end
		end
		expect.equal(evaluated, 3)
	end)
end
