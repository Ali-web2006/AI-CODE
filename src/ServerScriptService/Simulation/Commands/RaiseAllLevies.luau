--!strict
-- RaiseAllLevies: call the levies of every held province to arms and gather them at one province.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.RaiseAllLevies,
	schema = { provinceId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkRaiseAllLevies(sim, actor.houseId, payload.provinceId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applyRaiseAllLevies(sim, actor.houseId, payload.provinceId)
		if not ok then
			error(`RaiseAllLevies: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		local provinceName = Content.provinces[payload.provinceId].name
		local armies = if result.armies == 1 then "1 army" else `{result.armies} armies`
		return `Called {armies} ({EventText.troops(result.troops)} men) to {provinceName}.`, result
	end,
}

return command
