-- Scenario H — Security: forged ids, malformed payloads, missing entities and request spam are
-- handled safely; no request can create gold or touch unauthorized state.

return function(t)
	local fx, expect = t.fx, t.expect
	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands

	local function hostWithStark(options)
		local host, controls = fx.newHost(options)
		host:playerJoined(1, "Alys")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		controls.advance(10) -- refill the rate limiter
		return host, controls
	end

	t.test("malformed command names are rejected", function()
		local host = hostWithStark()
		for _, name in { 42, "", string.rep("x", 1000), {}, true } do
			expect.result(host:handleRequest(1, name, nil), Codes.InvalidPayload)
		end
		expect.result(host:handleRequest(1, "GiveMeGold", {}), Codes.UnknownCommand)
	end)

	t.test("malformed payloads are rejected for every command", function()
		local host, controls = hostWithStark()
		local cases = {
			{ Commands.DevelopProvince, "winterfell" },
			{ Commands.DevelopProvince, 17 },
			{ Commands.DevelopProvince, {} },
			{ Commands.DevelopProvince, { provinceId = string.rep("a", 500) } },
			{ Commands.DevelopProvince, { provinceId = "winter fell" } },
			{ Commands.DevelopProvince, { provinceId = "../winterfell" } },
			{ Commands.DevelopProvince, { "winterfell" } },
			{ Commands.DevelopProvince, { provinceId = "winterfell", cost = 0 } },
			{ Commands.DevelopProvince, setmetatable({ provinceId = "winterfell" }, {}) },
			{ Commands.ImproveRelations, { targetHouseId = { "lannister" } } },
			{ Commands.SetSpeed, { speed = 0 } },
			{ Commands.SetSpeed, { speed = 99 } },
			{ Commands.SetSpeed, { speed = 1.5 } },
			{ Commands.SetSpeed, { speed = 0 / 0 } },
			{ Commands.SetSpeed, { speed = "3" } },
			{ Commands.SetPaused, { paused = "no" } },
			{ Commands.SelectHouse, { houseId = "stark", extra = true } },
			{ Commands.SaveCampaign, { force = true } },
		}
		local big = {}
		for i = 1, 100 do
			big[`k{i}`] = i
		end
		table.insert(cases, { Commands.DevelopProvince, big })

		local before = fx.TableUtil.deepCopy(host.sim.state)
		for index, case in cases do
			controls.advance(1)
			expect.result(host:handleRequest(1, case[1], case[2]), Codes.InvalidPayload, `case {index} ({case[1]})`)
		end
		expect.deepEqual(host.sim.state, before, "no malformed request changed state")
	end)

	t.test("game commands without a house and for missing entities are rejected", function()
		local host, controls = fx.newHost()
		host:playerJoined(1, "Alys")
		expect.result(host:handleRequest(1, Commands.DevelopProvince, { provinceId = "winterfell" }), Codes.NoHouse)
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		controls.advance(5)
		expect.result(host:handleRequest(1, Commands.DevelopProvince, { provinceId = "nowhere" }), Codes.NotFound)
		expect.result(host:handleRequest(1, Commands.ImproveRelations, { targetHouseId = "nobody" }), Codes.NotFound)
	end)

	t.test("spammed requests are rate limited and cannot bypass costs", function()
		local host, controls = hostWithStark()
		local capacity = fx.GameConfig.Network.RateLimit.Capacity
		local okCount, limited = 0, 0
		for _ = 1, 50 do
			local result = host:handleRequest(1, Commands.ImproveRelations, { targetHouseId = "lannister" })
			if result.code == Codes.RateLimited then
				limited += 1
			elseif result.ok then
				okCount += 1
			end
		end
		expect.equal(okCount, 1, "only one envoy succeeded")
		expect.equal(limited, 50 - capacity, "requests beyond the burst capacity are rate limited")
		expect.equal(host.sim.state.houses.stark.treasury, 140 - 25, "the cost was charged exactly once")
		controls.advance(1)
		local refilled = host:handleRequest(1, Commands.ImproveRelations, { targetHouseId = "lannister" })
		expect.result(refilled, Codes.OnCooldown, "tokens refill over time, but the game cooldown still applies")
	end)

	t.test("persistence requests have their own cooldown", function()
		local host, controls = hostWithStark()
		expect.result(host:handleRequest(1, Commands.SaveCampaign, nil), Codes.Ok)
		controls.advance(1)
		expect.result(host:handleRequest(1, Commands.SaveCampaign, nil), Codes.RateLimited)
		controls.advance(fx.GameConfig.Network.PersistenceCooldownSeconds)
		expect.result(host:handleRequest(1, Commands.SaveCampaign, nil), Codes.Ok)
	end)

	t.test("reading the save slot is throttled to protect the DataStore budget", function()
		local host, controls = hostWithStark()
		expect.result(host:handleRequest(1, Commands.GetSaveInfo, nil), Codes.Ok)
		expect.result(host:handleRequest(1, Commands.GetSaveInfo, nil), Codes.RateLimited)
		controls.advance(fx.GameConfig.Network.SaveInfoCooldownSeconds)
		expect.result(host:handleRequest(1, Commands.GetSaveInfo, nil), Codes.Ok)
	end)

	t.test("non-hosts cannot save, load or change speed; debug commands are off in production", function()
		local host, controls = hostWithStark({ environment = "production" })
		host:playerJoined(2, "Bran")
		host:handleRequest(2, Commands.SelectHouse, { houseId = "lannister" })
		controls.advance(5)
		expect.result(host:handleRequest(2, Commands.SaveCampaign, nil), Codes.NotAuthorized)
		controls.advance(20)
		expect.result(host:handleRequest(2, Commands.LoadCampaign, nil), Codes.NotAuthorized)
		expect.result(host:handleRequest(2, Commands.SetSpeed, { speed = 2 }), Codes.NotAuthorized)
		expect.result(host:handleRequest(1, Commands.DebugAdvanceMonth, nil), Codes.NotAuthorized)
	end)

	t.test("fuzzed requests never throw and never create gold", function()
		local host, controls = hostWithStark({ config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 0 }) })
		local values = { nil, true, false, 0, -1, 1e308, -1e308, 0 / 0, "", "stark", "winterfell", string.rep("z", 80), {}, { 1, 2 } }
		local names = {}
		for _, name in Commands do
			table.insert(names, name)
		end
		table.insert(names, "Unknown")
		local fields = { "provinceId", "targetHouseId", "houseId", "speed", "paused", "treasury" }
		local seed = 12345
		local function nextInt(n)
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n + 1
		end
		local goldBefore = fx.totalTreasury(host.sim.state)
		for _ = 1, 2000 do
			controls.advance(0.5)
			local payload
			if nextInt(4) > 1 then
				payload = {}
				for _ = 1, nextInt(3) do
					payload[fields[nextInt(#fields)]] = values[nextInt(#values)]
				end
			else
				payload = values[nextInt(#values)]
			end
			local name = names[nextInt(#names)]
			-- Excluded: storage commands (covered in Scenario I) and the dev-only month advance,
			-- which legitimately produces a month of income.
			if name ~= Commands.SaveCampaign and name ~= Commands.LoadCampaign and name ~= Commands.DebugAdvanceMonth then
				local ok, result = pcall(host.handleRequest, host, 1, name, payload)
				expect.truthy(ok, `handleRequest threw for {name}: {tostring(result)}`)
				expect.truthy(type(result) == "table" and type(result.code) == "string", "always returns a result")
			end
		end
		-- No time passed (update is never called), so gold may only have been spent, never created.
		expect.equal(host.sim.monthsProcessed, 0, "no month was processed")
		expect.truthy(fx.totalTreasury(host.sim.state) <= goldBefore + 1e-9, "no gold was created")
		expect.deepEqual(fx.StateInvariants.check(host.sim.state, fx.GameConfig), {}, "state still valid")
	end)
end
