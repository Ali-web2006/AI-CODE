--!strict
--[[
	LobbyScreen — choose a house to lead (or, for the host, continue a saved campaign).

	Every card shows the house's real starting situation from the server snapshot: ruler, provinces,
	treasury and monthly income, and whether another player already leads it or it is reserved for
	a disconnected player. Selecting a house sends SelectHouse; the server decides.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local CharacterRules = require(ReplicatedStorage.Shared.Rules.CharacterRules)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local CampaignMenu = require(script.Parent.CampaignMenu)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts
local Commands = Protocol.Commands

local LobbyScreen = {}

local function houseStatus(store: any, houseId: string): (string, boolean)
	local player = store:playerForHouse(houseId)
	if player then
		return `Led by {player.name}`, false
	end
	for _, reserved in store.session.reservedHouseIds or {} do
		if reserved == houseId then
			return "Reserved for a returning player", false
		end
	end
	local definition = Content.houses[houseId]
	if not definition.playable then
		return "Not playable", false
	end
	return "Available", true
end

function LobbyScreen.mount(parent: Frame, ctx: UIContext.Context): UIContext.Panel
	local store = ctx.store
	local root = UI.create("Frame", {
		Name = "Lobby",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Colors.Backdrop,
		BorderSizePixel = 0,
		Visible = false,
		Parent = parent,
	})
	UI.create("UIGradient", {
		Color = ColorSequence.new(Colors.Burgundy, Colors.Backdrop),
		Rotation = 90,
		Parent = root,
	})

	local column = UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.new(1, -40, 1, -32),
		BackgroundTransparency = 1,
		Parent = root,
	})
	UI.create("UISizeConstraint", { MaxSize = Vector2.new(1200, math.huge), Parent = column })

	local title = UI.label({ text = "Iron Throne", size = Theme.TextSize.Display, font = Fonts.Title, color = Colors.GoldBright, align = Enum.TextXAlignment.Center, parent = column })
	title.Size = UDim2.new(1, 0, 0, 54)
	local subtitle = UI.label({ text = "", size = Theme.TextSize.Body, font = Fonts.SerifItalic, color = Colors.MutedOnDark, align = Enum.TextXAlignment.Center, parent = column })
	subtitle.Position = UDim2.fromOffset(0, 56)
	subtitle.Size = UDim2.new(1, 0, 0, 22)

	local body = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 90), Size = UDim2.new(1, 0, 1, -90), Parent = column })
	local gridScroll = UI.scroll({ Size = UDim2.new(0.6, -10, 1, 0), Parent = body })
	local grid = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = gridScroll })
	local gridLayout = UI.create("UIGridLayout", {
		CellSize = UDim2.new(0.5, -6, 0, 132),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})

	local detail = UI.create("Frame", {
		BackgroundColor3 = Colors.Parchment,
		Position = UDim2.fromScale(0.6, 0),
		Size = UDim2.fromScale(0.4, 1),
		Parent = body,
	})
	UI.corner(detail)
	UI.stroke(detail, Colors.Gold, 1.5)
	local detailScroll = UI.scroll({ Parent = detail })
	UI.padding(detailScroll, 14)
	local detailContent = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = detailScroll })
	UI.list(detailContent, "vertical", 8)

	local highlighted: string? = nil
	local saveInfoText = "Checking for a saved campaign..."
	local saveInfoRequested = false
	local visible = false
	local render: () -> ()

	local function requestSaveInfo()
		local persistence = store.session.persistence
		if saveInfoRequested or not store.session.isHost or not (persistence and persistence.available) then
			return
		end
		saveInfoRequested = true
		ctx.run(Commands.GetSaveInfo, nil, "lobby-saveinfo", function(result)
			saveInfoText = CampaignMenu.describeSave(result)
			if result.ok and result.data and not result.data.exists then
				saveInfoText = "No saved campaign yet."
			end
			if visible then
				render()
			end
		end)
	end

	local function renderCards()
		for _, child in grid:GetChildren() do
			if not child:IsA("UIGridLayout") then
				child:Destroy()
			end
		end
		local clock = store.campaign.clock
		local ordered = table.clone(Content.houseIds)
		table.sort(ordered, function(a, b)
			local ha, hb = Content.houses[a], Content.houses[b]
			if ha.tier ~= hb.tier then
				return ha.tier == "great"
			end
			return ha.name < hb.name
		end)
		for index, houseId in ordered do
			local definition = Content.houses[houseId]
			local view = store:house(houseId)
			if not view then
				continue
			end
			local status, available = houseStatus(store, houseId)
			local card = UI.create("TextButton", {
				AutoButtonColor = false,
				Text = "",
				BackgroundColor3 = if houseId == highlighted then Colors.ParchmentDeep else Colors.Parchment,
				LayoutOrder = index,
				Parent = grid,
			})
			UI.corner(card)
			UI.stroke(card, if houseId == highlighted then Colors.GoldBright else Colors.ParchmentEdge, if houseId == highlighted then 2.5 else 1)
			UI.padding(card, 10)
			UI.shield(houseId, 40, card)
			local name = UI.label({ text = definition.name, font = Fonts.Heading, size = Theme.TextSize.Body, parent = card })
			name.Position = UDim2.fromOffset(50, 0)
			name.Size = UDim2.new(1, -50, 0, 20)
			local tierText = if definition.tier == "great" then "Great House" else "Minor House"
			local tier = UI.label({ text = `{tierText} · {definition.seatName}`, size = Theme.TextSize.Small, color = Colors.InkMuted, parent = card })
			tier.Position = UDim2.fromOffset(50, 20)
			tier.Size = UDim2.new(1, -50, 0, 18)
			local ruler = store:character(view.rulerId)
			local rulerText = if ruler and clock then `{CharacterRules.displayName(ruler :: any)}, {CharacterRules.age(ruler :: any, clock.date)}` else ""
			local rulerLabel = UI.label({ text = rulerText, size = Theme.TextSize.Small, parent = card })
			rulerLabel.Position = UDim2.fromOffset(0, 50)
			rulerLabel.Size = UDim2.new(1, 0, 0, 18)
			local economy = UI.label({
				text = `{#view.provinceIds} provinces · {Format.gold(view.treasury, 0)} gold · {Format.signed(view.budget.net)}/month`,
				size = Theme.TextSize.Small,
				color = Colors.InkMuted,
				parent = card,
			})
			economy.Position = UDim2.fromOffset(0, 70)
			economy.Size = UDim2.new(1, 0, 0, 18)
			local statusLabel = UI.label({
				text = status,
				size = Theme.TextSize.Small,
				font = Fonts.BodyBold,
				color = if available then Colors.Positive else Colors.Negative,
				parent = card,
			})
			statusLabel.Position = UDim2.fromOffset(0, 92)
			statusLabel.Size = UDim2.new(1, 0, 0, 18)
			card.Activated:Connect(function()
				highlighted = houseId
				render()
			end)
		end
	end

	local function renderDetail()
		for _, child in detailContent:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
		local session = store.session
		local clock = store.campaign.clock

		-- Saved campaign (host only).
		if session.isHost then
			local persistence = session.persistence or {}
			local saveCard = UI.card({ LayoutOrder = 1, Parent = detailContent, BackgroundColor3 = Colors.ParchmentDeep })
			UI.padding(saveCard, 10)
			UI.list(saveCard, "vertical", 6)
			UI.label({ text = "Continue a campaign", font = Fonts.Heading, size = Theme.TextSize.Body, order = 1, parent = saveCard })
			UI.label({ text = CampaignMenu.storageDescription(session), wrap = true, size = Theme.TextSize.Small, color = Colors.InkMuted, order = 2, parent = saveCard })
			if persistence.available then
				UI.label({ text = saveInfoText, wrap = true, size = Theme.TextSize.Small, order = 3, parent = saveCard })
				local loadButton = UI.button({
					text = "Load saved campaign",
					variant = "secondary",
					order = 4,
					parent = saveCard,
					onActivated = function()
						ctx.run(Commands.LoadCampaign, nil, "lobby-load")
					end,
				})
				if not string.find(saveInfoText, "Last save", 1, true) then
					UI.setEnabled(loadButton, false, "There is no saved campaign to load.")
				end
			end
		end

		if not highlighted then
			UI.label({ text = "Choose your house", font = Fonts.Heading, size = Theme.TextSize.Title, order = 2, parent = detailContent })
			UI.label({
				text = "Every house begins with different lands, wealth, rulers and rivalries. Great houses command more; minor houses must be cleverer. Select a house on the left to read its situation.",
				wrap = true,
				color = Colors.InkMuted,
				order = 3,
				parent = detailContent,
			})
		else
			local houseId = highlighted
			local definition = Content.houses[houseId]
			local view = store:house(houseId)
			local header = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 74), LayoutOrder = 2, Parent = detailContent })
			UI.shield(houseId, 60, header)
			local name = UI.label({ text = definition.name, font = Fonts.Heading, size = Theme.TextSize.Title, parent = header })
			name.Position = UDim2.fromOffset(72, 6)
			name.Size = UDim2.new(1, -72, 0, 30)
			local words = UI.label({ text = `"{definition.words}"`, font = Fonts.SerifItalic, size = Theme.TextSize.Small, color = Colors.InkMuted, parent = header })
			words.Position = UDim2.fromOffset(72, 38)
			words.Size = UDim2.new(1, -72, 0, 18)
			UI.label({ text = definition.description, wrap = true, order = 3, parent = detailContent })

			if view and clock then
				local ruler = store:character(view.rulerId)
				if ruler then
					local traitNames = {}
					for _, traitId in ruler.traits do
						local trait = Content.traits[traitId]
						table.insert(traitNames, trait and trait.name or traitId)
					end
					UI.label({
						text = `<b>Ruler:</b> {Format.escape(CharacterRules.displayName(ruler :: any))}, age {CharacterRules.age(ruler :: any, clock.date)} ({table.concat(traitNames, ", ")}). Diplomacy {ruler.skills.diplomacy}, Stewardship {ruler.skills.stewardship}.`,
						rich = true,
						wrap = true,
						size = Theme.TextSize.Small,
						order = 4,
						parent = detailContent,
					})
				end
				local stats = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = detailContent })
				UI.list(stats, "vertical", 1)
				UI.statRow("Provinces", tostring(#view.provinceIds), 1, stats)
				UI.statRow("Treasury", `{Format.gold(view.treasury)} gold`, 2, stats)
				UI.statRow("Net income", `{Format.signed(view.budget.net)} gold per month`, 3, stats)
				UI.statRow("Total development", tostring(view.totalDevelopment), 4, stats)
			end

			local status, available = houseStatus(store, houseId)
			local begin = UI.button({
				text = `Lead {definition.name}`,
				variant = "primary",
				size = UDim2.new(1, 0, 0, 42),
				order = 6,
				parent = detailContent,
				onActivated = function()
					ctx.run(Commands.SelectHouse, { houseId = houseId }, "select-house")
				end,
			})
			if not available then
				UI.setEnabled(begin, false, status)
			else
				Tooltip.setText(begin, "The campaign starts paused. The host starts the clock.")
			end
		end

		-- Players connected.
		UI.sectionHeader("Players in this realm", 20, detailContent)
		for index, player in session.players or {} do
			local houseName = player.houseId and Content.houses[player.houseId] and Content.houses[player.houseId].name or "choosing a house"
			UI.label({
				text = `{player.name}{if player.isHost then " (host)" else ""} · {houseName}`,
				size = Theme.TextSize.Small,
				order = 20 + index,
				parent = detailContent,
			})
		end
	end

	render = function()
		local bookmark = store.campaign.bookmarkId and Content.getBookmark(store.campaign.bookmarkId)
		local clock = store.campaign.clock
		if bookmark and clock then
			subtitle.Text = `{bookmark.name} · {CalendarDate.format(clock.date)} · Grand strategy in the Seven Kingdoms`
		end
		local compact = ctx.isCompact()
		gridLayout.CellSize = if compact then UDim2.new(1, -4, 0, 132) else UDim2.new(0.5, -6, 0, 132)
		renderCards()
		renderDetail()
		requestSaveInfo()
	end

	local panel: UIContext.Panel = {
		update = function(changes)
			if visible and (changes.full or changes.session or next(changes.houses) ~= nil) then
				render()
			end
		end,
		setVisible = function(isVisible)
			visible = isVisible
			root.Visible = isVisible
			if isVisible then
				saveInfoRequested = false
				render()
			end
		end,
	}
	return panel
end

return LobbyScreen
