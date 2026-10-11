--!strict
--[[
	MapIcons — small flat map symbols built from plain frames (no image assets), crisp at any UI
	scale: a castle for seats, a house for cities, an anchor for ports and a tower for landmarks.
	Each icon fills a square `holder` frame; shapes are positioned in scale units of the holder.
]]

local MapIcons = {}

export type Kind = "seat" | "city" | "port" | "landmark"

local function piece(holder: GuiObject, x: number, y: number, w: number, h: number, color: Color3, zIndex: number, rotation: number?): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = color
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(w, h)
	frame.Rotation = rotation or 0
	frame.ZIndex = zIndex
	frame.Parent = holder
	return frame
end

local function outlined(holder: GuiObject, x: number, y: number, w: number, h: number, fill: Color3, ink: Color3, zIndex: number): Frame
	local frame = piece(holder, x, y, w, h, fill, zIndex)
	local stroke = Instance.new("UIStroke")
	stroke.Color = ink
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	return frame
end

function MapIcons.build(holder: GuiObject, kind: Kind, ink: Color3, paper: Color3)
	local z = holder.ZIndex
	if kind == "seat" then
		-- Keep with three merlons and a gate.
		outlined(holder, 0.08, 0.36, 0.84, 0.6, paper, ink, z)
		for _, x in { 0.08, 0.4, 0.72 } do
			outlined(holder, x, 0.1, 0.2, 0.24, paper, ink, z)
		end
		piece(holder, 0.4, 0.62, 0.2, 0.34, ink, z + 1)
	elseif kind == "city" then
		-- House with a pitched roof (a rotated square cut by the walls).
		piece(holder, 0.22, 0.12, 0.56, 0.56, ink, z, 45)
		outlined(holder, 0.16, 0.44, 0.68, 0.52, paper, ink, z + 1)
		piece(holder, 0.42, 0.66, 0.16, 0.3, ink, z + 2)
	elseif kind == "port" then
		-- Anchor: ring, shank, stock and flukes.
		local ring = piece(holder, 0.36, 0.02, 0.28, 0.24, paper, z)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = ring
		local ringStroke = Instance.new("UIStroke")
		ringStroke.Color = ink
		ringStroke.Thickness = 1.5
		ringStroke.Parent = ring
		piece(holder, 0.45, 0.24, 0.1, 0.7, ink, z)
		piece(holder, 0.22, 0.34, 0.56, 0.1, ink, z)
		piece(holder, 0.12, 0.78, 0.76, 0.1, ink, z)
		piece(holder, 0.1, 0.6, 0.1, 0.26, ink, z, -20)
		piece(holder, 0.8, 0.6, 0.1, 0.26, ink, z, 20)
	else
		-- Tower with a pointed cap.
		outlined(holder, 0.3, 0.38, 0.4, 0.58, paper, ink, z)
		local cap = piece(holder, 0.5, 0.36, 0.32, 0.32, ink, z + 1, 45)
		cap.AnchorPoint = Vector2.new(0.5, 0.5)
		piece(holder, 0.44, 0.6, 0.12, 0.2, ink, z + 1)
	end
end

return MapIcons
