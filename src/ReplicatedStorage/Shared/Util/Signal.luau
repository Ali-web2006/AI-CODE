--!strict
--[[
	Signal — a minimal synchronous event implementation in pure Luau (no BindableEvent), so the
	same code runs in Roblox and in headless tests.

	A failing handler is reported with a traceback and does not prevent other handlers from
	running or corrupt the caller's state.
]]

export type Connection = {
	Disconnect: (self: Connection) -> (),
	connected: boolean,
}

local Signal = {}
Signal.__index = Signal

type SignalData = {
	_handlers: { { fn: (...any) -> (), connection: Connection } },
}

export type Signal = typeof(setmetatable({} :: SignalData, Signal))

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): Connection
	local connection = { connected = true } :: any
	local handlers = self._handlers
	local entry = { fn = fn, connection = connection }
	function connection.Disconnect(this: Connection)
		if not this.connected then
			return
		end
		this.connected = false
		local index = table.find(handlers, entry)
		if index then
			table.remove(handlers, index)
		end
	end
	table.insert(handlers, entry)
	return connection
end

function Signal.Fire(self: Signal, ...: any)
	-- Snapshot so handlers may disconnect during dispatch.
	for _, entry in table.clone(self._handlers) do
		if entry.connection.connected then
			local failure: string? = nil
			local ok = xpcall(entry.fn, function(message: any)
				failure = debug.traceback(tostring(message), 2)
			end, ...)
			if not ok then
				warn(`[IronThrone][Signal] handler failed: {failure}`)
			end
		end
	end
end

function Signal.DisconnectAll(self: Signal)
	for _, entry in self._handlers do
		entry.connection.connected = false
	end
	table.clear(self._handlers)
end

return Signal
