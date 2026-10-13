--!strict
--[[
	ProvincePanel — inspection of the selected province and its contextual actions.

	Shows server-supplied ownership, development and economy, the static identity from Content,
	the province's troops and the armies standing in it, and its connections (clickable). For the
	player's own provinces it offers the Develop action with a full cost/benefit preview, and
	raising its levies or calling every levy of the house to it; each button is disabled with an
	explanation whenever the server would reject the request (worked out with the same shared
	rules). For foreign provinces it links to diplomacy with the owner.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local MovementRules = require(ReplicatedStorage.Shared.Rules.MovementRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local ArmyInfo = require(script.Parent.ArmyInfo)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

local ProvincePanel = {}

local CONNECTION_NAMES = { road = "road", river = "river", sea = "sea lane", pass = "mountain pass", wild = "wilderness" }
local BUSY = "Waiting for the server..."

-- The house holds a province: owns it and no other house occupies it (levies can be raised there).
local function holds(view: { [string]: any }, houseId: string): boolean
	return view.ownerHouseId == houseId and (view.occupierHouseId == nil or view.occupierHouseId == houseId)
end

type CallPlan = { armies: number, troops: number, withLevies: number }

--[[
	What "Call all levies here" would raise, as the server plans it (Military.checkRaiseAllLevies):
	every province the house holds with at least MinArmySize levies raises an army if it can reach
	the rally province, by land or, when the house's fleet can carry that levy, by sea.
]]
local function callPlan(store: any, house: { [string]: any }, houseId: string, rallyId: string): CallPlan
	local config = GameConfig.Military
	local military: { [string]: any }? = house.military
	local ships = if military then military.ships or 0 else 0
	local plan: CallPlan = { armies = 0, troops = 0, withLevies = 0 }
	for _, provinceId in house.provinceIds do
		local view = store:province(provinceId)
		if view and holds(view, houseId) and (view.levies or 0) >= config.MinArmySize then
			plan.withLevies += 1
			local reachable = provinceId == rallyId
			if not reachable then
				local units = MilitaryRules.splitMen(view.levies, MilitaryRules.composition(houseId))
				local canSail = ships >= MilitaryRules.shipsNeeded(view.levies, config)
				reachable = MovementRules.findPath(provinceId, rallyId, units, canSail, config) ~= nil
			end
			if reachable then
				plan.armies += 1
				plan.troops += view.levies
			end
		end
	end
	return plan
end

--[[
	What the panel shows of the player's house: the treasury (Develop), the ruler (the payback
	preview), the number of armies, the fleet and the holdings (the raise buttons). Other house
	changes, such as troop totals falling while an army starves, do not redraw the panel, so its
	buttons are not destroyed under the pointer every few days.
]]
local function houseKey(house: { [string]: any }?): string
	if not house then
		return ""
	end
	local military: { [string]: any } = house.military or {}
	return `{house.treasury}|{house.rulerId}|{military.armies}|{military.ships}|{table.concat(house.provinceIds, ",")}`
end

function ProvincePanel.mount(parent: Frame, ctx: UIContext.Context): UIContext.Panel
	local store = ctx.store
	local root = UI.scroll({ Name = "ProvincePanel", Parent = parent })
	local content = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = root })
	UI.list(content, "vertical", 10)
	UI.padding(content, 2, 2)
	-- Armies shown in the last render: army id -> ArmyInfo.structuralKey (a supply tick, which
	-- changes only morale and supply, does not redraw the panel).
	local listedArmies: { [string]: string } = {}
	-- houseKey of the player's house at the last render.
	local renderedHouseKey = ""

	-- Hidden behind another tab, the panel skips updates (army changes arrive often while armies
	-- march); showing it renders it afresh.
	local visible = true

	local function clear()
		for _, child in content:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
		listedArmies = {}
	end

	local function renderEmpty()
		UI.label({ text = "The Realm", size = Theme.TextSize.Title, font = Fonts.Heading, order = 1, parent = content })
		UI.label({
			text = "Select a province on the map to inspect it: click its land or its castle. Your provinces have a thin gold outline, the selected one a thick one.",
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

	-- The Military section: troops of the province, armies standing in it and, for the player's
	-- own province, the raise actions. LayoutOrders 9-12.
	local function renderMilitary(provinceId: string, view: { [string]: any }, myHouseId: string?)
		local config = GameConfig.Military
		local definition = Content.provinces[provinceId]
		UI.sectionHeader("Military", 9, content)
		local stats = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 10, Parent = content })
		UI.list(stats, "vertical", 2)
		local levies, leviesMax = view.levies or 0, view.leviesMax or 0
		local leviesRow = UI.statRow("Levies", `{Format.troops(levies)} / {Format.troops(leviesMax)}`, 1, stats)
		Tooltip.setText(
			leviesRow,
			`Men this province can raise into an army. The pool refills by {Format.troops(math.ceil(leviesMax * config.LevyReplenishPerMonth))} a month (unless occupied) up to {Format.troops(leviesMax)}, which grows with development.`
		)
		local garrison, garrisonMax = view.garrisonTroops or 0, view.garrisonMax or 0
		local garrisonRow = UI.statRow("Garrison", `{Format.troops(garrison)} / {Format.troops(garrisonMax)}`, 2, stats)
		Tooltip.setText(garrisonRow, "Men who hold the walls; they never march. Fortresses and cities keep the largest garrisons.")
		if (view.ships or 0) > 0 then
			local shipsRow = UI.statRow("Ships", tostring(view.ships), 3, stats)
			Tooltip.setText(shipsRow, `Ships this province adds to its holder's fleet; each carries {config.ShipCapacity} men.`)
		end

		-- Armies standing here (an army on the road counts where it set out from).
		local armies = store:armiesIn(provinceId)
		if #armies > 0 then
			local list = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 11, Parent = content })
			UI.list(list, "vertical", 2)
			for index, army in armies do
				listedArmies[army.id] = ArmyInfo.structuralKey(army)
				local owner = Content.houses[army.houseId]
				local link = UI.create("TextButton", {
					Name = `ArmyLink_{army.id}`,
					BackgroundTransparency = 1,
					AutoButtonColor = false,
					RichText = true,
					Text = `{Format.escape(ArmyInfo.name(army))}  <font color="#6C5A42">{Format.troops(army.troops)} · {owner and owner.surname or "?"}</font>`,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Colors.Burgundy,
					TextSize = Theme.TextSize.Body,
					FontFace = Fonts.BodySemibold,
					Size = UDim2.new(1, 0, 0, 22),
					LayoutOrder = index,
					Parent = list,
				})
				link.Activated:Connect(function()
					ctx.selectArmy(army.id, true)
				end)
				Tooltip.bind(link, function()
					local current = store:army(army.id)
					return if current then ArmyInfo.tooltip(store, current) else nil
				end)
			end
		end

		if not myHouseId or view.ownerHouseId ~= myHouseId then
			return
		end
		local myHouse = store:house(myHouseId)
		if not myHouse then
			return
		end
		local held = holds(view, myHouseId)
		local military: { [string]: any }? = myHouse.military
		local fielded = if military then military.armies or 0 else #store:armiesOf(myHouseId)
		local card = UI.card({ LayoutOrder = 12, Parent = content, BackgroundColor3 = Colors.ParchmentDeep })
		UI.padding(card, 10)
		UI.list(card, "vertical", 6)
		UI.label({ text = "Raise troops", font = Fonts.Heading, size = Theme.TextSize.Body, order = 1, parent = card })

		-- Raise this province's levies.
		local raiseKey = `raise:{provinceId}`
		local raise = UI.button({
			text = `Raise levies here ({Format.troops(levies)} men)`,
			variant = "primary",
			order = 2,
			parent = card,
			onActivated = function()
				ctx.run(Protocol.Commands.RaiseArmy, { provinceId = provinceId }, raiseKey)
			end,
		})
		if not held then
			UI.setEnabled(raise, false, `{definition.name} is occupied; its levies cannot be raised.`)
		elseif levies < config.MinArmySize then
			UI.setEnabled(
				raise,
				false,
				`{definition.name} has {Format.troops(levies)} levies; at least {Format.troops(config.MinArmySize)} are needed to raise an army. The pool refills by {Format.troops(math.ceil(leviesMax * config.LevyReplenishPerMonth))} a month.`
			)
		elseif fielded >= config.MaxArmiesPerHouse then
			UI.setEnabled(raise, false, `Your house already fields {config.MaxArmiesPerHouse} armies, the most it can keep.`)
		elseif ctx.isBusy(raiseKey) then
			UI.setEnabled(raise, false, BUSY)
		else
			local units = MilitaryRules.splitMen(levies, MilitaryRules.composition(myHouseId))
			local commander = ArmyInfo.nextCommander(store, myHouseId)
			local leader = if commander then ArmyInfo.commanderText(store, { commanderId = commander.id }) else "nobody (every adult already leads an army)"
			Tooltip.setText(
				raise,
				`Raise the {MilitaryRules.armyName({ originId = provinceId })}: {Format.troops(levies)} men led by {leader}. Upkeep {Format.gold(MilitaryRules.upkeep(units, config))} gold a month. The levy pool empties and refills over the months.`
			)
		end

		-- Call every levy of the house to this province.
		local callKey = `raiseall:{provinceId}`
		local call = UI.button({
			text = "Call all levies here",
			variant = "secondary",
			order = 3,
			parent = card,
			onActivated = function()
				ctx.run(Protocol.Commands.RaiseAllLevies, { provinceId = provinceId }, callKey)
			end,
		})
		local plan = callPlan(store, myHouse, myHouseId, provinceId)
		if not held then
			UI.setEnabled(call, false, `{definition.name} is occupied; your levies cannot gather there.`)
		elseif plan.withLevies == 0 then
			UI.setEnabled(call, false, `No province of your house has the {Format.troops(config.MinArmySize)} levies needed to raise an army.`)
		elseif plan.armies == 0 then
			UI.setEnabled(call, false, `None of your levies can reach {definition.name}.`)
		elseif fielded + plan.armies > config.MaxArmiesPerHouse then
			UI.setEnabled(
				call,
				false,
				`Calling every levy would raise {plan.armies} armies; your house can keep {config.MaxArmiesPerHouse} and already fields {fielded}.`
			)
		elseif ctx.isBusy(callKey) then
			UI.setEnabled(call, false, BUSY)
		else
			Tooltip.setText(
				call,
				`Raise {plan.armies} {if plan.armies == 1 then "army" else "armies"} ({Format.troops(plan.troops)} men) in every province you hold with at least {Format.troops(config.MinArmySize)} levies. They march here and join the army raised in {definition.name}.`
			)
		end
	end

	local function render()
		clear()
		local myHouseIdNow = store:myHouseId()
		renderedHouseKey = houseKey(if myHouseIdNow then store:house(myHouseIdNow) else nil)
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

		-- Military (LayoutOrders 9-12)
		renderMilitary(provinceId, view, myHouseId)

		-- Connections
		UI.sectionHeader("Borders", 13, content)
		local borders = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 14, Parent = content })
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
			if not visible then
				return
			end
			local provinceId = ctx.selectedProvince()
			local myHouseId = store:myHouseId()
			local relevant = changes.full
				or changes.session
				or (provinceId ~= nil and changes.provinces[provinceId] == true)
				or (myHouseId ~= nil and changes.houses[myHouseId] == true and houseKey(store:house(myHouseId)) ~= renderedHouseKey)
			if not relevant and provinceId ~= nil then
				-- An army that arrives here, or one listed here that left, changed or no longer exists.
				for armyId in changes.armies do
					local army = store:army(armyId)
					local listed = listedArmies[armyId]
					if (listed ~= nil or (army ~= nil and army.locationId == provinceId))
						and (army == nil or listed ~= ArmyInfo.structuralKey(army)) then
						relevant = true
						break
					end
				end
			end
			if relevant then
				render()
			end
		end,
		setVisible = function(isVisible)
			visible = isVisible
			root.Visible = isVisible
			if isVisible then
				render()
			end
		end,
	}
	return panel
end

return ProvincePanel
