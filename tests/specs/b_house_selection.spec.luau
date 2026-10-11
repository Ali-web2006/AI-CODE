-- Scenario B — House selection: correct starting state, one house per player, no claiming a
-- house another player holds, reservations on disconnect, host election.

return function(t)
	local fx, expect = t.fx, t.expect
	local Codes = fx.Protocol.ResultCodes
	local Commands = fx.Protocol.Commands

	t.test("selecting a house gives the player that house's starting state", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		local lobby = host:syncPayload(1)
		expect.equal(lobby.session.houseId, nil, "no house before selection")
		expect.equal(lobby.session.isHost, true, "first player is host")

		local result = host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		expect.result(result, Codes.Ok)
		local sync = host:syncPayload(1)
		expect.equal(sync.session.houseId, "stark")
		local house = sync.campaign.houses.stark
		expect.equal(house.treasury, 140, "starting treasury")
		expect.deepEqual(house.provinceIds, { "barrowlands", "moat_cailin", "white_harbor", "winterfell", "wolfswood" })
		expect.equal(house.rulerId, "eddard_stark")
		expect.truthy(house.budget.net > 0, "Stark starts with positive net income")
	end)

	t.test("a player cannot claim a second house", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		expect.result(host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" }), Codes.Ok)
		local second = host:handleRequest(1, Commands.SelectHouse, { houseId = "lannister" })
		expect.result(second, Codes.AlreadyHasHouse)
		expect.equal(host.sessions:houseOf(1), "stark")
		expect.equal(host.sessions:controllerOf("lannister"), nil, "lannister remains unclaimed")
	end)

	t.test("a player cannot claim a house another player leads", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		host:playerJoined(2, "Bran")
		expect.result(host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" }), Codes.Ok)
		expect.result(host:handleRequest(2, Commands.SelectHouse, { houseId = "stark" }), Codes.HouseUnavailable)
		expect.result(host:handleRequest(2, Commands.SelectHouse, { houseId = "lannister" }), Codes.Ok)
		expect.equal(host.sessions:controllerOf("stark"), 1)
		expect.equal(host.sessions:controllerOf("lannister"), 2)
	end)

	t.test("unknown houses and unconnected users are rejected", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		expect.result(host:handleRequest(1, Commands.SelectHouse, { houseId = "targaryen" }), Codes.HouseUnavailable)
		expect.result(host:handleRequest(99, Commands.SelectHouse, { houseId = "stark" }), Codes.NotAuthorized)
	end)

	t.test("the acting house always comes from the session, not the payload", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		host:playerJoined(2, "Bran")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		host:handleRequest(2, Commands.SelectHouse, { houseId = "lannister" })
		local before = fx.TableUtil.deepCopy(host.sim.state)
		-- Bran (Lannister) tries to develop Winterfell, and tries to smuggle a house id.
		expect.result(host:handleRequest(2, Commands.DevelopProvince, { provinceId = "winterfell" }), Codes.NotOwner)
		expect.result(host:handleRequest(2, Commands.DevelopProvince, { provinceId = "winterfell", houseId = "stark" }), Codes.InvalidPayload)
		expect.deepEqual(host.sim.state, before, "state unchanged by forged requests")
	end)

	t.test("disconnected houses are reserved, governed by AI, and restored on rejoin", function()
		local host, controls = fx.newHost()
		host:playerJoined(1, "Alys")
		host:playerJoined(2, "Bran")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		host:playerLeft(1)
		expect.equal(host.sessions:isHumanControlled("stark"), false, "AI governs the disconnected house")
		expect.result(host:handleRequest(2, Commands.SelectHouse, { houseId = "stark" }), Codes.HouseUnavailable)

		host:playerJoined(1, "Alys")
		expect.equal(host.sessions:houseOf(1), "stark", "house restored on rejoin")

		-- After the reservation window, another player may take an abandoned house.
		host:playerLeft(1)
		controls.advance(fx.GameConfig.Sessions.ReconnectReservationSeconds + 1)
		expect.result(host:handleRequest(2, Commands.SelectHouse, { houseId = "stark" }), Codes.Ok)
	end)

	t.test("host role passes to the longest-connected remaining player", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		host:playerJoined(2, "Bran")
		host:playerJoined(3, "Cat")
		expect.equal(host.sessions:hostUserId(), 1)
		host:playerLeft(1)
		expect.equal(host.sessions:hostUserId(), 2)
		expect.equal(host:syncPayload(2).session.isHost, true)
		expect.equal(host:syncPayload(3).session.isHost, false)
	end)

	t.test("the clock pauses when no connected player leads a house", function()
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		expect.result(host:handleRequest(1, Commands.SetPaused, { paused = false }), Codes.Ok)
		expect.equal(host.sim.state.clock.paused, false)
		host:playerLeft(1)
		expect.equal(host.sim.state.clock.paused, true)
	end)
end
