--!strict
-- ChroniclePanel — the event log: everything the simulation reported to this player, newest first.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local EventText = require(ReplicatedStorage.Shared.Text.EventText)
local Theme = require(script.Parent.Theme)
local UI = require(script.Parent.UIComponents)
local UIContext = require(script.Parent.UIContext)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

local TONE_COLORS = {
	good = Colors.Positive,
	bad = Colors.Negative,
	info = Colors.Gold,
	quiet = Colors.ParchmentEdge,
}

local ChroniclePanel = {}

function ChroniclePanel.mount(parent: Frame, ctx: UIContext.Context): UIContext.Panel
	local store = ctx.store
	local root = UI.scroll({ Name = "ChroniclePanel", Parent = parent, Visible = false })
	local content = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = root })
	UI.list(content, "vertical", 6)
	UI.padding(content, 2, 2)
	local visible = false

	local function render()
		for _, child in content:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
		UI.label({ text = "Chronicle", size = Theme.TextSize.Title, font = Fonts.Heading, order = 0, parent = content })
		if #store.eventLog == 0 then
			UI.label({ text = "Nothing has happened yet. Start the clock to let the realm move.", wrap = true, color = Colors.InkMuted, order = 1, parent = content })
			return
		end
		local myHouseId = store:myHouseId()
		local order = 0
		for index = #store.eventLog, 1, -1 do
			local event = store.eventLog[index]
			local text, tone = EventText.format(event, myHouseId)
			order += 1
			local row = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = content })
			UI.create("Frame", { BackgroundColor3 = TONE_COLORS[tone] or Colors.ParchmentEdge, BorderSizePixel = 0, Size = UDim2.new(0, 3, 1, 0), Parent = row })
			local body = UI.create("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = row })
			UI.list(body, "vertical", 0)
			UI.label({ text = CalendarDate.format(event.date), size = 12, font = Fonts.BodyBold, color = Colors.InkMuted, order = 1, parent = body })
			UI.label({ text = text, wrap = true, size = Theme.TextSize.Small, color = Colors.Ink, order = 2, parent = body })
		end
	end

	local panel: UIContext.Panel = {
		update = function(changes)
			if visible and (changes.full or #changes.events > 0) then
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

return ChroniclePanel
