--!strict
--[[
	CommandTypes — the contract every game command implements.

	  name      Protocol command name.
	  schema    PayloadSchema describing the only accepted payload fields.
	  validate  Pure check of prerequisites against current state. Must not mutate anything.
	            Returns (ok, code, message).
	  execute   Performs the mutation. Called only after validate succeeded in the same step.
	            Convention: compute first, mutate last, so an error cannot leave partial state.
	            Returns (message, data).

	Adding a new action (alliances, marriages, war declarations) means adding one module here and
	registering it in CommandProcessor; transport, authorization, rate limiting and replication
	are inherited unchanged.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local PayloadSchema = require(script.Parent.Parent.PayloadSchema)
local SimContext = require(script.Parent.Parent.SimContext)

export type CommandDefinition = {
	name: string,
	schema: PayloadSchema.Schema,
	validate: (sim: SimContext.SimContext, actor: GameTypes.Actor, payload: any) -> (boolean, string, string),
	execute: (sim: SimContext.SimContext, actor: GameTypes.Actor, payload: any) -> (string, { [string]: any }),
}

return {}
