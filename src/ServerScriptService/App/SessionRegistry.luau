--!strict
--[[
	SessionRegistry — player session state, kept separate from campaign state.

	Rules (docs/ARCHITECTURE.md §Multiplayer):
	  * A player controls at most one house; a house is controlled by at most one player.
	  * The host is the longest-connected player. When the host leaves, the next
	    longest-connected player becomes host. The host controls speed and unpausing.
	  * When a player disconnects, their house is reserved for them for
	    Sessions.ReconnectReservationSeconds. During that window nobody else may claim it, the AI
	    governs it (if AiGovernsDisconnectedHouses), and the player is restored to it on rejoin.

	Pure Luau: time is injected, players are identified by userId.
]]

type SessionsConfig = {
	ReconnectReservationSeconds: number,
	AiGovernsDisconnectedHouses: boolean,
}

export type Session = {
	userId: number,
	name: string,
	joinOrder: number,
	houseId: string?,
}

type Reservation = {
	userId: number,
	expiresAt: number,
}

local SessionRegistry = {}
SessionRegistry.__index = SessionRegistry

type SessionRegistryData = {
	config: SessionsConfig,
	now: () -> number,
	sessions: { [number]: Session },
	controllers: { [string]: number },
	reservations: { [string]: Reservation },
	joinCounter: number,
}

export type SessionRegistry = typeof(setmetatable({} :: SessionRegistryData, SessionRegistry))

export type ClaimResult = {
	ok: boolean,
	code: string,
	message: string,
}

function SessionRegistry.new(config: SessionsConfig, now: () -> number): SessionRegistry
	return setmetatable({
		config = config,
		now = now,
		sessions = {},
		controllers = {},
		reservations = {},
		joinCounter = 0,
	}, SessionRegistry)
end

function SessionRegistry.pruneReservations(self: SessionRegistry)
	local now = self.now()
	for houseId, reservation in self.reservations do
		if now >= reservation.expiresAt then
			self.reservations[houseId] = nil
		end
	end
end

-- Registers a connecting player (idempotent). Callers use reservedHouseFor afterwards to restore a
-- reconnecting player's house.
function SessionRegistry.join(self: SessionRegistry, userId: number, name: string): Session
	self:pruneReservations()
	local existing = self.sessions[userId]
	if existing then
		return existing
	end
	self.joinCounter += 1
	local session: Session = { userId = userId, name = name, joinOrder = self.joinCounter, houseId = nil }
	self.sessions[userId] = session
	return session
end

function SessionRegistry.reservedHouseFor(self: SessionRegistry, userId: number): string?
	self:pruneReservations()
	for houseId, reservation in self.reservations do
		if reservation.userId == userId then
			return houseId
		end
	end
	return nil
end

function SessionRegistry.leave(self: SessionRegistry, userId: number)
	local session = self.sessions[userId]
	if not session then
		return
	end
	if session.houseId then
		self.controllers[session.houseId] = nil
		self.reservations[session.houseId] = {
			userId = userId,
			expiresAt = self.now() + self.config.ReconnectReservationSeconds,
		}
	end
	self.sessions[userId] = nil
end

function SessionRegistry.claimHouse(self: SessionRegistry, userId: number, houseId: string, isClaimable: (houseId: string) -> (boolean, string?)): ClaimResult
	self:pruneReservations()
	local session = self.sessions[userId]
	if not session then
		return { ok = false, code = "NotAuthorized", message = "You are not connected to this campaign." }
	end
	if session.houseId ~= nil then
		return { ok = false, code = "AlreadyHasHouse", message = "You already lead a house." }
	end
	local claimable, reason = isClaimable(houseId)
	if not claimable then
		return { ok = false, code = "HouseUnavailable", message = reason or "That house cannot be chosen." }
	end
	local controller = self.controllers[houseId]
	if controller ~= nil and controller ~= userId then
		return { ok = false, code = "HouseUnavailable", message = "Another player already leads that house." }
	end
	local reservation = self.reservations[houseId]
	if reservation and reservation.userId ~= userId then
		return { ok = false, code = "HouseUnavailable", message = "That house is reserved for a player who disconnected." }
	end
	self.reservations[houseId] = nil
	self.controllers[houseId] = userId
	session.houseId = houseId
	return { ok = true, code = "Ok", message = "" }
end

-- Clears every claim (used when a different campaign is loaded and houses may no longer exist).
function SessionRegistry.releaseAll(self: SessionRegistry)
	for _, session in self.sessions do
		session.houseId = nil
	end
	table.clear(self.controllers)
	table.clear(self.reservations)
end

function SessionRegistry.release(self: SessionRegistry, userId: number)
	local session = self.sessions[userId]
	if session and session.houseId then
		self.controllers[session.houseId] = nil
		session.houseId = nil
	end
end

function SessionRegistry.session(self: SessionRegistry, userId: number): Session?
	return self.sessions[userId]
end

function SessionRegistry.houseOf(self: SessionRegistry, userId: number): string?
	local session = self.sessions[userId]
	return session and session.houseId
end

function SessionRegistry.controllerOf(self: SessionRegistry, houseId: string): number?
	return self.controllers[houseId]
end

function SessionRegistry.isHumanControlled(self: SessionRegistry, houseId: string): boolean
	if self.controllers[houseId] ~= nil then
		return true
	end
	if not self.config.AiGovernsDisconnectedHouses then
		self:pruneReservations()
		return self.reservations[houseId] ~= nil
	end
	return false
end

function SessionRegistry.isReserved(self: SessionRegistry, houseId: string): boolean
	self:pruneReservations()
	return self.reservations[houseId] ~= nil
end

function SessionRegistry.hostUserId(self: SessionRegistry): number?
	local host: Session? = nil
	for _, session in self.sessions do
		if host == nil or session.joinOrder < host.joinOrder then
			host = session
		end
	end
	return host and host.userId
end

function SessionRegistry.isHost(self: SessionRegistry, userId: number): boolean
	return self:hostUserId() == userId
end

function SessionRegistry.claimedCount(self: SessionRegistry): number
	local count = 0
	for _ in self.controllers do
		count += 1
	end
	return count
end

-- Connected players ordered by join order (stable for UI lists).
function SessionRegistry.list(self: SessionRegistry): { Session }
	local list = {}
	for _, session in self.sessions do
		table.insert(list, session)
	end
	table.sort(list, function(a, b)
		return a.joinOrder < b.joinOrder
	end)
	return list
end

return SessionRegistry
