--!strict
--[[
	MapController — the strategic map.

	Layers inside the map container (bottom to top):
	  DragCatcher  transparent button that receives pan/click input on empty map
	  Canvas       geometry in map units, scaled by a UIScale for zoom: sea, coastline, landmass,
	               territory halos, routes between adjacent provinces, region labels
	  Symbols      province nodes positioned in screen space (constant size at every zoom, so they
	               stay readable and easy to tap)
	  Overlay      map-mode selector, legend and zoom buttons

	All province data shown comes from the replicated server state; static geometry comes from
	shared Content. Map modes: realm (owner), relations (to your house), wealth (income), terrain.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Format = require(script.Parent.Parent.UI.Format)
local Theme = require(script.Parent.Parent.UI.Theme)
local Tooltip = require(script.Parent.Parent.UI.Tooltip)
local UI = require(script.Parent.Parent.UI.UIComponents)
local ReplicaStore = require(script.Parent.ReplicaStore)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

export type MapMode = "realm" | "relations" | "wealth" | "terrain"

export type Options = {
	store: ReplicaStore.ReplicaStore,
	getScale: () -> number,
	onSelect: (provinceId: string?) -> (),
}

type Node = {
	button: TextButton,
	marker: Frame,
	markerStroke: UIStroke,
	badge: TextLabel,
	ring: Frame,
	halo: Frame,
	hoverScale: UIScale,
}

local MapController = {}

local MAP_WIDTH = Content.map.width
local MAP_HEIGHT = Content.map.height
local MAX_ZOOM = 2.4
local ROUTE_TRIM = 14

type RouteStyle = {
	color: Color3,
	thickness: number,
	dash: number?,
	gap: number?,
	transparency: number,
}

local ROUTE_STYLES: { [string]: RouteStyle } = {
	road = { color = Colors.Road, thickness = 3, dash = nil, gap = nil, transparency = 0.2 },
	river = { color = Colors.River, thickness = 3, dash = nil, gap = nil, transparency = 0.15 },
	pass = { color = Colors.Pass, thickness = 3, dash = 10, gap = 6, transparency = 0.1 },
	sea = { color = Colors.SeaLane, thickness = 2.5, dash = 6, gap = 8, transparency = 0.15 },
	wild = { color = Colors.Wild, thickness = 2, dash = 6, gap = 6, transparency = 0.25 },
}

local options: Options
local container: Frame
local canvas: Frame
local canvasScale: UIScale
local symbols: Frame
local legend: Frame
local modeButtons: { [string]: TextButton } = {}
local nodes: { [string]: Node } = {}

local zoom = 0.5
local offset = Vector2.zero
local mode: MapMode = "realm"
local selectedId: string? = nil
local hovering = false

-- Geometry helpers ----------------------------------------------------------------------------

local function circle(parent: Instance, x: number, y: number, radius: number, color: Color3, transparency: number?, zIndex: number?): Frame
	local frame = UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(radius * 2, radius * 2),
		BackgroundColor3 = color,
		BackgroundTransparency = transparency or 0,
		BorderSizePixel = 0,
		ZIndex = zIndex or 1,
		Parent = parent,
	})
	UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = frame })
	return frame
end

local function segment(parent: Instance, from: Vector2, to: Vector2, style: RouteStyle, zIndex: number)
	local delta = to - from
	local length = delta.Magnitude
	if length <= 0 then
		return
	end
	UI.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset((from.X + to.X) / 2, (from.Y + to.Y) / 2),
		Size = UDim2.fromOffset(length, style.thickness),
		Rotation = math.deg(math.atan2(delta.Y, delta.X)),
		BackgroundColor3 = style.color,
		BackgroundTransparency = style.transparency,
		BorderSizePixel = 0,
		ZIndex = zIndex,
		Parent = parent,
	})
end

local function route(parent: Instance, a: Vector2, b: Vector2, kind: string)
	local style = ROUTE_STYLES[kind] or ROUTE_STYLES.road
	local direction = (b - a).Unit
	local from = a + direction * ROUTE_TRIM
	local to = b - direction * ROUTE_TRIM
	local length = (to - from).Magnitude
	local dash, gap = style.dash, style.gap
	if not dash or not gap then
		segment(parent, from, to, style, 5)
		return
	end
	local travelled = 0
	while travelled < length do
		local dashEnd = math.min(length, travelled + dash)
		segment(parent, from + direction * travelled, from + direction * dashEnd, style, 5)
		travelled = dashEnd + gap
	end
end

local function spaced(text: string): string
	return (string.gsub(text, "(.)", "%1 ")):sub(1, -2)
end

