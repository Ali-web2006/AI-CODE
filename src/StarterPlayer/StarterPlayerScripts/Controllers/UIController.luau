--!strict
--[[
	UIController — builds the interface and owns presentation state.

	Screen structure:
	  Backdrop  ScreenGui (no insets)       solid backdrop behind everything
	  Main      ScreenGui (core-UI insets)  lobby or game screen, scaled by one UIScale
	  Overlay   ScreenGui (no insets)       tooltips, scaled by the same factor

	Responsive layout: the whole interface is designed at 1280x720 virtual pixels and scaled to the
	viewport (clamped). When the virtual width is narrow (phones, small windows) the compact layout
	narrows the side panel and the navigation rail.

	Presentation state kept here: selected province, active tab, panel visibility. Game state is
	read from the ReplicaStore and changed only by server commands.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local ActionController = require(script.Parent.ActionController)
local MapController = require(script.Parent.MapController)
local StateController = require(script.Parent.StateController)
local UIFolder = script.Parent.Parent.UI
local CampaignMenu = require(UIFolder.CampaignMenu)
local ChroniclePanel = require(UIFolder.ChroniclePanel)
local DiplomacyPanel = require(UIFolder.DiplomacyPanel)
local LobbyScreen = require(UIFolder.LobbyScreen)
local Notifications = require(UIFolder.Notifications)
local ProvincePanel = require(UIFolder.ProvincePanel)
local RealmPanel = require(UIFolder.RealmPanel)
local Theme = require(UIFolder.Theme)
local Tooltip = require(UIFolder.Tooltip)
local TopBar = require(UIFolder.TopBar)
local UI = require(UIFolder.UIComponents)
local UIContext = require(UIFolder.UIContext)

local Colors = Theme.Colors
local Layout = Theme.Layout

local UIController = {}

local store = StateController.store
local scale = 1
local compact = false
local selectedProvinceId: string? = nil
local activeTab: UIContext.Tab = "map"
local panelHidden = false

local function scaledRoot(screenGui: ScreenGui, name: string): (Frame, UIScale)
	local root = UI.create("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = screenGui,
	})
	local uiScale = UI.create("UIScale", { Scale = 1, Parent = root })
	return root, uiScale
end

local function hideDefaultCoreGui()
	for _, coreType in { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Health, Enum.CoreGuiType.EmotesMenu } do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(coreType, false)
		end)
	end
end

