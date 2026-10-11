--!strict
-- ImproveRelations: send an envoy with gifts to another house to improve relations.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Diplomacy = require(script.Parent.Parent.Diplomacy)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.ImproveRelations,
	schema = { targetHouseId = "id" },

	validate = function(sim, actor, payload)
		local check = Diplomacy.checkImproveRelations(sim, actor.houseId, payload.targetHouseId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Diplomacy.applyImproveRelations(sim, actor.houseId, payload.targetHouseId)
		if not ok then
			error(`ImproveRelations: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		local targetName = Content.houses[payload.targetHouseId].name
		return `Envoy received by {targetName}: relations {result.before} -> {result.score} for {result.cost} gold.`, result
	end,
}

return command
