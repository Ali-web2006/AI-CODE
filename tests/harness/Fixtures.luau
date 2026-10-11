--[[
	Fixtures — deterministic builders for simulations and campaign hosts used by the specs.

	All time is synthetic (a controllable clock), all randomness comes from fixed seeds and storage
	is an InMemoryBackend that round-trips through real JSON, like a DataStore.
]]

local serde = require("@lune/serde")

local Fixtures = {}

function Fixtures.new(vr)
	local self = {}

	self.GameConfig = vr.require("ReplicatedStorage.Shared.Config.GameConfig")
	self.Content = vr.require("ReplicatedStorage.Shared.Data.Content")
	self.TableUtil = vr.require("ReplicatedStorage.Shared.Util.TableUtil")
	self.CalendarDate = vr.require("ReplicatedStorage.Shared.Util.CalendarDate")
	self.Protocol = vr.require("ReplicatedStorage.Shared.Net.Protocol")
	self.EconomyRules = vr.require("ReplicatedStorage.Shared.Rules.EconomyRules")
	self.DiplomacyRules = vr.require("ReplicatedStorage.Shared.Rules.DiplomacyRules")
	self.CampaignState = vr.require("ServerScriptService.Simulation.CampaignState")
	self.Simulation = vr.require("ServerScriptService.Simulation.Simulation")
	self.Diagnostics = vr.require("ServerScriptService.Simulation.Diagnostics")
	self.StateInvariants = vr.require("ServerScriptService.Simulation.StateInvariants")
	self.CampaignHost = vr.require("ServerScriptService.App.CampaignHost")
	self.CampaignRepository = vr.require("ServerScriptService.App.CampaignRepository")
	self.CampaignSerializer = vr.require("ServerScriptService.App.CampaignSerializer")
	self.InMemoryBackend = vr.require("ServerScriptService.App.InMemoryBackend")

	self.codec = {
		encode = function(value)
			return serde.encode("json", value)
		end,
		decode = function(text)
			return serde.decode("json", text)
		end,
	}

	-- A deep, mutable copy of GameConfig with optional overrides applied (dotted keys).
	function self.config(overrides: { [string]: any }?)
		local config = self.TableUtil.deepCopy(self.GameConfig)
		for path, value in overrides or {} do
			local node = config
			local parts = string.split(path, ".")
			for i = 1, #parts - 1 do
				node = node[parts[i]]
			end
			node[parts[#parts]] = value
		end
		return config
	end

	function self.capturingDiagnostics()
		local lines = {}
		local diagnostics = self.Diagnostics.new(function(level, line)
			table.insert(lines, `{level}: {line}`)
		end, function()
			return 0
		end, 0)
		return diagnostics, lines
	end

	function self.newState(config, seed: number?)
		config = config or self.GameConfig
		local bookmark = self.Content.getBookmark(config.DefaultBookmarkId)
		return self.CampaignState.createFromBookmark(bookmark, {
			seed = seed or 1337,
			campaignId = "test-campaign",
			schemaVersion = config.SchemaVersion,
			clockConfig = config.Clock,
			aiConfig = config.AI,
		})
	end

	-- options: config, seed, human = { houseId = true }
	function self.newSim(options: { [string]: any }?)
		options = options or {}
		local config = options.config or self.GameConfig
		local diagnostics, lines = self.capturingDiagnostics()
		local human = options.human or {}
		local sim = self.Simulation.new({
			state = self.newState(config, options.seed),
			config = config,
			diagnostics = diagnostics,
			isHumanControlled = function(houseId)
				return human[houseId] == true
			end,
		})
		return sim, lines
	end

	-- options: config, environment, seed, backend ("memory" | "none" | custom backend), sleep
	function self.newHost(options: { [string]: any }?)
		options = options or {}
		local config = options.config or self.GameConfig
		local time = { now = 0 }
		local diagnostics, lines = self.capturingDiagnostics()
		local backend = options.backend
		if backend == nil or backend == "memory" then
			backend = self.InMemoryBackend.new(self.codec)
		end
		local repository = nil
		local persistence = { available = false, backendName = "None", persistent = false, reason = "disabled in test" }
		if backend ~= "none" then
			repository = self.CampaignRepository.new({
				backend = backend,
				codec = self.codec,
				config = config.Persistence,
				sleep = options.sleep or function() end,
				sessionId = options.sessionId or "test-session",
			})
			persistence = { available = true, backendName = backend.name, persistent = backend.persistent }
		end
		local host = self.CampaignHost.new({
			config = config,
			environment = options.environment or "development",
			seed = options.seed or 1337,
			campaignId = "test-campaign",
			now = function()
				return time.now
			end,
			wallClock = function()
				return 1700000000 + math.floor(time.now)
			end,
			diagnostics = diagnostics,
			repository = repository,
			persistence = persistence,
		})
		local controls = {
			time = time,
			lines = lines,
			backend = backend,
			repository = repository,
		}
		-- Advances synthetic time (seconds), letting rate limiters refill.
		function controls.advance(seconds: number)
			time.now += seconds
		end
		return host, controls
	end

	-- Sum of all treasuries (useful to detect money being created or destroyed).
	function self.totalTreasury(state)
		local total = 0
		for _, house in state.houses do
			total += house.treasury
		end
		return total
	end

	return self
end

return Fixtures
