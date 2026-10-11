--!strict
--[[
	NetClient — the client side of the network contract (Shared/Net/Protocol).

	request() never throws: transport failures become a Result with code "InternalError", so UI
	code handles every outcome through one path. Requests yield, so callers run them in their own
	thread (ActionController does this).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)

export type Result = {
	ok: boolean,
	code: string,
	message: string,
	data: { [string]: any }?,
}

local NetClient = {}

local commandRemote: RemoteFunction
local syncRemote: RemoteFunction
local deltaRemote: RemoteEvent

function NetClient.connect()
	local folder = ReplicatedStorage:WaitForChild(Protocol.RemoteFolderName)
	commandRemote = folder:WaitForChild(Protocol.Remotes.Command) :: RemoteFunction
	syncRemote = folder:WaitForChild(Protocol.Remotes.Sync) :: RemoteFunction
	deltaRemote = folder:WaitForChild(Protocol.Remotes.StateDelta) :: RemoteEvent
end

function NetClient.request(commandName: string, payload: { [string]: any }?): Result
	local ok, result = pcall(function()
		return commandRemote:InvokeServer(commandName, payload)
	end)
	if not ok then
		return { ok = false, code = Protocol.ResultCodes.InternalError, message = `Connection problem: {tostring(result)}` }
	end
	if type(result) ~= "table" or type(result.code) ~= "string" then
		return { ok = false, code = Protocol.ResultCodes.InternalError, message = "The server sent an unexpected reply." }
	end
	return result :: Result
end

-- Full snapshot; nil when the server declined (rate limit) or the call failed.
function NetClient.sync(): { [string]: any }?
	local ok, result = pcall(function()
		return syncRemote:InvokeServer()
	end)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

function NetClient.onDelta(handler: (payload: { [string]: any }) -> ()): RBXScriptConnection
	return deltaRemote.OnClientEvent:Connect(handler)
end

return NetClient
