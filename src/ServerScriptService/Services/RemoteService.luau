--!strict
--[[
	RemoteService — creates the network remotes (Shared/Net/Protocol) and binds them to the
	CampaignHost. This is the only module that touches RemoteEvents/RemoteFunctions on the server.

	Client -> server requests are passed through untouched to CampaignHost.handleRequest, which
	performs all type checking, rate limiting, authorization and validation. The server never
	calls InvokeClient.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local CampaignHost = require(script.Parent.Parent.App.CampaignHost)

export type RemoteService = {
	send: (messages: { CampaignHost.ReplicationMessage }) -> (),
}

local RemoteService = {}

function RemoteService.start(host: CampaignHost.CampaignHost): RemoteService
	local existing = ReplicatedStorage:FindFirstChild(Protocol.RemoteFolderName)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = Protocol.RemoteFolderName

	local commandRemote = Instance.new("RemoteFunction")
	commandRemote.Name = Protocol.Remotes.Command
	commandRemote.Parent = folder

	local syncRemote = Instance.new("RemoteFunction")
	syncRemote.Name = Protocol.Remotes.Sync
	syncRemote.Parent = folder

	local deltaRemote = Instance.new("RemoteEvent")
	deltaRemote.Name = Protocol.Remotes.StateDelta
	deltaRemote.Parent = folder

	commandRemote.OnServerInvoke = function(player: Player, commandName: any, payload: any)
		return host:handleRequest(player.UserId, commandName, payload)
	end

	syncRemote.OnServerInvoke = function(player: Player)
		return host:requestSync(player.UserId)
	end

	-- Parent last so clients never observe a partially built folder.
	folder.Parent = ReplicatedStorage

	local service: RemoteService = {
		send = function(messages: { CampaignHost.ReplicationMessage })
			for _, message in messages do
				local player = Players:GetPlayerByUserId(message.userId)
				if player then
					deltaRemote:FireClient(player, message.payload)
				end
			end
		end,
	}
	return service
end

return RemoteService
