--!strict
--[[
	ActionController — sends player commands and reports their results.

	Every gameplay button calls ActionController.run, which marks the action busy (so a double
	click cannot send two requests), invokes the server in its own thread and reports the server's
	verdict through `resultReported`. The client never applies an outcome itself; state changes
	arrive through replication.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local NetClient = require(script.Parent.NetClient)

local ActionController = {}

-- Fired with (commandName, result) after every request.
ActionController.resultReported = Signal.new()

local busy: { [string]: boolean } = {}

function ActionController.isBusy(key: string): boolean
	return busy[key] == true
end

-- `key` identifies the button/action for busy-state tracking (defaults to the command name).
function ActionController.run(commandName: string, payload: { [string]: any }?, key: string?, onDone: ((result: NetClient.Result) -> ())?)
	local busyKey = key or commandName
	if busy[busyKey] then
		return
	end
	busy[busyKey] = true
	task.spawn(function()
		local result = NetClient.request(commandName, payload)
		busy[busyKey] = nil
		ActionController.resultReported:Fire(commandName, result)
		if onDone then
			onDone(result)
		end
	end)
end

return ActionController
