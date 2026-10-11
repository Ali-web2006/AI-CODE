--!strict
--[[
	UIComponents — small factory functions that give every screen the same visual language.

	Components are plain Instances built with `create`; nothing here holds game state. Buttons
	accept an `onActivated` callback and expose `setEnabled(button, enabled, reason)` so a
	disabled button always explains why (through its tooltip) instead of failing silently.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

local UI = {}

export type Props = { [string]: any }

-- Creates an Instance, applies properties and parents children. `Parent` is applied last.
function UI.create(className: string, props: Props?, children: { Instance }?): any
	local instance = Instance.new(className)
	local parent = nil
	for key, value in props or {} do
		if key == "Parent" then
			parent = value
		else
			(instance :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UI.corner(parent: Instance, radius: number?): UICorner
	return UI.create("UICorner", { CornerRadius = UDim.new(0, radius or Theme.Layout.Corner), Parent = parent })
end

function UI.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return UI.create("UIStroke", {
		Color = color or Colors.ChromeBorder,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function UI.padding(parent: Instance, all: number, horizontal: number?): UIPadding
	local h = horizontal or all
	return UI.create("UIPadding", {
		PaddingTop = UDim.new(0, all),
		PaddingBottom = UDim.new(0, all),
		PaddingLeft = UDim.new(0, h),
		PaddingRight = UDim.new(0, h),
		Parent = parent,
	})
end

function UI.list(parent: Instance, direction: "vertical" | "horizontal", gap: number?, alignment: Enum.HorizontalAlignment?): UIListLayout
	return UI.create("UIListLayout", {
		FillDirection = if direction == "horizontal" then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or Theme.Layout.Gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = alignment or Enum.HorizontalAlignment.Left,
		VerticalAlignment = if direction == "horizontal" then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
		Parent = parent,
	})
end

export type LabelOptions = {
	text: string,
	size: number?,
	font: Font?,
	color: Color3?,
	wrap: boolean?,
	rich: boolean?,
	align: Enum.TextXAlignment?,
	order: number?,
	width: UDim?,
	height: number?,
	parent: Instance?,
}

-- A transparent text label. With wrap = true it grows vertically to fit its text.
function UI.label(options: LabelOptions): TextLabel
	local wrap = options.wrap == true
	local size = options.size or Theme.TextSize.Body
	return UI.create("TextLabel", {
		BackgroundTransparency = 1,
		Text = options.text,
		TextSize = size,
		FontFace = options.font or Fonts.Body,
		TextColor3 = options.color or Colors.Ink,
		TextWrapped = wrap,
		RichText = options.rich == true,
		TextXAlignment = options.align or Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		LayoutOrder = options.order or 0,
		Size = if wrap
			then UDim2.new(options.width or UDim.new(1, 0), UDim.new(0, 0))
			else UDim2.new(options.width or UDim.new(1, 0), UDim.new(0, options.height or size + 6)),
		AutomaticSize = if wrap then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		Parent = options.parent,
	})
end

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger" | "chrome"

local BUTTON_STYLES: { [string]: { background: Color3, text: Color3, border: Color3, hover: Color3 } } = {
	primary = { background = Colors.Burgundy, text = Colors.TextOnDark, border = Colors.Gold, hover = Colors.BurgundyBright },
	secondary = { background = Colors.ParchmentDeep, text = Colors.Ink, border = Colors.ParchmentEdge, hover = Colors.Parchment },
	ghost = { background = Colors.Parchment, text = Colors.Ink, border = Colors.ParchmentEdge, hover = Colors.ParchmentDeep },
	danger = { background = Colors.Negative, text = Colors.TextOnDark, border = Colors.Ink, hover = Colors.NegativeOnDark },
	chrome = { background = Colors.ChromeRaised, text = Colors.TextOnDark, border = Colors.ChromeBorder, hover = Colors.Burgundy },
}

export type ButtonOptions = {
	text: string,
	variant: ButtonVariant?,
	size: UDim2?,
	textSize: number?,
	order: number?,
	parent: Instance?,
	onActivated: (() -> ())?,
}

function UI.button(options: ButtonOptions): TextButton
	local style = BUTTON_STYLES[options.variant or "secondary"]
	local button = UI.create("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = style.background,
		Text = options.text,
		TextColor3 = style.text,
		TextSize = options.textSize or Theme.TextSize.Body,
		FontFace = Fonts.BodyBold,
		Size = options.size or UDim2.new(1, 0, 0, 36),
		LayoutOrder = options.order or 0,
		Parent = options.parent,
	})
	UI.corner(button, 5)
	UI.stroke(button, style.border, 1)
	button:SetAttribute("Enabled", true)
	button:SetAttribute("Selected", false)

	local function refresh(hovered: boolean)
		if not button:GetAttribute("Enabled") then
			button.BackgroundColor3 = Theme.mix(style.background, Colors.Disabled, 0.6)
			button.TextColor3 = Theme.mix(style.text, Colors.Disabled, 0.5)
		elseif button:GetAttribute("Selected") then
			button.BackgroundColor3 = style.hover
			button.TextColor3 = style.text
		else
			button.BackgroundColor3 = if hovered then style.hover else style.background
			button.TextColor3 = style.text
		end
	end
	button.MouseEnter:Connect(function()
		refresh(true)
	end)
	button.MouseLeave:Connect(function()
		refresh(false)
	end)
	button:GetAttributeChangedSignal("Enabled"):Connect(function()
		refresh(false)
	end)
	button:GetAttributeChangedSignal("Selected"):Connect(function()
		refresh(false)
	end)
	if options.onActivated then
		local callback = options.onActivated
		button.Activated:Connect(function()
			if button:GetAttribute("Enabled") then
				callback()
			end
		end)
	end
	return button
end

-- Enables/disables a button created by UI.button; a disabled button shows `reason` on hover.
function UI.setEnabled(button: GuiButton, enabled: boolean, reason: string?)
	button:SetAttribute("Enabled", enabled)
	Tooltip.setText(button, if enabled then nil else reason)
end

function UI.setSelected(button: GuiButton, selected: boolean)
	button:SetAttribute("Selected", selected)
end

-- A parchment card with an inked border.
function UI.card(props: Props?): Frame
	local frame = UI.create("Frame", {
		BackgroundColor3 = Colors.Parchment,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	for key, value in props or {} do
		(frame :: any)[key] = value
	end
	UI.corner(frame)
	UI.stroke(frame, Colors.ParchmentEdge, 1)
	return frame
end

function UI.divider(parent: Instance, order: number?, color: Color3?): Frame
	return UI.create("Frame", {
		BackgroundColor3 = color or Colors.ParchmentEdge,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		LayoutOrder = order or 0,
		Parent = parent,
	})
end

-- A vertical scrolling list whose canvas grows with its content.
function UI.scroll(props: Props?): ScrollingFrame
	local frame = UI.create("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Colors.ParchmentEdge,
	})
	for key, value in props or {} do
		(frame :: any)[key] = value
	end
	return frame
end

-- A small rounded tag ("Great House", trait names).
function UI.chip(text: string, background: Color3, foreground: Color3, order: number?, parent: Instance?): TextLabel
	local chip = UI.create("TextLabel", {
		BackgroundColor3 = background,
		Text = text,
		TextColor3 = foreground,
		TextSize = Theme.TextSize.Small,
		FontFace = Fonts.BodySemibold,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		LayoutOrder = order or 0,
		Parent = parent,
	})
	UI.corner(chip, 10)
	UI.padding(chip, 0, 8)
	return chip
end

-- A label/value row used in stat blocks.
function UI.statRow(label: string, value: string, order: number?, parent: Instance?, valueColor: Color3?): Frame
	local row = UI.create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = order or 0,
		Parent = parent,
	})
	UI.label({ text = label, color = Colors.InkMuted, width = UDim.new(0.55, 0), parent = row })
	local valueLabel = UI.label({
		text = value,
		font = Fonts.BodyBold,
		color = valueColor or Colors.Ink,
		align = Enum.TextXAlignment.Right,
		width = UDim.new(0.45, 0),
		parent = row,
	})
	valueLabel.Position = UDim2.fromScale(0.55, 0)
	valueLabel.Name = "Value"
	return row
end

function UI.sectionHeader(text: string, order: number?, parent: Instance?): TextLabel
	return UI.label({
		text = string.upper(text),
		size = Theme.TextSize.Small,
		font = Fonts.BodyBold,
		color = Colors.Burgundy,
		order = order,
		parent = parent,
	})
end

-- Procedural heraldic shield: field colour, a division in the charge colour, and a monogram.
function UI.shield(houseId: string, size: number, parent: Instance?): Frame
	local house = Content.houses[houseId]
	local heraldry = house and house.heraldry
	local field = if heraldry then Theme.fromRGB(heraldry.field) else Colors.Disabled
	local charge = if heraldry then Theme.fromRGB(heraldry.charge) else Colors.Ink
	local shield = UI.create("Frame", {
		Name = "Shield",
		BackgroundColor3 = field,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, math.floor(size * 1.15)),
		ClipsDescendants = true,
		Parent = parent,
	})
	UI.create("UICorner", { CornerRadius = UDim.new(0.18, 0), Parent = shield })
	UI.stroke(shield, Colors.Gold, math.max(1, math.floor(size / 22)))

	local division = heraldry and heraldry.division or "plain"
	local function band(position: UDim2, bandSize: UDim2)
		UI.create("Frame", {
			BackgroundColor3 = charge,
			BorderSizePixel = 0,
			Position = position,
			Size = bandSize,
			Parent = shield,
		})
	end
	if division == "chief" then
		band(UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.3))
	elseif division == "pale" then
		band(UDim2.fromScale(0.5, 0), UDim2.fromScale(0.5, 1))
	elseif division == "fess" then
		band(UDim2.fromScale(0, 0.38), UDim2.fromScale(1, 0.24))
	elseif division == "quarterly" then
		band(UDim2.fromScale(0.5, 0), UDim2.fromScale(0.5, 0.5))
		band(UDim2.fromScale(0, 0.5), UDim2.fromScale(0.5, 0.5))
	elseif division == "bordure" then
		UI.stroke(shield, charge, math.max(2, math.floor(size / 9)))
	end

	local monogramColor = if division == "plain" or division == "bordure" then charge else Colors.TextOnDark
	UI.create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = heraldry and heraldry.monogram or "?",
		TextColor3 = monogramColor,
		TextStrokeColor3 = Colors.Ink,
		TextStrokeTransparency = if division == "plain" or division == "bordure" then 1 else 0.4,
		FontFace = Fonts.Title,
		TextSize = math.floor(size * 0.62),
		ZIndex = 2,
		Parent = shield,
	})
	return shield
