--!strict
-- StopArmy: cancel an army's march orders; an army on the road halts at the end of its current leg.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.StopArmy,
	schema = { armyId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkStopArmy(sim, actor.houseId, payload.armyId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applyStopArmy(sim, actor.houseId, payload.armyId)
		if not ok then
			error(`StopArmy: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		return `The {MilitaryRules.armyName(result :: any)} halts at {Content.provinces[result.provinceId].name}.`, result
	end,
}

return command
