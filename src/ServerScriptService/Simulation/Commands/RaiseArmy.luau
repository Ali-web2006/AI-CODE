--!strict
-- RaiseArmy: raise every available levy of a province into a new army.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Military = require(script.Parent.Parent.Military)
local CommandTypes = require(script.Parent.CommandTypes)

local command: CommandTypes.CommandDefinition = {
	name = Protocol.Commands.RaiseArmy,
	schema = { provinceId = "id" },

	validate = function(sim, actor, payload)
		local check = Military.checkRaiseArmy(sim, actor.houseId, payload.provinceId)
		return check.ok, check.code, check.message
	end,

	execute = function(sim, actor, payload)
		local ok, data = Military.applyRaiseArmy(sim, actor.houseId, payload.provinceId)
		if not ok then
			-- validate() ran in the same server step, so this indicates a logic error.
			error(`RaiseArmy: post-validation failure {(data :: any).code}`)
		end
		local result = data :: { [string]: any }
		local provinceName = Content.provinces[payload.provinceId].name
		return `Raised {EventText.troops(result.troops)} men at {provinceName}.`, result
	end,
}

return command
