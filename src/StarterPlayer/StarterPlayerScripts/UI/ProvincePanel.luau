--!strict
--[[
	ProvincePanel — inspection of the selected province and its contextual actions.

	Shows server-supplied ownership, development and economy, the static identity from Content,
	and the province's connections (clickable). For the player's own provinces it offers the
	Develop action with a full cost/benefit preview; the button is disabled with an explanation
	whenever the server would reject the request. For foreign provinces it links to diplomacy
	with the owner.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

local ProvincePanel = {}

local CONNECTION_NAMES = { road = "road", river = "river", sea = "sea lane", pass = "mountain pass", wild = "wilderness" }

function ProvincePanel.mount(parent: Frame, ctx: UIContext.Context): UIContext.Panel
	local store = ctx.store
	local root = UI.scroll({ Name = "ProvincePanel", Parent = parent })
	local content = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = root })
	UI.list(content, "vertical", 10)
	UI.padding(content, 2, 2)

	local function clear()
		for _, child in content:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	local function renderEmpty()
		UI.label({ text = "The Realm", size = Theme.TextSize.Title, font = Fonts.Heading, order = 1, parent = content })
		UI.label({
			text = "Select a province on the map to inspect it. Your provinces have a gold outline; the small badge on each marker is its development level.",
			wrap = true,
			color = Colors.InkMuted,
			order = 2,
			parent = content,
		})
		UI.sectionHeader("Holding markers", 3, content)
		local order = 3
		for _, holding in Content.raw.holdingKinds do
			order += 1
			UI.label({ text = `{holding.name}: {holding.description}`, wrap = true, size = Theme.TextSize.Small, color = Colors.Ink, order = order, parent = content })
		end
	end

	local function render()
		clear()
		local provinceId = ctx.selectedProvince()
		local view = provinceId and store:province(provinceId)
		if not provinceId or not view then
			renderEmpty()
			return
		end
		local definition = Content.provinces[provinceId]
		local terrain = Content.terrains[definition.terrainId]
		local holding = Content.holdingKinds[definition.holding.kind]
		local region = Content.regions[definition.regionId]
		local myHouseId = store:myHouseId()
		local owner = Content.houses[view.ownerHouseId]
		local isMine = view.ownerHouseId == myHouseId
		local economy = GameConfig.Economy

		-- Header
		UI.label({ text = definition.name, size = Theme.TextSize.Title, font = Fonts.Heading, order = 1, parent = content })
		UI.label({
			text = `{holding.name} of {definition.holding.name} · {terrain.name} · {region.name}`,
			color = Colors.InkMuted,
			size = Theme.TextSize.Body,
			wrap = true,
			order = 2,
			parent = content,
		})
		if definition.holding.description then
			UI.label({ text = definition.holding.description, font = Fonts.SerifItalic, size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 3, parent = content })
		end

		-- Owner card
		local ownerCard = UI.card({ LayoutOrder = 4, Parent = content })
		UI.padding(ownerCard, 8)
		local ownerRow = UI.create("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 44), Parent = ownerCard })
		UI.shield(view.ownerHouseId, 34, ownerRow)
		local ownerName = UI.label({ text = owner and owner.name or "?", font = Fonts.Heading, size = Theme.TextSize.Large, parent = ownerRow })
		ownerName.Position = UDim2.fromOffset(44, 2)
		ownerName.Size = UDim2.new(1, -44, 0, 22)
		local player = store:playerForHouse(view.ownerHouseId)
		local ownerNote = if isMine then "Your house" elseif player then `Led by {player.name}` else "Governed by the AI"
		if view.occupierHouseId and view.occupierHouseId ~= view.ownerHouseId then
			ownerNote ..= ` · Occupied by {Content.houses[view.occupierHouseId].name}`
		end
		local ownerSub = UI.label({ text = ownerNote, size = Theme.TextSize.Small, color = if isMine then Colors.Positive else Colors.InkMuted, parent = ownerRow })
		ownerSub.Position = UDim2.fromOffset(44, 24)
		ownerSub.Size = UDim2.new(1, -44, 0, 18)
		if not isMine then
			ownerRow.Activated:Connect(function()
				ctx.focusHouse(view.ownerHouseId)
			end)
			Tooltip.setText(ownerRow, `Open diplomacy with {owner and owner.name or "this house"}.`)
		end

		-- Economy
		UI.sectionHeader("Economy", 5, content)
		local stats = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6, Parent = content })
		UI.list(stats, "vertical", 2)
		local developmentRow = UI.statRow("Development", `{view.development} / {economy.MaxDevelopment}`, 1, stats)
		local incomeRow = UI.statRow("Monthly income", `{Format.gold(view.income)} gold`, 2, stats, Colors.Positive)
		UI.statRow("Garrison upkeep", `-{Format.gold(view.garrison)} gold`, 3, stats, Colors.Negative)
		UI.statRow("Administration", `-{Format.gold(view.administration)} gold`, 4, stats, Colors.Negative)

		Tooltip.bind(incomeRow, function()
			local lines = { `<b>Monthly income: {Format.gold(view.income)} gold</b>` }
			for _, line in EconomyRules.provinceIncomeBreakdown(provinceId, view.development, economy) do
				local value = if line.label == "Base tax" then `{Format.gold(line.value, 2)}` else Format.multiplier(line.value)
				table.insert(lines, `  {Format.escape(line.label)}: {value}`)
			end
			table.insert(lines, "The owner's tax multiplier (ruler stewardship and traits) applies on top.")
			return table.concat(lines, "\n")
		end)
		Tooltip.setText(developmentRow, `Each level adds {math.floor(economy.DevelopmentIncomePerLevel * 100)}% of base tax to income and {Format.gold(economy.AdministrationPerDevelopment, 2)} gold of administration.`)

		-- Development pips
		local pips = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 10), LayoutOrder = 7, Parent = content })
		UI.list(pips, "horizontal", 3)
		for level = 1, economy.MaxDevelopment do
			local pip = UI.create("Frame", {
				BackgroundColor3 = if level <= view.development then Colors.Gold else Colors.ParchmentDeep,
				BorderSizePixel = 0,
				Size = UDim2.new(1 / economy.MaxDevelopment, -3, 1, 0),
				LayoutOrder = level,
				Parent = pips,
			})
			UI.corner(pip, 2)
		end

		-- Development action
		if isMine then
			local myHouse = store:house(myHouseId :: string)
			local ruler = myHouse and store:character(myHouse.rulerId)
			local actionCard = UI.card({ LayoutOrder = 8, Parent = content, BackgroundColor3 = Colors.ParchmentDeep })
			UI.padding(actionCard, 10)
			UI.list(actionCard, "vertical", 6)
			UI.label({ text = "Invest in development", font = Fonts.Heading, size = Theme.TextSize.Body, order = 1, parent = actionCard })

			local cost = view.developmentCost
			local key = `develop:{provinceId}`
			local button = UI.button({
				text = if cost then `Develop ({cost} gold)` else "Fully developed",
				variant = "primary",
				order = 3,
				parent = actionCard,
				onActivated = function()
					ctx.run(Protocol.Commands.DevelopProvince, { provinceId = provinceId }, key)
				end,
			})
			if cost then
				local netGain = EconomyRules.developmentNetGain(provinceId, view.development, ruler :: any, economy)
				local grossGain = (view.nextIncome or view.income) - view.income
				local payback = if netGain > 0 then math.ceil(cost / netGain) else nil
				UI.label({
					text = `Level {view.development} -> {view.development + 1}: income +{Format.gold(grossGain, 2)} before your multiplier, net {Format.signed(netGain, 2)} gold per month after administration.`
						.. (if payback then ` Pays for itself in about {payback} months.` else " This investment will never pay for itself."),
					wrap = true,
					size = Theme.TextSize.Small,
					color = Colors.Ink,
					order = 2,
					parent = actionCard,
				})
				local treasury = myHouse and myHouse.treasury or 0
				if treasury < cost then
					UI.setEnabled(button, false, `Requires {cost} gold; your treasury holds {Format.gold(treasury)}.`)
				elseif ctx.isBusy(key) then
					UI.setEnabled(button, false, "Waiting for the server...")
				else
					Tooltip.setText(button, `Spend {cost} gold to raise {definition.name} to development {view.development + 1}.`)
				end
			else
				UI.setEnabled(button, false, `{definition.name} has reached the maximum development of {economy.MaxDevelopment}.`)
			end
		else
			local diplomacyButton = UI.button({
				text = `Diplomacy with {owner and owner.surname or "owner"}`,
				variant = "secondary",
				order = 8,
				parent = content,
				onActivated = function()
					ctx.focusHouse(view.ownerHouseId)
				end,
			})
			Tooltip.setText(diplomacyButton, "Only a province's owner may develop it. You can court its owner instead.")
		end

		-- Connections
		UI.sectionHeader("Borders", 9, content)
		local borders = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 10, Parent = content })
		UI.list(borders, "vertical", 2)
		local neighbours: { { id: string, kind: string } } = {}
		for neighbourId, kind in definition.adjacent do
			table.insert(neighbours, { id = neighbourId, kind = kind })
		end
		table.sort(neighbours, function(a, b)
			return Content.provinces[a.id].name < Content.provinces[b.id].name
		end)
		for index, neighbour in neighbours do
			local neighbourView = store:province(neighbour.id)
			local neighbourOwner = neighbourView and Content.houses[neighbourView.ownerHouseId]
			local link = UI.create("TextButton", {
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = `{Content.provinces[neighbour.id].name}  <font color="#6C5A42">by {CONNECTION_NAMES[neighbour.kind] or neighbour.kind} · {neighbourOwner and neighbourOwner.surname or "?"}</font>`,
				RichText = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Colors.Burgundy,
				TextSize = Theme.TextSize.Body,
				FontFace = Fonts.BodySemibold,
				Size = UDim2.new(1, 0, 0, 22),
				LayoutOrder = index,
				Parent = borders,
			})
			link.Activated:Connect(function()
				ctx.selectProvince(neighbour.id, true)
			end)
		end
	end

	local panel: UIContext.Panel = {
		update = function(changes)
			local provinceId = ctx.selectedProvince()
			local myHouseId = store:myHouseId()
			local relevant = changes.full
				or changes.session
				or (provinceId ~= nil and changes.provinces[provinceId] == true)
				or (myHouseId ~= nil and changes.houses[myHouseId] == true)
			if relevant then
				render()
			end
		end,
		setVisible = function(visible)
			root.Visible = visible
			if visible then
				render()
			end
		end,
	}
	return panel
end

return ProvincePanel
