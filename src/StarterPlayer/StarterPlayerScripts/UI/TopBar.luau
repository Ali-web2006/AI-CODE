--!strict
--[[
	TopBar — house identity, treasury, troops, holdings, campaign date and time controls.

	Every number is server-supplied. The treasury tooltip explains the monthly budget line by line
	using the breakdown the server computed; the troops tooltip breaks the house's men down into
	armies, levies, garrisons and ships, and a click on it opens the Military tab. Time controls
	follow the host policy; buttons that the player may not use are disabled with an explanation
	instead of hidden.

	Width at the 1280 design size: the stats group (treasury 130, troops 140, holdings 120, gaps
	18) ends at x 746, before the right-hand group (about 508 px, right-aligned at 1270). The
	troops block is the widest so its caption fits "Troops · 12 armies". The compact layout hides
	holdings.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local CharacterRules = require(ReplicatedStorage.Shared.Rules.CharacterRules)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts
local Commands = Protocol.Commands

local TopBar = {}

local SPEED_NAMES = { "Normal speed", "Fast", "Very fast" }

function TopBar.mount(parent: Frame, ctx: UIContext.Context, onCampaignMenu: (anchor: GuiObject) -> ()): UIContext.Panel
	local store = ctx.store
	local bar = UI.create("Frame", {
		Name = "TopBar",
		BackgroundColor3 = Colors.Chrome,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.Layout.TopBarHeight),
		ZIndex = 5,
		Parent = parent,
	})
	UI.create("Frame", {
		Name = "GoldRule",
		BackgroundColor3 = Colors.Gold,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -2),
		Size = UDim2.new(1, 0, 0, 2),
		Parent = bar,
	})

	-- Left: identity -------------------------------------------------------------------------
	local identity = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 300, 1, -2), Parent = bar })
	local shieldHolder = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 9), Size = UDim2.fromOffset(34, 40), Parent = identity })
	local houseLabel = UI.label({ text = "", size = Theme.TextSize.Large, font = Fonts.Heading, color = Colors.TextOnDark, parent = identity })
	houseLabel.Position = UDim2.fromOffset(44, 8)
	houseLabel.Size = UDim2.new(1, -44, 0, 22)
	local rulerLabel = UI.label({ text = "", size = Theme.TextSize.Small, color = Colors.MutedOnDark, parent = identity })
	rulerLabel.Position = UDim2.fromOffset(44, 31)
	rulerLabel.Size = UDim2.new(1, -44, 0, 18)

	-- Middle: stats ----------------------------------------------------------------------------
	local stats = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(320, 0), Size = UDim2.new(0, 430, 1, -2), Parent = bar })
	UI.list(stats, "horizontal", 18)

	local function statBlock(order: number, width: number): (TextButton, TextLabel, TextLabel)
		local block = UI.create("TextButton", {
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Size = UDim2.new(0, width, 1, 0),
			LayoutOrder = order,
			Parent = stats,
		})
		local value = UI.label({ text = "", size = Theme.TextSize.Large, font = Fonts.Heading, color = Colors.GoldBright, parent = block })
		value.Position = UDim2.fromOffset(0, 8)
		value.Size = UDim2.new(1, 0, 0, 22)
		local caption = UI.label({ text = "", size = Theme.TextSize.Small, color = Colors.MutedOnDark, parent = block })
		caption.Position = UDim2.fromOffset(0, 31)
		caption.Size = UDim2.new(1, 0, 0, 18)
		return block, value, caption
	end

	local treasuryBlock, treasuryValue, treasuryCaption = statBlock(1, 130)
	local coin = UI.create("Frame", { BackgroundColor3 = Colors.Gold, Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(0, 13), Parent = treasuryBlock })
	UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = coin })
	UI.stroke(coin, Colors.GoldBright, 1)
	treasuryValue.Position = UDim2.fromOffset(20, 8)
	treasuryValue.Size = UDim2.new(1, -20, 0, 22)
	treasuryCaption.Position = UDim2.fromOffset(20, 31)
	treasuryCaption.Size = UDim2.new(1, -20, 0, 18)

	-- Troops: a small banner on a staff, like the army tokens on the map.
	local troopsBlock, troopsValue, troopsCaption = statBlock(2, 140)
	troopsBlock.Name = "Troops"
	UI.create("Frame", { BackgroundColor3 = Colors.GoldBright, BorderSizePixel = 0, Size = UDim2.fromOffset(2, 17), Position = UDim2.fromOffset(1, 11), Parent = troopsBlock })
	local flag = UI.create("Frame", { BackgroundColor3 = Colors.BurgundyBright, BorderSizePixel = 0, Size = UDim2.fromOffset(11, 8), Position = UDim2.fromOffset(3, 11), Parent = troopsBlock })
	UI.stroke(flag, Colors.GoldBright, 1)
	troopsValue.Position = UDim2.fromOffset(20, 8)
	troopsValue.Size = UDim2.new(1, -20, 0, 22)
	troopsCaption.Position = UDim2.fromOffset(20, 31)
	troopsCaption.Size = UDim2.new(1, -20, 0, 18)
	troopsBlock.Activated:Connect(function()
		ctx.showTab("military")
	end)

	local holdingsBlock, holdingsValue, holdingsCaption = statBlock(3, 120)

	-- Right: date, time controls, campaign menu -------------------------------------------------
	local right = UI.create("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.new(0, 470, 1, -2),
		Parent = bar,
	})
	local rightLayout = UI.list(right, "horizontal", 8, Enum.HorizontalAlignment.Right)
	rightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right

	local dateBlock = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, 170, 1, 0), LayoutOrder = 1, Parent = right })
	local dateLabel = UI.label({ text = "", size = Theme.TextSize.Large, font = Fonts.Heading, color = Colors.TextOnDark, align = Enum.TextXAlignment.Right, parent = dateBlock })
	dateLabel.Position = UDim2.fromOffset(0, 8)
	dateLabel.Size = UDim2.new(1, 0, 0, 22)
	local statusLabel = UI.label({ text = "", size = Theme.TextSize.Small, font = Fonts.BodyBold, color = Colors.MutedOnDark, align = Enum.TextXAlignment.Right, parent = dateBlock })
	statusLabel.Position = UDim2.fromOffset(0, 31)
	statusLabel.Size = UDim2.new(1, 0, 0, 18)

	local pauseButton = UI.button({
		text = "Pause",
		variant = "primary",
		size = UDim2.fromOffset(86, 34),
		order = 2,
		parent = right,
		onActivated = function()
			local paused = store.campaign.clock and store.campaign.clock.paused
			ctx.run(Commands.SetPaused, { paused = not paused }, "pause")
		end,
	})
	local speedButtons: { TextButton } = {}
	for speed = 1, #GameConfig.Clock.SecondsPerDay do
		speedButtons[speed] = UI.button({
			text = string.rep(">", speed),
			variant = "chrome",
			size = UDim2.fromOffset(40, 34),
			textSize = Theme.TextSize.Body,
			order = 2 + speed,
			parent = right,
			onActivated = function()
				ctx.run(Commands.SetSpeed, { speed = speed }, "speed")
			end,
		})
	end
	local menuButton = UI.button({
		text = "Campaign",
		variant = "chrome",
		size = UDim2.fromOffset(92, 34),
		order = 10,
		parent = right,
	})
	menuButton.Activated:Connect(function()
		onCampaignMenu(menuButton)
	end)
	Tooltip.setText(menuButton, "Save, load and campaign options.")

	-- Tooltips ---------------------------------------------------------------------------------
	Tooltip.bind(treasuryBlock, function()
		local houseId = store:myHouseId()
		local house = houseId and store:house(houseId)
		if not house then
			return nil
		end
		local budget = house.budget
		local lines = {
			`<b>Treasury: {Format.gold(house.treasury)} gold</b>`,
			"Projected for this month:",
			`  Province income {Format.gold(budget.grossProvinceIncome)} x {string.format("%.3f", budget.taxMultiplier)} = <b>{Format.signed(budget.taxIncome)}</b>`,
		}
		for _, line in budget.taxMultiplierLines do
			table.insert(lines, `      {Format.escape(line.label)}: {Format.percent(line.value)}`)
		end
		table.insert(lines, `  Court upkeep: <b>-{Format.gold(budget.courtUpkeep)}</b> (base {Format.gold(budget.courtUpkeepBase)})`)
		for _, line in budget.courtMultiplierLines do
			table.insert(lines, `      {Format.escape(line.label)}: {Format.percent(line.value)}`)
		end
		table.insert(lines, `  Garrisons: <b>-{Format.gold(budget.garrisonUpkeep)}</b>`)
		table.insert(lines, `  Armies: <b>-{Format.gold(budget.armyUpkeep or 0)}</b>`)
		table.insert(lines, `  Administration: <b>-{Format.gold(budget.administration)}</b>`)
		table.insert(lines, `<b>Net: {Format.signed(budget.net)} gold per month</b>`)
		table.insert(lines, "Income and expenses are applied once at the end of each month.")
		return table.concat(lines, "\n")
	end)
	Tooltip.bind(troopsBlock, function()
		local houseId = store:myHouseId()
		local house = houseId and store:house(houseId)
		local military = house and house.military
		if not house or not military then
			return nil
		end
		local armies = military.armies or 0
		local inUse = military.shipsInUse or 0
		local lines = {
			`<b>Troops: {Format.troops(military.total)} men</b>`,
			`  In armies: <b>{Format.troops(military.raised)}</b> ({armies} {if armies == 1 then "army" else "armies"})`,
			`  Levies at home: <b>{Format.troops(military.levies)}</b> of {Format.troops(military.leviesMax)}`,
			`  Garrisons: <b>{Format.troops(military.garrisons)}</b> of {Format.troops(military.garrisonsMax)}`,
			`  Ships: <b>{military.ships}</b>{if inUse > 0 then ` ({inUse} at sea)` else ""}`,
			`  Army upkeep: <b>-{Format.gold(house.budget.armyUpkeep or 0)}</b> gold per month`,
			`Levies refill by {math.floor(GameConfig.Military.LevyReplenishPerMonth * 100 + 0.5)}% of their maximum each month. Click for the Military tab.`,
		}
		return table.concat(lines, "\n")
	end)
	Tooltip.bind(holdingsBlock, function()
		local houseId = store:myHouseId()
		local house = houseId and store:house(houseId)
		if not house then
			return nil
		end
		return `<b>{#house.provinceIds} provinces</b>, total development {house.totalDevelopment}.\nDevelopment raises a province's income; see the Realm tab for every holding.`
	end)
	Tooltip.bind(dateBlock, function()
		local clock = store.campaign.clock
		if not clock then
			return nil
		end
		local host = "the host"
		for _, player in store.session.players or {} do
			if player.isHost then
				host = player.name
			end
		end
		return `The campaign clock is shared by every player and runs on the server.\nSpeed and resuming are controlled by {Format.escape(host)}.`
	end)
	for speed, button in speedButtons do
		Tooltip.setText(button, SPEED_NAMES[speed])
	end

	-- Refresh -----------------------------------------------------------------------------------
	local lastTreasury: number? = nil

	local function renderIdentity()
		local houseId = store:myHouseId()
		for _, child in shieldHolder:GetChildren() do
			child:Destroy()
		end
		if not houseId then
			houseLabel.Text = ""
			rulerLabel.Text = ""
			return
		end
		UI.shield(houseId, 34, shieldHolder)
		houseLabel.Text = Content.houses[houseId].name
		local house = store:house(houseId)
		local ruler = house and store:character(house.rulerId)
		local clock = store.campaign.clock
		if ruler and clock then
			rulerLabel.Text = `{CharacterRules.displayName(ruler :: any)}, {CharacterRules.age(ruler :: any, clock.date)}`
		end
	end

	local function renderEconomy()
		local houseId = store:myHouseId()
		local house = houseId and store:house(houseId)
		if not house then
			return
		end
		treasuryValue.Text = Format.gold(house.treasury)
		local net = house.budget.net
		treasuryCaption.Text = `{Format.signed(net)} per month`
		treasuryCaption.TextColor3 = if net >= 0 then Colors.PositiveOnDark else Colors.NegativeOnDark
		treasuryValue.TextColor3 = if house.treasury >= 0 then Colors.GoldBright else Colors.NegativeOnDark
		if lastTreasury and lastTreasury ~= house.treasury then
			UI.flash(treasuryBlock, if house.treasury > lastTreasury then Colors.Positive else Colors.Negative)
		end
		lastTreasury = house.treasury
		local military = house.military
		if military then
			local armies = military.armies or 0
			troopsValue.Text = Format.troops(military.total or 0)
			troopsCaption.Text = if armies == 0 then "Troops" elseif armies == 1 then "Troops · 1 army" else `Troops · {armies} armies`
		end
		holdingsValue.Text = `{#house.provinceIds} provinces`
		holdingsCaption.Text = `Development {house.totalDevelopment}`
	end

	local function renderClock()
		local clock = store.campaign.clock
		if not clock then
			return
		end
		dateLabel.Text = CalendarDate.format(clock.date)
		statusLabel.Text = if clock.paused then "PAUSED" else SPEED_NAMES[clock.speed] or ""
		statusLabel.TextColor3 = if clock.paused then Colors.NegativeOnDark else Colors.MutedOnDark

		local session = store.session
		local isHost = session.isHost == true
		local leadsHouse = session.houseId ~= nil
		pauseButton.Text = if clock.paused then "Resume" else "Pause"
		if clock.paused then
			UI.setEnabled(pauseButton, isHost, "Only the host can resume the campaign.")
		else
			UI.setEnabled(pauseButton, isHost or (session.anyPlayerMayPause and leadsHouse), "Only the host can pause the campaign.")
		end
		for speed, button in speedButtons do
			UI.setEnabled(button, isHost, "Only the host can change the speed.")
			UI.setSelected(button, speed == clock.speed)
			if isHost then
				Tooltip.setText(button, SPEED_NAMES[speed])
			end
		end
	end

	local lastMonth = -1
	local panel: UIContext.Panel = {
		update = function(changes)
			local clock = store.campaign.clock
			local monthIndex = if clock then CalendarDate.monthIndex(clock.date) else -1
			if changes.full or changes.session or monthIndex ~= lastMonth then
				lastMonth = monthIndex
				renderIdentity()
			end
			local houseId = store:myHouseId()
			if changes.full or changes.session or (houseId and changes.houses[houseId]) then
				renderEconomy()
			end
			if changes.full or changes.clock or changes.session then
				renderClock()
			end
			holdingsBlock.Visible = not ctx.isCompact()
		end,
		setVisible = function(visible)
			bar.Visible = visible
		end,
	}
	return panel
end

return TopBar
