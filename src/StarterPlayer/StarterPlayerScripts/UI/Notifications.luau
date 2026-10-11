--!strict
--[[
	Notifications — short-lived toasts for important outcomes (rejected requests, envoys to your
	court, treasury crises, saves and loads). Routine events go only to the Chronicle so the screen
	is never flooded; at most MAX_VISIBLE toasts are shown at once.
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local UI = require(script.Parent.UIComponents)

local Colors = Theme.Colors

local MAX_VISIBLE = 4
local LIFETIME = 4.5

local TONE_COLORS = {
	good = Colors.Positive,
	bad = Colors.Negative,
	info = Colors.Gold,
	quiet = Colors.ParchmentEdge,
}

export type Notifications = {
	toast: (text: string, tone: string) -> (),
}

local Notifications = {}

function Notifications.mount(parent: Frame): Notifications
	local stack = UI.create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(440, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 30,
		Parent = parent,
	})
	local layout = UI.list(stack, "vertical", 6, Enum.HorizontalAlignment.Center)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	local counter = 0

	local function toast(text: string, tone: string)
		counter += 1
		local toastFrame = UI.create("Frame", {
			BackgroundColor3 = Colors.Chrome,
			BackgroundTransparency = 0.05,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = counter,
			ZIndex = 30,
			Parent = stack,
		})
		UI.corner(toastFrame)
		UI.stroke(toastFrame, TONE_COLORS[tone] or Colors.Gold, 1.5)
		UI.padding(toastFrame, 8, 12)
		local label = UI.label({ text = text, wrap = true, color = Colors.TextOnDark, size = Theme.TextSize.Body, parent = toastFrame })
		label.ZIndex = 31

		local toasts = {}
		for _, child in stack:GetChildren() do
			if child:IsA("Frame") then
				table.insert(toasts, child)
			end
		end
		table.sort(toasts, function(a, b)
			return (a :: Frame).LayoutOrder < (b :: Frame).LayoutOrder
		end)
		for index = 1, #toasts - MAX_VISIBLE do
			toasts[index]:Destroy()
		end

		task.delay(LIFETIME, function()
			if not toastFrame.Parent then
				return
			end
			local info = TweenInfo.new(0.4)
			TweenService:Create(toastFrame, info, { BackgroundTransparency = 1 }):Play()
			TweenService:Create(label, info, { TextTransparency = 1 }):Play()
			task.wait(0.45)
			toastFrame:Destroy()
		end)
	end

	return { toast = toast }
end

return Notifications
