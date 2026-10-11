--!strict
--[[
	Client bootstrap: connects to the server's remotes, builds the interface and starts state
	synchronisation. The client renders server state and sends requests; it never advances time or
	decides outcomes.
]]

local Controllers = script.Parent:WaitForChild("Controllers")
local NetClient = require(Controllers:WaitForChild("NetClient"))
local StateController = require(Controllers:WaitForChild("StateController"))
local UIController = require(Controllers:WaitForChild("UIController"))

NetClient.connect()
UIController.start()
StateController.start()
