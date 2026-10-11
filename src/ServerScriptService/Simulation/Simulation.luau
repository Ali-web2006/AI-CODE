--!strict
--[[
	Simulation — the aggregate root of one running campaign.

	Owns the authoritative CampaignState plus runtime-only helpers (clock accumulator, change
	journal). It is completely independent of Roblox services: the CampaignService adapter feeds it
	real elapsed time; tests feed it synthetic time.

	Time model:
	  update(dt)   real seconds -> whole days (GameClock) -> advanceDay() for each day
	  advanceDay() moves the date forward one day, runs daily systems, and when the month changes
	               runs the monthly systems for the month that just ended.
	  Monthly systems run in this fixed order: Economy, Diplomacy (drift), AI.

	The monthly guard: clock.lastProcessedMonthIndex is advanced exactly once per month. A month
	at or before it is never processed again, regardless of speed changes, pauses or catch-up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local AIDirector = require(script.Parent.AIDirector)
local ChangeJournal = require(script.Parent.ChangeJournal)
local CommandProcessor = require(script.Parent.CommandProcessor)
local Diagnostics = require(script.Parent.Diagnostics)
local Diplomacy = require(script.Parent.Diplomacy)
local Economy = require(script.Parent.Economy)
local GameClock = require(script.Parent.GameClock)
local SimContext = require(script.Parent.SimContext)

type SystemFn = (sim: SimContext.SimContext, index: number) -> ()
type System = { name: string, run: SystemFn }

export type Options = {
	state: GameTypes.CampaignState,
	config: SimContext.Config,
	diagnostics: Diagnostics.Diagnostics?,
	isHumanControlled: ((houseId: string) -> boolean)?,
}

local Simulation = {}
Simulation.__index = Simulation

type SimulationData = {
	state: GameTypes.CampaignState,
	config: SimContext.Config,
	journal: ChangeJournal.ChangeJournal,
	diagnostics: Diagnostics.Diagnostics,
	isHumanControlled: (houseId: string) -> boolean,
	clock: GameClock.GameClock,
	dailySystems: { System },
	monthlySystems: { System },
	monthsProcessed: number,
}

export type Simulation = typeof(setmetatable({} :: SimulationData, Simulation))

function Simulation.new(options: Options): Simulation
	local self = setmetatable({
		state = options.state,
		config = options.config,
		journal = ChangeJournal.new(),
		diagnostics = options.diagnostics or Diagnostics.silent(),
		isHumanControlled = options.isHumanControlled or function(_houseId: string)
			return false
		end,
		clock = GameClock.new(options.config.Clock),
		-- Extension point: Phase 4/5 register daily systems (scheme progress, army movement).
		dailySystems = {},
		monthlySystems = {
			{ name = "Economy", run = Economy.processMonth },
			{ name = "Diplomacy", run = Diplomacy.processMonth },
			{ name = "AI", run = AIDirector.processMonth },
		},
		monthsProcessed = 0,
	}, Simulation)
	return self
end

-- The simulation satisfies the SimContext shape expected by domain modules.
function Simulation.context(self: Simulation): SimContext.SimContext
	return (self :: any) :: SimContext.SimContext
end

local function runSystem(self: Simulation, system: System, index: number)
	local ok, err = pcall(system.run, self:context(), index)
	if not ok then
		-- A failing system must not stall the campaign clock; it is reported loudly instead.
		self.diagnostics:error("Simulation", `system '{system.name}' failed at index {index}: {tostring(err)}`)
	end
end

function Simulation.processMonth(self: Simulation, monthIndex: number)
	local clock = self.state.clock
	if monthIndex <= clock.lastProcessedMonthIndex then
		self.diagnostics:error("Clock", `refused to process {CalendarDate.formatMonthIndex(monthIndex)} twice`)
		return
	end
	if monthIndex ~= clock.lastProcessedMonthIndex + 1 then
		self.diagnostics:error("Clock", `month gap detected: last processed {clock.lastProcessedMonthIndex}, now {monthIndex}`)
	end
	clock.lastProcessedMonthIndex = monthIndex
	self.monthsProcessed += 1
	for _, system in self.monthlySystems do
		runSystem(self, system, monthIndex)
	end
end

function Simulation.advanceDay(self: Simulation)
	local clock = self.state.clock
	local previous = clock.date
	local nextDate = CalendarDate.addDays(previous, 1)
	clock.date = nextDate
	self.journal:markClock()

	local dayNumber = CalendarDate.toDayNumber(nextDate)
	for _, system in self.dailySystems do
		runSystem(self, system, dayNumber)
	end
	if nextDate.month ~= previous.month then
		self:processMonth(CalendarDate.monthIndex(previous))
	end
end

-- Advances by real elapsed seconds; returns the number of days simulated.
function Simulation.update(self: Simulation, elapsedSeconds: number): number
	local clock = self.state.clock
	local days = self.clock:consume(elapsedSeconds, clock.speed, clock.paused)
	for _ = 1, days do
		self:advanceDay()
	end
	return days
end

-- Development/test helper: advance day by day until the current month has been processed.
function Simulation.advanceToNextMonth(self: Simulation): number
	local target = self.state.clock.lastProcessedMonthIndex + 1
	local days = 0
	while self.state.clock.lastProcessedMonthIndex < target and days < 32 do
		self:advanceDay()
		days += 1
	end
	return days
end

function Simulation.setSpeed(self: Simulation, speed: number): boolean
	if not self.clock:isValidSpeed(speed) then
		return false
	end
	self.state.clock.speed = speed
	self.journal:markClock()
	return true
end

function Simulation.setPaused(self: Simulation, paused: boolean)
	self.state.clock.paused = paused
	self.journal:markClock()
end

function Simulation.submit(self: Simulation, actor: GameTypes.Actor, commandName: string, payload: any): GameTypes.CommandResult
	return CommandProcessor.submit(self:context(), actor, commandName, payload)
end

return Simulation
