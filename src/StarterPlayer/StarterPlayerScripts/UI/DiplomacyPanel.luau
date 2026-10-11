--!strict
--[[
	DiplomacyPanel — every other house, its standing with yours, and the Improve Relations action.

	The list shows each house's relation (symmetric house-level relations), the historical reason
	for the baseline, and whether it borders you. Selecting a house shows its power and the envoy
	action with a preview of cost and gain computed by the shared DiplomacyRules from replicated
	data; the server recomputes and validates everything when the request arrives.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local CharacterRules = require(ReplicatedStorage.Shared.Rules.CharacterRules)
local Content = require(ReplicatedStorage.Shared.Data.Content)
local DiplomacyRules = require(ReplicatedStorage.Shared.Rules.DiplomacyRules)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Format = require(script.Parent.Format)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts
local Diplomacy = GameConfig.Diplomacy

local DiplomacyPanel = {}

-- Historical reasons for baseline relations, from the bookmark definition.
local function baselineReason(bookmarkId: string?, houseA: string, houseB: string): string?
	local bookmark = bookmarkId and Content.getBookmark(bookmarkId)
	if not bookmark then
		return nil
	end
	local key = DiplomacyRules.relationKey(houseA, houseB)
	for _, relation in bookmark.relations do
		if DiplomacyRules.relationKey(relation.a, relation.b) == key then
			return relation.reason
		end
	end
	return nil
end

local function bordersHouse(store: any, houseA: string, houseB: string): boolean
	local houseView = store:house(houseA)
	if not houseView then
		return false
	end
	for _, provinceId in houseView.provinceIds do
		for neighbourId in Content.provinces[provinceId].adjacent do
			local neighbour = store:province(neighbourId)
			if neighbour and neighbour.ownerHouseId == houseB then
				return true
			end
		end
	end
	return false
end

function DiplomacyPanel.mount(parent: Frame, ctx: UIContext.Context): (UIContext.Panel, (houseId: string) -> ())
	local store = ctx.store
	local root = UI.scroll({ Name = "DiplomacyPanel", Parent = parent, Visible = false })
	local content = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = root })
	UI.list(content, "vertical", 8)
	UI.padding(content, 2, 2)

	local selectedHouse: string? = nil
	local visible = false

	local function clear()
		for _, child in content:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
	end

	local render: () -> ()

	local function renderDetail(myHouseId: string, targetId: string, order: number)
		local target = Content.houses[targetId]
		local targetView = store:house(targetId)
		local relation = store:relation(myHouseId, targetId)
		local clock = store.campaign.clock
		if not targetView or not relation or not clock then
			return
		end
		local card = UI.card({ LayoutOrder = order, Parent = content, BackgroundColor3 = Colors.ParchmentDeep })
		UI.padding(card, 10)
		UI.list(card, "vertical", 6)

		local header = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = 1, Parent = card })
		UI.shield(targetId, 38, header)
		local title = UI.label({ text = target.name, font = Fonts.Heading, size = Theme.TextSize.Large, parent = header })
		title.Position = UDim2.fromOffset(48, 2)
		title.Size = UDim2.new(1, -48, 0, 22)
		local ruler = store:character(targetView.rulerId)
		local player = store:playerForHouse(targetId)
		local sub = UI.label({
			text = `{if ruler then CharacterRules.displayName(ruler :: any) else "?"} · {if player then `led by {player.name}` else "AI"}`,
			size = Theme.TextSize.Small,
			color = Colors.InkMuted,
			parent = header,
		})
		sub.Position = UDim2.fromOffset(48, 25)
		sub.Size = UDim2.new(1, -48, 0, 18)

		local tier = DiplomacyRules.tierFor(relation.score, Diplomacy)
		UI.label({
			text = `Relations: <b>{relation.score}</b> ({tier.label}) · baseline {relation.baseline}`,
			rich = true,
			order = 2,
			parent = card,
		})
		UI.relationBar(relation.score, relation.baseline, card, 3)
		local reason = baselineReason(store.campaign.bookmarkId, myHouseId, targetId)
		UI.label({
			text = (if reason then reason .. " " else "")
				.. `Relations drift toward the baseline by {Diplomacy.DriftPerMonth} per month.`,
			wrap = true,
			size = Theme.TextSize.Small,
			color = Colors.InkMuted,
			order = 4,
			parent = card,
		})
		local stats = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = card })
		UI.list(stats, "vertical", 1)
		UI.statRow("Provinces", tostring(#targetView.provinceIds), 1, stats)
		UI.statRow("Total development", tostring(targetView.totalDevelopment), 2, stats)
		UI.statRow("Monthly net income", Format.signed(targetView.budget.net), 3, stats)
		UI.statRow("Treasury", Format.gold(targetView.treasury), 4, stats)
		UI.statRow("Borders your realm", if bordersHouse(store, myHouseId, targetId) then "Yes" else "No", 5, stats)

		-- Improve Relations action
		local settings = Diplomacy.ImproveRelations
		local myHouse = store:house(myHouseId)
		local myRuler = myHouse and store:character(myHouse.rulerId)
		local gain, lines = DiplomacyRules.improveRelationsGain(myRuler :: any, ruler :: any, Diplomacy)
		local projected = math.min(Diplomacy.MaxRelation, relation.score + gain)
		local key = `envoy:{targetId}`
		local button = UI.button({
			text = `Send envoy ({settings.GoldCost} gold)`,
			variant = "primary",
			order = 7,
			parent = card,
			onActivated = function()
				ctx.run(Protocol.Commands.ImproveRelations, { targetHouseId = targetId }, key, function()
					render()
				end)
			end,
		})
		local breakdown = {}
		for _, line in lines do
			table.insert(breakdown, `{line.label} {Format.signed(line.value, 0)}`)
		end
		UI.label({
			text = `Improve Relations: {relation.score} -> {projected} ({table.concat(breakdown, ", ")}). Another envoy may follow after {settings.CooldownMonths} months.`,
			wrap = true,
			size = Theme.TextSize.Small,
			order = 6,
			parent = card,
		})

		local monthIndex = CalendarDate.monthIndex(clock.date)
		local availableFrom = relation.cooldowns and relation.cooldowns[myHouseId]
		local treasury = myHouse and myHouse.treasury or 0
		if relation.score >= Diplomacy.MaxRelation then
			UI.setEnabled(button, false, "Relations cannot improve further.")
		elseif availableFrom and monthIndex < availableFrom then
			local months = availableFrom - monthIndex
			UI.setEnabled(button, false, `An envoy recently visited. Next envoy in {months} month{if months == 1 then "" else "s"} ({CalendarDate.formatMonthIndex(availableFrom)}).`)
		elseif treasury < settings.GoldCost then
			UI.setEnabled(button, false, `Requires {settings.GoldCost} gold; your treasury holds {Format.gold(treasury)}.`)
		else
			Tooltip.setText(button, `Spend {settings.GoldCost} gold on gifts and an envoy to {target.name}.`)
		end
	end

	render = function()
		clear()
		local myHouseId = store:myHouseId()
		if not myHouseId then
			return
		end
		UI.label({ text = "Diplomacy", size = Theme.TextSize.Title, font = Fonts.Heading, order = 1, parent = content })
		UI.label({
			text = "Relations between houses are mutual. Send envoys to improve them; they slowly return to their historical baseline.",
			wrap = true,
			size = Theme.TextSize.Small,
			color = Colors.InkMuted,
			order = 2,
			parent = content,
		})

		local others = {}
		for _, houseId in Content.houseIds do
			local view = store:house(houseId)
			if houseId ~= myHouseId and view and not view.extinct then
				table.insert(others, houseId)
			end
		end
		table.sort(others, function(a, b)
			local ra, rb = store:relation(myHouseId, a), store:relation(myHouseId, b)
			local sa, sb = ra and ra.score or 0, rb and rb.score or 0
			if sa ~= sb then
				return sa > sb
			end
			return a < b
		end)

		local order = 10
		for _, houseId in others do
			local relation = store:relation(myHouseId, houseId)
			local score = relation and relation.score or 0
			local row = UI.create("TextButton", {
				AutoButtonColor = false,
				Text = "",
				BackgroundColor3 = if houseId == selectedHouse then Colors.ParchmentDeep else Colors.Parchment,
				Size = UDim2.new(1, 0, 0, 50),
				LayoutOrder = order,
				Parent = content,
			})
			UI.corner(row, 5)
			UI.stroke(row, if houseId == selectedHouse then Colors.Gold else Colors.ParchmentEdge, if houseId == selectedHouse then 2 else 1)
			UI.padding(row, 6)
			UI.shield(houseId, 30, row)
			local name = UI.label({ text = Content.houses[houseId].name, font = Fonts.BodyBold, parent = row })
			name.Position = UDim2.fromOffset(40, 0)
			name.Size = UDim2.new(1, -110, 0, 18)
			local tier = DiplomacyRules.tierFor(score, Diplomacy)
			local value = UI.label({ text = `{score} {tier.label}`, font = Fonts.BodyBold, size = Theme.TextSize.Small, align = Enum.TextXAlignment.Right, color = Theme.mix(Theme.relationColor(score), Colors.Ink, 0.35), parent = row })
			value.Position = UDim2.new(1, -110, 0, 0)
			value.Size = UDim2.fromOffset(110, 18)
			local barHolder = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(40, 24), Size = UDim2.new(1, -40, 0, 10), Parent = row })
			UI.relationBar(score, relation and relation.baseline, barHolder)
			row.Activated:Connect(function()
				selectedHouse = if selectedHouse == houseId then nil else houseId
				render()
			end)
			Tooltip.bind(row, function()
				local reason = baselineReason(store.campaign.bookmarkId, myHouseId, houseId)
				return `<b>{Content.houses[houseId].name}</b>: relations {score}` .. (if reason then `\n{Format.escape(reason)}` else "")
			end)
			order += 1
			if houseId == selectedHouse then
				renderDetail(myHouseId, houseId, order)
				order += 1
			end
		end
	end

	local function focus(houseId: string)
		selectedHouse = houseId
		if visible then
			render()
		end
	end

	local lastMonth = -1
	local panel: UIContext.Panel = {
		update = function(changes)
			if not visible then
				return
			end
			local clock = store.campaign.clock
			local monthIndex = if clock then CalendarDate.monthIndex(clock.date) else -1
			if changes.full or changes.session or next(changes.relations) ~= nil or next(changes.houses) ~= nil or monthIndex ~= lastMonth then
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
	return panel, focus
end

return DiplomacyPanel
