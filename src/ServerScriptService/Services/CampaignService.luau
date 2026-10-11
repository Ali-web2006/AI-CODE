--!strict
--[[
	CampaignService — drives the CampaignHost from Roblox engine events.

	  * Players.PlayerAdded / PlayerRemoving  -> session join / leave
	  * RunService.Heartbeat (one connection) -> host:update(dt), then replication of due deltas
	  * a single autosave loop                -> host:saveForHost("autosave") when the campaign changed
	  * game:BindToClose                      -> final save on shutdown

	There is exactly one simulation loop for the whole campaign; no per-entity loops exist.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local CampaignHost = require(script.Parent.Parent.App.CampaignHost)
local RemoteService = require(script.Parent.RemoteService)

local CampaignService = {}

function CampaignService.start(host: CampaignHost.CampaignHost, remotes: RemoteService.RemoteService)
	local function onPlayerAdded(player: Player)
		host:playerJoined(player.UserId, player.DisplayName)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		host:playerLeft(player.UserId)
		remotes.send(host:collectReplication(true))
	end)

	RunService.Heartbeat:Connect(function(deltaTime: number)
		local ok, err = pcall(function()
			host:update(deltaTime)
			local messages = host:collectReplication(false)
			if #messages > 0 then
				remotes.send(messages)
			end
		end)
		if not ok then
			host.diagnostics:throttled("heartbeat", "error", "Simulation", `heartbeat step failed: {tostring(err)}`)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(GameConfig.Persistence.AutosaveIntervalSeconds)
			if host:shouldAutosave() then
				host:saveForHost("autosave")
				remotes.send(host:collectReplication(true))
			end
		end
	end)

	game:BindToClose(function()
		if host:shouldAutosave() then
			host:saveForHost("shutdown")
		end
	end)
end

return CampaignService
