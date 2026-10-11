--!strict
--[[
	StateController — keeps the ReplicaStore synchronised with the server.

	Startup: subscribe to deltas first (buffering them), then request the full snapshot, then
	replay buffered deltas newer than the snapshot. A sequence gap or a server "resync" marker
	triggers a fresh snapshot. Snapshots are retried with backoff if the server declines.
]]

local NetClient = require(script.Parent.NetClient)
local ReplicaStore = require(script.Parent.ReplicaStore)

local StateController = {}

local store = ReplicaStore.new()
local buffered: { { [string]: any } } = {}
local syncing = false

StateController.store = store

local function resync()
	if syncing then
		return
	end
	syncing = true
	task.spawn(function()
		local delay = 0.5
		while true do
			local snapshot = NetClient.sync()
			if snapshot then
				store:applyFull(snapshot)
				-- Replay deltas that arrived while the snapshot was in flight.
				local pending = buffered
				buffered = {}
				table.sort(pending, function(a, b)
					return (a.seq or 0) < (b.seq or 0)
				end)
				syncing = false
				for _, payload in pending do
					StateController.receive(payload)
				end
				return
			end
			task.wait(delay)
			delay = math.min(delay * 2, 8)
		end
	end)
end

function StateController.receive(payload: { [string]: any })
	if syncing then
		table.insert(buffered, payload)
		return
	end
	local outcome = store:applyDelta(payload)
	if outcome == "gap" or outcome == "resync" then
		resync()
	elseif outcome == "notready" then
		table.insert(buffered, payload)
	end
end

function StateController.start()
	NetClient.onDelta(StateController.receive)
	resync()
end

return StateController