end

-- A horizontal relation bar from -100 to 100 with a baseline marker.
function UI.relationBar(score: number, baseline: number?, parent: Instance?, order: number?): Frame
	local bar = UI.create("Frame", {
		BackgroundColor3 = Colors.ParchmentDeep,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 8),
		LayoutOrder = order or 0,
		Parent = parent,
	})
	UI.corner(bar, 4)
	local center = 0.5
	local fraction = math.clamp(score / 200, -0.5, 0.5)
	UI.create("Frame", {
		BackgroundColor3 = Theme.relationColor(score),
		BorderSizePixel = 0,
		Position = UDim2.fromScale(if fraction >= 0 then center else center + fraction, 0),
		Size = UDim2.fromScale(math.abs(fraction), 1),
		Parent = bar,
	})
	UI.create("Frame", {
		BackgroundColor3 = Colors.Ink,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, -2),
		Size = UDim2.new(0, 1, 1, 4),
		Parent = bar,
	})
	if baseline then
		UI.create("Frame", {
			Name = "Baseline",
			BackgroundColor3 = Colors.Gold,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5 + math.clamp(baseline / 200, -0.5, 0.5), 0, 0, -3),
			Size = UDim2.new(0, 3, 1, 6),
			Parent = bar,
		})
	end
	return bar
end

-- Fades a GuiObject's background briefly to draw attention to a changed value.
function UI.flash(object: GuiObject, color: Color3)
	local original = object.BackgroundColor3
	local originalTransparency = object.BackgroundTransparency
	object.BackgroundColor3 = color
	object.BackgroundTransparency = 0.3
	TweenService:Create(object, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = originalTransparency,
	}):Play()
	task.delay(0.85, function()
		if object.Parent then
			object.BackgroundColor3 = original
		end
	end)
end

UI.Theme = Theme
UI.Tooltip = Tooltip

return UI
