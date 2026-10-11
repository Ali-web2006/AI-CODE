-- Scenario J — Integration: a complete session through the same request/replication pipeline
-- the RemoteService uses, with a client replica applying the sequenced deltas.

return function(t)
	local fx, expect, vr = t.fx, t.expect, t.vr
	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands
	local ReplicaStore = vr.require("StarterPlayer.StarterPlayerScripts.Controllers.ReplicaStore")

	t.test("house selection -> time -> development -> diplomacy -> pause -> save/load", function()
		local host, controls = fx.newHost()
		local replica = ReplicaStore.new()
		local function pump()
			for _, message in host:collectReplication(true) do
				if message.userId == 1 then
					local applied = replica:applyDelta(message.payload)
					if applied == "resync" then
						replica:applyFull(host:syncPayload(1))
					end
					expect.truthy(applied ~= "gap", "no sequence gaps")
				end
			end
		end

		-- 1-3. Join, see the lobby, choose a house.
		host:playerJoined(1, "Alys")
		replica:applyFull(host:syncPayload(1))
		expect.equal(replica.session.isHost, true)
		expect.result(host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" }), Codes.Ok)
		pump()
		expect.equal(replica.session.houseId, "stark", "session update replicated")

		-- 4-5. Inspect the map and a province.
		local winterfell = replica.campaign.provinces.winterfell
		expect.equal(winterfell.ownerHouseId, "stark")
		expect.equal(winterfell.development, 4)

		-- 6-7. Advance time at speed 3 for two months; income arrives through deltas.
		controls.advance(1)
		expect.result(host:handleRequest(1, Commands.SetPaused, { paused = false }), Codes.Ok)
		expect.result(host:handleRequest(1, Commands.SetSpeed, { speed = 3 }), Codes.Ok)
		while host.sim.state.clock.lastProcessedMonthIndex < 297 * 12 + 1 do
			host:update(1 / 60)
			controls.advance(1 / 60)
			pump()
		end
		local stark = replica.campaign.houses.stark
		expect.equal(#stark.ledger, 2, "two monthly ledger entries replicated")
		expect.equal(stark.treasury, host.sim.state.houses.stark.treasury, "replica treasury matches the server")
		expect.deepEqual(replica.campaign.clock.date, host.sim.state.clock.date, "replica date matches the server")

		-- 8. Invest in development.
		local treasuryBefore = stark.treasury
		local develop = host:handleRequest(1, Commands.DevelopProvince, { provinceId = "winterfell" })
		expect.result(develop, Codes.Ok)
		pump()
		expect.equal(replica.campaign.provinces.winterfell.development, 5)
		expect.near(replica.campaign.houses.stark.treasury, treasuryBefore - develop.data.cost, 1e-9)

		-- 9-10. Improve relations with House Lannister.
		controls.advance(1)
		local improve = host:handleRequest(1, Commands.ImproveRelations, { targetHouseId = "lannister" })
		expect.result(improve, Codes.Ok)
		pump()
		local relation = replica:relation("stark", "lannister")
		expect.equal(relation.score, improve.data.score)
		expect.truthy(#replica.eventLog > 0, "events reached the client chronicle")

		-- 11. Pause and resume.
		controls.advance(1)
		expect.result(host:handleRequest(1, Commands.SetPaused, { paused = true }), Codes.Ok)
		local pausedDate = fx.TableUtil.deepCopy(host.sim.state.clock.date)
		for _ = 1, 600 do
			host:update(1 / 60)
		end
		expect.deepEqual(host.sim.state.clock.date, pausedDate, "paused")
		expect.result(host:handleRequest(1, Commands.SetPaused, { paused = false }), Codes.Ok)
		for _ = 1, 60 do
			host:update(1 / 60)
		end
		expect.truthy(fx.CalendarDate.compare(host.sim.state.clock.date, pausedDate) > 0, "resumed")
		host:handleRequest(1, Commands.SetPaused, { paused = true })
		pump()

		-- 12. Save, keep playing, load.
		local savedState = fx.TableUtil.deepCopy(host.sim.state)
		expect.result(host:handleRequest(1, Commands.SaveCampaign, nil), Codes.Ok)
		host.sim:advanceToNextMonth()
		pump()
		controls.advance(fx.GameConfig.Network.PersistenceCooldownSeconds + 1)
		expect.result(host:handleRequest(1, Commands.LoadCampaign, nil), Codes.Ok)
		pump()
		expect.deepEqual(host.sim.state, savedState, "server state restored")
		expect.deepEqual(replica.campaign.clock.date, savedState.clock.date, "client replica resynchronised")
		expect.equal(replica.campaign.houses.stark.treasury, savedState.houses.stark.treasury)

		expect.deepEqual(fx.StateInvariants.check(host.sim.state, fx.GameConfig), {})
		for _, line in controls.lines do
			expect.falsy(string.find(line, "error:", 1, true), `unexpected error diagnostic: {line}`)
		end
	end)

	t.test("the replica detects sequence gaps and requests a resync", function()
		local replica = ReplicaStore.new()
		replica:applyFull({ seq = 3, campaign = { clock = {}, houses = {}, provinces = {}, relations = {}, characters = {} }, session = {} })
		expect.equal(replica:applyDelta({ seq = 3 }), "stale")
		expect.equal(replica:applyDelta({ seq = 4, campaign = { clock = { speed = 2 } } }), "applied")
		expect.equal(replica.campaign.clock.speed, 2)
		expect.equal(replica:applyDelta({ seq = 6 }), "gap")
		expect.equal(replica:applyDelta({ seq = 5, resync = true }), "resync")
	end)
end
