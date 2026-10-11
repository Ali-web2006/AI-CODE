-- Scenario D — Clock: expected advancement per speed, pause holds time, monthly processing
-- happens exactly once per month, and the calendar arithmetic is exact.

return function(t)
	local fx, expect = t.fx, t.expect
	local CalendarDate = fx.CalendarDate

	local function dayNumber(sim)
		return CalendarDate.toDayNumber(sim.state.clock.date)
	end

	-- Drives the simulation like the Heartbeat adapter: many small frames.
	local function runFrames(sim, seconds: number, frameRate: number)
		local frames = math.floor(seconds * frameRate + 0.5)
		for _ = 1, frames do
			sim:update(1 / frameRate)
		end
	end

	t.test("paused time does not advance", function()
		local sim = fx.newSim()
		expect.equal(sim.state.clock.paused, true)
		local start = dayNumber(sim)
		runFrames(sim, 30, 60)
		expect.equal(sim:update(1000), 0)
		expect.equal(dayNumber(sim), start)
	end)

	t.test("each speed advances the expected number of days", function()
		for speed, secondsPerDay in fx.GameConfig.Clock.SecondsPerDay do
			local sim = fx.newSim()
			sim:setPaused(false)
			sim:setSpeed(speed)
			local start = dayNumber(sim)
			local seconds = secondsPerDay * 50
			runFrames(sim, seconds, 60)
			local advanced = dayNumber(sim) - start
			expect.truthy(math.abs(advanced - 50) <= 1, `speed {speed}: expected ~50 days, got {advanced}`)
		end
	end)

	t.test("exact multiples of the day length advance exactly", function()
		local sim = fx.newSim()
		sim:setPaused(false)
		sim:setSpeed(1)
		local start = dayNumber(sim)
		for _ = 1, 10 do
			sim:update(0.4)
		end
		expect.equal(dayNumber(sim) - start, 10)
	end)

	t.test("invalid elapsed time is ignored and catch-up is capped", function()
		local sim = fx.newSim()
		sim:setPaused(false)
		sim:setSpeed(3)
		local start = dayNumber(sim)
		expect.equal(sim:update(-5), 0, "negative")
		expect.equal(sim:update(0 / 0), 0, "NaN")
		expect.equal(sim:update(math.huge), 0, "infinite")
		expect.equal(sim:update(0), 0, "zero")
		expect.equal(dayNumber(sim), start)
		expect.equal(sim:update(10000), fx.GameConfig.Clock.MaxDaysPerStep, "a long hitch is capped")
		expect.equal(sim.clock.accumulator, 0, "the backlog is discarded")
	end)

	t.test("a year with constant speed changes processes exactly twelve months", function()
		local sim = fx.newSim()
		sim:setPaused(false)
		local speeds = { 1, 3, 2, 3, 1, 2 }
		local step = 0
		while sim.state.clock.date.year < 298 do
			step += 1
			sim:setSpeed(speeds[(step % #speeds) + 1])
			if step % 7 == 0 then
				sim:setPaused(true)
				runFrames(sim, 0.5, 60)
				sim:setPaused(false)
			end
			runFrames(sim, 0.75, 60)
		end
		expect.equal(sim.monthsProcessed, 12, "months processed")
		for houseId, house in sim.state.houses do
			expect.equal(#house.ledger, 12, `{houseId} ledger entries`)
			for i, entry in house.ledger do
				expect.equal(entry.monthIndex, 297 * 12 + (i - 1), `{houseId} ledger month {i}`)
			end
		end
		expect.equal(sim.state.clock.lastProcessedMonthIndex, CalendarDate.monthIndex(sim.state.clock.date) - 1)
	end)

	t.test("monthly income is applied once: treasury follows the ledger exactly", function()
		local sim = fx.newSim({ config = fx.config({ ["AI.MaxEvaluationsPerMonth"] = 0 }) })
		local before = sim.state.houses.stark.treasury
		sim:setPaused(false)
		sim:setSpeed(3)
		for _ = 1, 3 do
			sim:advanceToNextMonth()
		end
		local expected = before
		for _, entry in sim.state.houses.stark.ledger do
			expected = fx.EconomyRules.roundGold(expected + entry.net)
		end
		expect.equal(#sim.state.houses.stark.ledger, 3)
		expect.near(sim.state.houses.stark.treasury, expected, 1e-9)
	end)

	t.test("processing the same month twice is refused", function()
		local sim, lines = fx.newSim()
		sim:advanceToNextMonth()
		local treasury = sim.state.houses.stark.treasury
		local processed = sim.state.clock.lastProcessedMonthIndex
		sim:processMonth(processed)
		expect.equal(sim.state.houses.stark.treasury, treasury, "treasury unchanged")
		expect.equal(#sim.state.houses.stark.ledger, 1)
		expect.anyContains(lines, "refused to process")
	end)

	t.test("calendar arithmetic handles month and year boundaries", function()
		expect.deepEqual(CalendarDate.addDays(CalendarDate.new(297, 1, 31), 1), { year = 297, month = 2, day = 1 })
		expect.deepEqual(CalendarDate.addDays(CalendarDate.new(297, 2, 28), 1), { year = 297, month = 3, day = 1 })
		expect.deepEqual(CalendarDate.addDays(CalendarDate.new(297, 12, 31), 1), { year = 298, month = 1, day = 1 })
		expect.deepEqual(CalendarDate.addDays(CalendarDate.new(297, 1, 1), 365), { year = 298, month = 1, day = 1 })
		for _, n in { 0, 1, 58, 59, 364, 365, 109000 } do
			expect.equal(CalendarDate.toDayNumber(CalendarDate.fromDayNumber(n)), n, `round trip {n}`)
		end
		expect.equal(CalendarDate.yearsBetween(CalendarDate.new(263, 4, 14), CalendarDate.new(297, 4, 13)), 33)
		expect.equal(CalendarDate.yearsBetween(CalendarDate.new(263, 4, 14), CalendarDate.new(297, 4, 14)), 34)
		expect.equal(CalendarDate.format(CalendarDate.new(297, 3, 5)), "5 March 297 AC")
		expect.falsy(CalendarDate.isValid({ year = 297, month = 2, day = 29 }), "no leap days")
	end)

	t.test("speed and pause permissions follow the host policy", function()
		local Codes = fx.Protocol.ResultCodes
		local Commands = fx.Protocol.Commands
		local host = fx.newHost()
		host:playerJoined(1, "Alys")
		host:playerJoined(2, "Bran")
		expect.result(host:handleRequest(1, Commands.SetPaused, { paused = false }), Codes.CampaignNotRunning, "no houses yet")
		host:handleRequest(1, Commands.SelectHouse, { houseId = "stark" })
		host:handleRequest(2, Commands.SelectHouse, { houseId = "lannister" })
		expect.result(host:handleRequest(2, Commands.SetSpeed, { speed = 3 }), Codes.NotAuthorized)
		expect.result(host:handleRequest(2, Commands.SetPaused, { paused = false }), Codes.NotAuthorized)
		expect.result(host:handleRequest(1, Commands.SetPaused, { paused = false }), Codes.Ok)
		expect.result(host:handleRequest(1, Commands.SetSpeed, { speed = 3 }), Codes.Ok)
		expect.result(host:handleRequest(2, Commands.SetPaused, { paused = true }), Codes.Ok, "any player leading a house may pause")
		expect.equal(host.sim.state.clock.paused, true)
		expect.equal(host.sim.state.clock.speed, 3)
	end)
end
