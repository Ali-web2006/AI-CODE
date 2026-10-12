--!strict
-- DisbandArmy: send an army home; its men refill the levy pools (no gold is refunded).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.DisbandArmy,
	schema = { armyId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkDisbandArmy(sim, actor.houseId, payload.armyId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applyDisbandArmy(sim, actor.houseId, payload.armyId)
		if not ok then
			error(`DisbandArmy: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		local name = MilitaryRules.armyName(result :: any)
		return `The {name} disbanded: {EventText.troops(result.returned)} of {EventText.troops(result.troops)} men returned to the levies.`,
			result
	end,
}

return command