-- Territory halo radius: a fraction of the distance to the nearest province, so neighbouring
-- territories touch without one swallowing another.
local function haloRadii(): { [string]: number }
	local radii = {}
	for _, idA in Content.provinceIds do
		local a = Content.provinces[idA].position
		local nearest = math.huge
		for _, idB in Content.provinceIds do
			if idA ~= idB then
				local b = Content.provinces[idB].position
				nearest = math.min(nearest, math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2))
			end
		end
		radii[idA] = math.clamp(nearest * 0.62, 34, 82)
	end
	return radii
end

-- Colouring -----------------------------------------------------------------------------------

local maxIncome = 1

local function provinceColor(provinceId: string): Color3
	local store = options.store
	local view = store:province(provinceId)
	if not view then
		return Colors.Disabled
	end
	if mode == "realm" then
		local house = Content.houses[view.ownerHouseId]
		return if house then Theme.fromRGB(house.mapColor) else Colors.Disabled
	elseif mode == "relations" then
		local myHouseId = store:myHouseId()
		if not myHouseId then
			return Colors.Disabled
		end
		if view.ownerHouseId == myHouseId then
			return Colors.Gold
		end
		local relation = store:relation(myHouseId, view.ownerHouseId)
		return Theme.relationColor(if relation then relation.score else 0)
	elseif mode == "wealth" then
		local t = math.clamp((view.income or 0) / maxIncome, 0, 1)
		return Theme.mix(Color3.fromRGB(236, 226, 196), Color3.fromRGB(120, 80, 20), t ^ 0.8)
	end
	local terrain = Content.terrains[Content.provinces[provinceId].terrainId]
	return Theme.fromRGB(terrain.color)
end

local function updateNode(provinceId: string)
	local node = nodes[provinceId]
	local view = options.store:province(provinceId)
	if not node or not view then
		return
	end
	local color = provinceColor(provinceId)
	node.marker.BackgroundColor3 = color
	node.halo.BackgroundColor3 = color
	node.halo.BackgroundTransparency = if mode == "terrain" then 0.35 else 0.5
	node.badge.Text = tostring(view.development)
	local mine = view.ownerHouseId == options.store:myHouseId()
	node.markerStroke.Color = if mine then Colors.GoldBright else Colors.Ink
	node.markerStroke.Thickness = if mine then 2.5 else 1.5
	node.ring.Visible = provinceId == selectedId
end

local function recomputeMaxIncome()
	maxIncome = 1
	for _, provinceId in Content.provinceIds do
		local view = options.store:province(provinceId)
		local income = if view then view.income else nil
		if type(income) == "number" and income > maxIncome then
			maxIncome = income
		end
	end
end

-- Legend --------------------------------------------------------------------------------------

local function legendRow(text: string, color: Color3, order: number)
	local row = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = order, Parent = legend })
	local swatch = UI.create("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(12, 12),
		Position = UDim2.fromOffset(0, 2),
		Parent = row,
	})
	UI.corner(swatch, 3)
	UI.stroke(swatch, Colors.Ink, 1, 0.5)
	local label = UI.label({ text = text, size = Theme.TextSize.Small, color = Colors.Ink, parent = row, height = 16 })
	label.Position = UDim2.fromOffset(18, 0)
	label.Size = UDim2.new(1, -18, 1, 0)
end

local function rebuildLegend()
	for _, child in legend:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if mode == "realm" then
		UI.label({ text = "Colour shows the owning house. Gold outlines mark your provinces.", size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 1, parent = legend })
	elseif mode == "relations" then
		legendRow("Your house", Colors.Gold, 1)
		legendRow("Friendly (+100)", Theme.relationColor(100), 2)
		legendRow("Neutral (0)", Theme.relationColor(0), 3)
		legendRow("Hostile (-100)", Theme.relationColor(-100), 4)
	elseif mode == "wealth" then
		legendRow(`Poor`, Color3.fromRGB(236, 226, 196), 1)
		legendRow(`Rich ({Format.gold(maxIncome)} gold/month)`, Color3.fromRGB(120, 80, 20), 2)
	else
		local order = 0
		for _, terrain in Content.raw.terrains do
			order += 1
			legendRow(terrain.name, Theme.fromRGB(terrain.color), order)
		end
	end
	UI.label({ text = "Routes: road, river, ~ sea lane, - - mountain pass", size = Theme.TextSize.Small, wrap = true, color = Colors.InkMuted, order = 99, parent = legend })
end

-- View transform ------------------------------------------------------------------------------

local function viewSize(): Vector2
	local scale = options.getScale()
	return container.AbsoluteSize / scale
end

