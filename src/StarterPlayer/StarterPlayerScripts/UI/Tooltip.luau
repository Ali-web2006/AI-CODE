--!strict
--[[
	Tooltip — one shared tooltip that follows the pointer.

	Any GuiObject can carry a tooltip through Tooltip.bind(object, provider), where provider
	returns rich text (or nil for none) at hover time, so tooltips always describe current state.
	Tooltip.setText is a shortcut for fixed text. On touch devices a long press shows the tooltip
	for a few seconds, because touch screens have no hover.
]]

local UserInputService = game:GetService("UserInputService")

local Tooltip = {}

type Provider = () -> string?

local providers: { [GuiObject]: Provider } = setmetatable({}, { __mode = "k" }) :: any
local bound: { [GuiObject]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local layer: Frame? = nil
local box: Frame? = nil
local textLabel: TextLabel? = nil
local scale = 1
local current: GuiObject? = nil
local touchHideToken = 0

local function position()
	local currentBox, currentLayer = box, layer
	if not currentBox or not currentLayer then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	local viewport = currentLayer.AbsoluteSize
	local size = currentBox.AbsoluteSize
	local x = mouse.X + 16
	local y = mouse.Y + 18
	if x + size.X > viewport.X then
		x = mouse.X - size.X - 12
	end
	if y + size.Y > viewport.Y then
		y = mouse.Y - size.Y - 12
	end
	currentBox.Position = UDim2.fromOffset(math.max(4, x) / scale, math.max(4, y) / scale)
end

local function show(object: GuiObject)
	local provider = providers[object]
	local text = provider and provider()
	local currentBox, label = box, textLabel
	if not text or text == "" or not currentBox or not label then
		return
	end
	current = object
	label.Text = text
	currentBox.Visible = true
	position()
end

local function hide(object: GuiObject?)
	if object == nil or current == object then
		current = nil
		if box then
			box.Visible = false
		end
	end
end

-- Called once by UIController with the tooltip's own full-screen layer (inset-free, scaled).
function Tooltip.mount(parentLayer: Frame, theme: any)
	layer = parentLayer
	local frame = Instance.new("Frame")
	frame.Name = "Tooltip"
	frame.BackgroundColor3 = theme.Colors.Chrome
	frame.BorderSizePixel = 0
	frame.AutomaticSize = Enum.AutomaticSize.XY
	frame.Size = UDim2.fromOffset(0, 0)
	frame.Visible = false
	frame.ZIndex = 50
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = theme.Colors.Gold
	stroke.Thickness = 1
	stroke.Parent = frame
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = frame
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(340, math.huge)
	constraint.Parent = frame

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.RichText = true
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = theme.Colors.TextOnDark
	label.FontFace = theme.Fonts.Body
	label.TextSize = theme.TextSize.Body
	label.ZIndex = 51
	local labelConstraint = Instance.new("UISizeConstraint")
	labelConstraint.MaxSize = Vector2.new(320, math.huge)
	labelConstraint.Parent = label
	label.Parent = frame

	frame.Parent = parentLayer
	box = frame
	textLabel = label

	UserInputService.InputChanged:Connect(function(input)
		if current and input.UserInputType == Enum.UserInputType.MouseMovement then
			position()
		end
	end)
end

function Tooltip.setScale(newScale: number)
	scale = newScale
end

function Tooltip.bind(object: GuiObject, provider: Provider)
	providers[object] = provider
	if bound[object] then
		return
	end
	bound[object] = true
	object.MouseEnter:Connect(function()
		show(object)
	end)
	object.MouseLeave:Connect(function()
		hide(object)
	end)
	object.TouchLongPress:Connect(function(_positions, state)
		if state == Enum.UserInputState.Begin then
			show(object)
			touchHideToken += 1
			local token = touchHideToken
			task.delay(3, function()
				if token == touchHideToken then
					hide(object)
				end
			end)
		end
	end)
	object.AncestryChanged:Connect(function()
		if not object:IsDescendantOf(game) then
			hide(object)
		end
	end)
end

-- Fixed tooltip text; nil removes the tooltip content.
function Tooltip.setText(object: GuiObject, text: string?)
	Tooltip.bind(object, function()
		return text
	end)
	if current == object then
		if text then
			show(object)
		else
			hide(object)
		end
	end
end

return Tooltip
