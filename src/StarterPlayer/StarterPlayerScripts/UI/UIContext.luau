--!strict
--[[
	UIContext — the contract between UIController and the screens/panels it hosts. Panels receive
	a Context instead of requiring UIController (which would be circular), so each panel's
	dependencies are explicit.

	Presentation state (selected province, active tab, panel visibility) lives in UIController.
	Game state is read only from `store` and changed only through `run` (server commands).
]]

local ReplicaStore = require(script.Parent.Parent.Controllers.ReplicaStore)

export type Tab = "map" | "realm" | "diplomacy" | "chronicle"

export type Context = {
	store: ReplicaStore.ReplicaStore,
	-- Sends a command to the server; `key` identifies the button for busy tracking.
	run: (commandName: string, payload: { [string]: any }?, key: string?, onDone: ((result: any) -> ())?) -> (),
	isBusy: (key: string) -> boolean,
	selectProvince: (provinceId: string?, focus: boolean?) -> (),
	selectedProvince: () -> string?,
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