local function minZoom(): number
	local size = viewSize()
	return math.min(size.X / MAP_WIDTH, size.Y / MAP_HEIGHT) * 0.9
end

local function clampView()
	local size = viewSize()
	zoom = math.clamp(zoom, minZoom(), MAX_ZOOM)
	local width, height = MAP_WIDTH * zoom, MAP_HEIGHT * zoom
	local x = math.clamp(offset.X, math.min(size.X * 0.6 - width, size.X * 0.05), math.max(size.X * 0.4, size.X - width))
	local y = math.clamp(offset.Y, math.min(size.Y * 0.6 - height, size.Y * 0.05), math.max(size.Y * 0.4, size.Y - height))
	offset = Vector2.new(x, y)
end

local function applyView()
	clampView()
	canvasScale.Scale = zoom
	canvas.Position = UDim2.fromOffset(offset.X, offset.Y)
	for provinceId, node in nodes do
		local position = Content.provinces[provinceId].position
		node.button.Position = UDim2.fromOffset(offset.X + position.x * zoom, offset.Y + position.y * zoom)
	end
end

-- Zooms by `factor`, keeping the map point under `anchor` (container-local virtual px) fixed.
local function zoomAt(factor: number, anchor: Vector2)
	local mapPoint = (anchor - offset) / zoom
	zoom = math.clamp(zoom * factor, minZoom(), MAX_ZOOM)
	offset = anchor - mapPoint * zoom
	applyView()
end

local function toLocal(screenPosition: Vector3 | Vector2): Vector2
	local scale = options.getScale()
	return (Vector2.new(screenPosition.X, screenPosition.Y) - container.AbsolutePosition) / scale
end

function MapController.fitToView()
	local size = viewSize()
	zoom = math.max(minZoom(), size.Y / MAP_HEIGHT * 0.98)
	offset = Vector2.new((size.X - MAP_WIDTH * zoom) / 2, (size.Y - MAP_HEIGHT * zoom) / 2)
	applyView()
end

function MapController.focusProvince(provinceId: string, targetZoom: number?)
	local definition = Content.provinces[provinceId]
	if not definition then
		return
	end
	local size = viewSize()
	zoom = math.clamp(targetZoom or math.max(zoom, 0.8), minZoom(), MAX_ZOOM)
	offset = size / 2 - Vector2.new(definition.position.x, definition.position.y) * zoom
	applyView()
end

-- Input ----------------------------------------------------------------------------------------

local function bindInput(dragCatcher: TextButton)
	local dragging = false
	local dragInput: InputObject? = nil
	local lastPosition = Vector2.zero
	local travelled = 0
	local pinching = false
	local pinchStartZoom = zoom

	dragCatcher.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				return
			end
			dragging = true
			dragInput = input
			lastPosition = Vector2.new(input.Position.X, input.Position.Y)
			travelled = 0
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and not pinching then
			local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement and dragInput
				and dragInput.UserInputType == Enum.UserInputType.MouseButton1
			if isMouse or input == dragInput then
				local position = Vector2.new(input.Position.X, input.Position.Y)
				local delta = (position - lastPosition) / options.getScale()
				lastPosition = position
				travelled += delta.Magnitude
				offset += delta
				applyView()
			end
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and hovering then
			local factor = if input.Position.Z > 0 then 1.15 else 1 / 1.15
			zoomAt(factor, toLocal(input.Position))
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if not dragging then
			return
		end
		if input == dragInput or (input.UserInputType == Enum.UserInputType.MouseButton1 and dragInput
			and dragInput.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = false
			dragInput = nil
			if travelled < 4 and not pinching then
				-- A click on empty map clears the selection.
				options.onSelect(nil)
			end
		end
	end)

	UserInputService.TouchPinch:Connect(function(positions, scale, _velocity, state)
		if not hovering and state == Enum.UserInputState.Begin then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinching = true
			pinchStartZoom = zoom
		elseif state == Enum.UserInputState.Change and pinching then
			local anchor = if #positions >= 2 then toLocal((positions[1] + positions[2]) / 2) else viewSize() / 2
			zoomAt((pinchStartZoom * scale) / zoom, anchor)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			pinching = false
			dragging = false
			dragInput = nil
		end
	end)

	container.MouseEnter:Connect(function()
		hovering = true
	end)
	container.MouseLeave:Connect(function()
		hovering = false
	end)
	container.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			hovering = true
		end
	end)
end

-- Construction ---------------------------------------------------------------------------------

