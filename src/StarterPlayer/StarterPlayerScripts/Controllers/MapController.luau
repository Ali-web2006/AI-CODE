--!strict
--[[
	MapController — the world map: a political map of the nine great houses drawn from
	Data/World/MapData (outlines, palettes, crests, locations) and the replicated game state.

	Layers inside the map container (bottom to top):
	  Fills        ViewportFrame looking straight down at flat triangles (FlatTriangles): one
	               flat colour per sub-territory and special feature, on the ocean colour
	  DragCatcher  transparent button that receives pan, click and hover input
	  Canvas       map-sized frame moved and resized with the view; its children are placed in
	               scale units, so panning and zooming need no per-element work:
	                 borders (Path2D: constant on-screen width), hover glow, selection and
	                 own-province outlines, crests (SigilView), location icons and labels,
	                 great-house and feature labels
	  Overlay      map modes, legend, sub-territory border toggle, zoom buttons

	Interaction: hovering a sub-territory brightens it, outlines its whole region and shows a
	tooltip; clicking it (or a location) selects its province through options.onSelect; clicking
	the sea clears the selection. Drag or touch to pan, wheel or pinch to zoom, within limits.

	Map modes: "houses" (the great houses' palettes, the default), "realm" (current owner),
	"relations" (towards your house), "wealth" (income) and "terrain".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MapData = require(ReplicatedStorage.Shared.Data.World.MapData)
local Polygon = require(ReplicatedStorage.Shared.Util.Polygon)
local FlatTriangles = require(script.Parent.Parent.UI.FlatTriangles)
local Format = require(script.Parent.Parent.UI.Format)
local MapIcons = require(script.Parent.Parent.UI.MapIcons)
local MapStyle = require(script.Parent.Parent.UI.MapStyle)
local SigilView = require(script.Parent.Parent.UI.SigilView)
local Theme = require(script.Parent.Parent.UI.Theme)
local Tooltip = require(script.Parent.Parent.UI.Tooltip)
local UI = require(script.Parent.Parent.UI.UIComponents)
local ReplicaStore = require(script.Parent.ReplicaStore)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

export type MapMode = "houses" | "realm" | "relations" | "wealth" | "terrain"

export type Options = {
	store: ReplicaStore.ReplicaStore,
	getScale: () -> number,
	onSelect: (provinceId: string?) -> (),
}

-- Path2D strokes are opaque (scripts cannot set Path2D.Transparency).
type Stroke = { color: Color3, thickness: number }

type Sub = {
	data: MapData.SubTerritory,
	region: MapData.Region,
	house: MapData.House,
	baseColor: Color3,
	color: Color3,
	wedges: { WedgePart },
	bounds: { Polygon.Bounds },
}

type HouseLabel = { holder: Frame, house: TextLabel, name: TextLabel }
type LocationNode = { button: TextButton, label: TextLabel }
type FeatureLabel = { label: TextLabel }

local MapController = {}

local MAP_WIDTH = MapData.width
local MAP_HEIGHT = MapData.height
local FIELD_OF_VIEW = 40

local options: Options
local container: Frame
local viewport: ViewportFrame
local camera: Camera
local canvas: Frame
local subBorderLayer: Frame
local selectionLayer: Frame
local mineLayer: Frame
local legend: Frame
local bordersToggle: TextButton
local modeButtons: { [string]: TextButton } = {}

local houses: { [string]: MapData.House } = {}
local regions: { [string]: MapData.Region } = {}
local subs: { Sub } = {}
local subsByProvince: { [string]: { Sub } } = {}
local glowByRegion: { [string]: Frame } = {}
local crests: { ViewportFrame } = {}
local houseLabels: { HouseLabel } = {}
local featureLabels: { FeatureLabel } = {}
local locations: { LocationNode } = {}

local zoom = 0.35
local styledZoom = -1
local offset = Vector2.zero
local mode: MapMode = "houses"
local selectedId: string? = nil
local hoveredSub: Sub? = nil
local hoveredRegionId: string? = nil
local pointerInside = false
local overLocation: TextButton? = nil -- location icon under the pointer (its tooltip wins)
local subBordersVisible = true
local mineKey = ""
local maxIncome = 1

-- Helpers ----------------------------------------------------------------------------------------

local function fromHex(hex: string): Color3
	return Color3.fromHex(hex)
end

local function scalePosition(x: number, y: number): UDim2
	return UDim2.fromScale(x / MAP_WIDTH, y / MAP_HEIGHT)
end

local function houseOf(sub: MapData.SubTerritory, region: MapData.Region): MapData.House
	return houses[sub.houseId or region.houseId] or houses[region.houseId]
end

local function layer(name: string, zIndex: number): Frame
	return UI.create("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = zIndex,
		Parent = canvas,
	})
end

-- Draws a polygon outline with a Path2D (several when the path exceeds the point limit).
local function outline(parent: GuiObject, path: Polygon.Path, style: Stroke)
	local n = #path // 2
	local points: { Path2DControlPoint } = {}
	for i = 1, n do
		points[i] = Path2DControlPoint.new(scalePosition(path[2 * i - 1], path[2 * i]))
	end
	local probe = Instance.new("Path2D")
	local limit = probe:GetMaxControlPoints()
	local chunks: { { Path2DControlPoint } } = {}
	local closed = true
	if limit > 0 and n > limit then
		closed = false
		table.insert(points, points[1])
		local start = 1
		while start < #points do
			local stop = math.min(#points, start + limit - 1)
			local chunk: { Path2DControlPoint } = {}
			for i = start, stop do
				table.insert(chunk, points[i])
			end
			table.insert(chunks, chunk)
			start = stop
		end
	else
		chunks = { points }
	end
	for index, chunk in chunks do
		local line = if index == 1 then probe else Instance.new("Path2D")
		line.Color3 = style.color
		line.Thickness = style.thickness
		line.Closed = closed
		line:SetControlPoints(chunk)
		line.Parent = parent
	end
end

-- Colouring --------------------------------------------------------------------------------------

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

local function modeColor(sub: Sub): Color3
	if mode == "houses" then
		return sub.baseColor
	end
	local store = options.store
	local provinceId = sub.data.provinceId
	local view = store:province(provinceId)
	if not view then
		return Colors.Disabled
	end
	local color: Color3
	if mode == "realm" then
		local owner = Content.houses[view.ownerHouseId]
		color = if owner then Theme.fromRGB(owner.mapColor) else Colors.Disabled
	elseif mode == "relations" then
		local myHouseId = store:myHouseId()
		if not myHouseId then
			color = Colors.Disabled
		elseif view.ownerHouseId == myHouseId then
			color = Colors.Gold
		else
			local relation = store:relation(myHouseId, view.ownerHouseId)
			color = Theme.relationColor(if relation then relation.score else 0)
		end
	elseif mode == "wealth" then
		local t = math.clamp((view.income or 0) / maxIncome, 0, 1)
		color = Theme.mix(Color3.fromRGB(236, 226, 196), Color3.fromRGB(120, 80, 20), t ^ 0.8)
	else
		local terrain = Content.terrains[Content.provinces[provinceId].terrainId]
		color = Theme.fromRGB(terrain.color)
	end
	-- Keep sub-territories of one province distinguishable.
	return color:Lerp(Color3.new(0, 0, 0), ((sub.data.shade - 1) % 3) * 0.06)
end

local function paint(sub: Sub, color: Color3)
	for _, wedge in sub.wedges do
		wedge.Color = color
	end
end

local function displayColor(sub: Sub): Color3
	if sub == hoveredSub then
		return sub.color:Lerp(Color3.new(1, 1, 1), MapStyle.HoverLighten)
	end
	return sub.color
end

local function recolorAll()
	for _, sub in subs do
		local color = modeColor(sub)
		if color ~= sub.color then
			sub.color = color
			paint(sub, displayColor(sub))
		end
	end
end

local function recolorProvince(provinceId: string)
	for _, sub in subsByProvince[provinceId] or {} do
		local color = modeColor(sub)
		if color ~= sub.color then
			sub.color = color
			paint(sub, displayColor(sub))
		end
	end
end

-- Outlines of the provinces the player's house holds (thin gold) and of the selection (thick).
local function rebuildMine()
	local myHouseId = options.store:myHouseId()
	local owned = {}
	if myHouseId then
		for _, provinceId in Content.provinceIds do
			local view = options.store:province(provinceId)
			if view and view.ownerHouseId == myHouseId then
				table.insert(owned, provinceId)
			end
		end
	end
	local key = table.concat(owned, ",")
	if key == mineKey then
		return
	end
	mineKey = key
	mineLayer:ClearAllChildren()
	local style = { color = Colors.Gold, thickness = 1.5 }
	for _, provinceId in owned do
		for _, sub in subsByProvince[provinceId] or {} do
			for _, path in sub.data.paths do
				outline(mineLayer, path, style)
			end
		end
	end
end

local function rebuildSelection()
	selectionLayer:ClearAllChildren()
	local provinceId = selectedId
	if not provinceId then
		return
	end
	for _, sub in subsByProvince[provinceId] or {} do
		for _, path in sub.data.paths do
			outline(selectionLayer, path, MapStyle.Selection)
		end
	end
end

-- Hover ------------------------------------------------------------------------------------------

local function subAt(x: number, y: number): Sub?
	for _, sub in subs do
		for index, path in sub.data.paths do
			local b = sub.bounds[index]
			if x >= b.minX and x <= b.maxX and y >= b.minY and y <= b.maxY and Polygon.contains(path, x, y) then
				return sub
			end
		end
	end
	return nil
end

local function setHover(sub: Sub?)
	if sub == hoveredSub then
		return
	end
	local previous = hoveredSub
	hoveredSub = sub
	if previous then
		paint(previous, displayColor(previous))
	end
	if sub then
		paint(sub, displayColor(sub))
	end
	local regionId = if sub then sub.region.id else nil
	if regionId ~= hoveredRegionId then
		if hoveredRegionId and glowByRegion[hoveredRegionId] then
			glowByRegion[hoveredRegionId].Visible = false
		end
		hoveredRegionId = regionId
		if regionId and glowByRegion[regionId] then
			glowByRegion[regionId].Visible = true
		end
	end
end

local function provinceLines(provinceId: string): string?
	local view = options.store:province(provinceId)
	local definition = Content.provinces[provinceId]
	if not view or not definition then
		return nil
	end
	local owner = Content.houses[view.ownerHouseId]
	local terrain = Content.terrains[definition.terrainId]
	local holding = Content.holdingKinds[definition.holding.kind]
	return `{Format.escape(definition.name)}: {holding.name} of {Format.escape(definition.holding.name)} · {terrain.name}\nHeld by {owner and owner.name or "?"} · Development {view.development}/{GameConfig.Economy.MaxDevelopment} · Income {Format.gold(view.income)} gold/month`
end

local function subTooltip(): string?
	local sub = hoveredSub
	if not sub then
		return nil
	end
	local header = `<b>{Format.escape(sub.region.name)}</b> · {Format.escape(sub.house.name)}`
	local details = provinceLines(sub.data.provinceId)
	return if details then `{header}\n{details}` else header
end

-- View transform ---------------------------------------------------------------------------------

local function viewSize(): Vector2
	return container.AbsoluteSize / options.getScale()
end

local function minZoom(): number
	local size = viewSize()
	return math.min(size.X / MAP_WIDTH, size.Y / MAP_HEIGHT) * 0.9
end

local function clampView()
	local size = viewSize()
	zoom = math.clamp(zoom, minZoom(), MapStyle.MaxZoom)
	local width, height = MAP_WIDTH * zoom, MAP_HEIGHT * zoom
	local x = math.clamp(offset.X, math.min(size.X * 0.6 - width, size.X * 0.05), math.max(size.X * 0.4, size.X - width))
	local y = math.clamp(offset.Y, math.min(size.Y * 0.6 - height, size.Y * 0.05), math.max(size.Y * 0.4, size.Y - height))
	offset = Vector2.new(x, y)
end

-- Sizes that follow the zoom: crests, labels and which location details are shown.
local function styleForZoom()
	if math.abs(zoom - styledZoom) < 1e-4 then
		return
	end
	styledZoom = zoom
	local crestWidth = MapStyle.clamp(MapStyle.CrestUnits, zoom, MapStyle.CrestMin, MapStyle.CrestMax)
	local fade = math.clamp((zoom - MapStyle.CrestFadeFrom) / (MapStyle.CrestFadeTo - MapStyle.CrestFadeFrom), 0, 1) * MapStyle.CrestFadeMax
	for _, crest in crests do
		crest.Size = UDim2.fromOffset(crestWidth, crestWidth * 1.2)
		SigilView.setTransparency(crest, fade)
	end
	local houseText = math.floor(MapStyle.clamp(MapStyle.HouseTextUnits, zoom, MapStyle.HouseTextMin, MapStyle.HouseTextMax) + 0.5)
	for _, entry in houseLabels do
		entry.name.TextSize = houseText
		entry.house.TextSize = math.floor(houseText * MapStyle.HouseLineRatio + 0.5)
	end
	local featureText = math.floor(MapStyle.clamp(MapStyle.FeatureTextUnits, zoom, MapStyle.FeatureTextMin, MapStyle.FeatureTextMax) + 0.5)
	for _, entry in featureLabels do
		entry.label.TextSize = featureText
	end
	local showIcons = zoom >= MapStyle.LocationIconZoom
	local showLabels = zoom >= MapStyle.LocationLabelZoom
	for _, node in locations do
		node.button.Visible = showIcons
		node.label.Visible = showLabels
	end
end

local function applyView()
	clampView()
	canvas.Position = UDim2.fromOffset(offset.X, offset.Y)
	canvas.Size = UDim2.fromOffset(MAP_WIDTH * zoom, MAP_HEIGHT * zoom)
	local size = viewSize()
	local centre = (size / 2 - offset) / zoom
	camera.CFrame = FlatTriangles.topDownCFrame(centre.X, centre.Y, zoom, size.Y, FIELD_OF_VIEW)
	styleForZoom()
end

-- Zooms by `factor`, keeping the map point under `anchor` (container-local virtual px) fixed.
local function zoomAt(factor: number, anchor: Vector2)
	local mapPoint = (anchor - offset) / zoom
	zoom = math.clamp(zoom * factor, minZoom(), MapStyle.MaxZoom)
	offset = anchor - mapPoint * zoom
	applyView()
end

local function toLocal(screenPosition: Vector3 | Vector2): Vector2
	return (Vector2.new(screenPosition.X, screenPosition.Y) - container.AbsolutePosition) / options.getScale()
end

local function mapPointAt(screenPosition: Vector3 | Vector2): Vector2
	return (toLocal(screenPosition) - offset) / zoom
end

function MapController.fitToView()
	local size = viewSize()
	zoom = math.max(minZoom(), size.Y / MAP_HEIGHT * MapStyle.FitMargin)
	offset = Vector2.new((size.X - MAP_WIDTH * zoom) / 2, (size.Y - MAP_HEIGHT * zoom) / 2)
	applyView()
end

function MapController.focusProvince(provinceId: string, targetZoom: number?)
	local definition = Content.provinces[provinceId]
	if not definition then
		return
	end
	local size = viewSize()
	zoom = math.clamp(targetZoom or math.max(zoom, 0.8), minZoom(), MapStyle.MaxZoom)
	offset = size / 2 - Vector2.new(definition.position.x, definition.position.y) * zoom
	applyView()
end

-- Input ------------------------------------------------------------------------------------------

local beginDrag: (input: InputObject, onLocation: boolean?) -> ()

local function bindInput(dragCatcher: TextButton)
	local dragging = false
	local dragInput: InputObject? = nil
	local lastPosition = Vector2.zero
	local travelled = 0
	local pinching = false
	local pinchStartZoom = zoom
	local pressedLocation = false -- the press started on a location icon, which selects on its own

	beginDrag = function(input: InputObject, onLocation: boolean?)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				return
			end
			dragging = true
			dragInput = input
			lastPosition = Vector2.new(input.Position.X, input.Position.Y)
			travelled = 0
			pressedLocation = onLocation == true
			if input.UserInputType == Enum.UserInputType.Touch then
				local point = mapPointAt(input.Position)
				setHover(subAt(point.X, point.Y))
			end
		end
	end
	dragCatcher.InputBegan:Connect(function(input)
		beginDrag(input, false)
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
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and pointerInside then
			local point = mapPointAt(input.Position)
			setHover(subAt(point.X, point.Y))
			if not overLocation then
				Tooltip.refresh(dragCatcher)
			end
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and pointerInside then
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
			if travelled < 4 and not pinching and not pressedLocation then
				-- A click selects the province under the pointer; the sea clears the selection.
				local point = mapPointAt(input.Position)
				local sub = subAt(point.X, point.Y)
				options.onSelect(if sub then sub.data.provinceId else nil)
			end
			if input.UserInputType == Enum.UserInputType.Touch then
				setHover(nil) -- touch has no hover: the highlight lasts only while the finger is down
			end
		end
	end)

	UserInputService.TouchPinch:Connect(function(positions, pinchScale, _velocity, state)
		if not pointerInside and state == Enum.UserInputState.Begin then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinching = true
			pinchStartZoom = zoom
		elseif state == Enum.UserInputState.Change and pinching then
			local anchor = if #positions >= 2 then toLocal((positions[1] + positions[2]) / 2) else viewSize() / 2
			zoomAt((pinchStartZoom * pinchScale) / zoom, anchor)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			pinching = false
			dragging = false
			dragInput = nil
		end
	end)

	container.MouseEnter:Connect(function()
		pointerInside = true
	end)
	container.MouseLeave:Connect(function()
		pointerInside = false
		setHover(nil)
		Tooltip.refresh(dragCatcher)
	end)
	container.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			pointerInside = true
		end
	end)

	Tooltip.bind(dragCatcher, subTooltip)
end

-- Construction -----------------------------------------------------------------------------------

local function buildFills()
	camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local land = Instance.new("Model")
	land.Name = "Land"
	for _, sub in subs do
		for _, path in sub.data.paths do
			FlatTriangles.addList(sub.wedges, Polygon.triangulate(path), 0, sub.color)
		end
		FlatTriangles.parentAll(sub.wedges, land)
	end
	for _, feature in MapData.specialFeatures do
		local wedges: { WedgePart } = {}
		for _, path in feature.paths do
			FlatTriangles.addList(wedges, Polygon.triangulate(path), 0, fromHex(feature.color))
		end
		FlatTriangles.parentAll(wedges, land)
	end
	land.Parent = viewport
end

local function buildBorders()
	subBorderLayer = layer("SubBorders", 1)
	for _, sub in subs do
		for _, path in sub.data.paths do
			outline(subBorderLayer, path, MapStyle.SubBorder)
		end
	end
	local features = layer("FeatureBorders", 2)
	for _, feature in MapData.specialFeatures do
		for _, path in feature.paths do
			outline(features, path, MapStyle.FeatureBorder)
		end
	end
	local regionLayer = layer("RegionBorders", 3)
	for _, region in MapData.regions do
		for _, path in region.paths do
			outline(regionLayer, path, MapStyle.RegionBorder)
		end
	end
	local glowLayer = layer("RegionGlow", 4)
	for _, region in MapData.regions do
		local glow = UI.create("Frame", {
			Name = `Glow_{region.id}`,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = false,
			Parent = glowLayer,
		})
		for _, path in region.paths do
			outline(glow, path, MapStyle.RegionGlow)
		end
		for _, path in region.paths do
			outline(glow, path, MapStyle.RegionGlowCore)
		end
		glowByRegion[region.id] = glow
	end
	mineLayer = layer("OwnProvinces", 5)
	selectionLayer = layer("Selection", 6)
end

local function textLabel(props: { [string]: any }, halo: Color3): TextLabel
	local label = UI.create("TextLabel", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		FontFace = props.FontFace or Fonts.Heading,
		TextColor3 = props.TextColor3,
		TextSize = props.TextSize or 14,
		Text = props.Text,
		Name = props.Name,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = props.Parent,
	})
	UI.create("UIStroke", {
		Color = halo,
		Thickness = props.HaloThickness or 1.5,
		Transparency = 0.1,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
	return label
end

local function buildCrestsAndLabels()
	local crestLayer = layer("Crests", 7)
	for _, house in MapData.houses do
		local crest = house.crest
		if crest and not house.minor then
			local view = SigilView.new(house.id, {
				anchorPoint = Vector2.new(0.5, 0.5),
				position = scalePosition(crest.x, crest.y),
				fallbackColor = fromHex(house.primaryColor),
				name = `Crest_{house.id}`,
				parent = crestLayer,
			})
			table.insert(crests, view)
		end
	end
	for _, region in MapData.regions do
		local crest = region.crest
		local house = houses[region.houseId]
		if crest and house then
			local view = SigilView.new(house.id, {
				anchorPoint = Vector2.new(0.5, 0.5),
				position = scalePosition(crest.x, crest.y),
				fallbackColor = fromHex(house.primaryColor),
				name = `Crest_{region.id}`,
				parent = crestLayer,
			})
			table.insert(crests, view)
		end
	end

	local labelLayer = layer("Labels", 9)
	for _, feature in MapData.specialFeatures do
		local spot = feature.label
		if spot then
			local fill = fromHex(feature.color)
			local textColor, halo = MapStyle.contrast(fill)
			local label = textLabel({ Name = `Feature_{feature.id}`, Text = string.upper(feature.name), TextColor3 = textColor, Parent = labelLayer }, halo)
			label.AnchorPoint = Vector2.new(0.5, 0.5)
			label.Position = scalePosition(spot.x, spot.y)
			table.insert(featureLabels, { label = label })
		end
	end
	-- Two-line labels: every great house ("HOUSE" / name) and every region with its own title.
	local entries: { { id: string, color: string, lines: { string }, spot: MapData.Point } } = {}
	for _, house in MapData.houses do
		if house.label and not house.minor then
			local name = string.upper((string.gsub(house.name, "^House%s+", "")))
			table.insert(entries, { id = house.id, color = house.primaryColor, lines = { "HOUSE", name }, spot = house.label })
		end
	end
	for _, region in MapData.regions do
		local house = houses[region.houseId]
		if region.title and region.label and house then
			local palette = region.shadeColors or house.shadeColors
			table.insert(entries, { id = region.id, color = palette[1], lines = region.title, spot = region.label })
		end
	end
	for _, entry in entries do
		local spot = entry.spot
		local textColor, halo = MapStyle.contrast(fromHex(entry.color))
		local holder = UI.create("Frame", {
			Name = `HouseLabel_{entry.id}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = scalePosition(spot.x, spot.y),
			AutomaticSize = Enum.AutomaticSize.XY,
			Size = UDim2.fromOffset(0, 0),
			BackgroundTransparency = 1,
			Parent = labelLayer,
		})
		UI.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, -2),
			Parent = holder,
		})
		local houseLine = textLabel({ Text = entry.lines[1], TextColor3 = textColor, LayoutOrder = 1, Parent = holder }, halo)
		local nameLine = textLabel({ Text = entry.lines[2] or "", TextColor3 = textColor, LayoutOrder = 2, Parent = holder }, halo)
		table.insert(houseLabels, { holder = holder, house = houseLine, name = nameLine })
	end
end

local function locationTooltip(location: MapData.Location): string
	local provinceId = location.provinceId
	local details = if provinceId then provinceLines(provinceId) else nil
	local title = `<b>{Format.escape(location.name)}</b>`
	return if details then `{title}\n{details}` else title
end

local function buildLocations()
	local locationLayer = layer("Locations", 8)
	for _, location in MapData.locations do
		local provinceId = location.provinceId
		local button = UI.create("TextButton", {
			Name = if provinceId then `Province_{provinceId}` else `Location_{location.id}`,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = scalePosition(location.x, location.y),
			Size = UDim2.fromOffset(MapStyle.IconSize, MapStyle.IconSize),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 1,
			Parent = locationLayer,
		})
		local icon = UI.create("Frame", { Name = "Icon", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 1, Parent = button })
		MapIcons.build(icon, location.type, MapStyle.Ink, MapStyle.Paper)
		local label = textLabel({
			Name = "Label",
			Text = location.name,
			TextSize = MapStyle.LocationTextSize,
			FontFace = Fonts.Serif,
			TextColor3 = MapStyle.Ink,
			HaloThickness = 1.2,
			Parent = button,
		}, MapStyle.Paper)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 1, 1)
		label.ZIndex = 4

		button.InputBegan:Connect(function(input)
			beginDrag(input, true)
		end)
		button.MouseEnter:Connect(function()
			overLocation = button
		end)
		button.MouseLeave:Connect(function()
			if overLocation == button then
				overLocation = nil
			end
		end)
		button.Activated:Connect(function()
			if provinceId then
				options.onSelect(provinceId)
			end
		end)
		Tooltip.bind(button, function()
			return locationTooltip(location)
		end)
		table.insert(locations, { button = button, label = label })
	end
end

-- Overlay ----------------------------------------------------------------------------------------

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
	if mode == "houses" then
		UI.label({ text = "The lands of the great houses. Shades mark the sub-territories of each region.", size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 1, parent = legend })
	elseif mode == "realm" then
		UI.label({ text = "Colour shows the house that holds each province today.", size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 1, parent = legend })
	elseif mode == "relations" then
		legendRow("Your house", Colors.Gold, 1)
		legendRow("Friendly (+100)", Theme.relationColor(100), 2)
		legendRow("Neutral (0)", Theme.relationColor(0), 3)
		legendRow("Hostile (-100)", Theme.relationColor(-100), 4)
	elseif mode == "wealth" then
		legendRow("Poor", Color3.fromRGB(236, 226, 196), 1)
		legendRow(`Rich ({Format.gold(maxIncome)} gold/month)`, Color3.fromRGB(120, 80, 20), 2)
	else
		local order = 0
		for _, terrain in Content.raw.terrains do
			order += 1
			legendRow(terrain.name, Theme.fromRGB(terrain.color), order)
		end
	end
	UI.label({ text = "Gold outlines: your provinces (thin), the selection (thick).", size = Theme.TextSize.Small, wrap = true, color = Colors.InkMuted, order = 99, parent = legend })
end

local function setSubBordersVisible(visible: boolean)
	subBordersVisible = visible
	subBorderLayer.Visible = visible
	bordersToggle.Text = if visible then "Sub-territory borders: on" else "Sub-territory borders: off"
	UI.setSelected(bordersToggle, visible)
end

local function buildOverlay()
	local modes = UI.create("Frame", {
		Name = "MapModes",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -10),
		Size = UDim2.fromOffset(204, 0),
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

	local grid = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 96), LayoutOrder = 2, Parent = modes })
	UI.create("UIGridLayout", {
		CellSize = UDim2.new(0.5, -3, 0, 28),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	local modeInfo: { { id: MapMode, label: string, tip: string } } = {
		{ id = "houses", label = "Houses", tip = "The lands of the nine great houses." },
		{ id = "realm", label = "Realm", tip = "Who holds each province today." },
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

	bordersToggle = UI.button({
		text = "Sub-territory borders: on",
		variant = "ghost",
		textSize = Theme.TextSize.Small,
		size = UDim2.new(1, 0, 0, 26),
		order = 3,
		parent = modes,
		onActivated = function()
			setSubBordersVisible(not subBordersVisible)
		end,
	})
	Tooltip.setText(bordersToggle, "Show or hide the thin borders between sub-territories.")

	legend = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = modes })
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

local function indexData()
	for _, house in MapData.houses do
		houses[house.id] = house
	end
	for _, region in MapData.regions do
		regions[region.id] = region
	end
	for _, data in MapData.subTerritories do
		local region = regions[data.regionId]
		local house = houseOf(data, region)
		local shades = if data.houseId == nil and region.shadeColors then region.shadeColors else house.shadeColors
		local baseColor = fromHex(shades[math.clamp(data.shade, 1, #shades)])
		local bounds = {}
		for index, path in data.paths do
			bounds[index] = Polygon.bounds(path)
		end
		local sub: Sub = { data = data, region = region, house = house, baseColor = baseColor, color = baseColor, wedges = {}, bounds = bounds }
		table.insert(subs, sub)
		local list = subsByProvince[data.provinceId]
		if not list then
			list = {}
			subsByProvince[data.provinceId] = list
		end
		table.insert(list, sub)
	end
end

function MapController.mount(parent: Frame, mapOptions: Options)
	options = mapOptions
	indexData()
	local ocean = fromHex(MapData.oceanColor)
	container = UI.create("Frame", {
		Name = "Map",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = ocean,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,
	})
	viewport = UI.create("ViewportFrame", {
		Name = "Fills",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = ocean,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = container,
	})
	FlatTriangles.setupViewport(viewport)

	local dragCatcher = UI.create("TextButton", {
		Name = "DragCatcher",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 2,
		Parent = container,
	})

	canvas = UI.create("Frame", {
		Name = "Canvas",
		Size = UDim2.fromOffset(MAP_WIDTH * zoom, MAP_HEIGHT * zoom),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = container,
	})

	buildFills()
	buildBorders()
	bindInput(dragCatcher)
	buildCrestsAndLabels()
	buildLocations()
	buildOverlay()

	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyView)
	MapController.setMode("houses")
	MapController.fitToView()
end

function MapController.setMode(newMode: MapMode)
	mode = newMode
	for id, button in modeButtons do
		UI.setSelected(button, id == mode)
	end
	recomputeMaxIncome()
	rebuildLegend()
	recolorAll()
	rebuildMine()
end

function MapController.select(provinceId: string?)
	selectedId = provinceId
	rebuildSelection()
end

-- Applies replicated changes: only affected provinces are recoloured unless the mode depends on
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
		recolorAll()
	else
		for provinceId in changes.provinces do
			recolorProvince(provinceId)
		end
	end
	if all or next(changes.provinces) ~= nil then
		rebuildMine()
	end
end

return MapController
