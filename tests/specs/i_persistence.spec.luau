-- Scenario I — Persistence: the versioned save format round-trips through JSON, malformed saves
-- are rejected without touching live state, transient failures retry with backoff, concurrent
-- writers cannot overwrite newer data, and unavailable storage does not affect gameplay.

return function(t)
	local fx, expect = t.fx, t.expect
	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands
	local Serializer = fx.CampaignSerializer

	local function jsonRoundTrip(value)
		return fx.codec.decode(fx.codec.encode(value))
	end

	t.test("a fresh campaign round-trips through serialize -> JSON -> deserialize", function()
		local state = fx.newState()
		local record = jsonRoundTrip(Serializer.serialize(state, 1700000000, "stark"))
		local result = Serializer.deserialize(record, fx.GameConfig)
		expect.truthy(result.ok, `deserialize failed: {table.concat(result.errors, "; ")}`)
		expect.deepEqual(result.warnings, {})
		expect.deepEqual(result.state, state)
	end)

	t.test("a campaign after years of AI play round-trips exactly", function()
		local sim = fx.newSim({ seed = 31 })
		for _ = 1, 30 do
			sim:advanceToNextMonth()
		end
		sim.state.clock.paused = true -- loaded campaigns always start paused
		local record = jsonRoundTrip(Serializer.serialize(sim.state, 1700000000, nil))
		local result = Serializer.deserialize(record, fx.GameConfig)
		expect.truthy(result.ok, `deserialize failed: {table.concat(result.errors, "; ")}`)
		expect.deepEqual(result.state, sim.state)
	end)

	t.test("malformed saves are rejected with a reason", function()
		local good = Serializer.serialize(fx.newState(), 1, nil)
		local function broken(mutate)
			local record = jsonRoundTrip(good)
			mutate(record)
			return Serializer.deserialize(record, fx.GameConfig)
		end
		local cases = {
			{ "wrong format", function(r) r.format = "Other" end, "not an Iron Throne campaign save" },
			{ "newer schema", function(r) r.schemaVersion = 99 end, "newer than this server" },
			{ "unknown province", function(r) r.campaign.provinces.atlantis = { ownerHouseId = "stark", development = 1 } end, "no longer exists" },
			{ "bad treasury", function(r) r.campaign.houses.stark.treasury = "lots" end, "house 'stark' is malformed" },
			{ "bad owner", function(r) r.campaign.provinces.winterfell.ownerHouseId = "targaryen" end, "owner 'targaryen' does not exist" },
			{ "bad development", function(r) r.campaign.provinces.winterfell.development = 99 end, "out of range" },
			{ "inconsistent clock", function(r) r.campaign.clock.lastProcessedMonthIndex = 0 end, "lastProcessedMonthIndex" },
			{ "bad rng", function(r) r.campaign.rngState = 0 end, "rng state is invalid" },
			{ "unknown trait", function(r) r.campaign.characters.eddard_stark.traits = { "telepathic" } end, "unknown trait" },
		}
		for _, case in cases do
			local result = broken(case[2])
			expect.falsy(result.ok, `{case[1]} should be rejected`)
			expect.anyContains(result.errors, case[3], case[1])
		end
	end)

	-- A campaign with armies in every state: marching by land and by sea, waiting for ships,
	-- gathering, leaderless, idle; plus emptied and refilling levy pools.
	local function campaignWithArmies()
		local sim = fx.newSim({
			seed = 77,
			config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 0, ["Military.ShipCapacity"] = 30 }),
			human = { stark = true, greyjoy = true },
		})
		local stark = { kind = "player", userId = 1, houseId = "stark" }
		local greyjoy = { kind = "player", userId = 2, houseId = "greyjoy" }
		local function order(actor, command, payload)
			expect.result(sim:submit(actor, command, payload), Codes.Ok, command)
		end
		order(stark, Commands.RaiseAllLevies, { provinceId = "white_harbor" })
		order(stark, Commands.SplitArmy, { armyId = "army_1" })
		order(greyjoy, Commands.RaiseArmy, { provinceId = "pyke" })
		order(greyjoy, Commands.RaiseArmy, { provinceId = "harlaw" })
		order(greyjoy, Commands.MoveArmy, { armyId = "army_7", provinceId = "lannisport" })
		order(greyjoy, Commands.MoveArmy, { armyId = "army_8", provinceId = "lannisport" })
		for _ = 1, 4 do
			sim:advanceDay()
		end
		sim.state.clock.paused = true -- loaded campaigns always start paused
		return sim
	end

	t.test("a campaign with armies on the march round-trips exactly", function()
		local sim = campaignWithArmies()
		local armies = sim.state.armies
		expect.truthy(armies.army_7.legStartDay ~= nil and armies.army_8.legStartDay == nil, "one fleet at sea, one army waiting")
		expect.truthy(armies.army_2.gather and armies.army_2.legStartDay ~= nil, "levies marching to the rally")
		expect.equal(armies.army_6.commanderId, nil, "a leaderless army")
		local record = jsonRoundTrip(Serializer.serialize(sim.state, 1700000000, "stark"))
		expect.equal(record.schemaVersion, 2)
		local result = Serializer.deserialize(record, sim.config)
		expect.truthy(result.ok, `deserialize failed: {table.concat(result.errors, "; ")}`)
		expect.deepEqual(result.warnings, {})
		expect.deepEqual(result.state, sim.state)
	end)

	t.test("a schema 1 save loads with full levy pools and no armies", function()
		local state = fx.newState()
		local record = jsonRoundTrip(Serializer.serialize(state, 1, nil))
		record.schemaVersion = 1
		record.campaign.armies = nil
		record.campaign.nextArmySerial = nil
		for _, province in record.campaign.provinces do
			province.levies = nil
			province.garrisonTroops = nil
		end
		local result = Serializer.deserialize(record, fx.GameConfig)
		expect.truthy(result.ok, `deserialize failed: {table.concat(result.errors, "; ")}`)
		expect.deepEqual(result.warnings, {}, "no warnings for the new fields")
		expect.deepEqual(result.state, state, "identical to a fresh campaign")
		expect.equal(result.state.schemaVersion, 2)

		-- Pools are sized to the saved development, not the bookmark's.
		record = jsonRoundTrip(Serializer.serialize(state, 1, nil))
		record.schemaVersion = 1
		record.campaign.armies = nil
		record.campaign.nextArmySerial = nil
		for _, province in record.campaign.provinces do
			province.levies = nil
			province.garrisonTroops = nil
		end
		record.campaign.provinces.winterfell.development = 6
		result = Serializer.deserialize(record, fx.GameConfig)
		expect.truthy(result.ok, `deserialize failed: {table.concat(result.errors, "; ")}`)
		local winterfell = result.state.provinces.winterfell
		expect.equal(winterfell.levies, 15400, "(1,200 + 1,700 * 6) * 1.35, full")
		expect.equal(winterfell.garrisonTroops, 1100)
		expect.deepEqual(result.state.armies, {})
		expect.equal(result.state.nextArmySerial, 1)
	end)

	t.test("malformed armies and pools are rejected with a reason", function()
		local sim = campaignWithArmies()
		local good = Serializer.serialize(sim.state, 1, nil)
		local function broken(mutate)
			local record = jsonRoundTrip(good)
			mutate(record)
			return Serializer.deserialize(record, sim.config)
		end
		local cases = {
			{ "armies missing", function(r) r.campaign.armies = nil end, "armies are missing" },
			{ "bad army counter", function(r) r.campaign.nextArmySerial = "nine" end, "army id counter is invalid" },
			{ "army counter behind", function(r) r.campaign.nextArmySerial = 3 end, "serial is not below" },
			{ "bad army id", function(r) r.campaign.armies["army x"] = r.campaign.armies.army_1 end, "not of the form army_<serial>" },
			{ "unknown army house", function(r) r.campaign.armies.army_1.houseId = "targaryen" end, "unknown house 'targaryen'" },
			{ "unknown army province", function(r) r.campaign.armies.army_1.locationId = "atlantis" end, "unknown province 'atlantis'" },
			{ "unknown unit", function(r) r.campaign.armies.army_1.units.dragons = 3 end, "unknown unit 'dragons'" },
			{ "fractional men", function(r) r.campaign.armies.army_1.units.archers = 1.5 end, "invalid head count" },
			{ "no men", function(r) r.campaign.armies.army_1.units = {} end, "has no units" },
			{ "zero men", function(r) r.campaign.armies.army_1.units.archers = 0 end, "has 0 men" },
			{ "unknown commander", function(r) r.campaign.armies.army_1.commanderId = "aegon_targaryen" end, "unknown commander" },
			{ "foreign commander", function(r) r.campaign.armies.army_1.commanderId = "balon_greyjoy" end, "is not of house 'stark'" },
			{ "commander twice", function(r) r.campaign.armies.army_2.commanderId = r.campaign.armies.army_1.commanderId end, "already commands" },
			{ "morale out of range", function(r) r.campaign.armies.army_1.morale = 101 end, "morale 101 is out of range" },
			{ "supply not a number", function(r) r.campaign.armies.army_1.supply = "full" end, "morale or supply invalid" },
			{ "route off the map", function(r) r.campaign.armies.army_2.route = { "atlantis" } end, "is not a province" },
			{ "route not adjacent", function(r) r.campaign.armies.army_2.route = { "pyke" } end, "is not adjacent" },
			{ "half a leg", function(r) r.campaign.armies.army_2.legEndDay = nil end, "only one leg day is set" },
			{ "backwards leg", function(r) r.campaign.armies.army_2.legEndDay = r.campaign.armies.army_2.legStartDay end, "are invalid" },
			{
				"leg without route",
				function(r)
					r.campaign.armies.army_1.legStartDay = 1
					r.campaign.armies.army_1.legEndDay = 2
				end,
				"has a leg but no route",
			},
			{ "bad flag", function(r) r.campaign.armies.army_1.gather = "yes" end, "flags invalid" },
			{ "levies missing", function(r) r.campaign.provinces.winterfell.levies = nil end, "province 'winterfell' is malformed" },
			{ "levies above the maximum", function(r) r.campaign.provinces.wolfswood.levies = 99999 end, "levies 99999 are outside" },
			{ "negative garrison", function(r) r.campaign.provinces.winterfell.garrisonTroops = -1 end, "garrison -1 is outside" },
		}
		for _, case in cases do
			local result = broken(case[2])
			expect.falsy(result.ok, `{case[1]} should be rejected`)
			expect.anyContains(result.errors, case[3], case[1])
		end
	end)

	t.test("content added after a save is initialised from the bookmark with a warning", function()
		local record = jsonRoundTrip(Serializer.serialize(fx.newState(), 1, nil))
		record.campaign.provinces.the_arbor = nil
		local result = Serializer.deserialize(record, fx.GameConfig)
		expect.truthy(result.ok)
		expect.anyContains(result.warnings, "province 'the_arbor' was not in the save")
		expect.equal(result.state.provinces.the_arbor.ownerHouseId, "tyrell")
	end)

	t.test("transient storage failures are retried with backoff", function()
		local inner = fx.InMemoryBackend.new(fx.codec)
		local failuresLeft = 2
		local flaky = {
			name = "Flaky",
			persistent = true,
			get = function(_, key)
				return inner:get(key)
			end,
			update = function(_, key, transform)
				if failuresLeft > 0 then
					failuresLeft -= 1
					error("503: throttled")
				end
				return inner:update(key, transform)
			end,
		}
		local sleeps = {}
		local repository = fx.CampaignRepository.new({
			backend = flaky,
			codec = fx.codec,
			config = fx.GameConfig.Persistence,
			sleep = function(seconds)
				table.insert(sleeps, seconds)
			end,
			sessionId = "s1",
		})
		local write = repository:write(1, Serializer.serialize(fx.newState(), 1, nil))
		expect.truthy(write.ok, `write failed: {write.message}`)
		expect.equal(write.revision, 1)
		expect.deepEqual(sleeps, { 1, 2 }, "backoff between attempts")

		failuresLeft = 10
		local failed = repository:write(1, Serializer.serialize(fx.newState(), 2, nil))
		expect.result(failed, "StorageUnavailable", "gives up after MaxAttempts")
		expect.equal(inner:get("host_1").revision, 1, "stored data untouched by the failed write")
	end)

	t.test("an older session cannot overwrite a newer save", function()
		local backend = fx.InMemoryBackend.new(fx.codec)
		local function repo(sessionId)
			return fx.CampaignRepository.new({
				backend = backend,
				codec = fx.codec,
				config = fx.GameConfig.Persistence,
				sleep = function() end,
				sessionId = sessionId,
			})
		end
		local serverA, serverB = repo("A"), repo("B")
		serverA:read(1)
		serverB:read(1)
		expect.truthy(serverA:write(1, Serializer.serialize(fx.newState(nil, 1), 1, nil)).ok)
		local conflict = serverB:write(1, Serializer.serialize(fx.newState(nil, 2), 2, nil))
		expect.result(conflict, "SaveConflict")
		local stored = backend:get("host_1")
		expect.equal(stored.writerSessionId, "A", "server A's newer data survived")
		expect.equal(stored.campaign.seed, 1)
		-- After re-reading, B knows the current revision and may save again.
		serverB:read(1)
		expect.truthy(serverB:write(1, Serializer.serialize(fx.newState(nil, 2), 3, nil)).ok)
		expect.equal(backend:get("host_1").revision, 2)
	end)

	t.test("oversized saves are refused before writing", function()
		local backend = fx.InMemoryBackend.new(fx.codec)
		local repository = fx.CampaignRepository.new({
			backend = backend,
			codec = fx.codec,
			config = fx.config({ ["Persistence.MaxSerializedBytes"] = 100 }).Persistence,
			sleep = function() end,
			sessionId = "s",
		})
		expect.result(repository:write(1, Serializer.serialize(fx.newState(), 1, nil)), "InvalidSave")
		expect.equal(backend:get("host_1"), nil)
	end)

	t.test("save then load through the host restores the campaign", function()
		local host, controls = fx.newHost()
		host:playerJoined(1, "Alys")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		host:handleRequest(1, Commands.DevelopProvince, { provinceId = "winterfell" })
		host.sim:advanceToNextMonth()
		local saved = fx.TableUtil.deepCopy(host.sim.state)
		expect.result(host:handleRequest(1, Commands.SaveCampaign, nil), Codes.Ok)

		for _ = 1, 4 do
			host.sim:advanceToNextMonth()
		end
		expect.notEqual(host.sim.state.clock.date.month, saved.clock.date.month)
		controls.advance(fx.GameConfig.Network.PersistenceCooldownSeconds + 1)
		host:collectReplication(true)

		local info = host:handleRequest(1, Commands.GetSaveInfo, nil)
		expect.result(info, Codes.Ok)
		expect.deepEqual(info.data.summary.date, saved.clock.date)
		expect.equal(info.data.summary.hostHouseId, "stark")

		local load = host:handleRequest(1, Commands.LoadCampaign, nil)
		expect.result(load, Codes.Ok)
		saved.clock.paused = true
		expect.deepEqual(host.sim.state, saved, "the loaded state equals the saved state")
		expect.equal(host.sessions:houseOf(1), "stark", "the host leads the saved house")

		local messages = host:collectReplication(true)
		expect.equal(#messages, 1)
		expect.equal(messages[1].payload.resync, true, "clients are told to resynchronise")
	end)

	t.test("loading a corrupt slot leaves the live campaign untouched", function()
		local host, controls = fx.newHost()
		host:playerJoined(1, "Alys")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		controls.backend.store[controls.repository:slotKey(1)] = fx.codec.encode({ format = "IronThroneCampaign", schemaVersion = 1, campaign = { bookmarkId = "long_summer_297" } })
		local before = fx.TableUtil.deepCopy(host.sim.state)
		expect.result(host:handleRequest(1, Commands.LoadCampaign, nil), Codes.InvalidSave)
		expect.deepEqual(host.sim.state, before)
	end)

	t.test("unavailable storage is reported and gameplay continues", function()
		local host = fx.newHost({ backend = "none" })
		host:playerJoined(1, "Alys")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		expect.result(host:handleRequest(1, Commands.SaveCampaign, nil), Codes.StorageUnavailable)
		expect.result(host:handleRequest(1, Commands.LoadCampaign, nil), Codes.StorageUnavailable)
		expect.result(host:handleRequest(1, Commands.DevelopProvince, { provinceId = "winterfell" }), Codes.Ok)
		local session = host:syncPayload(1).session
		expect.equal(session.persistence.available, false)
	end)

	t.test("development and production use different storage names", function()
		local persistence = fx.GameConfig.Persistence
		expect.notEqual(persistence.DevelopmentDataStoreName, persistence.ProductionDataStoreName)
	end)
end
