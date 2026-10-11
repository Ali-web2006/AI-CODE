--!strict
--[[
	PersistenceService — adapts Roblox DataStoreService to the CampaignRepository backend contract
	and chooses the storage backend at startup.

	Backend selection (GameConfig.Persistence.Backend):
	  "datastore"  use DataStoreService; if unreachable, saving is reported unavailable
	  "memory"     use the in-memory backend (non-persistent, clearly labelled in the UI)
	  "auto"       try DataStoreService, fall back to memory if it is unreachable

	Development and production use different DataStore names (GameConfig.Persistence), so test
	sessions in Studio can never overwrite live saves. DataStore access from Studio requires a
	published place and "Enable Studio Access to API Services" (docs/TEST_PLAN.md).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local App = script.Parent.Parent.App
local CampaignHost = require(App.CampaignHost)
local CampaignRepository = require(App.CampaignRepository)
local InMemoryBackend = require(App.InMemoryBackend)

local PersistenceService = {}

local codec = {
	encode = function(value: any): string
		return HttpService:JSONEncode(value)
	end,
	decode = function(text: string): any
		return HttpService:JSONDecode(text)
	end,
}

-- DataStore-backed implementation of the repository backend contract.
local function newDataStoreBackend(dataStore: DataStore): CampaignRepository.Backend
	local backend = {
		name = "DataStore",
		persistent = true,
	}

	local function ensureBudget(requestType: Enum.DataStoreRequestType)
		if DataStoreService:GetRequestBudgetForRequestType(requestType) < 1 then
			-- Raising lets the repository's bounded retry/backoff handle exhausted budgets.
			error(`DataStore request budget exhausted for {requestType.Name}`)
		end
	end

	function backend.get(_self: any, key: string): any
		ensureBudget(Enum.DataStoreRequestType.GetAsync)
		return dataStore:GetAsync(key)
	end

	function backend.update(_self: any, key: string, transform: (current: any) -> any): any
		ensureBudget(Enum.DataStoreRequestType.UpdateAsync)
		return dataStore:UpdateAsync(key, function(current: any)
			return transform(current)
		end)
	end

	return backend :: any
end

export type Setup = {
	repository: CampaignRepository.CampaignRepository?,
	status: CampaignHost.PersistenceStatus,
}

function PersistenceService.setup(environment: "development" | "production", sessionId: string, log: (string) -> ()): Setup
	local settings = GameConfig.Persistence
	local storeName = if environment == "production" then settings.ProductionDataStoreName else settings.DevelopmentDataStoreName

	local backend: CampaignRepository.Backend? = nil
	local status: CampaignHost.PersistenceStatus
	local reason: string? = nil

	if settings.Backend ~= "memory" then
		local ok, result = pcall(function()
			local dataStore = DataStoreService:GetDataStore(storeName)
			-- A cheap read proves the API is actually reachable (Studio without API access fails here).
			dataStore:GetAsync("__probe")
			return dataStore
		end)
		if ok then
			backend = newDataStoreBackend(result)
			log(`using DataStore '{storeName}'`)
		else
			reason = `DataStore unavailable ({tostring(result)})`
			log(reason)
		end
	end

	if backend == nil and settings.Backend ~= "datastore" then
		backend = InMemoryBackend.new(codec) :: any
		log("using the in-memory backend: saves last only while this server runs")
	end

	if backend == nil then
		return {
			repository = nil,
			status = { available = false, backendName = "None", persistent = false, reason = reason or "storage disabled" },
		}
	end

	local repository = CampaignRepository.new({
		backend = backend :: CampaignRepository.Backend,
		codec = codec,
		config = settings,
		sleep = function(seconds: number)
			task.wait(seconds)
		end,
		sessionId = sessionId,
		log = log,
	})
	status = {
		available = true,
		backendName = (backend :: CampaignRepository.Backend).name,
		persistent = (backend :: CampaignRepository.Backend).persistent,
		reason = if (backend :: CampaignRepository.Backend).persistent then nil else reason or "in-memory storage",
	}
	return { repository = repository, status = status }
end

return PersistenceService
