--!strict
--[[
	UIContext — the contract between UIController and the screens/panels it hosts. Panels receive
	a Context instead of requiring UIController (which would be circular), so each panel's
	dependencies are explicit.

	Presentation state (selected province, selected army, a pending move order, active tab, panel
	visibility) lives in UIController. Game state is read only from `store` and changed only
	through `run` (server commands).
]]

local ReplicaStore = require(script.Parent.Parent.Controllers.ReplicaStore)

export type Tab = "map" | "realm" | "military" | "diplomacy" | "chronicle"

export type Context = {
	store: ReplicaStore.ReplicaStore,
	-- Sends a command to the server; `key` identifies the button for busy tracking.
	run: (commandName: string, payload: { [string]: any }?, key: string?, onDone: ((result: any) -> ())?) -> (),
	isBusy: (key: string) -> boolean,
	selectProvince: (provinceId: string?, focus: boolean?) -> (),
	selectedProvince: () -> string?,
	-- Selects an army (any house's) and opens the Military tab; `focus` centres the map on it.
	-- nil clears the army selection.
	selectArmy: (armyId: string?, focus: boolean?) -> (),
	selectedArmy: () -> string?,
	-- Move mode for one of the player's armies: the next click on land sends the march order;
	-- a right-click, Esc or cancelMoveOrder ends it without an order.
	beginMoveOrder: (armyId: string) -> (),
	cancelMoveOrder: () -> (),
	-- The army waiting for a destination, if move mode is on.
	pendingMoveOrder: () -> string?,
	-- Shows a tab (and the side panel if it was hidden).
	showTab: (tab: Tab) -> (),
	focusHouse: (houseId: string) -> (),
	notify: (text: string, tone: string) -> (),
	isCompact: () -> boolean,
}

export type Panel = {
	update: (changes: ReplicaStore.ChangeSet) -> (),
	setVisible: (visible: boolean) -> (),
}

return {}
