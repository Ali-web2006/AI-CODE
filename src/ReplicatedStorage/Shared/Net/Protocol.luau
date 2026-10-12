--!strict
--[[
	Protocol — the client/server network contract (documented in docs/ARCHITECTURE.md §Network).

	Remotes (created by the server inside ReplicatedStorage.<RemoteFolderName>):
	  Command    RemoteFunction  client -> server  (commandName: string, payload: table?) -> Result
	  Sync       RemoteFunction  client -> server  () -> full snapshot for that player
	  StateDelta RemoteEvent     server -> client  (delta) sequenced incremental update

	The server never invokes a client (no RemoteFunction:InvokeClient), so a misbehaving client
	cannot stall server threads.

	Every Result has the shape { ok: boolean, code: string, message: string, data: table? }.
	`code` is one of ResultCodes; `message` is human-readable and safe to show to the player.
]]

local Protocol = {}

Protocol.RemoteFolderName = "IronThroneNet"

Protocol.Remotes = table.freeze({
	Command = "Command",
	Sync = "Sync",
	StateDelta = "StateDelta",
})

Protocol.Commands = table.freeze({
	-- Session / campaign control (handled by CampaignHost)
	SelectHouse = "SelectHouse",
	SetSpeed = "SetSpeed",
	SetPaused = "SetPaused",
	GetSaveInfo = "GetSaveInfo",
	SaveCampaign = "SaveCampaign",
	LoadCampaign = "LoadCampaign",
	DebugAdvanceMonth = "DebugAdvanceMonth",
	-- Game actions (handled by the CommandProcessor; also used by the AI)
	DevelopProvince = "DevelopProvince",
	ImproveRelations = "ImproveRelations",
	RaiseArmy = "RaiseArmy",
	RaiseAllLevies = "RaiseAllLevies",
	MoveArmy = "MoveArmy",
	StopArmy = "StopArmy",
	SplitArmy = "SplitArmy",
	MergeArmies = "MergeArmies",
	DisbandArmy = "DisbandArmy",
})

Protocol.ResultCodes = table.freeze({
	Ok = "Ok",
	UnknownCommand = "UnknownCommand",
	InvalidPayload = "InvalidPayload",
	RateLimited = "RateLimited",
	NoHouse = "NoHouse",
	AlreadyHasHouse = "AlreadyHasHouse",
	HouseUnavailable = "HouseUnavailable",
	NotAuthorized = "NotAuthorized",
	NotFound = "NotFound",
	NotOwner = "NotOwner",
	InvalidTarget = "InvalidTarget",
	InsufficientFunds = "InsufficientFunds",
	MaxDevelopment = "MaxDevelopment",
	MaxRelation = "MaxRelation",
	OnCooldown = "OnCooldown",
	NotEnoughTroops = "NotEnoughTroops",
	NoPath = "NoPath",
	NotEnoughShips = "NotEnoughShips",
	LimitReached = "LimitReached",
	CampaignNotRunning = "CampaignNotRunning",
	StorageUnavailable = "StorageUnavailable",
	SaveConflict = "SaveConflict",
	SaveInProgress = "SaveInProgress",
	NoSave = "NoSave",
	InvalidSave = "InvalidSave",
	InternalError = "InternalError",
})

return Protocol
