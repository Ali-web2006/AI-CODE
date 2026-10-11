--!strict
-- DevelopProvince: spend gold to raise a province's development by one level.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Economy = require(script.Parent.Parent.Economy)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.DevelopProvince,
	schema = { provinceId = "id" },

	validate = function(sim, actor, payload)
		local check = Economy.checkDevelop(sim, actor.houseId, payload.provinceId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Economy.develop(sim, actor.houseId, payload.provinceId)
		if not ok then
			-- validate() ran in the same server step, so this indicates a logic error.
			error(`DevelopProvince: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		local provinceName = Content.provinces[payload.provinceId].name
		return `{provinceName} developed to level {result.development} for {result.cost} gold.`, result
	end,
}

return command
