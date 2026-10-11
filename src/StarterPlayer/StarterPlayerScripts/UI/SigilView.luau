--!strict
--[[
	SigilView — a reusable house crest: the house's sigil art (Data/World/SigilArt) drawn on a
	heater shield inside a ViewportFrame. Any screen can use it:

		local crest = SigilView.new("stark", { size = UDim2.fromOffset(60, 72), parent = frame })

	The view keeps the art's 100:120 aspect ratio. A house without art yet shows a plain shield in
	its fallback colour. Transparency fades the whole crest (used by the map at high zoom).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SigilArt = require(ReplicatedStorage.Shared.Data.World.SigilArt)
local FlatTriangles = require(script.Parent.FlatTriangles)

local SigilView = {}

-- A wide field of view keeps the camera close (about 86 studs), so layers 0.1 studs apart never
-- fight for depth while the perspective difference between them stays far below a pixel.
local FIELD_OF_VIEW = 70
local LAYER_STEP = 0.1
local PLAIN_SHIELD = { 4, 4, 96, 4, 96, 60, 4, 4, 96, 60, 4, 60, 4, 60, 96, 60, 50, 116 }

export type Options = {
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	parent: Instance?,
	zIndex: number?,
	fallbackColor: Color3?,
	name: string?,
}

function SigilView.new(houseId: string, options: Options?): ViewportFrame
	local opts: Options = options or {}
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = opts.name or `Sigil_{houseId}`
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Size = opts.size or UDim2.fromOffset(50, 60)
	viewport.Position = opts.position or UDim2.new()
	viewport.AnchorPoint = opts.anchorPoint or Vector2.zero
	viewport.ZIndex = opts.zIndex or 1
	FlatTriangles.setupViewport(viewport)

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 100 / 120
	aspect.Parent = viewport

	-- Fixed camera framing the 100 x 120 art box exactly (the view is always 100:120).
	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.CFrame = FlatTriangles.topDownCFrame(50, 60, 1, 120, FIELD_OF_VIEW)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local parts: { WedgePart } = {}
	local art = SigilArt[houseId]
	if art then
		-- Higher layers are nearer the camera; shrinking each by (distance - height) / distance
		-- about the box centre makes every layer project at exactly the same size.
		local distance = camera.CFrame.Position.Y
		for index, layer in art.layers do
			local height = index * LAYER_STEP
			local k = (distance - height) / distance
			FlatTriangles.addList(parts, layer.tris, height, Color3.fromHex(layer.color), k, 50 * (1 - k), 60 * (1 - k))
		end
	else
		FlatTriangles.addList(parts, PLAIN_SHIELD, 0, opts.fallbackColor or Color3.fromRGB(120, 110, 96))
	end
	local model = Instance.new("Model")
	model.Name = "Art"
	FlatTriangles.parentAll(parts, model)
	model.Parent = viewport

	if opts.parent then
		viewport.Parent = opts.parent
	end
	return viewport
end

-- 0 = opaque, 1 = invisible.
function SigilView.setTransparency(view: ViewportFrame, transparency: number)
	view.ImageTransparency = transparency
end

return SigilView
