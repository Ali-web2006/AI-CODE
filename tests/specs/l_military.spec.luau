-- Scenario L — Military: levies, garrisons and ships per province and per house (calibrated to the
-- lore of 297 AC), unit maps (composition split, halving), march timing and routes over the
-- province graph, and the upkeep, strength and morale ratings of an army; then the simulation:
-- raising, calling the banners, marching by land and sea, splitting, merging, disbanding, upkeep,
-- supply and starvation, monthly refills, determinism and replication to the client.

return function(t)
	local fx, expect, vr = t.fx, t.expect, t.vr
	local Content = fx.Content
	local MilitaryRules = vr.require("ReplicatedStorage.Shared.Rules.MilitaryRules")
	local MovementRules = vr.require("ReplicatedStorage.Shared.Rules.MovementRules")
	local military = fx.GameConfig.Military
	local bookmark = Content.getBookmark(fx.GameConfig.DefaultBookmarkId)

	-- The army Winterfell raises at the bookmark: 10,800 levies split by the Stark composition.
	local WINTERFELL_ARMY = { levy_spearmen = 3780, archers = 1620, light_cavalry = 1080, northern_clansmen = 4320 }

	-- Levies + garrisons and ships of every house at the bookmark, at full pools.
	local function houseTotals(): ({ [string]: number }, { [string]: number })
		local men, ships = {}, {}
		for _, provinceId in Content.provinceIds do
			local setup = bookmark.provinces[provinceId]
			local houseId = setup.ownerHouseId
			men[houseId] = (men[houseId] or 0)
				+ MilitaryRules.levyMax(provinceId, setup.development, military)
				+ MilitaryRules.garrisonMax(provinceId, setup.development, military)
			ships[houseId] = (ships[houseId] or 0) + MilitaryRules.ships(provinceId, setup.development)
		end
		return men, ships
	end

	-- Formulas: levies, garrisons and ships ---------------------------------------------------

	t.test("levy, garrison and ship formulas give the documented values", function()
		local cases = {
			-- id, development, levies, garrison, ships
			-- (1200 + 1700*4) * castle 1.0 * plains 1.0 * north 1.35 = 10800
			{ "winterfell", 4, 10800, 900, 0 },
			-- (1200 + 1700*1) * fortress 0.5 * marsh 0.6 * north 1.35 = 1174.5 -> 1150; 1500 + 300*1
			{ "moat_cailin", 1, 1150, 1800, 0 },
			-- (1200 + 1700*2) * castle 1.0 * island 0.8 * iron_islands 1.0 = 3680 -> 3700; ships (4 + 0) * 2 * 10
			{ "pyke", 2, 3700, 700, 80 },
			-- (1200 + 1700*6) * port 0.8 * coast 1.0 * westerlands 1.3 = 11856 -> 11850; ships (2 + 3) * 6 * 1.3
			{ "lannisport", 6, 11850, 1320, 39 },
			-- (1200 + 1700*7) * city 0.6 * coast 1.0 * crownlands 0.9 = 7074 -> 7050; ships 2 * 7 * 1.6 = 22.4 -> 22
			{ "kings_landing", 7, 7050, 2950, 22 },
		}
		for _, case in cases do
			local id, development, levies, garrison, ships = table.unpack(case)
			expect.equal(MilitaryRules.levyMax(id, development, military), levies, `{id} levies`)
			expect.equal(MilitaryRules.garrisonMax(id, development, military), garrison, `{id} garrison`)
			expect.equal(MilitaryRules.ships(id, development), ships, `{id} ships`)
		end

		-- The config is honoured, not GameConfig: without the base, Winterfell musters 1700*4*1.35.
		local tuned = fx.config({ ["Military.LevyBase"] = 0 }).Military
		expect.equal(MilitaryRules.levyMax("winterfell", 4, tuned), 9200, "levies without LevyBase")
	end)

	t.test("every province musters rounded, growing pools at every development level", function()
		local economy = fx.GameConfig.Economy
		for _, provinceId in Content.provinceIds do
			local previousLevies, previousGarrison = 0, 0
			for development = economy.MinDevelopment, economy.MaxDevelopment do
				local levies = MilitaryRules.levyMax(provinceId, development, military)
				local garrison = MilitaryRules.garrisonMax(provinceId, development, military)
				local ships = MilitaryRules.ships(provinceId, development)
				local where = `{provinceId} at development {development}`
				expect.truthy(levies > 0 and levies % military.LevyRounding == 0, `{where}: levies {levies}`)
				expect.truthy(garrison > 0 and garrison % military.GarrisonRounding == 0, `{where}: garrison {garrison}`)
				expect.truthy(ships >= 0 and math.floor(ships) == ships, `{where}: ships {ships}`)
				expect.truthy(levies >= previousLevies and garrison > previousGarrison, `{where}: pools grow`)
				previousLevies, previousGarrison = levies, garrison
			end
		end
	end)

	t.test("house troop totals follow the lore of 297 AC", function()
		local men, ships = houseTotals()
		-- Levies + garrisons at the bookmark that GameConfig.Military and the terrain, holding and
		-- region factors are calibrated to.
		local lore = {
			tyrell = 64000,
			lannister = 42000,
			baratheon = 40000,
			stark = 39000,
			arryn = 28000,
			martell = 26000,
			tully = 21000,
			greyjoy = 10000,
			bolton = 8000,
			frey = 9000,
		}
		for houseId, expected in lore do
			local actual = men[houseId]
			expect.truthy(math.abs(actual - expected) <= expected * 0.10, `{houseId}: {actual} men, lore says about {expected}`)
		end

		-- The great houses, largest host first.
		local order = { "tyrell", "lannister", "baratheon", "stark", "arryn", "martell", "tully", "greyjoy" }
		for index = 1, #order - 1 do
			local larger, smaller = order[index], order[index + 1]
			expect.truthy(men[larger] > men[smaller], `{larger} ({men[larger]}) outnumbers {smaller} ({men[smaller]})`)
		end

		-- Greyjoy: the smallest great-house host but by far the largest fleet (about 200 ships).
		expect.truthy(math.abs(ships.greyjoy - 200) <= 20, `greyjoy ships {ships.greyjoy}`)
		for _, houseId in Content.houseIds do
			if houseId ~= "greyjoy" then
				expect.truthy(ships.greyjoy > ships[houseId], `greyjoy has more ships than {houseId}`)
			end
			local house = Content.houses[houseId]
			if house.tier == "great" and houseId ~= "greyjoy" then
				expect.truthy(men.greyjoy < men[houseId], `greyjoy fields fewer men than {houseId}`)
			end
		end
	end)

	t.test("fortresses keep the largest garrisons and fortresses and cities raise fewer levies", function()
		for development = 1, fx.GameConfig.Economy.MaxDevelopment do
			-- The Bloody Gate (fortress) and the Eyrie (castle) share region and terrain.
			expect.truthy(
				MilitaryRules.garrisonMax("bloody_gate", development, military) > MilitaryRules.garrisonMax("the_eyrie", development, military),
				`fortress garrison at development {development}`
			)
			expect.truthy(
				MilitaryRules.levyMax("bloody_gate", development, military) < MilitaryRules.levyMax("the_eyrie", development, military),
				`fortress levies at development {development}`
			)
			-- King's Landing and Oldtown (cities on the coast) raise fewer men than a castle of their
			-- region on poorer land (Dragonstone on its island, Horn Hill in the hills).
			expect.truthy(
				MilitaryRules.levyMax("kings_landing", development, military) < MilitaryRules.levyMax("dragonstone", development, military),
				`city levies in the Crownlands at development {development}`
			)
			expect.truthy(
				MilitaryRules.levyMax("oldtown", development, military) < MilitaryRules.levyMax("horn_hill", development, military),
				`city levies in the Reach at development {development}`
			)
		end
	end)

	-- Formulas: unit maps ---------------------------------------------------------------------

	t.test("houses raise their own composition, or the default one", function()
		expect.deepEqual(MilitaryRules.composition("stark"), Content.military.compositions.stark)
		expect.deepEqual(MilitaryRules.composition("frey"), Content.military.defaultComposition, "frey uses the default")
		expect.deepEqual(MilitaryRules.composition("bolton"), Content.military.defaultComposition, "bolton uses the default")
		for _, houseId in Content.houseIds do
			local shares = 0
			for unitId, fraction in MilitaryRules.composition(houseId) do
				expect.truthy(Content.units[unitId], `{houseId}: unit {unitId} exists`)
				shares += fraction
			end
			expect.near(shares, 1, 1e-9, `{houseId}: shares sum to 1`)
		end
	end)

	t.test("splitMen hands out every man by largest remainder", function()
		expect.deepEqual(MilitaryRules.splitMen(10800, MilitaryRules.composition("stark")), WINTERFELL_ARMY, "Winterfell levy")

		for _, total in { 0, 1, 2, 7, 99, 100, 101, 997, 10800, 12345 } do
			for _, houseId in Content.houseIds do
				local fractions = MilitaryRules.composition(houseId)
				local units = MilitaryRules.splitMen(total, fractions)
				local where = `{total} men for {houseId}`
				expect.equal(MilitaryRules.troops(units), total, `{where}: total`)
				for unitId, count in units do
					local exact = total * fractions[unitId]
					expect.truthy(count > 0 and math.floor(count) == count, `{where}: {unitId} is a positive integer`)
					expect.truthy(count >= math.floor(exact + 1e-9) and count <= math.floor(exact + 1e-9) + 1, `{where}: {unitId} {count} near {exact}`)
				end
			end
		end

		-- Equal remainders go to the smaller unit id, whatever order the table was built in.
		expect.deepEqual(MilitaryRules.splitMen(1, { b = 0.5, a = 0.5 }), { a = 1 }, "one man, two equal shares")
		expect.deepEqual(MilitaryRules.splitMen(2, { c = 0.25, b = 0.25, a = 0.5 }), { a = 1, b = 1 }, "tie between b and c")
		expect.deepEqual(MilitaryRules.splitMen(2, { a = 0.5, b = 0.25, c = 0.25 }), { a = 1, b = 1 }, "same in another order")
		expect.deepEqual(MilitaryRules.splitMen(0, MilitaryRules.composition("stark")), {}, "nobody to split")
	end)

	t.test("halve conserves every unit and drops empty entries", function()
		local keep, split = MilitaryRules.halve({ levy_spearmen = 7, archers = 1, light_cavalry = 2 })
		expect.deepEqual(keep, { levy_spearmen = 4, archers = 1, light_cavalry = 1 }, "kept")
		expect.deepEqual(split, { levy_spearmen = 3, light_cavalry = 1 }, "split off")

		local winterfellKeep, winterfellSplit = MilitaryRules.halve(WINTERFELL_ARMY)
		expect.equal(MilitaryRules.troops(winterfellKeep), 5400)
		expect.equal(MilitaryRules.troops(winterfellSplit), 5400)
		for unitId, count in WINTERFELL_ARMY do
			expect.equal((winterfellKeep[unitId] or 0) + (winterfellSplit[unitId] or 0), count, `{unitId} conserved`)
		end

		local oneKeep, oneSplit = MilitaryRules.halve({ archers = 1 })
		expect.deepEqual(oneKeep, { archers = 1 })
		expect.deepEqual(oneSplit, {}, "a single man cannot be halved")
	end)

	t.test("an army moves at the pace of its slowest unit", function()
		expect.equal(MilitaryRules.armySpeed({}), 1, "empty")
		expect.equal(MilitaryRules.armySpeed({ light_cavalry = 500 }), 1.35, "cavalry alone")
		expect.equal(MilitaryRules.armySpeed(WINTERFELL_ARMY), 1.0, "Winterfell levy")
		expect.equal(MilitaryRules.armySpeed({ light_cavalry = 500, siege_engines = 20 }), 0.85, "siege engines slow everyone")
	end)

	-- Formulas: movement ----------------------------------------------------------------------

	t.test("leg days depend on distance, connection, destination terrain and speed", function()
		local cases = {
			-- from, to, Winterfell levy, cavalry alone
			-- road into coast: 194.88 / 12 * road 0.8 * coast 1.0 = 12.99 -> 13 (/ 1.35 -> 10)
			{ "winterfell", "white_harbor", 13, 10 },
			-- road into the marsh of the Neck: 116.85 / 12 * 0.8 * marsh 1.8 = 14.02 -> 15
			{ "white_harbor", "moat_cailin", 15, 11 },
			{ "barrowlands", "moat_cailin", 19, 15 },
			-- the mountain pass to the Eyrie: 82.86 / 12 * pass 1.6 * mountains 1.7 = 18.78 -> 19
			{ "bloody_gate", "the_eyrie", 19, 14 },
			-- river: 137.61 / 12 * river 1.0 * plains 1.0 = 11.47 -> 12
			{ "the_twins", "riverrun", 12, 9 },
			-- sea: 269.05 / 30 = 8.97 -> 9, whatever the army
			{ "pyke", "lannisport", 9, 9 },
		}
		for _, case in cases do
			local from, to, levyDays, cavalryDays = table.unpack(case)
			expect.equal(MilitaryRules.legDays(from, to, WINTERFELL_ARMY, military), levyDays, `{from} -> {to}`)
			expect.equal(MilitaryRules.legDays(from, to, { light_cavalry = 100 }, military), cavalryDays, `{from} -> {to} (cavalry)`)
		end
		expect.equal(MilitaryRules.legDays("winterfell", "pyke", WINTERFELL_ARMY, military), nil, "not adjacent")
		expect.equal(MilitaryRules.legDays("winterfell", "atlantis", WINTERFELL_ARMY, military), nil, "unknown province")

		-- Every connection takes at least one whole day, and a very fast march is clamped to 1.
		local fast = fx.config({ ["Military.MarchUnitsPerDay"] = 1e6 }).Military
		for _, fromId in Content.provinceIds do
			for toId in Content.provinces[fromId].adjacent do
				local days = MilitaryRules.legDays(fromId, toId, WINTERFELL_ARMY, military) :: number
				expect.truthy(days >= 1 and math.floor(days) == days, `{fromId} -> {toId}: {days} days`)
				if Content.provinces[fromId].adjacent[toId] ~= "sea" then
					expect.equal(MilitaryRules.legDays(fromId, toId, WINTERFELL_ARMY, fast), 1, `{fromId} -> {toId} at speed`)
				end
			end
		end
	end)

	t.test("findPath takes the fastest route and only sails when allowed", function()
		local path, days = MovementRules.findPath("winterfell", "moat_cailin", WINTERFELL_ARMY, true, military)
		expect.deepEqual(path, { "white_harbor", "moat_cailin" }, "through White Harbor")
		expect.equal(days, 13 + 15)

		path, days = MovementRules.findPath("winterfell", "winterfell", WINTERFELL_ARMY, true, military)
		expect.deepEqual(path, {}, "already there")
		expect.equal(days, 0)

		path, days = MovementRules.findPath("pyke", "lannisport", WINTERFELL_ARMY, true, military)
		expect.deepEqual(path, { "lannisport" }, "Pyke sails to Lannisport")
		expect.equal(days, 9)
		path = MovementRules.findPath("pyke", "lannisport", WINTERFELL_ARMY, false, military)
		expect.equal(path, nil, "Pyke is an island: no route without ships")

		-- To Sunspear: the long road through the Boneway, or a much faster voyage.
		local landPath, landDays = MovementRules.findPath("winterfell", "sunspear", WINTERFELL_ARMY, false, military)
		local seaPath, seaDays = MovementRules.findPath("winterfell", "sunspear", WINTERFELL_ARMY, true, military)
		expect.truthy(landPath and seaPath, "both routes exist")
		expect.truthy(seaDays < landDays, `sailing ({seaDays} days) beats marching ({landDays} days)`)
		expect.equal(MovementRules.routeDays("winterfell", landPath :: { string }, WINTERFELL_ARMY, military), landDays)
		expect.equal(MovementRules.routeDays("winterfell", seaPath :: { string }, WINTERFELL_ARMY, military), seaDays)
		expect.equal(MovementRules.routeDays("winterfell", {}, WINTERFELL_ARMY, military), 0, "empty route")
		expect.equal(MovementRules.routeDays("winterfell", { "pyke" }, WINTERFELL_ARMY, military), math.huge, "broken route")
	end)

	t.test("findPath is optimal, deterministic and never uses sea lanes without ships", function()
		-- Reference: Floyd-Warshall over the same edge costs.
		local function allPairs(canSail: boolean): { [string]: { [string]: number } }
			local best = {}
			for _, a in Content.provinceIds do
				best[a] = { [a] = 0 }
				for b, kind in Content.provinces[a].adjacent do
					if canSail or kind ~= "sea" then
						best[a][b] = MilitaryRules.legDays(a, b, WINTERFELL_ARMY, military)
					end
				end
			end
			for _, k in Content.provinceIds do
				for _, a in Content.provinceIds do
					for _, b in Content.provinceIds do
						local viaK = best[a][k] and best[k][b] and best[a][k] + best[k][b]
						if viaK and (best[a][b] == nil or viaK < best[a][b]) then
							best[a][b] = viaK
						end
					end
				end
			end
			return best
		end

		for _, canSail in { true, false } do
			local best = allPairs(canSail)
			for _, fromId in Content.provinceIds do
				for _, toId in Content.provinceIds do
					local where = `{fromId} -> {toId} (sailing {canSail})`
					local path, days = MovementRules.findPath(fromId, toId, WINTERFELL_ARMY, canSail, military)
					local again, againDays = MovementRules.findPath(fromId, toId, WINTERFELL_ARMY, canSail, military)
					expect.deepEqual(again, path, `{where}: same route twice`)
					expect.equal(againDays, days, `{where}: same days twice`)
					if best[fromId][toId] == nil then
						expect.equal(path, nil, `{where}: unreachable`)
						continue
					end
					expect.truthy(path, `{where}: route found`)
					local route = path :: { string }
					expect.equal(days, best[fromId][toId], `{where}: fastest`)
					expect.equal(MovementRules.routeDays(fromId, route, WINTERFELL_ARMY, military), days, `{where}: route days`)
					if fromId ~= toId then
						expect.equal(route[#route], toId, `{where}: ends at the destination`)
						expect.falsy(table.find(route, fromId), `{where}: excludes the start`)
					end
					local previous = fromId
					for _, stop in route do
						local kind = Content.provinces[previous].adjacent[stop]
						expect.truthy(kind ~= nil, `{where}: {previous} -> {stop} adjacent`)
						expect.truthy(canSail or kind ~= "sea", `{where}: {previous} -> {stop} by land`)
						previous = stop
					end
				end
			end
		end
	end)

	t.test("routes of equal length are broken by the lexicographically smaller route", function()
		-- With every land leg clamped to 1 day, Winterfell reaches Moat Cailin in 2 days through
		-- Barrow Hall or through White Harbor; "barrowlands" sorts first.
		local fast = fx.config({ ["Military.MarchUnitsPerDay"] = 1e6 }).Military
		local path, days = MovementRules.findPath("winterfell", "moat_cailin", WINTERFELL_ARMY, false, fast)
		expect.deepEqual(path, { "barrowlands", "moat_cailin" })
		expect.equal(days, 2)
		path, days = MovementRules.findPath("winterfell", "the_twins", WINTERFELL_ARMY, false, fast)
		expect.deepEqual(path, { "barrowlands", "moat_cailin", "the_twins" })
		expect.equal(days, 3)
	end)

	-- Formulas: upkeep, strength, morale and ships ---------------------------------------------

	t.test("upkeep, strength and starting morale of the Winterfell levy", function()
		-- (3.78 * 1.0 + 1.62 * 1.1 + 1.08 * 2.0 + 4.32 * 1.0) * 1.5 = 18.063 -> 18.06 gold per month
		expect.equal(MilitaryRules.upkeep(WINTERFELL_ARMY, military), 18.06, "upkeep")
		expect.equal(MilitaryRules.upkeep(WINTERFELL_ARMY, fx.config({ ["Military.UpkeepPerThousandPerMonth"] = 3 }).Military), 36.13, "tuned upkeep")
		expect.equal(MilitaryRules.upkeep({}, military), 0, "no men, no upkeep")

		-- (3780 * 9 + 1620 * 8 + 1080 * 11.5 + 4320 * 11) / 1000 = 106.92
		expect.equal(MilitaryRules.strength(WINTERFELL_ARMY), 106.9, "leaderless")
		expect.equal(MilitaryRules.strength(WINTERFELL_ARMY, 10), 106.9, "an average commander")
		expect.equal(MilitaryRules.strength(WINTERFELL_ARMY, 15), 117.6, "martial 15: +10%")
		expect.equal(MilitaryRules.strength(WINTERFELL_ARMY, 5), 96.2, "martial 5: -10%")

		-- 60 + (1080 * 5 + 4320 * 10) / 10800 = 64.5 -> 65
		expect.equal(MilitaryRules.moraleStart(WINTERFELL_ARMY, military), 65, "Stark morale")
		-- Default composition: 60 + 0.15 * 5 = 60.75 -> 61; Ironborn: 60 + 0.6 * 15 = 69.
		expect.equal(MilitaryRules.moraleStart(MilitaryRules.splitMen(1000, MilitaryRules.composition("frey")), military), 61)
		expect.equal(MilitaryRules.moraleStart(MilitaryRules.splitMen(1000, MilitaryRules.composition("greyjoy")), military), 69)
		expect.equal(MilitaryRules.moraleStart(WINTERFELL_ARMY, fx.config({ ["Military.MoraleBase"] = 99 }).Military), 100, "capped")
	end)

	t.test("ships needed and army names", function()
		expect.equal(MilitaryRules.shipsNeeded(0, military), 0)
		expect.equal(MilitaryRules.shipsNeeded(1, military), 1)
		expect.equal(MilitaryRules.shipsNeeded(100, military), 1)
		expect.equal(MilitaryRules.shipsNeeded(101, military), 2)
		expect.equal(MilitaryRules.shipsNeeded(10800, military), 108)

		expect.equal(MilitaryRules.armyName({ originId = "winterfell" }), "Army of Winterfell")
		expect.equal(MilitaryRules.armyName({ originId = "wolfswood" }), "Army of Deepwood Motte", "named after the holding")
		expect.equal(MilitaryRules.armyName({ originId = "the_arbor" }), "Army of Ryamsport")
	end)

	-- Simulation: raising armies ---------------------------------------------------------------

	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands
	local CampaignState = fx.CampaignState
	local Economy = vr.require("ServerScriptService.Simulation.Economy")
	local EventText = vr.require("ReplicatedStorage.Shared.Text.EventText")
	local Military = vr.require("ServerScriptService.Simulation.Military")
	local Snapshot = vr.require("ServerScriptService.Simulation.Snapshot")
	local ReplicaStore = vr.require("StarterPlayer.StarterPlayerScripts.Controllers.ReplicaStore")
	local STARK = { kind = "player", userId = 1, houseId = "stark" }
	local GREYJOY = { kind = "player", userId = 2, houseId = "greyjoy" }
	local FREY = { kind = "player", userId = 3, houseId = "frey" }

	-- A simulation in which only the players act (the AI is idle).
	local function quietSim(overrides: { [string]: any }?)
		local all: { [string]: any } = { ["AI.MaxEvaluationsPerMonth"] = 0 }
		for key, value in overrides or {} do
			all[key] = value
		end
		return fx.newSim({ config = fx.config(all), human = { stark = true, greyjoy = true, frey = true } })
	end

	local function advanceDays(sim, days: number)
		for _ = 1, days do
			sim:advanceDay()
		end
	end

	local function today(sim): number
		return CampaignState.todayNumber(sim.state)
	end

	-- Advances to the next day on which supply, morale and attrition are processed.
	local function advanceToSupplyTick(sim)
		repeat
			sim:advanceDay()
		until today(sim) % sim.config.Military.SupplyTickDays == 0
	end

	local function expectValid(sim, label: string?)
		expect.deepEqual(fx.StateInvariants.check(sim.state, sim.config), {}, label or "invariants hold")
	end

	local function eventsOf(events, kind: string)
		local found = {}
		for _, event in events do
			if event.kind == kind then
				table.insert(found, event)
			end
		end
		return found
	end

	local function submitOk(sim, actor, command: string, payload)
		local result = sim:submit(actor, command, payload)
		expect.result(result, Codes.Ok, `{command} {fx.codec.encode(payload)} ({result.message})`)
		return result
	end

	-- Asserts a rejection by code and that it changed nothing.
	local function expectRejected(sim, actor, command: string, payload, code: string, label: string)
		local before = fx.TableUtil.deepCopy(sim.state)
		local result = sim:submit(actor, command, payload)
		expect.result(result, code, label)
		expect.truthy(type(result.message) == "string" and #result.message > 0, `{label}: explained`)
		expect.deepEqual(sim.state, before, `{label}: state unchanged`)
	end

	local function levyMax(sim, provinceId: string): number
		return MilitaryRules.levyMax(provinceId, sim.state.provinces[provinceId].development, sim.config.Military)
	end

	t.test("raising levies musters the house composition under the best commander", function()
		local sim = quietSim()
		local result = submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		expect.equal(result.message, "Raised 10,800 men at Winterfell.")
		expect.deepEqual(result.data, { armyId = "army_1", provinceId = "winterfell", troops = 10800, commanderId = "eddard_stark" })
		expect.deepEqual(sim.state.armies.army_1, {
			id = "army_1",
			houseId = "stark",
			originId = "winterfell",
			commanderId = "eddard_stark",
			locationId = "winterfell",
			units = WINTERFELL_ARMY,
			morale = 65,
			supply = military.SupplyMax,
			route = {},
			gather = false,
			starving = false,
		}, "the army")
		expect.equal(sim.state.provinces.winterfell.levies, 0, "the pool is emptied")
		expect.equal(sim.state.provinces.winterfell.garrisonTroops, 900, "the garrison stays")
		expect.equal(sim.state.nextArmySerial, 2)

		local changes = sim.journal.changes
		expect.truthy(changes.armies.army_1 and changes.provinces.winterfell and changes.houses.stark, "army, province and house marked")
		local raised = eventsOf(changes.events, "ArmyRaised")
		expect.equal(#raised, 1, "one ArmyRaised event")
		expect.equal(raised[1].priority, "normal")
		expect.deepEqual(raised[1].audience, { "stark" })
		expect.deepEqual(raised[1].data, { houseId = "stark", armyId = "army_1", provinceId = "winterfell", troops = 10800 })

		-- Benjen (martial 11) leads the next army; then nobody: Jon Snow (10) and Robb (9) are 13.
		expect.equal(submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "white_harbor" }).data.commanderId, "benjen_stark")
		local third = submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "barrowlands" })
		expect.equal(third.data.armyId, "army_3")
		expect.equal(sim.state.armies.army_3.commanderId, nil, "leaderless")
		expectValid(sim)
	end)

	t.test("commanders: highest martial, then the ruler, then the id; never a child", function()
		local sim = quietSim()
		local context = sim:context()
		local characters = sim.state.characters
		expect.equal(Military.bestCommander(context, "lannister"), "jaime_lannister", "Jaime (16) outranks Tywin (15)")
		characters.jaime_lannister.skills.martial = 15
		expect.equal(Military.bestCommander(context, "lannister"), "tywin_lannister", "a tie goes to the ruler")
		characters.tywin_lannister.skills.martial = 14
		characters.kevan_lannister.skills.martial = 15
		expect.equal(Military.bestCommander(context, "lannister"), "jaime_lannister", "then to the smaller id")

		submitOk(sim, { kind = "player", userId = 4, houseId = "lannister" }, Commands.RaiseArmy, { provinceId = "casterly_rock" })
		expect.equal(sim.state.armies.army_1.commanderId, "jaime_lannister")
		expect.equal(Military.bestCommander(context, "lannister"), "kevan_lannister", "Jaime already commands an army")
		expect.equal(Military.bestCommander(context, "lannister", "army_1"), "jaime_lannister", "unless that army is excluded")

		-- House Arryn: Jon Arryn, and Robert Arryn who is a child.
		expect.equal(Military.bestCommander(context, "arryn"), "jon_arryn")
		submitOk(sim, { kind = "player", userId = 5, houseId = "arryn" }, Commands.RaiseArmy, { provinceId = "the_eyrie" })
		expect.equal(Military.bestCommander(context, "arryn"), nil, "no adult left to lead")
	end)

	t.test("rejected raises change nothing", function()
		local sim = quietSim({ ["Military.MaxArmiesPerHouse"] = 2 })
		expectRejected(sim, STARK, Commands.RaiseArmy, { provinceId = "atlantis" }, Codes.NotFound, "unknown province")
		expectRejected(sim, STARK, Commands.RaiseArmy, { provinceId = "casterly_rock" }, Codes.NotOwner, "Lannister land")
		sim.state.provinces.wolfswood.occupierHouseId = "bolton"
		expectRejected(sim, STARK, Commands.RaiseArmy, { provinceId = "wolfswood" }, Codes.NotOwner, "occupied land")
		expectRejected(sim, STARK, Commands.RaiseAllLevies, { provinceId = "wolfswood" }, Codes.NotOwner, "occupied rally")
		sim.state.provinces.wolfswood.occupierHouseId = nil
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		expectRejected(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" }, Codes.NotEnoughTroops, "the pool is empty")
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "white_harbor" })
		expectRejected(sim, STARK, Commands.RaiseArmy, { provinceId = "barrowlands" }, Codes.LimitReached, "army limit")
		expectRejected(sim, STARK, Commands.RaiseAllLevies, { provinceId = "barrowlands" }, Codes.LimitReached, "army limit (call)")
		expectRejected(sim, STARK, Commands.RaiseAllLevies, { provinceId = "casterly_rock" }, Codes.NotOwner, "foreign rally")
		expectRejected(sim, STARK, Commands.RaiseAllLevies, { provinceId = "atlantis" }, Codes.NotFound, "unknown rally")
		expectValid(sim)

		local drained = quietSim()
		submitOk(drained, STARK, Commands.RaiseAllLevies, { provinceId = "winterfell" })
		expectRejected(drained, STARK, Commands.RaiseAllLevies, { provinceId = "winterfell" }, Codes.NotEnoughTroops, "every pool is empty")
	end)

	t.test("calling the banners raises every levy and merges the armies at the rally", function()
		local sim = quietSim()
		local start = today(sim)
		local expectedTroops, expectedUnits = 0, {}
		local leviesOf = {}
		for _, province in CampaignState.ownedProvinces(sim.state, "stark") do
			leviesOf[province.id] = province.levies
			expectedTroops += province.levies
			for unitId, count in MilitaryRules.splitMen(province.levies, MilitaryRules.composition("stark")) do
				expectedUnits[unitId] = (expectedUnits[unitId] or 0) + count
			end
		end

		local result = submitOk(sim, STARK, Commands.RaiseAllLevies, { provinceId = "white_harbor" })
		expect.equal(result.message, `Called 5 armies ({EventText.troops(expectedTroops)} men) to White Harbor.`)
		expect.deepEqual(result.data, {
			provinceId = "white_harbor",
			armies = 5,
			troops = expectedTroops,
			-- The rally province raises first, then the others in id order.
			armyIds = { "army_1", "army_2", "army_3", "army_4", "army_5" },
		})
		local origins = { "white_harbor", "barrowlands", "moat_cailin", "winterfell", "wolfswood" }
		local latest = start
		for index, originId in origins do
			local army = sim.state.armies[`army_{index}`]
			expect.equal(army.originId, originId, `army_{index} origin`)
			expect.equal(MilitaryRules.troops(army.units), leviesOf[originId], `army_{index} troops`)
			expect.equal(sim.state.provinces[originId].levies, 0, `{originId} pool emptied`)
			if originId == "white_harbor" then
				expect.deepEqual(army.route, {}, "the rally army waits")
				expect.equal(army.gather, false)
			else
				local canSail = Military.shipsTotal(sim:context(), "stark") >= MilitaryRules.shipsNeeded(leviesOf[originId], military)
				local path = MovementRules.findPath(originId, "white_harbor", army.units, canSail, military)
				expect.deepEqual(army.route, path, `{originId} marches to the rally`)
				expect.equal(army.gather, true, `{originId} gathers`)
				expect.equal(army.legStartDay, start, `{originId} sets off at once`)
				expect.equal(army.legEndDay, start + MilitaryRules.legDays(originId, army.route[1], army.units, military))
				latest = math.max(latest, start + MovementRules.routeDays(originId, path :: { string }, army.units, military))
			end
		end
		expect.equal(sim.state.armies.army_1.commanderId, "eddard_stark", "the rally army gets the best commander")
		expect.equal(sim.state.armies.army_2.commanderId, "benjen_stark")
		local called = eventsOf(sim.journal.changes.events, "LeviesCalled")
		expect.equal(#called, 1, "one LeviesCalled event")
		expect.deepEqual(called[1].data, { houseId = "stark", provinceId = "white_harbor", armies = 5, troops = expectedTroops })
		expect.equal(#eventsOf(sim.journal.changes.events, "ArmyRaised"), 0, "no event per army")
		expectValid(sim, "invariants after the call")

		sim.journal:flush()
		advanceDays(sim, latest - start)
		local merged = eventsOf(sim.journal:flush().events, "ArmiesMerged")
		expect.equal(#merged, 4, "four armies joined the rally army")
		expect.deepEqual(fx.TableUtil.sortedKeys(sim.state.armies), { "army_1" }, "one army remains")
		local host = sim.state.armies.army_1
		expect.equal(MilitaryRules.troops(host.units), expectedTroops, "nobody was lost")
		expect.deepEqual(host.units, expectedUnits, "every unit conserved")
		expect.equal(host.commanderId, "eddard_stark", "Eddard keeps the command")
		expect.equal(host.gather, false)
		local last = merged[#merged].data
		expect.equal(last.armyId, "army_1", "merged into the rally army")
		expect.equal(last.originId, "white_harbor")
		expect.equal(last.troops, expectedTroops)
		expectValid(sim, "invariants after gathering")
	end)

	t.test("gathering armies join an idle army, never one passing through the rally", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "white_harbor" })
		local passing = sim.state.armies.army_1
		local passingUnits = table.clone(passing.units)
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "winterfell" })
		local start = today(sim)
		-- White Harbor's own pool is empty, so no army waits at the rally.
		local call = submitOk(sim, STARK, Commands.RaiseAllLevies, { provinceId = "white_harbor" })
		expect.equal(call.data.armies, 4)
		local first, last = math.huge, 0
		for _, armyId in call.data.armyIds do
			local army = sim.state.armies[armyId]
			local days = MovementRules.routeDays(army.locationId, army.route, army.units, military)
			first, last = math.min(first, days), math.max(last, days)
		end
		expect.truthy(start + first < (passing.legEndDay :: number), "the first levy arrives while army_1 is still leaving")
		advanceDays(sim, first)
		expect.deepEqual(passing.units, passingUnits, "the passing army took nobody in")
		local waiting = {}
		for _, army in CampaignState.armiesIn(sim.state, "white_harbor") do
			if Military.isIdle(army) then
				table.insert(waiting, army.id)
			end
		end
		expect.equal(#waiting, 1, "the first arrival waits at the rally")

		advanceDays(sim, last - first)
		expect.equal(passing.locationId, "winterfell")
		expect.deepEqual(passing.units, passingUnits)
		local gathered = CampaignState.armiesIn(sim.state, "white_harbor")
		expect.equal(#gathered, 1, "the others merged into it")
		expect.equal(gathered[1].id, waiting[1])
		expect.equal(MilitaryRules.troops(gathered[1].units), call.data.troops)
		expectValid(sim)
	end)

	t.test("a new order or a stop releases an army from gathering", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseAllLevies, { provinceId = "white_harbor" })
		local barrowlands, winterfell = sim.state.armies.army_2, sim.state.armies.army_4
		expect.truthy(barrowlands.gather and winterfell.gather, "both gather")
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_2", provinceId = "moat_cailin" })
		expect.equal(barrowlands.gather, false, "a new order")
		submitOk(sim, STARK, Commands.StopArmy, { armyId = "army_4" })
		expect.equal(winterfell.gather, false, "a stop")
		advanceDays(sim, 40)
		expect.equal(sim.state.armies.army_4.locationId, "white_harbor", "halted at the rally")
		expect.truthy(Military.isIdle(sim.state.armies.army_4), "beside the rally army, not merged")
		expect.equal(sim.state.armies.army_2.locationId, "moat_cailin")
		expectValid(sim)
	end)

	-- Simulation: marching ---------------------------------------------------------------------

	t.test("a march follows the leg days exactly and is replicated only when a leg changes", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		local army = sim.state.armies.army_1
		-- Full morale: at home nothing else changes, so only leg changes mark the army dirty.
		army.morale = military.MoraleMax
		local start = today(sim)
		local result = submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "moat_cailin" })
		expect.equal(result.message, "The Army of Winterfell marches to Moat Cailin (28 days).")
		expect.equal(result.data.days, 28)
		expect.equal(result.data.waiting, false)
		expect.deepEqual(army.route, { "white_harbor", "moat_cailin" })
		expect.equal(army.legStartDay, start)
		expect.equal(army.legEndDay, start + 13)
		expect.truthy(sim.journal.changes.armies.army_1 and sim.journal.changes.houses.stark, "the order is replicated")
		expectValid(sim)

		sim.journal:flush()
		for day = 1, 12 do
			sim:advanceDay()
			expect.equal(sim.journal.changes.armies.army_1, nil, `day {day}: nothing to replicate while marching`)
		end
		expect.equal(army.locationId, "winterfell", "still on the road")
		sim:advanceDay()
		expect.equal(army.locationId, "white_harbor", "first leg done on day 13")
		expect.deepEqual(army.route, { "moat_cailin" })
		expect.equal(army.legStartDay, start + 13)
		expect.equal(army.legEndDay, start + 28, "the marsh of the Neck takes 15 days")
		expect.truthy(sim.journal.changes.armies.army_1, "the new leg is replicated")
		expect.equal(#eventsOf(sim.journal.changes.events, "ArmyArrived"), 0, "no arrival event at a waypoint")

		advanceDays(sim, 14)
		expect.equal(army.locationId, "white_harbor", "day 27: still marching")
		sim.journal:flush()
		sim:advanceDay()
		expect.equal(army.locationId, "moat_cailin", "arrived on day 28")
		expect.deepEqual(army.route, {})
		expect.equal(army.legStartDay, nil)
		expect.equal(army.legEndDay, nil)
		local arrived = eventsOf(sim.journal.changes.events, "ArmyArrived")
		expect.equal(#arrived, 1)
		expect.equal(arrived[1].priority, "low")
		expect.deepEqual(arrived[1].data, { houseId = "stark", armyId = "army_1", originId = "winterfell", provinceId = "moat_cailin" })
		expect.equal(EventText.format(arrived[1], "stark"), "The Army of Winterfell has reached Moat Cailin.")
		expectValid(sim)
	end)

	t.test("a new order keeps the current leg and replaces the rest of the route", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		local army = sim.state.armies.army_1
		local start = today(sim)
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "moat_cailin" })
		advanceDays(sim, 5)

		local toDreadfort = MilitaryRules.legDays("white_harbor", "dreadfort", army.units, military) :: number
		local result = submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "dreadfort" })
		expect.equal(result.data.days, 8 + toDreadfort, "the rest of this leg plus the new route")
		expect.deepEqual(army.route, { "white_harbor", "dreadfort" })
		expect.equal(army.legStartDay, start, "the current leg is kept")
		expect.equal(army.legEndDay, start + 13)

		-- Turning back: the army first reaches White Harbor, then marches home.
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "winterfell" })
		expect.deepEqual(army.route, { "white_harbor", "winterfell" })
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "winterfell" }, Codes.InvalidTarget, "same destination")
		local home = MilitaryRules.legDays("white_harbor", "winterfell", army.units, military) :: number
		advanceDays(sim, 8 + home)
		expect.equal(army.locationId, "winterfell")
		expect.equal(today(sim), start + 13 + home)
		expect.deepEqual(army.route, {})
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "winterfell" }, Codes.InvalidTarget, "already there")
		expectValid(sim)
	end)

	t.test("stopping halts an army at the end of its current leg", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		local army = sim.state.armies.army_1
		local start = today(sim)
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "moat_cailin" })
		advanceDays(sim, 3)
		local result = submitOk(sim, STARK, Commands.StopArmy, { armyId = "army_1" })
		expect.equal(result.message, "The Army of Winterfell halts at White Harbor.")
		expect.deepEqual(army.route, { "white_harbor" })
		expect.equal(army.legEndDay, start + 13, "the leg under way is finished")
		advanceDays(sim, 10)
		expect.equal(army.locationId, "white_harbor")
		expect.deepEqual(army.route, {}, "and stays there")
		expectRejected(sim, STARK, Commands.StopArmy, { armyId = "army_1" }, Codes.InvalidTarget, "nothing to stop")
		expectValid(sim)
	end)

	t.test("sea crossings need ships: the ironborn sail, the North and the Freys cannot", function()
		local sim = quietSim()
		local context = sim:context()
		submitOk(sim, GREYJOY, Commands.RaiseArmy, { provinceId = "pyke" })
		local raiders = sim.state.armies.army_1
		expect.equal(MilitaryRules.troops(raiders.units), 3700)
		local start = today(sim)
		local result = submitOk(sim, GREYJOY, Commands.MoveArmy, { armyId = "army_1", provinceId = "lannisport" })
		expect.equal(result.message, "The Army of Pyke marches to Lannisport (9 days).")
		expect.deepEqual(raiders.route, { "lannisport" })
		expect.equal(raiders.legEndDay, start + 9)
		expect.truthy(Military.atSea(raiders), "aboard ships")
		local fleet = Snapshot.houseView(context, "greyjoy").military
		expect.equal(fleet.ships, Military.shipsTotal(context, "greyjoy"))
		expect.equal(fleet.shipsInUse, 37, "3,700 men fill 37 ships")

		-- At sea supply and morale do not change, even on a supply day.
		local supply, morale = raiders.supply, raiders.morale
		advanceToSupplyTick(sim)
		expect.equal(raiders.supply, supply)
		expect.equal(raiders.morale, morale)
		advanceDays(sim, start + 9 - today(sim))
		expect.equal(raiders.locationId, "lannisport", "landed")
		expect.equal(Snapshot.houseView(context, "greyjoy").military.shipsInUse, 0, "the ships are free again")

		-- Winterfell's 10,800 men need 108 ships to reach Dragonstone; the North has 25.
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		expect.equal(Military.shipsTotal(context, "stark"), 25)
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_2", provinceId = "dragonstone" }, Codes.NotEnoughShips, "too few ships")
		-- Land routes need no ships at all.
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_2", provinceId = "white_harbor" })
		advanceDays(sim, 13)
		-- A detachment small enough for the northern fleet may sail.
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_2" })
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_2" })
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_2" })
		-- Halving keeps the odd man: 10,800 -> 5,400 -> 2,700 -> 1,351 men, 14 ships.
		expect.equal(MilitaryRules.troops(sim.state.armies.army_2.units), 1351)
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_2", provinceId = "dragonstone" })
		expect.deepEqual(sim.state.armies.army_2.route, { "gulltown", "dragonstone" })

		-- House Frey has no ships at all.
		submitOk(sim, FREY, Commands.RaiseArmy, { provinceId = "the_twins" })
		local freyArmy = `army_{sim.state.nextArmySerial - 1}`
		expect.equal(Military.shipsTotal(context, "frey"), 0)
		expectRejected(sim, FREY, Commands.MoveArmy, { armyId = freyArmy, provinceId = "pyke" }, Codes.NotEnoughShips, "no fleet")
		expectValid(sim)
	end)

	t.test("ships at sea delay a second embarkation until they are free", function()
		-- With 30 men per ship, Pyke's levy needs 124 ships and Ten Towers' 169: the 200 ships of the
		-- Iron Islands carry one at a time.
		local sim = quietSim({ ["Military.ShipCapacity"] = 30 })
		local context = sim:context()
		submitOk(sim, GREYJOY, Commands.RaiseArmy, { provinceId = "pyke" })
		submitOk(sim, GREYJOY, Commands.RaiseArmy, { provinceId = "harlaw" })
		expect.equal(Military.shipsTotal(context, "greyjoy"), 200)
		local start = today(sim)
		submitOk(sim, GREYJOY, Commands.MoveArmy, { armyId = "army_1", provinceId = "lannisport" })
		expect.equal(Military.shipsInUse(context, "greyjoy"), 124)

		local second = sim.state.armies.army_2
		local result = submitOk(sim, GREYJOY, Commands.MoveArmy, { armyId = "army_2", provinceId = "lannisport" })
		expect.equal(result.data.waiting, true, "the order waits for ships")
		expect.truthy(string.find(result.message, "waits for ships", 1, true), result.message)
		expect.deepEqual(second.route, { "pyke", "lannisport" })
		expect.equal(second.legStartDay, nil)
		expect.equal(second.legEndDay, nil)
		expectValid(sim, "a waiting army is valid")
		-- A waiting army can be stopped (it stays) and ordered again.
		submitOk(sim, GREYJOY, Commands.StopArmy, { armyId = "army_2" })
		expect.deepEqual(second.route, {})
		submitOk(sim, GREYJOY, Commands.MoveArmy, { armyId = "army_2", provinceId = "lannisport" })
		expect.equal(second.legStartDay, nil, "waiting again")

		sim.journal:flush()
		advanceDays(sim, 8)
		expect.equal(second.locationId, "harlaw", "still waiting on day 8")
		expect.equal(second.legStartDay, nil)
		sim:advanceDay()
		expect.equal(sim.state.armies.army_1.locationId, "lannisport", "the first army landed on day 9")
		expect.equal(second.legStartDay, start + 9, "and the second embarked the same day")
		expect.equal(second.legEndDay, start + 9 + MilitaryRules.legDays("harlaw", "pyke", second.units, sim.config.Military))
		expect.truthy(sim.journal.changes.armies.army_2, "the departure is replicated")
		expectValid(sim)
	end)

	-- Simulation: split, merge, disband ----------------------------------------------------------

	t.test("split and merge conserve every man", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		local first = sim.state.armies.army_1
		first.morale, first.supply = 70, 90

		local result = submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_1" })
		expect.equal(result.message, "The Army of Winterfell divided: 5,400 men form a new army.")
		expect.deepEqual(result.data, { armyId = "army_1", newArmyId = "army_2", originId = "winterfell", troops = 5400, kept = 5400 })
		local second = sim.state.armies.army_2
		for unitId, count in WINTERFELL_ARMY do
			expect.equal((first.units[unitId] or 0) + (second.units[unitId] or 0), count, `{unitId} conserved`)
		end
		expect.equal(second.commanderId, "benjen_stark", "the next best commander")
		expect.equal(second.locationId, "winterfell")
		expect.equal(second.originId, "winterfell")
		expect.equal(second.morale, 70, "morale copied")
		expect.equal(second.supply, 90, "supply copied")
		local split = eventsOf(sim.journal.changes.events, "ArmySplit")
		expect.deepEqual(split[1].data, { houseId = "stark", armyId = "army_1", newArmyId = "army_2", originId = "winterfell", troops = 5400 })
		expectValid(sim)

		-- A leaderless third army: merging it keeps Benjen in command.
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_2" })
		expect.equal(sim.state.armies.army_3.commanderId, nil)
		submitOk(sim, STARK, Commands.MergeArmies, { armyId = "army_3", intoArmyId = "army_2" })
		expect.equal(second.commanderId, "benjen_stark")
		expect.equal(MilitaryRules.troops(second.units), 5400)

		-- Merging into Eddard's army: morale and supply are head-count-weighted averages.
		second.morale, second.supply = 40, 50
		sim.journal:flush()
		local merge = submitOk(sim, STARK, Commands.MergeArmies, { armyId = "army_2", intoArmyId = "army_1" })
		expect.equal(merge.message, "The armies joined: the Army of Winterfell now has 10,800 men.")
		expect.deepEqual(merge.data, { armyId = "army_1", mergedId = "army_2", originId = "winterfell", troops = 10800 })
		expect.deepEqual(first.units, WINTERFELL_ARMY, "the levy is whole again")
		expect.equal(first.morale, 55)
		expect.equal(first.supply, 70)
		expect.equal(first.commanderId, "eddard_stark", "the higher martial commands")
		expect.equal(sim.state.armies.army_2, nil, "the merged army is gone")
		expect.truthy(sim.journal.changes.removedArmies.army_2, "its removal is replicated")
		expect.equal(sim.journal.changes.armies.army_2, nil, "and no update for it")
		expect.truthy(sim.journal.changes.armies.army_1)

		-- The joining commander takes over when he outranks the target's (here: no commander).
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_1" })
		expect.equal(sim.state.armies.army_4.commanderId, "benjen_stark")
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_4" })
		submitOk(sim, STARK, Commands.MergeArmies, { armyId = "army_4", intoArmyId = "army_5" })
		expect.equal(sim.state.armies.army_5.commanderId, "benjen_stark")

		-- Equal martial: the army merged into keeps its commander.
		sim.state.characters.benjen_stark.skills.martial = 13
		submitOk(sim, STARK, Commands.MergeArmies, { armyId = "army_1", intoArmyId = "army_5" })
		expect.equal(sim.state.armies.army_5.commanderId, "benjen_stark", "a tie keeps the target's commander")
		expect.deepEqual(sim.state.armies.army_5.units, WINTERFELL_ARMY)
		expectValid(sim)
	end)

	t.test("rejected splits and merges change nothing", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "white_harbor" })
		submitOk(sim, GREYJOY, Commands.RaiseArmy, { provinceId = "pyke" })
		expectRejected(sim, STARK, Commands.MergeArmies, { armyId = "army_1", intoArmyId = "army_1" }, Codes.InvalidTarget, "merge with itself")
		expectRejected(sim, STARK, Commands.MergeArmies, { armyId = "army_1", intoArmyId = "army_2" }, Codes.InvalidTarget, "different provinces")
		expectRejected(sim, STARK, Commands.MergeArmies, { armyId = "army_1", intoArmyId = "army_3" }, Codes.NotOwner, "a Greyjoy army")
		expectRejected(sim, STARK, Commands.MergeArmies, { armyId = "army_9", intoArmyId = "army_1" }, Codes.NotFound, "unknown army")
		expectRejected(sim, STARK, Commands.SplitArmy, { armyId = "army_3" }, Codes.NotOwner, "split a Greyjoy army")
		expectRejected(sim, STARK, Commands.SplitArmy, { armyId = "army_9" }, Codes.NotFound, "split an unknown army")
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "white_harbor" })
		expectRejected(sim, STARK, Commands.SplitArmy, { armyId = "army_1" }, Codes.InvalidTarget, "split while marching")
		expectRejected(sim, STARK, Commands.MergeArmies, { armyId = "army_2", intoArmyId = "army_1" }, Codes.InvalidTarget, "merge with a marching army")
		expectValid(sim)

		local small = quietSim({ ["Military.MinArmySize"] = 1000 })
		submitOk(small, STARK, Commands.RaiseArmy, { provinceId = "moat_cailin" })
		expectRejected(small, STARK, Commands.SplitArmy, { armyId = "army_1" }, Codes.NotEnoughTroops, "halves below the minimum")
		local capped = quietSim({ ["Military.MaxArmiesPerHouse"] = 1 })
		submitOk(capped, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		expectRejected(capped, STARK, Commands.SplitArmy, { armyId = "army_1" }, Codes.LimitReached, "split beyond the army limit")
	end)

	t.test("disbanding returns men to the levy pools, never above the maximum, without gold", function()
		local sim = quietSim()
		local treasury = sim.state.houses.stark.treasury
		local harbourLevies = sim.state.provinces.white_harbor.levies
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "white_harbor" })
		submitOk(sim, STARK, Commands.SplitArmy, { armyId = "army_1" })

		-- 5,400 men for pools short of 10,800 and of White Harbor's levy: shared by shortfall.
		local shares = MilitaryRules.splitMen(5400, { winterfell = 10800, white_harbor = harbourLevies })
		local result = submitOk(sim, STARK, Commands.DisbandArmy, { armyId = "army_3" })
		expect.deepEqual(result.data, { armyId = "army_3", originId = "winterfell", troops = 5400, returned = 5400 })
		expect.equal(result.message, "The Army of Winterfell disbanded: 5,400 of 5,400 men returned to the levies.")
		expect.equal(sim.state.provinces.winterfell.levies, shares.winterfell)
		expect.equal(sim.state.provinces.white_harbor.levies, shares.white_harbor)
		expect.equal(sim.state.armies.army_3, nil)
		expect.truthy(sim.journal.changes.removedArmies.army_3 and sim.journal.changes.provinces.winterfell, "replicated")
		local disbanded = eventsOf(sim.journal.changes.events, "ArmyDisbanded")
		expect.deepEqual(disbanded[1].data, { houseId = "stark", armyId = "army_3", originId = "winterfell", troops = 5400, returned = 5400 })
		expectValid(sim)

		submitOk(sim, STARK, Commands.DisbandArmy, { armyId = "army_1" })
		submitOk(sim, STARK, Commands.DisbandArmy, { armyId = "army_2" })
		expect.deepEqual(sim.state.armies, {}, "every army went home")
		for _, province in CampaignState.ownedProvinces(sim.state, "stark") do
			expect.equal(province.levies, levyMax(sim, province.id), `{province.id} pool full again`)
		end
		expect.equal(sim.state.houses.stark.treasury, treasury, "no gold changed hands")

		-- Men the pools cannot take back are lost: a month after raising, Winterfell has refilled.
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		sim:advanceToNextMonth()
		expect.equal(sim.state.provinces.winterfell.levies, 864)
		local gold = sim.state.houses.stark.treasury
		local late = submitOk(sim, STARK, Commands.DisbandArmy, { armyId = "army_4" })
		expect.equal(late.data.returned, 10800 - 864, "only the shortfall returns")
		expect.equal(sim.state.provinces.winterfell.levies, 10800)
		expect.equal(sim.state.houses.stark.treasury, gold, "no refund")
		expectRejected(sim, STARK, Commands.DisbandArmy, { armyId = "army_4" }, Codes.NotFound, "already disbanded")
		expectValid(sim)
	end)

	-- Simulation: upkeep, supply and refills ------------------------------------------------------

	t.test("army upkeep enters the budget and the monthly ledger", function()
		local plain = quietSim()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		local base = Economy.budgetFor(plain:context(), "stark")
		local budget = Economy.budgetFor(sim:context(), "stark")
		expect.equal(base.armyUpkeep, 0, "no armies, no upkeep")
		expect.equal(budget.armyUpkeep, 18.06)
		expect.near(budget.expenses, base.expenses + 18.06, 1e-9, "upkeep is an expense")
		expect.equal(Snapshot.houseView(sim:context(), "stark").budget.armyUpkeep, 18.06, "the house view shows it")

		local startTreasury = sim.state.houses.stark.treasury
		plain:advanceToNextMonth()
		sim:advanceToNextMonth()
		local plainEntry = plain.state.houses.stark.ledger[1]
		local entry = sim.state.houses.stark.ledger[1]
		expect.near(entry.expenses - plainEntry.expenses, 18.06, 0.011, "charged once in the ledger")
		expect.near(plain.state.houses.stark.treasury - sim.state.houses.stark.treasury, 18.06, 0.011, "and paid from the treasury")
		expect.near(sim.state.houses.stark.treasury, startTreasury + entry.net, 1e-9, "only through the ledger")
	end)

	t.test("supply drains abroad, starvation kills men, and supply returns at home", function()
		local sim = quietSim({ ["Military.SupplyLossForeign"] = 40 })
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "moat_cailin" })
		local army = sim.state.armies.army_1
		local morale = army.morale
		-- The Twins are Frey land (plains: drain x1.0). On the march the destination is the ground.
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "the_twins" })
		advanceToSupplyTick(sim)
		expect.equal(army.supply, 60)
		expect.equal(army.morale, morale, "no morale lost while supplied")
		advanceToSupplyTick(sim)
		expect.equal(army.supply, 20)
		sim.journal:flush()
		advanceToSupplyTick(sim)
		expect.equal(army.supply, 0)
		expect.equal(army.starving, true)
		expect.equal(MilitaryRules.troops(army.units), 1150 - 35, "ceil(1,150 * 3%) men starved")
		expect.equal(army.morale, morale - military.MoraleLossStarving)
		local starving = eventsOf(sim.journal.changes.events, "ArmyStarving")
		expect.equal(#starving, 1)
		expect.equal(starving[1].priority, "high")
		expect.deepEqual(starving[1].data, { houseId = "stark", armyId = "army_1", originId = "moat_cailin", provinceId = "the_twins" })
		expect.equal(select(2, EventText.format(starving[1], "stark")), "bad")
		expectValid(sim)

		local before = table.clone(army.units)
		sim.journal:flush()
		advanceToSupplyTick(sim)
		expect.equal(MilitaryRules.troops(army.units), 1115 - 34, "ceil(1,115 * 3%) more")
		for unitId, count in army.units do
			expect.truthy(count <= before[unitId], `{unitId} only shrinks`)
		end
		expect.equal(#eventsOf(sim.journal.changes.events, "ArmyStarving"), 0, "the event fires once")

		-- Home again: once the army has arrived at the Twins it marches back to Moat Cailin.
		for _ = 1, 60 do
			if army.locationId == "the_twins" then
				break
			end
			sim:advanceDay()
		end
		expect.equal(army.locationId, "the_twins", "arrived")
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "moat_cailin" })
		local lowMorale = army.morale
		advanceToSupplyTick(sim)
		expect.equal(army.supply, military.SupplyGainHome)
		expect.equal(army.starving, false, "recovered")
		expect.equal(army.morale, lowMorale + military.MoraleRecoveryHome)
		expectValid(sim)
	end)

	t.test("an army starved below half the minimum size deserts", function()
		local sim = quietSim({ ["Military.SupplyLossForeign"] = 100, ["Military.AttritionStarving"] = 0.5 })
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "moat_cailin" })
		submitOk(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "the_twins" })
		local sizes = {}
		local events = {}
		for _ = 1, 10 do
			if not sim.state.armies.army_1 then
				break
			end
			advanceToSupplyTick(sim)
			local army = sim.state.armies.army_1
			table.insert(sizes, if army then MilitaryRules.troops(army.units) else 0)
			for _, event in sim.journal:flush().events do
				table.insert(events, event)
			end
		end
		expect.deepEqual(sizes, { 575, 287, 143, 71, 0 }, "halved every supply day until it broke")
		local deserted = eventsOf(events, "ArmyDesertion")
		expect.equal(#deserted, 1)
		expect.deepEqual(deserted[1].data, { houseId = "stark", armyId = "army_1", originId = "moat_cailin", provinceId = "the_twins", troops = 35 })
		expect.equal(EventText.format(deserted[1], "stark"), "The Army of Moat Cailin melted away in The Twins: its last 35 men deserted.")
		expect.equal(Economy.budgetFor(sim:context(), "stark").armyUpkeep, 0)
		expectValid(sim)
	end)

	t.test("levy and garrison pools refill every month up to their maximum", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		-- Nothing spends garrisons yet, and nobody occupies land yet: set both up by hand.
		sim.state.provinces.winterfell.garrisonTroops = 0
		sim.state.provinces.wolfswood.levies = 0
		sim.state.provinces.wolfswood.occupierHouseId = "bolton"
		sim.journal:flush()
		sim:advanceToNextMonth()
		local winterfell = sim.state.provinces.winterfell
		expect.equal(winterfell.levies, 864, "ceil(10,800 * 8%)")
		expect.equal(winterfell.garrisonTroops, 135, "ceil(900 * 15%)")
		expect.equal(sim.state.provinces.wolfswood.levies, 0, "occupied: no refill")
		local changes = sim.journal.changes
		expect.truthy(changes.provinces.winterfell and changes.houses.stark, "province and owner marked")
		expect.equal(changes.provinces.barrowlands, nil, "full pools are not marked")
		for _ = 1, 12 do
			sim:advanceToNextMonth()
		end
		expect.equal(winterfell.levies, 10800, "full again after 13 months, never above")
		expect.equal(winterfell.garrisonTroops, 900)
		expectValid(sim)

		-- Rounding up ignores floating-point noise: 10,800 * 0.07 is 756.0000000000001, not 757.
		local tuned = quietSim({ ["Military.LevyReplenishPerMonth"] = 0.07 })
		submitOk(tuned, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		tuned:advanceToNextMonth()
		expect.equal(tuned.state.provinces.winterfell.levies, 756)
	end)

	t.test("rejected moves, stops and disbands change nothing", function()
		local sim = quietSim()
		submitOk(sim, STARK, Commands.RaiseArmy, { provinceId = "winterfell" })
		submitOk(sim, GREYJOY, Commands.RaiseArmy, { provinceId = "pyke" })
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_9", provinceId = "moat_cailin" }, Codes.NotFound, "unknown army")
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_2", provinceId = "moat_cailin" }, Codes.NotOwner, "Greyjoy army")
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "atlantis" }, Codes.NotFound, "unknown province")
		expectRejected(sim, STARK, Commands.MoveArmy, { armyId = "army_1", provinceId = "winterfell" }, Codes.InvalidTarget, "already there")
		expectRejected(sim, STARK, Commands.StopArmy, { armyId = "army_1" }, Codes.InvalidTarget, "no orders")
		expectRejected(sim, STARK, Commands.StopArmy, { armyId = "army_2" }, Codes.NotOwner, "stop a Greyjoy army")
		expectRejected(sim, STARK, Commands.DisbandArmy, { armyId = "army_2" }, Codes.NotOwner, "disband a Greyjoy army")
		expectRejected(sim, STARK, Commands.DisbandArmy, { armyId = "nothing" }, Codes.NotFound, "disband nothing")
		sim.state.houses.stark.extinct = true
		expectRejected(sim, STARK, Commands.RaiseArmy, { provinceId = "white_harbor" }, Codes.NotAuthorized, "an extinct house")
	end)

	t.test("every army event has text", function()
		local cases = {
			{ "ArmyRaised", { provinceId = "winterfell", troops = 10800 }, "The Army of Winterfell has been raised: 10,800 men.", "info" },
			{ "LeviesCalled", { provinceId = "white_harbor", armies = 5, troops = 33350 }, "The banners are called to White Harbor: 5 armies, 33,350 men.", "info" },
			{ "ArmyArrived", { originId = "winterfell", provinceId = "moat_cailin" }, "The Army of Winterfell has reached Moat Cailin.", "info" },
			{ "ArmySplit", { originId = "pyke", troops = 1850 }, "The Army of Pyke divided: 1,850 men march under a new banner.", "quiet" },
			{ "ArmiesMerged", { originId = "pyke", troops = 3700 }, "Armies joined the Army of Pyke: 3,700 men now march together.", "quiet" },
			{ "ArmyDisbanded", { originId = "pyke", troops = 3700, returned = 3000 }, "The Army of Pyke was disbanded: 3,000 of 3,700 men returned to the levies.", "quiet" },
			{ "ArmyStarving", { originId = "pyke", provinceId = "lannisport" }, "The Army of Pyke has run out of supplies in Lannisport. Men are dying.", "bad" },
			{ "ArmyDesertion", { originId = "pyke", provinceId = "lannisport", troops = 40 }, "The Army of Pyke melted away in Lannisport: its last 40 men deserted.", "bad" },
		}
		for _, case in cases do
			local text, tone = EventText.format({ kind = case[1], data = case[2] }, "stark")
			expect.equal(text, case[3], case[1])
			expect.equal(tone, case[4], `{case[1]} tone`)
		end
		expect.equal(EventText.troops(0), "0")
		expect.equal(EventText.troops(999), "999")
		expect.equal(EventText.troops(1000), "1,000")
		expect.equal(EventText.troops(1234567), "1,234,567")
	end)

	-- Simulation: determinism and replication -----------------------------------------------------

	t.test("the same seed and orders give the same campaign, armies included", function()
		local function play()
			local sim = fx.newSim({ seed = 2024, human = { stark = true, greyjoy = true } })
			submitOk(sim, STARK, Commands.RaiseAllLevies, { provinceId = "winterfell" })
			submitOk(sim, GREYJOY, Commands.RaiseArmy, { provinceId = "pyke" })
			submitOk(sim, GREYJOY, Commands.MoveArmy, { armyId = "army_6", provinceId = "oldtown" })
			for _ = 1, 4 do
				sim:advanceToNextMonth()
			end
			expectValid(sim)
			return sim.state
		end
		local a, b = play(), play()
		expect.truthy(next(a.armies) ~= nil, "armies are in the field")
		expect.deepEqual(a, b, "identical campaigns")
	end)

	t.test("armies replicate to the client replica, including their removal", function()
		local host, controls = fx.newHost({ config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 0 }) })
		local replica = ReplicaStore.new()
		local lastChanges = nil
		replica.changed:Connect(function(changes)
			lastChanges = changes
		end)
		local lastDelta = nil
		local function pump()
			for _, message in host:collectReplication(true) do
				if message.userId == 1 then
					lastDelta = message.payload
					local applied = replica:applyDelta(message.payload)
					if applied == "resync" then
						replica:applyFull(host:syncPayload(1))
					end
					expect.truthy(applied ~= "gap", "no sequence gaps")
				end
			end
		end
		local function request(command: string, payload)
			controls.advance(1)
			local result = host:handleRequest(1, command, payload)
			expect.result(result, Codes.Ok, `{command}: {result.message}`)
			pump()
			return result
		end

		host:playerJoined(1, "Alys")
		replica:applyFull(host:syncPayload(1))
		expect.deepEqual(replica.campaign.armies, {}, "no armies at the start")
		request(Commands.SelectHouse, { houseId = "stark" })
		request(Commands.RaiseArmy, { provinceId = "winterfell" })

		local context = host.sim:context()
		local view = replica:army("army_1")
		expect.deepEqual(view, Snapshot.armyView(context, host.sim.state.armies.army_1), "the replica holds the army view")
		expect.equal(view.troops, 10800)
		expect.deepEqual(view.units, WINTERFELL_ARMY)
		expect.equal(view.commanderId, "eddard_stark")
		expect.equal(view.strength, MilitaryRules.strength(WINTERFELL_ARMY, 13))
		expect.equal(view.upkeep, 18.06)
		expect.equal(view.speed, 1)
		local province = replica:province("winterfell")
		expect.equal(province.levies, 0)
		expect.equal(province.leviesMax, 10800)
		expect.equal(province.garrisonTroops, 900)
		expect.equal(province.garrisonMax, 900)
		expect.equal(province.ships, 0)
		local house = replica:house("stark")
		expect.equal(house.budget.armyUpkeep, 18.06)
		expect.equal(house.military.raised, 10800)
		expect.equal(house.military.armies, 1)
		expect.equal(house.military.ships, 25)
		expect.equal(house.military.total, house.military.raised + house.military.levies + house.military.garrisons)
		expect.equal(house.military.leviesMax - house.military.levies, 10800, "only Winterfell's pool is empty")

		-- A march replicates its route and leg days; the days in between send no army data.
		request(Commands.MoveArmy, { armyId = "army_1", provinceId = "moat_cailin" })
		expect.deepEqual(replica:army("army_1").route, { "white_harbor", "moat_cailin" })
		expect.equal(replica:army("army_1").legEndDay, host.sim.state.armies.army_1.legEndDay)
		host.sim:advanceDay()
		pump()
		expect.equal(lastDelta.campaign.armies, nil, "no army update mid-leg")
		expect.equal(replica.campaign.clock.dayNumber, CampaignState.todayNumber(host.sim.state), "the clock carries the day number")

		-- Split and merge: the merged army disappears from the replica.
		request(Commands.RaiseArmy, { provinceId = "white_harbor" })
		request(Commands.SplitArmy, { armyId = "army_2" })
		local inHarbour = {}
		for _, army in replica:armiesIn("white_harbor") do
			table.insert(inHarbour, army.id)
		end
		expect.deepEqual(inHarbour, { "army_2", "army_3" })
		local ofStark = {}
		for _, army in replica:armiesOf("stark") do
			table.insert(ofStark, army.id)
		end
		expect.deepEqual(ofStark, { "army_1", "army_2", "army_3" })
		expect.deepEqual(replica:armiesOf("lannister"), {})

		request(Commands.MergeArmies, { armyId = "army_3", intoArmyId = "army_2" })
		expect.deepEqual(lastDelta.campaign.removedArmies, { "army_3" }, "the delta lists the removal")
		expect.equal(replica:army("army_3"), nil, "removed from the replica")
		expect.truthy(lastChanges.armies.army_3 and lastChanges.armies.army_2, "both reported as changed")
		expect.equal(replica:army("army_2").troops, MilitaryRules.troops(host.sim.state.armies.army_2.units))

		request(Commands.DisbandArmy, { armyId = "army_2" })
		expect.equal(replica:army("army_2"), nil, "disbanded armies disappear too")
		expect.equal(replica:province("white_harbor").levies, host.sim.state.provinces.white_harbor.levies)

		-- A full snapshot carries the same armies.
		local fresh = ReplicaStore.new()
		fresh:applyFull(host:syncPayload(1))
		expect.deepEqual(fresh.campaign.armies, replica.campaign.armies)
		local bare = ReplicaStore.new()
		bare:applyFull({ seq = 1, campaign = { clock = {} }, session = {} })
		expect.deepEqual(bare.campaign.armies, {}, "a snapshot without armies still has the collection")
		expect.deepEqual(bare:armiesOf("stark"), {})

		for _, line in controls.lines do
			expect.falsy(string.find(line, "error:", 1, true), `unexpected error diagnostic: {line}`)
		end
	end)
end
