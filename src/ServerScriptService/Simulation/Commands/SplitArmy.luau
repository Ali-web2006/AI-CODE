--!strict
-- SplitArmy: divide an idle army into two halves (every unit split in two).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.SplitArmy,
	schema = { armyId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkSplitArmy(sim, actor.houseId, payload.armyId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applySplitArmy(sim, actor.houseId, payload.armyId)
		if not ok then
			error(`SplitArmy: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		return `The {MilitaryRules.armyName(result :: any)} divided: {EventText.troops(result.troops)} men form a new army.`, result
	end,
}

return command
