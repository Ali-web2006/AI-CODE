--!strict
--[[
	Diagnostics — structured server logging: "[IronThrone][Subsystem] message".

	Expected rejections (a player clicking an unaffordable button repeatedly) are logged through
	`throttled`, which emits a given key at most once per window so the output is never flooded.
	The sink is injected: Roblox prints to the output window; tests capture lines for assertions.
]]

export type Level = "info" | "warn" | "error"
export type Sink = (level: Level, line: string) -> ()

local Diagnostics = {}
Diagnostics.__index = Diagnostics

type DiagnosticsData = {
	_sink: Sink,
	_now: () -> number,
	_window: number,
	_lastEmitted: { [string]: number },
}

export type Diagnostics = typeof(setmetatable({} :: DiagnosticsData, Diagnostics))

function Diagnostics.new(sink: Sink, now: () -> number, throttleWindow: number): Diagnostics
	return setmetatable({
		_sink = sink,
		_now = now,
		_window = throttleWindow,
		_lastEmitted = {},
	}, Diagnostics)
end

-- A sink that discards everything (for tests that do not inspect logs).
function Diagnostics.silent(): Diagnostics
	return Diagnostics.new(function() end, function()
		return 0
	end, 0)
end

function Diagnostics.emit(self: Diagnostics, level: Level, subsystem: string, message: string)
	self._sink(level, `[IronThrone][{subsystem}] {message}`)
end

function Diagnostics.info(self: Diagnostics, subsystem: string, message: string)
	self:emit("info", subsystem, message)
end

function Diagnostics.warn(self: Diagnostics, subsystem: string, message: string)
	self:emit("warn", subsystem, message)
end

function Diagnostics.error(self: Diagnostics, subsystem: string, message: string)
	self:emit("error", subsystem, message)
end

function Diagnostics.throttled(self: Diagnostics, key: string, level: Level, subsystem: string, message: string)
	local now = self._now()
	local last = self._lastEmitted[key]
	if last and now - last < self._window then
		return
	end
	self._lastEmitted[key] = now
	self:emit(level, subsystem, message)
end

return Diagnostics
