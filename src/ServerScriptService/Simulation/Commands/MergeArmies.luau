--!strict
-- MergeArmies: join one idle army into another in the same province.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.MergeArmies,
	schema = { armyId = "id", intoArmyId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkMergeArmies(sim, actor.houseId, payload.armyId, payload.intoArmyId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applyMergeArmies(sim, actor.houseId, payload.armyId, payload.intoArmyId)
		if not ok then
			error(`MergeArmies: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		return `The armies joined: the {MilitaryRules.armyName(result :: any)} now has {EventText.troops(result.troops)} men.`, result
	end,
}

return command
