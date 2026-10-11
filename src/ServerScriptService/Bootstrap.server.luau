--!strict
--[[
	Server bootstrap: resolves the environment, chooses persistence, validates content, creates the
	campaign and starts the services. Nothing else on the server runs gameplay code.

	Startup order:
	  1. environment ("development" in Studio unless GameConfig.Environment.Mode overrides it)
	  2. diagnostics sink
	  3. persistence backend (DataStore, or labelled in-memory fallback)
	  4. CampaignHost (validates content and the bookmark; refuses to start on errors)
	  5. remotes, then the Heartbeat-driven campaign service
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Diagnostics = require(script.Parent.Simulation.Diagnostics)
local CampaignHost = require(script.Parent.App.CampaignHost)
local CampaignService = require(script.Parent.Services.CampaignService)
local PersistenceService = require(script.Parent.Services.PersistenceService)
local RemoteService = require(script.Parent.Services.RemoteService)

local environment: "development" | "production" = if GameConfig.Environment.Mode == "auto"
	then (if RunService:IsStudio() then "development" else "production")
	else GameConfig.Environment.Mode :: any

local diagnostics = Diagnostics.new(function(level, line)
	if level == "info" then
		print(line)
	elseif level == "warn" then
		warn(line)
	else
		warn(`ERROR {line}`)
	end
end, os.clock, GameConfig.Network.DiagnosticThrottleSeconds)

local sessionId = HttpService:GenerateGUID(false)
local seed = if environment == "development" then GameConfig.Environment.DevelopmentSeed else (os.time() % 2147483647) + 1

local persistence = PersistenceService.setup(environment, sessionId, function(message)
	diagnostics:info("Persistence", message)
end)

local host = CampaignHost.new({
	config = GameConfig,
	environment = environment,
	seed = seed,
	campaignId = sessionId,
	now = os.clock,
	wallClock = function()
		return os.time()
	end,
	diagnostics = diagnostics,
	repository = persistence.repository,
	persistence = persistence.status,
})

local remotes = RemoteService.start(host)
CampaignService.start(host, remotes)

diagnostics:info("Bootstrap", `server ready ({environment}, storage: {persistence.status.backendName})`)
