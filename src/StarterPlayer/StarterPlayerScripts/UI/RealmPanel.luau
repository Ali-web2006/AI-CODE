--!strict
--[[
	RealmPanel — the player's house: ruler, family, finances and holdings.

	The finance section shows the server's projected budget for the current month and the ledger of
	the months already settled, so the player can trace every change in the treasury.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local CharacterRules = require(ReplicatedStorage.Shared.Rules.CharacterRules)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

local SKILLS = {
	{ key = "diplomacy", short = "DIP", name = "Diplomacy", effect = "Improves the effect of envoys you send." },
	{ key = "martial", short = "MAR", name = "Martial", effect = "Will lead armies (Phase 5)." },
	{ key = "stewardship", short = "STE", name = "Stewardship", effect = "Raises all tax income by 1.5% per point." },
	{ key = "intrigue", short = "INT", name = "Intrigue", effect = "Will drive schemes (Phase 4)." },
	{ key = "learning", short = "LEA", name = "Learning", effect = "Will matter for faith and counsel (later phases)." },
	{ key = "prowess", short = "PRO", name = "Prowess", effect = "Personal combat skill (Phase 5)." },
}

local RealmPanel = {}

local function traitTooltip(traitId: string): string
	local trait = Content.traits[traitId]
	if not trait then
		return traitId
	end
	local lines = { `<b>{trait.name}</b>`, Format.escape(trait.description) }
	local modifiers = trait.modifiers
	if modifiers then
		if modifiers.taxIncome then
			table.insert(lines, `Tax income {Format.percent(modifiers.taxIncome)}`)
		end
		if modifiers.courtUpkeep then
			table.insert(lines, `Court upkeep {Format.percent(modifiers.courtUpkeep)}`)
		end
		if modifiers.relationsGainSent then
			table.insert(lines, `Envoys sent: {Format.signed(modifiers.relationsGainSent, 0)} relations`)
		end
		if modifiers.relationsGainReceived then
			table.insert(lines, `Envoys received: {Format.signed(modifiers.relationsGainReceived, 0)} relations`)
		end
	end
	return table.concat(lines, "\n")
end

function RealmPanel.mount(parent: Frame, ctx: UIContext.Context): UIContext.Panel
	local store = ctx.store
	local root = UI.scroll({ Name = "RealmPanel", Parent = parent, Visible = false })
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

	local function characterLine(character: { [string]: any }, relationLabel: string, order: number, parentFrame: Instance)
		local clock = store.campaign.clock
		local age = if clock then CharacterRules.age(character :: any, clock.date) else 0
		local status = if character.alive then `age {age}` else `died {character.deathDate.year} AC, aged {age}`
		local label = UI.label({
			text = `<b>{Format.escape(CharacterRules.displayName(character :: any))}</b> <font color="#6C5A42">· {relationLabel} · {status}</font>`,
			rich = true,
			size = Theme.TextSize.Body,
			order = order,
			parent = parentFrame,
		})
		if not character.alive then
			label.TextTransparency = 0.35
		end
	end

	local function render()
		clear()
		local houseId = store:myHouseId()
		local house = houseId and store:house(houseId)
		if not houseId or not house then
			return
		end
		local definition = Content.houses[houseId]
		local ruler = store:character(house.rulerId)
		local clock = store.campaign.clock

		-- Header
		local header = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 1, Parent = content })
		UI.shield(houseId, 50, header)
		local name = UI.label({ text = definition.name, size = Theme.TextSize.Title, font = Fonts.Heading, parent = header })
		name.Position = UDim2.fromOffset(62, 2)
		name.Size = UDim2.new(1, -62, 0, 30)
		local words = UI.label({ text = `"{definition.words}"`, font = Fonts.SerifItalic, size = Theme.TextSize.Small, color = Colors.InkMuted, parent = header })
		words.Position = UDim2.fromOffset(62, 32)
		words.Size = UDim2.new(1, -62, 0, 16)
		local seat = UI.label({ text = `Seat: {definition.seatName} · {if definition.tier == "great" then "Great House" else "Minor House"}`, size = Theme.TextSize.Small, color = Colors.InkMuted, parent = header })
		seat.Position = UDim2.fromOffset(62, 48)
		seat.Size = UDim2.new(1, -62, 0, 16)
		UI.label({ text = definition.description, wrap = true, size = Theme.TextSize.Small, color = Colors.Ink, order = 2, parent = content })

		-- Ruler
		if ruler and clock then
			UI.sectionHeader("Ruler", 3, content)
			local card = UI.card({ LayoutOrder = 4, Parent = content })
			UI.padding(card, 10)
			UI.list(card, "vertical", 6)
			local culture = Content.cultures[ruler.cultureId]
			local faith = Content.faiths[ruler.faithId]
			local epithet: string? = ruler.epithet
			UI.label({
				text = `<b>{Format.escape(CharacterRules.displayName(ruler :: any))}</b>{if epithet then ` <i>{Format.escape(epithet)}</i>` else ""}`,
				rich = true,
				font = Fonts.Serif,
				size = Theme.TextSize.Large,
				order = 1,
				parent = card,
			})
			UI.label({
				text = `Age {CharacterRules.age(ruler :: any, clock.date)} · {culture and culture.name or "?"} · {faith and faith.name or "?"}`,
				size = Theme.TextSize.Small,
				color = Colors.InkMuted,
				order = 2,
				parent = card,
			})
			local skills = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 3, Parent = card })
			UI.create("UIGridLayout", { CellSize = UDim2.new(1 / 6, -4, 1, 0), CellPadding = UDim2.fromOffset(4, 0), SortOrder = Enum.SortOrder.LayoutOrder, Parent = skills })
			for index, skill in SKILLS do
				local cell = UI.create("Frame", { BackgroundColor3 = Colors.ParchmentDeep, LayoutOrder = index, Parent = skills })
				UI.corner(cell, 4)
				local value = UI.label({ text = tostring(ruler.skills[skill.key]), font = Fonts.Heading, size = Theme.TextSize.Large, align = Enum.TextXAlignment.Center, parent = cell })
				value.Size = UDim2.new(1, 0, 0, 22)
				local caption = UI.label({ text = skill.short, size = 11, font = Fonts.BodyBold, color = Colors.InkMuted, align = Enum.TextXAlignment.Center, parent = cell })
				caption.Position = UDim2.fromOffset(0, 22)
				caption.Size = UDim2.new(1, 0, 0, 16)
				Tooltip.setText(cell, `<b>{skill.name} {ruler.skills[skill.key]}</b>\n{skill.effect}`)
			end
			local traits = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = card })
			local traitLayout = UI.list(traits, "horizontal", 6)
			traitLayout.Wraps = true
			for index, traitId in ruler.traits do
				local trait = Content.traits[traitId]
				local chip = UI.chip(trait and trait.name or traitId, Colors.Burgundy, Colors.TextOnDark, index, traits)
				Tooltip.setText(chip, traitTooltip(traitId))
			end

			-- Family
			UI.sectionHeader("Family", 5, content)
			local family = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 6, Parent = content })
			UI.list(family, "vertical", 2)
			local order = 0
			local function add(character: { [string]: any }?, relationLabel: string)
				if character then
					order += 1
					characterLine(character, relationLabel, order, family)
				end
			end
			add(ruler.fatherId and store:character(ruler.fatherId), "father")
			add(ruler.motherId and store:character(ruler.motherId), "mother")
			add(ruler.spouseId and store:character(ruler.spouseId), "spouse")
			local children = {}
			for _, character in store.campaign.characters or {} do
				if character.fatherId == ruler.id or character.motherId == ruler.id then
					table.insert(children, character)
				end
			end
			table.sort(children, function(a, b)
				return CalendarDate.compare(a.birthDate, b.birthDate) < 0
			end)
			for _, child in children do
				add(child, if child.bastard then "natural child" elseif child.sex == "male" then "son" else "daughter")
			end
			if order == 0 then
				UI.label({ text = "No close family.", color = Colors.InkMuted, order = 1, parent = family })
			end
		end

		-- Finances
		UI.sectionHeader("Finances", 7, content)
		local budget = house.budget
		local finances = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 8, Parent = content })
		UI.list(finances, "vertical", 2)
		UI.statRow("Treasury", `{Format.gold(house.treasury)} gold`, 1, finances, if house.treasury >= 0 then Colors.Ink else Colors.Negative)
		UI.statRow("Tax income (projected)", Format.signed(budget.taxIncome), 2, finances, Colors.Positive)
		UI.statRow("Court upkeep", `-{Format.gold(budget.courtUpkeep)}`, 3, finances, Colors.Negative)
		UI.statRow("Garrisons", `-{Format.gold(budget.garrisonUpkeep)}`, 4, finances, Colors.Negative)
		UI.statRow("Administration", `-{Format.gold(budget.administration)}`, 5, finances, Colors.Negative)
		UI.statRow("Net per month", Format.signed(budget.net), 6, finances, if budget.net >= 0 then Colors.Positive else Colors.Negative)

		if #house.ledger > 0 then
			UI.sectionHeader("Settled months", 9, content)
			local ledger = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 10, Parent = content })
			UI.list(ledger, "vertical", 1)
			for index = #house.ledger, 1, -1 do
				local entry = house.ledger[index]
				UI.label({
					text = `{CalendarDate.formatMonthIndex(entry.monthIndex)}  <font color="#548C46">+{Format.gold(entry.income)}</font>  <font color="#B04034">-{Format.gold(entry.expenses)}</font>  = <b>{Format.signed(entry.net)}</b>  -> {Format.gold(entry.treasuryAfter)}`,
					rich = true,
					size = Theme.TextSize.Small,
					order = #house.ledger - index + 1,
					parent = ledger,
				})
			end
		end

		-- Holdings
		UI.sectionHeader("Holdings", 11, content)
		local holdings = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 12, Parent = content })
		UI.list(holdings, "vertical", 2)
		for index, provinceId in house.provinceIds do
			local view = store:province(provinceId)
			if view then
				local link = UI.create("TextButton", {
					BackgroundTransparency = 1,
					AutoButtonColor = false,
					RichText = true,
					Text = `{Content.provinces[provinceId].name}  <font color="#6C5A42">dev {view.development} · {Format.gold(view.income)}/month</font>`,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = Colors.Burgundy,
					TextSize = Theme.TextSize.Body,
					FontFace = Fonts.BodySemibold,
					Size = UDim2.new(1, 0, 0, 22),
					LayoutOrder = index,
					Parent = holdings,
				})
				link.Activated:Connect(function()
					ctx.selectProvince(provinceId, true)
				end)
			end
		end
	end

	local visible = false
	local lastMonth = -1
	local panel: UIContext.Panel = {
		update = function(changes)
			if not visible then
				return
			end
			local houseId = store:myHouseId()
			local clock = store.campaign.clock
			local monthIndex = if clock then CalendarDate.monthIndex(clock.date) else -1
			local relevant = changes.full or changes.session or (houseId ~= nil and changes.houses[houseId] == true)
				or next(changes.provinces) ~= nil or monthIndex ~= lastMonth
			if relevant then
				lastMonth = monthIndex
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

return RealmPanel
