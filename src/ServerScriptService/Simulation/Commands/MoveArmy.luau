--!strict
-- MoveArmy: send an army to a province along the fastest route.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.MoveArmy,
	schema = { armyId = "id", provinceId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkMoveArmy(sim, actor.houseId, payload.armyId, payload.provinceId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applyMoveArmy(sim, actor.houseId, payload.armyId, payload.provinceId)
		if not ok then
			error(`MoveArmy: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		local name = MilitaryRules.armyName(result :: any)
		local provinceName = Content.provinces[payload.provinceId].name
		local days = if result.days == 1 then "1 day" else `{result.days} days`
		if result.waiting then
			return `The {name} waits for ships to sail for {provinceName} ({days} once under way).`, result
		end
		return `The {name} marches to {provinceName} ({days}).`, result
	end,
}

return command