function UIController.start()
	hideDefaultCoreGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local backdropGui = UI.create("ScreenGui", {
		Name = "IronThroneBackdrop",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 0,
		Parent = playerGui,
	})
	UI.create("Frame", { BackgroundColor3 = Colors.Backdrop, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = backdropGui })

	local mainGui = UI.create("ScreenGui", {
		Name = "IronThroneMain",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		DisplayOrder = 1,
		Parent = playerGui,
	})
	local overlayGui = UI.create("ScreenGui", {
		Name = "IronThroneOverlay",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
		Parent = playerGui,
	})

	local mainRoot, mainScale = scaledRoot(mainGui, "Root")
	local overlayRoot, overlayScale = scaledRoot(overlayGui, "Root")
	Tooltip.mount(overlayRoot, Theme)

	-- Context shared with every screen --------------------------------------------------------
	local notifications: Notifications.Notifications
	local selectProvince: (string?, boolean?) -> ()
	local showTab: (UIContext.Tab) -> ()
	local focusHouse: (string) -> ()

	local ctx: UIContext.Context = {
		store = store,
		run = function(commandName, payload, key, onDone)
			ActionController.run(commandName, payload, key, onDone)
		end,
		isBusy = ActionController.isBusy,
		selectProvince = function(provinceId, focus)
			selectProvince(provinceId, focus)
		end,
		selectedProvince = function()
			return selectedProvinceId
		end,
		showTab = function(tab)
			showTab(tab)
		end,
		focusHouse = function(houseId)
			focusHouse(houseId)
		end,
		notify = function(text, tone)
			notifications.toast(text, tone)
		end,
		isCompact = function()
			return compact
		end,
	}

	-- Lobby ------------------------------------------------------------------------------------
	local lobby = LobbyScreen.mount(mainRoot, ctx)

	-- Game screen ------------------------------------------------------------------------------
	local gameScreen = UI.create("Frame", { Name = "Game", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = mainRoot })
	local campaignMenu: CampaignMenu.CampaignMenu
	local topBar = TopBar.mount(gameScreen, ctx, function(anchor)
		campaignMenu.toggle(anchor)
	end)

	local bodyArea = UI.create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, Layout.TopBarHeight),
		Size = UDim2.new(1, 0, 1, -Layout.TopBarHeight),
		ZIndex = 1,
		Parent = gameScreen,
	})
	-- Explicit z-order: the map (which may draw rotated route segments that Roblox does not clip)
	-- sits below the navigation rail and the side panel; the top bar sits above the body.
	local nav = UI.create("Frame", { Name = "Nav", BackgroundColor3 = Colors.Chrome, BorderSizePixel = 0, ZIndex = 3, Parent = bodyArea })
	UI.padding(nav, 8, 6)
	UI.list(nav, "vertical", 6, Enum.HorizontalAlignment.Center)
	local mapArea = UI.create("Frame", { Name = "MapArea", BackgroundTransparency = 1, ZIndex = 1, Parent = bodyArea })
	local panelArea = UI.create("Frame", {
		Name = "Panel",
		BackgroundColor3 = Colors.Parchment,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = bodyArea,
	})
	UI.create("Frame", { Name = "Edge", BackgroundColor3 = Colors.Gold, BorderSizePixel = 0, Size = UDim2.new(0, 2, 1, 0), Parent = panelArea })
	local panelContent = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 12), Size = UDim2.new(1, -24, 1, -20), Parent = panelArea })

	notifications = Notifications.mount(mapArea)
	campaignMenu = CampaignMenu.mount(mainRoot, ctx, function()
		return scale
	end)

	MapController.mount(mapArea, {
		store = store,
		getScale = function()
			return scale
		end,
		onSelect = function(provinceId)
			selectProvince(provinceId, false)
		end,
	})

	local provincePanel = ProvincePanel.mount(panelContent, ctx)
	local realmPanel = RealmPanel.mount(panelContent, ctx)
	local diplomacyPanel, focusDiplomacy = DiplomacyPanel.mount(panelContent, ctx)
	local chroniclePanel = ChroniclePanel.mount(panelContent, ctx)
	local panels: { [UIContext.Tab]: UIContext.Panel } = {
		map = provincePanel,
		realm = realmPanel,
		diplomacy = diplomacyPanel,
		chronicle = chroniclePanel,
	}

	-- Navigation -------------------------------------------------------------------------------
	local tabButtons: { [string]: TextButton } = {}
	local tabs: { { id: UIContext.Tab, label: string, tip: string } } = {
		{ id = "map", label = "Map", tip = "The map and the selected province." },
		{ id = "realm", label = "Realm", tip = "Your ruler, family, finances and holdings." },
		{ id = "diplomacy", label = "Diplomacy", tip = "Relations with every other house." },
		{ id = "chronicle", label = "Chronicle", tip = "Everything that has happened." },
	}
	for index, tab in tabs do
		local button = UI.button({
			text = tab.label,
			variant = "chrome",
			size = UDim2.new(1, 0, 0, 40),
			textSize = Theme.TextSize.Small,
			order = index,
			parent = nav,
			onActivated = function()
				panelHidden = false
				showTab(tab.id)
			end,
		})
		Tooltip.setText(button, tab.tip)
		tabButtons[tab.id] = button
	end
	local hideButton = UI.button({
		text = "Hide panel",
		variant = "chrome",
		size = UDim2.new(1, 0, 0, 34),
		textSize = 12,
		order = 99,
		parent = nav,
	})

	local function applyLayout()
		local navWidth = if compact then 72 else Layout.NavWidth
		local panelWidth = if panelHidden then 0 elseif compact then Layout.CompactPanelWidth else Layout.PanelWidth
		nav.Size = UDim2.new(0, navWidth, 1, 0)
		mapArea.Position = UDim2.fromOffset(navWidth, 0)
		mapArea.Size = UDim2.new(1, -(navWidth + panelWidth), 1, 0)
		panelArea.Visible = not panelHidden
		panelArea.Position = UDim2.new(1, -panelWidth, 0, 0)
		panelArea.Size = UDim2.new(0, panelWidth, 1, 0)
		hideButton.Text = if panelHidden then "Show panel" else "Hide panel"
	end

	hideButton.Activated:Connect(function()
		panelHidden = not panelHidden
		applyLayout()
	end)

	showTab = function(tab)
		activeTab = tab
		for id, button in tabButtons do
			UI.setSelected(button, id == tab)
		end
		for id, panel in panels do
			panel.setVisible(id == tab and not panelHidden)
		end
		applyLayout()
	end

	selectProvince = function(provinceId, focus)
		selectedProvinceId = provinceId
		MapController.select(provinceId)
		if provinceId then
			if focus then
				MapController.focusProvince(provinceId)
			end
			panelHidden = false
			showTab("map")
		elseif activeTab == "map" then
			provincePanel.setVisible(true)
		end
	end

	focusHouse = function(houseId)
		panelHidden = false
		focusDiplomacy(houseId)
		showTab("diplomacy")
	end

	-- Responsive scaling -----------------------------------------------------------------------
	local function onViewportChanged()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local viewport = camera.ViewportSize
		scale = math.clamp(math.min(viewport.X / Layout.DesignWidth, viewport.Y / Layout.DesignHeight), 0.6, 1.5)
		mainScale.Scale = scale
		overlayScale.Scale = scale
		mainRoot.Size = UDim2.fromScale(1 / scale, 1 / scale)
		overlayRoot.Size = UDim2.fromScale(1 / scale, 1 / scale)
		Tooltip.setScale(scale)
		compact = viewport.X / scale < Layout.CompactBreakpoint
		applyLayout()
	end
	local function watchCamera()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(onViewportChanged)
		end
		onViewportChanged()
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	-- Screen switching and state updates -------------------------------------------------------
	-- The province holding the house seat (e.g. Winterfell for House Stark), else the first one.
	local function seatProvince(houseId: string): string?
		local house = store:house(houseId)
		if not house then
			return nil
		end
		local seatName = Content.houses[houseId].seatName
		for _, provinceId in house.provinceIds do
			if Content.provinces[provinceId].holding.name == seatName then
				return provinceId
			end
		end
		return house.provinceIds[1]
	end

	local inGame = false
	local lobbyShown = false
	local currentHouseId: string? = nil
	local function syncScreen()
		if not store.ready then
			return
		end
		local houseId = store:myHouseId()
		if houseId then
			if not inGame then
				inGame = true
				lobbyShown = false
				lobby.setVisible(false)
				gameScreen.Visible = true
				showTab("map")
			end
			if houseId ~= currentHouseId then
				-- New house (first selection, or restored by a campaign load): centre on its seat.
				currentHouseId = houseId
				local seat = seatProvince(houseId)
				if seat then
					selectProvince(seat, false)
					MapController.focusProvince(seat, 0.75)
				end
			end
		else
			currentHouseId = nil
			if inGame then
				inGame = false
				gameScreen.Visible = false
				campaignMenu.close()
			end
			if not lobbyShown then
				lobbyShown = true
				lobby.setVisible(true)
			end
		end
	end

	store.changed:Connect(function(changes)
		if changes.full or changes.session then
			syncScreen()
		end
		-- Each view updates in isolation: an error in one must not stop the others refreshing.
		local function safely(label: string, fn: () -> ())
			local ok, err = xpcall(fn, debug.traceback)
			if not ok then
				warn(`[IronThrone][UI] {label} failed to update: {err}`)
			end
		end
		safely("lobby", function()
			lobby.update(changes)
		end)
		if inGame then
			safely("top bar", function()
				topBar.update(changes)
			end)
			safely("map", function()
				MapController.refresh(changes)
			end)
			for tab, panel in panels do
				safely(`{tab} panel`, function()
					panel.update(changes)
				end)
			end
		end
		-- Toasts for important events; routine ones only reach the chronicle.
		for _, event in changes.events do
			local text, tone = EventText.format(event, store:myHouseId())
			if tone ~= "quiet" then
				notifications.toast(text, tone)
			end
		end
	end)

	ActionController.resultReported:Connect(function(_commandName, result)
		if not result.ok then
			notifications.toast(result.message, "bad")
		end
		-- Re-render the visible panel so busy/disabled states reflect the outcome.
		if inGame then
			local panel = panels[activeTab]
			if panel and not panelHidden then
				panel.setVisible(true)
			end
		end
	end)
end

return UIController
