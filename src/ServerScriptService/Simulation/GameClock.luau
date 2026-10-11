--!strict
--[[
	GameClock — converts real elapsed server time into whole in-game days.

	The persisted clock (date, speed, paused, lastProcessedMonthIndex) lives in campaign state.
	This object only holds the runtime accumulator of not-yet-converted real seconds, which is
	deliberately not saved.

	Guarantees (covered by tests in Scenario D):
	  * Paused, zero, negative, NaN or infinite elapsed time advances nothing.
	  * At most MaxDaysPerStep days are produced per call; any backlog beyond that is discarded,
	    so a server hitch cannot trigger a burst of catch-up simulation.
	  * Changing speed never produces extra days: the accumulator holds seconds, not days.
	Monthly processing is driven by the date itself (Simulation), never by the accumulator.
]]

export type ClockConfig = {
	SecondsPerDay: { number },
	DefaultSpeed: number,
	MaxDaysPerStep: number,
	StartPaused: boolean,
}

local EPSILON = 1e-9

local GameClock = {}
GameClock.__index = GameClock

type GameClockData = {
	config: ClockConfig,
	accumulator: number,
}

export type GameClock = typeof(setmetatable({} :: GameClockData, GameClock))

function GameClock.new(config: ClockConfig): GameClock
	return setmetatable({ config = config, accumulator = 0 }, GameClock)
end

function GameClock.isValidSpeed(self: GameClock, speed: any): boolean
	return type(speed) == "number" and math.floor(speed) == speed and speed >= 1 and speed <= #self.config.SecondsPerDay
end

function GameClock.secondsPerDay(self: GameClock, speed: number): number
	return self.config.SecondsPerDay[speed]
end

-- Returns how many whole days should be simulated for `elapsedSeconds` of real time.
function GameClock.consume(self: GameClock, elapsedSeconds: number, speed: number, paused: boolean): number
	if paused then
		return 0
	end
	if type(elapsedSeconds) ~= "number" or elapsedSeconds ~= elapsedSeconds or elapsedSeconds <= 0 or elapsedSeconds == math.huge then
		return 0
	end
	if not self:isValidSpeed(speed) then
		return 0
	end
	local secondsPerDay = self.config.SecondsPerDay[speed]
	self.accumulator += elapsedSeconds
	-- The epsilon absorbs binary floating-point error (0.4 * 10 / 0.4 may be 9.999...).
	local days = math.floor(self.accumulator / secondsPerDay + EPSILON)
	if days > self.config.MaxDaysPerStep then
		days = self.config.MaxDaysPerStep
		self.accumulator = 0
	else
		self.accumulator = math.max(0, self.accumulator - days * secondsPerDay)
	end
	return days
end

function GameClock.reset(self: GameClock)
	self.accumulator = 0
end

return GameClock
