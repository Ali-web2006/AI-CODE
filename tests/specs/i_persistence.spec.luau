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
