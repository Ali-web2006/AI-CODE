--!strict
--[[
	SimContext — the shape every domain module receives instead of requiring the Simulation
	module itself. This breaks the would-be cycle Simulation -> Economy -> Simulation and makes
	the dependencies of each domain operation explicit: state, config, journal, diagnostics and
	the session predicate.

	Also hosts `emitEvent`, the one place game events are constructed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
-- selene: allow(unused_variable) -- used only as a type: typeof(GameConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local ChangeJournal = require(script.Parent.ChangeJournal)
local Diagnostics = require(script.Parent.Diagnostics)

export type Config = typeof(GameConfig)

export type SimContext = {
	state: GameTypes.CampaignState,
	config: Config,
	journal: ChangeJournal.ChangeJournal,
	diagnostics: Diagnostics.Diagnostics,
	-- True when a connected player governs the house; the AI leaves such houses alone.
	isHumanControlled: (houseId: string) -> boolean,
}

local SimContext = {}

function SimContext.emitEvent(
	sim: SimContext,
	kind: string,
	priority: GameTypes.EventPriority,
	audience: { string }?,
	data: { [string]: any }
)
	sim.journal:pushEvent({
		kind = kind,
		priority = priority,
		audience = audience,
		date = CalendarDate.clone(sim.state.clock.date),
		data = data,
	})
end

return SimContext
