--!strict
--[[
	ArmyPanel — the Military tab: the house's forces and the selected army.

	  * Your forces: men in armies, levies at home, garrisons, ships and army upkeep, from the
	    server's house view (houseView.military and budget.armyUpkeep).
	  * Armies: the house's armies with their orders; a click selects one and centres the map on it.
	  * The selected army (any house's): commander, troops, strength, upkeep, pace, morale and supply,
	    its orders with the arrival estimate, and its composition by unit.

	For the player's own army it offers Move (move mode: the next click on land is the destination;
	right-click, Esc or leaving the tab cancels), Stop, Split, Merge with each other idle army of the house in the
	same province, and Disband (a second click confirms it). Every button the server would refuse
	is disabled with the reason, worked out from the replicated state with the same shared rules
	(MilitaryRules, GameConfig.Military) and the same wording the server uses. A foreign army is
	shown read-only.

	Refreshing: the panel rebuilds when the selection, the house's armies, the selected army or the
	house's totals change. A supply tick, which changes only an army's morale and supply (every few
	days, so several times a second at the fastest speed), updates the two meters in place instead
	(ArmyInfo.structuralKey tells the two apart), so buttons under the pointer survive it; as days
	pass the panel only rewrites the orders lines, whose arrival estimates count down.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local ArmyInfo = require(script.Parent.ArmyInfo)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts
local Commands = Protocol.Commands

type View = { [string]: any }
type Meter = { value: TextLabel, fill: Frame }

local ArmyPanel = {}

local CLASS_NAMES: { [string]: string } = { spear = "Spear", archer = "Archer", cavalry = "Cavalry", siege = "Siege" }
local BUSY = "Waiting for the server..."

local function men(count: number): string
	return Format.troops(count)
end

-- Men a disbanded army could hand back: the shortfall of the levy pools the house holds.
local function levyRoom(store: any, house: View, houseId: string): number
	local room = 0
	for _, provinceId in house.provinceIds do
		local view = store:province(provinceId)
		if view and (view.occupierHouseId == nil or view.occupierHouseId == houseId) then
			room += math.max(0, (view.leviesMax or 0) - (view.levies or 0))
		end
	end
	return room
end

local function unitTooltip(unitId: string, count: number, total: number): string
	local unit = Content.units[unitId]
	if not unit then
		return unitId
	end
	local lines = { `<b>{Format.escape(unit.name)}</b> · {CLASS_NAMES[unit.class] or unit.class}` }
	local owner = unit.houseId and Content.houses[unit.houseId]
	if owner then
		lines[1] ..= ` · unique to {Format.escape(owner.name)}`
	end
	table.insert(lines, Format.escape(unit.description))
	table.insert(lines, `{men(count)} men, {math.floor(count / math.max(1, total) * 100 + 0.5)}% of the army`)
	table.insert(lines, `Attack {unit.attack} · Defence {unit.defense} · Morale +{unit.morale} · Pace {Format.multiplier(unit.speed)} · Upkeep {Format.multiplier(unit.upkeep)}`)
	local counters: { [string]: number }? = (Content.military.counters :: any)[unit.class]
	if counters then
		for target, multiplier in counters do
			local targetName = if target == "walls" then "walls" else string.lower(CLASS_NAMES[target] or target)
			table.insert(lines, `Deals {Format.multiplier(multiplier)} damage to {targetName}.`)
		end
	end
	return table.concat(lines, "\n")
end

function ArmyPanel.mount(parent: Frame, ctx: UIContext.Context): UIContext.Panel
	local store = ctx.store
	local root = UI.scroll({ Name = "ArmyPanel", Parent = parent, Visible = false })
	local content = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = root })
	UI.list(content, "vertical", 10)
	UI.padding(content, 2, 2)

	local visible = false
	local confirmDisband: string? = nil -- the army whose Disband button awaits confirmation
	local liveOrders: { { label: TextLabel, armyId: string } } = {}
	local lastToday: number? = nil
	-- Army id -> ArmyInfo.structuralKey of every army shown in the last render.
	local renderedKeys: { [string]: string } = {}
	-- The selected army's morale and supply meters, updated in place on supply ticks.
	local meters: { morale: Meter?, supply: Meter? } = {}
	local render: () -> ()

	local function clear()
		for _, child in content:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
		liveOrders = {}
		renderedKeys = {}
		meters = {}
	end

	local function vertical(order: number, parentFrame: Instance, gap: number?): Frame
		local frame = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parentFrame })
		UI.list(frame, "vertical", gap or 2)
		return frame
	end

	local function ordersLabel(army: View, order: number, parentFrame: Instance, size: number?, color: Color3?): TextLabel
		local label = UI.label({
			text = ArmyInfo.ordersText(army, ArmyInfo.today(store)),
			size = size or Theme.TextSize.Body,
			color = color or Colors.Ink,
			wrap = true,
			order = order,
			parent = parentFrame,
		})
		table.insert(liveOrders, { label = label, armyId = army.id })
		return label
	end

	-- A labelled value with a bar under it (morale, supply).
	local function meter(labelText: string, value: number, maximum: number, color: Color3, order: number, parentFrame: Instance, tip: string): Meter
		local holder = vertical(order, parentFrame, 2)
		local row = UI.statRow(labelText, `{value} / {maximum}`, 1, holder)
		local bar = UI.create("Frame", { BackgroundColor3 = Colors.ParchmentDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 8), LayoutOrder = 2, Parent = holder })
		UI.corner(bar, 4)
		local fill = UI.create("Frame", {
			Name = "Fill",
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(math.clamp(value / math.max(1, maximum), 0, 1), 1),
			Parent = bar,
		})
		UI.corner(fill, 4)
		Tooltip.setText(holder, tip)
		return { value = row:FindFirstChild("Value") :: TextLabel, fill = fill }
	end

	local function setMeter(entry: Meter?, value: number, maximum: number, color: Color3)
		if entry then
			entry.value.Text = `{value} / {maximum}`
			entry.fill.Size = UDim2.fromScale(math.clamp(value / math.max(1, maximum), 0, 1), 1)
			entry.fill.BackgroundColor3 = color
		end
	end

	local function supplyColor(supply: number): Color3
		return if supply <= 25 then Colors.Negative else Colors.Positive
	end

	-- Your forces ----------------------------------------------------------------------------------
	local function renderSummary(house: View, order: number)
		local military: View = house.military or {}
		local config = GameConfig.Military
		UI.sectionHeader("Your forces", order, content)
		local stats = vertical(order + 1, content)
		local total = UI.statRow("Total men", men(military.total or 0), 1, stats)
		Tooltip.setText(total, "Every man of your house: in armies, in the levy pools at home and in the garrisons.")
		local raised = UI.statRow(`In armies ({military.armies or 0} of {config.MaxArmiesPerHouse})`, men(military.raised or 0), 2, stats)
		Tooltip.setText(raised, `Raised men. A house can keep at most {config.MaxArmiesPerHouse} armies.`)
		local levies = UI.statRow("Levies at home", `{men(military.levies or 0)} / {men(military.leviesMax or 0)}`, 3, stats)
		Tooltip.setText(levies, `Men who can be raised. Each province's pool refills by {math.floor(config.LevyReplenishPerMonth * 100 + 0.5)}% of its maximum every month. Raise them from a province you hold (Map tab).`)
		local garrisons = UI.statRow("Garrisons", `{men(military.garrisons or 0)} / {men(military.garrisonsMax or 0)}`, 4, stats)
		Tooltip.setText(garrisons, `Garrisons hold the walls of each province and never march. They refill by {math.floor(config.GarrisonReplenishPerMonth * 100 + 0.5)}% of their maximum every month.`)
		local inUse = military.shipsInUse or 0
		local ships = UI.statRow("Ships", if inUse > 0 then `{military.ships or 0} ({inUse} at sea)` else tostring(military.ships or 0), 5, stats)
		Tooltip.setText(ships, `Ships come from coasts, islands and ports. An army sails only when your fleet can carry all of it: one ship per {config.ShipCapacity} men.`)
		local upkeep = house.budget and house.budget.armyUpkeep or 0
		local upkeepRow = UI.statRow("Army upkeep", `-{Format.gold(upkeep)} gold/month`, 6, stats, if upkeep > 0 then Colors.Negative else Colors.Ink)
		Tooltip.setText(upkeepRow, `Every 1,000 men cost {Format.gold(config.UpkeepPerThousandPerMonth)} gold a month, times their unit's upkeep; paid with the monthly accounts.`)
	end

	-- Armies list ----------------------------------------------------------------------------------
	local function renderList(armies: { View }, selectedId: string?, order: number)
		UI.sectionHeader("Armies", order, content)
		local list = vertical(order + 1, content, 4)
		if #armies == 0 then
			UI.label({
				text = "No armies in the field. Select a province you hold on the map and choose \"Raise levies here\", or \"Call all levies here\" to gather the whole host.",
				wrap = true,
				size = Theme.TextSize.Small,
				color = Colors.InkMuted,
				order = 1,
				parent = list,
			})
			return
		end
		for index, army in armies do
			renderedKeys[army.id] = ArmyInfo.structuralKey(army)
			local selected = army.id == selectedId
			local row = UI.create("TextButton", {
				Name = `ArmyRow_{army.id}`,
				BackgroundColor3 = Colors.ParchmentDeep,
				BackgroundTransparency = if selected then 0 else 1,
				AutoButtonColor = false,
				Text = "",
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = index,
				Parent = list,
			})
			UI.corner(row, 4)
			UI.padding(row, 4, 6)
			UI.list(row, "vertical", 1)
			UI.label({
				text = `<b>{Format.escape(ArmyInfo.name(army))}</b>  {men(army.troops)} men`,
				rich = true,
				color = Colors.Burgundy,
				order = 1,
				parent = row,
			})
			ordersLabel(army, 2, row, Theme.TextSize.Small, Colors.InkMuted)
			row.Activated:Connect(function()
				ctx.selectArmy(army.id, true)
			end)
			Tooltip.setText(row, "Select this army and centre the map on it.")
		end
	end

	-- Orders (own armies) --------------------------------------------------------------------------
	local function renderOrders(army: View, house: View, card: Frame)
		local config = GameConfig.Military
		local armyId: string = army.id
		local name = ArmyInfo.name(army)
		local status = ArmyInfo.status(army)
		local myHouseId = store:myHouseId() :: string
		local pending = ctx.pendingMoveOrder() == armyId
		local military: View = house.military or {}

		if pending then
			UI.label({
				text = "Choose the destination: click a province on the map. Right-click or press Esc to cancel.",
				wrap = true,
				font = Fonts.BodySemibold,
				size = Theme.TextSize.Small,
				color = Colors.Burgundy,
				order = 3,
				parent = card,
			})
		end

		local grid = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 74), LayoutOrder = 4, Parent = card })
		UI.create("UIGridLayout", {
			CellSize = UDim2.new(0.5, -3, 0, 34),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = grid,
		})

		-- Move / Cancel move
		local moveKey = `move:{armyId}`
		local move = UI.button({
			text = if pending then "Cancel move" else "Move…",
			variant = "primary",
			order = 1,
			parent = grid,
			onActivated = function()
				if ctx.pendingMoveOrder() == armyId then
					ctx.cancelMoveOrder()
				else
					ctx.beginMoveOrder(armyId)
				end
			end,
		})
		if ctx.isBusy(moveKey) then
			UI.setEnabled(move, false, BUSY)
		elseif pending then
			Tooltip.setText(move, "Stop choosing a destination; the army keeps its current orders.")
		else
			local needed = MilitaryRules.shipsNeeded(army.troops, config)
			local fleet = military.ships or 0
			local sea = if fleet >= needed
				then `Your fleet of {fleet} ships can carry it by sea ({needed} needed).`
				else `It marches by land only: it needs {needed} ships to sail and your house has {fleet}.`
			Tooltip.setText(move, `Pick the destination on the map (or, with the army selected, right-click land). It takes the fastest route. {sea}`)
		end

		-- Stop
		local stopKey = `stop:{armyId}`
		local stop = UI.button({
			text = "Stop",
			variant = "secondary",
			order = 2,
			parent = grid,
			onActivated = function()
				ctx.run(Commands.StopArmy, { armyId = armyId }, stopKey)
			end,
		})
		if status == "idle" then
			UI.setEnabled(stop, false, `The {name} has no orders to cancel.`)
		elseif ctx.isBusy(stopKey) then
			UI.setEnabled(stop, false, BUSY)
		elseif status == "waiting" then
			Tooltip.setText(stop, `Cancel the voyage: the army stays at {ArmyInfo.provinceName(army.locationId)}.`)
		elseif #army.route > 1 then
			Tooltip.setText(stop, `Halt at {ArmyInfo.provinceName(army.route[1])}, the end of the current leg.`)
		else
			Tooltip.setText(stop, `The army is on its last leg and halts at {ArmyInfo.provinceName(army.route[1])} anyway.`)
		end

		-- Split
		local splitKey = `split:{armyId}`
		local keep, split = MilitaryRules.halve(army.units)
		local splitTroops = MilitaryRules.troops(split)
		local splitButton = UI.button({
			text = "Split",
			variant = "secondary",
			order = 3,
			parent = grid,
			onActivated = function()
				ctx.run(Commands.SplitArmy, { armyId = armyId }, splitKey)
			end,
		})
		if status ~= "idle" then
			UI.setEnabled(splitButton, false, `The {name} cannot divide while it has orders to march.`)
		elseif army.troops < 2 * config.MinArmySize or splitTroops < config.MinArmySize then
			UI.setEnabled(splitButton, false, `The {name} has {men(army.troops)} men; each half must have at least {men(config.MinArmySize)}.`)
		elseif (military.armies or 0) >= config.MaxArmiesPerHouse then
			UI.setEnabled(splitButton, false, `Your house already fields {config.MaxArmiesPerHouse} armies, the most it can keep.`)
		elseif ctx.isBusy(splitKey) then
			UI.setEnabled(splitButton, false, BUSY)
		else
			local successor = ArmyInfo.nextCommander(store, myHouseId)
			local leader = if successor then `led by {ArmyInfo.commanderText(store, { commanderId = successor.id })}` else "without a commander (nobody is free)"
			Tooltip.setText(splitButton, `Divide every unit in two: {men(MilitaryRules.troops(keep))} men stay and {men(splitTroops)} form a new army, {leader}.`)
		end

		-- Disband (two clicks)
		local disbandKey = `disband:{armyId}`
		local confirming = confirmDisband == armyId
		local disband = UI.button({
			text = if confirming then "Keep the army" else "Disband…",
			variant = if confirming then "ghost" else "danger",
			order = 4,
			parent = grid,
			onActivated = function()
				confirmDisband = if confirmDisband == armyId then nil else armyId
				render()
			end,
		})
		local room = levyRoom(store, house, myHouseId)
		local returned = math.min(army.troops, room)
		if ctx.isBusy(disbandKey) then
			UI.setEnabled(disband, false, BUSY)
		elseif confirming then
			Tooltip.setText(disband, "Keep the army under arms.")
		else
			Tooltip.setText(disband, `Send the men home: {men(returned)} of {men(army.troops)} fit back into your levy pools. Nothing is refunded.`)
		end
		if confirming then
			local lost = army.troops - returned
			UI.label({
				text = `Disband the {name}? {men(returned)} men return to your levy pools{if lost > 0 then `; {men(lost)} more than the pools can hold are lost` else ""}. Nothing is refunded.`,
				wrap = true,
				size = Theme.TextSize.Small,
				color = Colors.Negative,
				order = 5,
				parent = card,
			})
			local confirm = UI.button({
				text = "Confirm disband",
				variant = "danger",
				order = 6,
				parent = card,
				onActivated = function()
					confirmDisband = nil
					ctx.run(Commands.DisbandArmy, { armyId = armyId }, disbandKey)
				end,
			})
			if ctx.isBusy(disbandKey) then
				UI.setEnabled(confirm, false, BUSY)
			end
		end

		-- Merge with each other army of the house standing idle in the same province.
		local others = {}
		for _, other in store:armiesIn(army.locationId) do
			if other.id ~= armyId and other.houseId == myHouseId and #other.route == 0 then
				table.insert(others, other)
			end
		end
		for index, other in others do
			local mergeKey = `merge:{other.id}`
			local button = UI.button({
				text = `Merge with {ArmyInfo.name(other)} ({men(other.troops)})`,
				variant = "secondary",
				order = 10 + index,
				parent = card,
				onActivated = function()
					-- The other army joins this one, so the selection stays on this army.
					ctx.run(Commands.MergeArmies, { armyId = other.id, intoArmyId = armyId }, mergeKey)
				end,
			})
			if status ~= "idle" then
				UI.setEnabled(button, false, "Only armies without marching orders can merge.")
			elseif ctx.isBusy(mergeKey) then
				UI.setEnabled(button, false, BUSY)
			else
				local mine = ArmyInfo.commander(store, army)
				local theirs = ArmyInfo.commander(store, other)
				local leader = if theirs and (mine == nil or theirs.skills.martial > mine.skills.martial) then other else army
				Tooltip.setText(
					button,
					`The {ArmyInfo.name(other)} ({men(other.troops)} men) joins this army: {men(army.troops + other.troops)} men, led by {ArmyInfo.commanderText(store, leader)}. Morale and supply become the average of both.`
				)
			end
		end
	end

	-- Selected army --------------------------------------------------------------------------------
	local function renderArmy(army: View, house: View?, order: number)
		local config = GameConfig.Military
		local myHouseId = store:myHouseId()
		local isMine = army.houseId == myHouseId
		local owner = Content.houses[army.houseId]
		renderedKeys[army.id] = ArmyInfo.structuralKey(army)
		UI.sectionHeader(if isMine then "Selected army" else "Foreign army", order, content)
		local detail = vertical(order + 1, content, 8)

		-- Header: shield, name, house and origin.
		local header = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = 1, Parent = detail })
		UI.shield(army.houseId, 34, header)
		local title = UI.label({ text = ArmyInfo.name(army), font = Fonts.Heading, size = Theme.TextSize.Large, parent = header })
		title.Position = UDim2.fromOffset(44, 2)
		title.Size = UDim2.new(1, -44, 0, 22)
		local subtitle = UI.label({
			text = `{if owner then owner.name else "?"} · raised at {ArmyInfo.provinceName(army.originId)}`,
			size = Theme.TextSize.Small,
			color = Colors.InkMuted,
			parent = header,
		})
		subtitle.Position = UDim2.fromOffset(44, 24)
		subtitle.Size = UDim2.new(1, -44, 0, 18)

		-- Figures. The commander's name and martial get a row each: a name with its skill would
		-- overflow the value column of a narrow panel.
		local stats = vertical(2, detail)
		local leader = ArmyInfo.commander(store, army)
		local commander = UI.statRow("Commander", ArmyInfo.commanderName(store, army), 1, stats)
		Tooltip.setText(
			commander,
			if leader
				then "Leads the army; the army's strength rating follows the commander's martial skill."
				else "Nobody leads this army: every adult of the house already commands one."
		)
		if leader then
			local martial = UI.statRow("Martial", tostring(leader.skills.martial), 2, stats)
			Tooltip.setText(
				martial,
				`The commander's martial skill scales the army's strength by {math.floor(config.StrengthPerMartial * 100 + 0.5)}% per point above {config.CommanderMartialBaseline}.`
			)
		end
		UI.statRow("Troops", men(army.troops), 3, stats)
		local strength = UI.statRow("Strength", Format.gold(army.strength or 0), 4, stats)
		Tooltip.setText(strength, "A rating of the army's fighting power: thousands of men weighted by their attack and defence, scaled by the commander's martial.")
		local upkeep = UI.statRow("Upkeep", `-{Format.gold(army.upkeep or 0)} gold/month`, 5, stats, Colors.Negative)
		Tooltip.setText(upkeep, "Paid by its house with the monthly accounts, for each day the army is in the field.")
		local pace = UI.statRow("Pace", Format.multiplier(army.speed or 1), 6, stats)
		Tooltip.setText(pace, "An army marches at the average pace of its men: swift units quicken it, slow ones hold it back. At sea every army sails alike.")
		meters.morale = meter("Morale", army.morale, config.MoraleMax, Colors.Gold, 3, detail, `Starts at {config.MoraleBase} plus the units' morale bonus; recovers {config.MoraleRecoveryHome} every {config.SupplyTickDays} days on its own land and falls while it starves.`)
		meters.supply = meter(
			"Supply",
			army.supply,
			config.SupplyMax,
			supplyColor(army.supply),
			4,
			detail,
			`Every {config.SupplyTickDays} days: +{config.SupplyGainHome} on land its house controls, unchanged at sea, and down by {config.SupplyLossForeign} or more (by terrain) elsewhere. At zero the army starves and loses men.`
		)
		if army.starving then
			UI.label({
				text = `Starving: the army loses {math.floor(config.AttritionStarving * 100 + 0.5)}% of its men every {config.SupplyTickDays} days until it reaches land its house controls.`,
				wrap = true,
				size = Theme.TextSize.Small,
				font = Fonts.BodySemibold,
				color = Colors.Negative,
				order = 5,
				parent = detail,
			})
		end

		-- Orders card.
		local card = UI.card({ LayoutOrder = 6, Parent = detail, BackgroundColor3 = Colors.ParchmentDeep })
		UI.padding(card, 10)
		UI.list(card, "vertical", 6)
		UI.label({ text = "Orders", font = Fonts.Heading, size = Theme.TextSize.Body, order = 1, parent = card })
		ordersLabel(army, 2, card)
		if isMine and house then
			renderOrders(army, house, card)
		else
			UI.label({
				text = `This army answers to {if owner then owner.name else "another house"}; only its house can command it.`,
				wrap = true,
				size = Theme.TextSize.Small,
				color = Colors.InkMuted,
				order = 3,
				parent = card,
			})
		end

		-- Composition.
		UI.sectionHeader("Composition", 7, detail)
		local rows = vertical(8, detail, 6)
		local unitIds = {}
		for unitId in army.units do
			table.insert(unitIds, unitId)
		end
		table.sort(unitIds, function(a: string, b: string): boolean
			if army.units[a] ~= army.units[b] then
				return army.units[a] > army.units[b]
			end
			return a < b
		end)
		local total = math.max(1, army.troops)
		for index, unitId in unitIds do
			local count = army.units[unitId]
			local unit = Content.units[unitId]
			local row = vertical(index, rows, 2)
			local line = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 1, Parent = row })
			local unitName = UI.label({
				text = `{if unit then unit.name else unitId}  <font color="#6C5A42">{if unit then CLASS_NAMES[unit.class] or unit.class else ""} · {math.floor(count / total * 100 + 0.5)}%</font>`,
				rich = true,
				font = Fonts.BodySemibold,
				width = UDim.new(0.7, 0),
				parent = line,
			})
			unitName.Size = UDim2.fromScale(0.7, 1)
			local value = UI.label({ text = men(count), font = Fonts.BodyBold, align = Enum.TextXAlignment.Right, parent = line })
			value.Position = UDim2.fromScale(0.7, 0)
			value.Size = UDim2.fromScale(0.3, 1)
			local bar = UI.create("Frame", { BackgroundColor3 = Colors.ParchmentDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 5), LayoutOrder = 2, Parent = row })
			UI.corner(bar, 2)
			UI.create("Frame", {
				BackgroundColor3 = Colors.Burgundy,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(math.clamp(count / total, 0, 1), 1),
				Parent = bar,
			})
			Tooltip.setText(row, unitTooltip(unitId, count, total))
		end
	end

	render = function()
		clear()
		lastToday = ArmyInfo.today(store)
		local houseId = store:myHouseId()
		local house = houseId and store:house(houseId)
		if not houseId or not house then
			return
		end
		local selectedId = ctx.selectedArmy()
		local selected = if selectedId then store:army(selectedId) else nil
		if confirmDisband ~= nil and (selected == nil or confirmDisband ~= selected.id) then
			confirmDisband = nil
		end

		UI.label({ text = "Military", size = Theme.TextSize.Title, font = Fonts.Heading, order = 1, parent = content })
		renderSummary(house, 2)
		renderList(store:armiesOf(houseId), selectedId, 4)
		if selected then
			renderArmy(selected, house, 6)
		elseif #store:armiesOf(houseId) > 0 then
			UI.label({
				text = "Select an army in the list or on the map to see it and give it orders.",
				wrap = true,
				size = Theme.TextSize.Small,
				color = Colors.InkMuted,
				order = 6,
				parent = content,
			})
		end
	end

	-- A supply tick changed only morale and supply: move the selected army's meters.
	local function refreshMeters()
		local selectedId = ctx.selectedArmy()
		local army = if selectedId then store:army(selectedId) else nil
		if army then
			local config = GameConfig.Military
			setMeter(meters.morale, army.morale, config.MoraleMax, Colors.Gold)
			setMeter(meters.supply, army.supply, config.SupplyMax, supplyColor(army.supply))
		end
	end

	-- Days passing only change the arrival estimates.
	local function refreshOrders()
		local today = ArmyInfo.today(store)
		if today == lastToday then
			return
		end
		lastToday = today
		for _, entry in liveOrders do
			local army = store:army(entry.armyId)
			if army then
				entry.label.Text = ArmyInfo.ordersText(army, today)
			end
		end
	end

	local panel: UIContext.Panel = {
		update = function(changes)
			if not visible then
				return
			end
			local myHouseId = store:myHouseId()
			local selectedId = ctx.selectedArmy()
			local relevant = changes.full or changes.session or (myHouseId ~= nil and changes.houses[myHouseId] == true)
			local ticked = false
			if not relevant then
				for armyId in changes.armies do
					local army = store:army(armyId)
					if armyId == selectedId or army == nil or army.houseId == myHouseId then
						if army ~= nil and renderedKeys[armyId] == ArmyInfo.structuralKey(army) then
							ticked = true -- only its morale or supply changed
						else
							relevant = true
							break
						end
					end
				end
			end
			if not relevant and selectedId then
				local army = store:army(selectedId)
				local commanderId: string? = if army then army.commanderId else nil
				if commanderId and changes.characters[commanderId] then
					relevant = true
				end
			end
			if relevant then
				render()
			else
				if ticked then
					refreshMeters()
				end
				if changes.clock then
					refreshOrders()
				end
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

return ArmyPanel