local function buildGeometry()
	-- Coastline: slightly larger darker circles under the land produce an outline of the union.
	for _, blob in Content.map.landmass do
		circle(canvas, blob.x, blob.y, blob.r + 6, Colors.Coast, 0, 1)
	end
	for _, blob in Content.map.landmass do
		circle(canvas, blob.x, blob.y, blob.r, Colors.Land, 0, 2)
	end
	for _, label in Content.map.labels do
		local isSea = string.find(label.text, "SEA", 1, true) ~= nil
		UI.create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(label.x, label.y),
			Size = UDim2.fromOffset(320, 30),
			BackgroundTransparency = 1,
			Text = spaced(label.text),
			TextSize = if isSea then 15 else 19,
			FontFace = if isSea then Fonts.SerifItalic else Fonts.Heading,
			TextColor3 = if isSea then Colors.SeaLane else Colors.MapLabel,
			TextTransparency = if isSea then 0.2 else 0.45,
			ZIndex = 6,
			Parent = canvas,
		})
	end
	for _, idA in Content.provinceIds do
		local a = Content.provinces[idA]
		for idB, kind in a.adjacent do
			if idA < idB then
				local b = Content.provinces[idB]
				route(canvas, Vector2.new(a.position.x, a.position.y), Vector2.new(b.position.x, b.position.y), kind)
			end
		end
	end
end

local function provinceTooltip(provinceId: string): string?
	local view = options.store:province(provinceId)
	local definition = Content.provinces[provinceId]
	if not view then
		return nil
	end
	local owner = Content.houses[view.ownerHouseId]
	local terrain = Content.terrains[definition.terrainId]
	local holding = Content.holdingKinds[definition.holding.kind]
	return `<b>{Format.escape(definition.name)}</b>\n{holding.name} of {Format.escape(definition.holding.name)} · {terrain.name}\nOwner: {owner and owner.name or "?"}\nDevelopment {view.development}/{GameConfig.Economy.MaxDevelopment} · Income {Format.gold(view.income)} gold/month`
end

