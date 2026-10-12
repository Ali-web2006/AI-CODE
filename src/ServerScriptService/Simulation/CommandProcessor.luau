--!strict
--[[
	CommandProcessor — the single authoritative path for game actions.

	Player Input -> [transport + session authorization + rate limit: CampaignHost]
	             -> CommandProcessor.submit:
	                  1. resolve the command definition
	                  2. validate the payload schema
	                  3. verify the acting house exists and can act
	                  4. command.validate (prerequisites, ownership, costs, cooldowns)
	                  5. command.execute inside pcall (domain operation + state mutation)
	                  6. post-condition invariants on the acting house
	             -> ChangeJournal (replication) -> client UI

	AI rulers call exactly the same function with an "ai" actor, so they can never bypass costs,
	prerequisites or validation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local PayloadSchema = require(script.Parent.PayloadSchema)
local SimContext = require(script.Parent.SimContext)
local StateInvariants = require(script.Parent.StateInvariants)
local CommandTypes = require(script.Parent.Commands.CommandTypes)

type SimContext = SimContext.SimContext

local Codes = Protocol.ResultCodes

local registry: { [string]: CommandTypes.CommandDefinition } = {}
local commandModules = {
	script.Parent.Commands.DevelopProvince,
	script.Parent.Commands.ImproveRelations,
	script.Parent.Commands.RaiseArmy,
	script.Parent.Commands.RaiseAllLevies,
	script.Parent.Commands.MoveArmy,
	script.Parent.Commands.StopArmy,
	script.Parent.Commands.SplitArmy,
	script.Parent.Commands.MergeArmies,
	script.Parent.Commands.DisbandArmy,
}
for _, module in commandModules do
	local definition = require(module) :: CommandTypes.CommandDefinition
	registry[definition.name] = definition
end

local CommandProcessor = {}

local function reject(code: string, message: string): GameTypes.CommandResult
	return { ok = false, code = code, message = message }
end

function CommandProcessor.isGameCommand(commandName: string): boolean
	return registry[commandName] ~= nil
end

function CommandProcessor.schemaFor(commandName: string): PayloadSchema.Schema?
	local definition = registry[commandName]
	return definition and definition.schema
end

function CommandProcessor.payloadLimits(sim: SimContext): PayloadSchema.Limits
	return {
		maxIdLength = sim.config.Network.MaxIdLength,
		maxPayloadKeys = sim.config.Network.MaxPayloadKeys,
		speedCount = #sim.config.Clock.SecondsPerDay,
	}
end

function CommandProcessor.submit(sim: SimContext, actor: GameTypes.Actor, commandName: string, payload: any): GameTypes.CommandResult
	local definition = registry[commandName]
	if not definition then
		return reject(Codes.UnknownCommand, "Unknown action.")
	end

	local payloadOk, reason = PayloadSchema.validate(definition.schema, payload, CommandProcessor.payloadLimits(sim))
	if not payloadOk then
		sim.diagnostics:throttled(
			`payload:{actor.houseId}:{commandName}`,
			"warn",
			"Commands",
			`{commandName} from {actor.kind}:{actor.houseId} rejected: {reason}`
		)
		return reject(Codes.InvalidPayload, "The request was malformed.")
	end

	local house = sim.state.houses[actor.houseId]
	if not house or house.extinct then
		return reject(Codes.NotAuthorized, "Your house cannot act.")
	end

	local valid, code, message = definition.validate(sim, actor, payload)
	if not valid then
		sim.diagnostics:throttled(
			`reject:{actor.houseId}:{commandName}:{code}`,
			"info",
			"Commands",
			`{commandName} by {actor.kind}:{actor.houseId} rejected ({code}): {message}`
		)
		return reject(code, message)
	end

	local succeeded, resultMessage, data = pcall(definition.execute, sim, actor, payload)
	if not succeeded then
		sim.diagnostics:error("Commands", `{commandName} by {actor.kind}:{actor.houseId} failed during execution: {tostring(resultMessage)}`)
		return reject(Codes.InternalError, "The action failed on the server. It has been logged.")
	end

	local violation = StateInvariants.checkHouseTreasury(house)
	if violation then
		sim.diagnostics:error("Commands", `{commandName} by {actor.kind}:{actor.houseId} broke an invariant: {violation}`)
	end

	return { ok = true, code = Codes.Ok, message = resultMessage, data = data }
end

return CommandProcessor
