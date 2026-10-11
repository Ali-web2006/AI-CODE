-- Scenario A — Campaign initialization: valid initial state, unique ids, valid references, and
-- clear diagnostics for invalid content.

return function(t)
	local fx, expect, vr = t.fx, t.expect, t.vr
	local ContentValidator = vr.require("ServerScriptService.Simulation.ContentValidator")

	local function rawInput(overrides)
		local raw = fx.Content.raw
		local input = {
			terrains = raw.terrains,
			holdingKinds = raw.holdingKinds,
			regions = raw.regions,
			provinces = raw.provinces,
			houses = raw.houses,
			traits = raw.traits,
			cultures = raw.cultures,
			faiths = raw.faiths,
			map = fx.Content.map,
		}
		for key, value in overrides or {} do
			input[key] = value
		end
		return input
	end

	local bookmark = fx.Content.getBookmark(fx.GameConfig.DefaultBookmarkId)

	t.test("every module in the project loads under the virtual require", function()
		for _, module in vr.allModules() do
			local path = vr.pathOf(module)
			-- Client and engine-adapter modules need live Roblox services; they are compile-checked
			-- by tests/compile_check.luau and verified in Studio.
			local isEngineAdapter = string.find(path, "/StarterPlayer/", 1, true) or string.find(path, "/Services/", 1, true)
			if not isEngineAdapter then
				local ok, err = pcall(vr.requireInstance, module)
				expect.truthy(ok, `{vr.fullName(module)} failed to load: {tostring(err)}`)
			end
		end
	end)

	t.test("shipped content and bookmark validate without errors or warnings", function()
		local report = ContentValidator.validate(rawInput(), bookmark, fx.GameConfig)
		expect.deepEqual(report.errors, {}, "content errors")
		expect.deepEqual(report.warnings, {}, "content warnings")
	end)

	t.test("bookmark defines 10 houses (8 great, 2 minor) and 34 provinces", function()
		local great, minor = 0, 0
		for houseId in bookmark.houses do
			local house = fx.Content.houses[houseId]
			if house.tier == "great" then
				great += 1
			else
				minor += 1
			end
		end
		expect.equal(great, 8, "great houses")
		expect.equal(minor, 2, "minor houses")
		expect.equal(#fx.Content.provinceIds, 34, "province count")
	end)

	t.test("initial state passes every invariant and references only existing entities", function()
		local state = fx.newState()
		expect.deepEqual(fx.StateInvariants.check(state, fx.GameConfig), {}, "invariant violations")
		expect.equal(fx.TableUtil.count(state.houses), 10, "houses in state")
		expect.equal(fx.TableUtil.count(state.provinces), 34, "provinces in state")
		expect.equal(fx.TableUtil.count(state.relations), 45, "one relation per pair of houses")
		for _, province in state.provinces do
			expect.truthy(state.houses[province.ownerHouseId], `owner of {province.id}`)
		end
		for houseId, house in state.houses do
			local ruler = state.characters[house.rulerId]
			expect.truthy(ruler and ruler.alive and ruler.houseId == houseId, `ruler of {houseId}`)
			expect.truthy(#fx.CampaignState.ownedProvinces(state, houseId) > 0, `{houseId} owns provinces`)
		end
	end)

	t.test("starting values come from the bookmark", function()
		local state = fx.newState()
		expect.equal(state.houses.stark.treasury, 140)
		expect.equal(state.houses.lannister.treasury, 320)
		expect.equal(state.provinces.kings_landing.ownerHouseId, "baratheon")
		expect.equal(state.provinces.kings_landing.development, 7)
		expect.equal(fx.CampaignState.relation(state, "lannister", "martell").score, -70)
		expect.equal(fx.CampaignState.relation(state, "martell", "lannister").score, -70, "relations are symmetric")
		expect.equal(fx.CampaignState.relation(state, "bolton", "tyrell").score, 0, "unlisted pairs default to 0")
		expect.deepEqual(state.clock.date, { year = 297, month = 1, day = 1 })
		expect.equal(state.clock.paused, true, "campaign starts paused")
	end)

	t.test("validator reports duplicate province ids", function()
		local provinces = table.clone(fx.Content.raw.provinces)
		table.insert(provinces, fx.Content.raw.provinces[1])
		local report = ContentValidator.validate(rawInput({ provinces = provinces }), bookmark, fx.GameConfig)
		expect.anyContains(report.errors, "province 'winterfell': duplicate id")
	end)

	t.test("validator reports a broken and an asymmetric adjacency", function()
		local provinces = fx.TableUtil.deepCopy(fx.Content.raw.provinces)
		for _, province in provinces do
			if province.id == "winterfell" then
				province.adjacent.atlantis = "road"
			elseif province.id == "pyke" then
				province.adjacent.harlaw = nil
			end
		end
		local report = ContentValidator.validate(rawInput({ provinces = provinces }), bookmark, fx.GameConfig)
		expect.anyContains(report.errors, "province 'winterfell': adjacency references unknown province 'atlantis'")
		expect.anyContains(report.errors, "province 'harlaw': adjacency to 'pyke' is not symmetric")
	end)

	t.test("validator reports an invalid province owner and an invalid ruler", function()
		local broken = fx.TableUtil.deepCopy(bookmark)
		broken.provinces.riverrun.ownerHouseId = "targaryen"
		broken.houses.stark.rulerId = "rickard_stark" -- dead at the start date
		broken.houses.tully.rulerId = "nobody"
		local report = ContentValidator.validate(rawInput(), broken, fx.GameConfig)
		expect.anyContains(report.errors, "province 'riverrun': owner 'targaryen' is not a bookmark house")
		expect.anyContains(report.errors, "ruler 'rickard_stark' is dead")
		expect.anyContains(report.errors, "ruler 'nobody' is not a bookmark character")
	end)

	t.test("validator reports broken family links", function()
		local broken = fx.TableUtil.deepCopy(bookmark)
		for _, character in broken.characters do
			if character.id == "robb_stark" then
				character.fatherId = "sansa_stark" -- younger, and female
			elseif character.id == "jaime_lannister" then
				character.spouseId = "cersei_lannister" -- not reciprocated (Cersei is married to Robert)
			end
		end
		local report = ContentValidator.validate(rawInput(), broken, fx.GameConfig)
		expect.anyContains(report.errors, "character 'robb_stark': parent 'sansa_stark' is younger than 12")
		expect.anyContains(report.errors, "character 'robb_stark': fatherId 'sansa_stark' is not male")
		expect.anyContains(report.errors, "character 'jaime_lannister': spouse link to 'cersei_lannister' is not reciprocated")
	end)

	t.test("campaign host refuses to start with invalid content", function()
		-- Simulate a broken bookmark by asking for an unknown one.
		local ok, err = pcall(function()
			fx.newHost({ config = fx.config({ DefaultBookmarkId = "no_such_bookmark" }) })
		end)
		expect.falsy(ok, "host should refuse to start")
		expect.truthy(string.find(tostring(err), "unknown bookmark", 1, true), "diagnostic names the problem")
	end)
end