local function buildNodes()
	local radii = haloRadii()
	for _, provinceId in Content.provinceIds do
		local definition = Content.provinces[provinceId]
		local holding = Content.holdingKinds[definition.holding.kind]

		local halo = circle(canvas, definition.position.x, definition.position.y, radii[provinceId], Colors.Disabled, 0.5, 3)
		halo.Name = `Halo_{provinceId}`

		local button = UI.create("TextButton", {
			Name = `Province_{provinceId}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(34, 34),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 10,
			Parent = symbols,
		})
		local hoverScale = UI.create("UIScale", { Scale = 1, Parent = button })

		local ring = UI.create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(42, 42),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 10,
			Parent = button,
		})
		UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = ring })
		UI.stroke(ring, Colors.Selection, 3)

		local markerSize = if holding.marker == "diamond" then 17 else 22
		local marker = UI.create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(markerSize, markerSize),
			Rotation = if holding.marker == "diamond" then 45 else 0,
			BorderSizePixel = 0,
			ZIndex = 11,
			Parent = button,
		})
		if holding.marker == "circle" or holding.marker == "ring" then
			UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = marker })
		else
			UI.corner(marker, 3)
		end
		if holding.marker == "ring" then
			local hole = UI.create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.42, 0.42),
				BackgroundColor3 = Colors.Land,
				BorderSizePixel = 0,
				ZIndex = 12,
				Parent = marker,
			})
			UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = hole })
		end
		local markerStroke = UI.stroke(marker, Colors.Ink, 1.5)

		local badge = UI.create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, 0, 0, 2),
			Size = UDim2.fromOffset(15, 15),
			BackgroundColor3 = Colors.Chrome,
			Text = "",
			TextColor3 = Colors.GoldBright,
			TextSize = 11,
			FontFace = Fonts.BodyBold,
			ZIndex = 13,
			Parent = button,
		})
		UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = badge })

		UI.create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 1, -2),
			Size = UDim2.fromOffset(150, 16),
			BackgroundTransparency = 1,
			Text = definition.name,
			TextColor3 = Colors.Ink,
			TextStrokeColor3 = Colors.Land,
			TextStrokeTransparency = 0.2,
			TextSize = 13,
			FontFace = Fonts.Heading,
			ZIndex = 12,
			Parent = button,
		})

		button.Activated:Connect(function()
			options.onSelect(provinceId)
		end)
		button.MouseEnter:Connect(function()
			hoverScale.Scale = 1.15
		end)
		button.MouseLeave:Connect(function()
			hoverScale.Scale = 1
		end)
		Tooltip.bind(button, function()
			return provinceTooltip(provinceId)
		end)

		nodes[provinceId] = {
			button = button,
			marker = marker,
			markerStroke = markerStroke,
			badge = badge,
			ring = ring,
			halo = halo,
			hoverScale = hoverScale,
		}
	end
end

local function buildOverlay()
	local modes = UI.create("Frame", {
		Name = "MapModes",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -10),
		Size = UDim2.fromOffset(196, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Parchment,
		BackgroundTransparency = 0.05,
		Active = true, -- sink clicks so they do not reach the map underneath
		ZIndex = 20,
		Parent = container,
	})
	UI.corner(modes)
	UI.stroke(modes, Colors.ParchmentEdge)
	UI.padding(modes, 8)
	UI.list(modes, "vertical", 6)
	UI.sectionHeader("Map mode", 1, modes)

	local grid = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = 2, Parent = modes })
	UI.create("UIGridLayout", {
		CellSize = UDim2.new(0.5, -3, 0, 28),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local modeInfo: { { id: MapMode, label: string, tip: string } } = {
		{ id = "realm", label = "Realm", tip = "Who owns each province." },
		{ id = "relations", label = "Relations", tip = "How each owner regards your house." },
		{ id = "wealth", label = "Wealth", tip = "Monthly income of each province." },
		{ id = "terrain", label = "Terrain", tip = "Terrain affects income and development cost." },
	}
	for index, info in modeInfo do
		local button = UI.button({
			text = info.label,
			variant = "ghost",
			textSize = Theme.TextSize.Small,
			order = index,
			parent = grid,
			onActivated = function()
				MapController.setMode(info.id)
			end,
		})
		Tooltip.setText(button, info.tip)
		modeButtons[info.id] = button
	end

	legend = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = modes })
	UI.list(legend, "vertical", 3)

	local zoomBox = UI.create("Frame", {
		Name = "Zoom",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -10),
		Size = UDim2.fromOffset(40, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 20,
		Parent = container,
	})
	UI.list(zoomBox, "vertical", 6)
	local function zoomButton(text: string, tip: string, order: number, action: () -> ())
		local button = UI.button({ text = text, variant = "chrome", size = UDim2.fromOffset(40, 36), textSize = 20, order = order, parent = zoomBox, onActivated = action })
		Tooltip.setText(button, tip)
	end
	zoomButton("+", "Zoom in", 1, function()
		zoomAt(1.25, viewSize() / 2)
	end)
	zoomButton("-", "Zoom out", 2, function()
		zoomAt(1 / 1.25, viewSize() / 2)
	end)
	zoomButton("[ ]", "Show the whole map", 3, function()
		MapController.fitToView()
	end)
end

function MapController.mount(parent: Frame, mapOptions: Options)
	options = mapOptions
	container = UI.create("Frame", {
		Name = "Map",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Colors.Sea,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	UI.create("UIGradient", {
		Color = ColorSequence.new(Colors.Sea, Colors.SeaDeep),
		Rotation = 90,
		Parent = container,
	})

	local dragCatcher = UI.create("TextButton", {
		Name = "DragCatcher",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 1,
		Parent = container,
	})

	canvas = UI.create("Frame", {
		Name = "Canvas",
		Size = UDim2.fromOffset(MAP_WIDTH, MAP_HEIGHT),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = container,
	})
	canvasScale = UI.create("UIScale", { Scale = zoom, Parent = canvas })

	symbols = UI.create("Frame", {
		Name = "Symbols",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = container,
	})

	buildGeometry()
	buildNodes()
	buildOverlay()
	bindInput(dragCatcher)

	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyView)
	MapController.setMode("realm")
	MapController.fitToView()
end

function MapController.setMode(newMode: MapMode)
	mode = newMode
	for id, button in modeButtons do
		UI.setSelected(button, id == mode)
	end
	recomputeMaxIncome()
	rebuildLegend()
	for provinceId in nodes do
		updateNode(provinceId)
	end
end

function MapController.select(provinceId: string?)
	local previous = selectedId
	selectedId = provinceId
	if previous then
		updateNode(previous)
	end
	if provinceId then
		updateNode(provinceId)
	end
end

-- Applies replicated changes: only affected nodes are recoloured unless the mode depends on
-- data that changed globally (relations, the player's house, full resync).
function MapController.refresh(changes: ReplicaStore.ChangeSet)
	local all = changes.full or changes.session
	if mode == "relations" and next(changes.relations) ~= nil then
		all = true
	end
	if mode == "wealth" and next(changes.provinces) ~= nil then
		recomputeMaxIncome()
		rebuildLegend()
		all = true
	end
	if all then
		for provinceId in nodes do
			updateNode(provinceId)
		end
		return
	end
	for provinceId in changes.provinces do
		updateNode(provinceId)
	end
end

return MapController
