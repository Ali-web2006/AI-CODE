--!strict
--[[
	MapController — the world map: a political map of the nine great houses drawn from
	Data/World/MapData (outlines, palettes, crests, locations) and the replicated game state, which
	turns into an atlas of the land as you zoom in. Every tunable value (framing, zoom levels,
	camera, colours) is in UI/MapConfig.

	Layers inside the map container (bottom to top):
	  AtlasFills   ViewportFrame with the same flat triangles in the atlas look: each sub-territory
	               and special feature in the land's lore colour (MapConfig.terrainColor and
	               featureColor; sub-territories slightly lighter or darker by shade) on the pale
	               atlas sea. Shown only while the atlas look is in view
	  Fills        ViewportFrame looking straight down at flat triangles (FlatTriangles): one
	               flat colour per sub-territory and special feature (a model of triangles each,
	               named by its id), on the ocean colour. In the blend zone the whole picture fades
	               out (ImageTransparency), uncovering the atlas
	  DragCatcher  transparent button that receives pan, click and hover input
	  Canvas       map-sized frame moved and resized with the view; its children are placed in
	               scale units, so panning and zooming need no per-element work:
	                 borders (Path2D: constant on-screen width; the political black region borders
	                 or the atlas look's kingdom borders in the house colours), hover outlines,
	                 selection and own-province outlines, crests (SigilView), location icons and
	                 labels, great-house and feature labels, then army routes and army tokens
	                 (UI/ArmyLayer, mounted here with a small surface interface)
	  Overlay      map modes, legend, sub-territory border toggle, zoom buttons

	Zoom levels (MapConfig.Zoom, multiples of the whole-map view's zoom). Political below
	BlendStart. Across the blend zone (BlendStart to BlendEnd) the political colours fade out and
	the atlas look fades in, and crests and house names fade away with them. Once the fade passes
	Zoom.BorderSwitch the black political borders give way to kingdom borders in each ruling
	house's colour, and hovering a region outlines it in that colour and gives it a faint fill
	instead of brightening it. Atlas from Zoom.Atlas, Close from Zoom.Close (settlements come with
	Part C of the map upgrade). The blend applies in the houses and terrain modes only: the data
	modes (realm, relations, wealth, military) stay political at every zoom, so their colours
	remain readable.

	Camera. The view is framed by MapConfig.View.Bounds: the whole-map view fits the frame to the
	map area, the zoom never goes below it, and the view never pans out of the frame. On an axis
	where the frame is larger than the map area the view stays inside the frame; where it is
	smaller (the sides of the whole-map view), the frame stays wholly on screen but may slide.
	Flights (fitToView, focusProvince, focusStart, focusArmy and the + / - / [ ] buttons) are
	eased, and the mouse wheel zooms smoothly towards the pointer; both run on RenderStepped,
	connected only while the camera moves. A press on the map, a pinch, a new wheel notch or a new
	flight stops the running motion, while dragging during a wheel glide carries the glide along.
	A pinch zooms about the two-finger midpoint and pans with it; afterwards the finger still down
	pans on.
	Wheel and pinch keep the map point under the pointer fixed wherever these limits allow it;
	near Westeros's edges the view shifts just enough to stay within them.

	Interaction: hovering a sub-territory brightens it, outlines its whole region and shows a
	tooltip; clicking it (or a location) selects its province through options.onSelect; clicking
	the sea clears the selection. Clicking an army token selects the army (options.onSelectArmy).
	A right-click on land or a location reports the province under the pointer through
	options.onCommand, and a right-click on a token reports that army (options.onCommandArmy);
	UIController turns both into march orders. A token is drawn raised above its army's point,
	so the land under it is not where the army stands and is never the target. Drag or touch to
	pan, wheel or pinch to zoom, within limits.

	Map modes: "houses" (the great houses' palettes, the default), "realm" (current owner),
	"relations" (towards your house), "wealth" (income), "terrain" (the land's lore colours, as in
	the atlas look) and "military" (men present: the garrison plus the armies standing in each
	province, with a garrison label under every holding icon).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MapData = require(ReplicatedStorage.Shared.Data.World.MapData)
local Polygon = require(ReplicatedStorage.Shared.Util.Polygon)
local ArmyLayer = require(script.Parent.Parent.UI.ArmyLayer)
local FlatTriangles = require(script.Parent.Parent.UI.FlatTriangles)
local Format = require(script.Parent.Parent.UI.Format)
local MapConfig = require(script.Parent.Parent.UI.MapConfig)
local MapIcons = require(script.Parent.Parent.UI.MapIcons)
local SigilView = require(script.Parent.Parent.UI.SigilView)
local Theme = require(script.Parent.Parent.UI.Theme)
local Tooltip = require(script.Parent.Parent.UI.Tooltip)
local UI = require(script.Parent.Parent.UI.UIComponents)
local ReplicaStore = require(script.Parent.ReplicaStore)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

export type MapMode = "houses" | "realm" | "relations" | "wealth" | "terrain" | "military"

export type Options = {
	store: ReplicaStore.ReplicaStore,
	getScale: () -> number,
	onSelect: (provinceId: string?) -> (),
	-- A click on an army token.
	onSelectArmy: (armyId: string) -> (),
	-- A right-click on land: the province under the pointer (a march order for the selected army).
	onCommand: (provinceId: string) -> (),
	-- A right-click on an army token (a march order to where that army stands).
	onCommandArmy: (armyId: string) -> (),
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
	atlasColor: Color3, -- its colour in the atlas look
	atlasWedges: { WedgePart },
	bounds: { Polygon.Bounds },
}

-- A special feature's political triangles: its own colour, or its lore colour in the terrain mode.
type FeatureFill = { color: Color3, terrainColor: Color3, shown: Color3, wedges: { WedgePart } }

type HouseLabel = { holder: Frame, house: TextLabel, name: TextLabel, halos: { UIStroke } }
type LocationNode = { button: TextButton, label: TextLabel, garrison: TextLabel?, provinceId: string? }
type FeatureLabel = { label: TextLabel }

-- A camera flight: the view centre (map units) and the zoom, eased from start to target.
type Flight = { fromCentre: Vector2, toCentre: Vector2, fromZoom: number, toZoom: number, duration: number, elapsed: number }

local MapController = {}

local MAP_WIDTH = MapData.width
local MAP_HEIGHT = MapData.height
local FIELD_OF_VIEW = 40
-- Before the map area has a size its whole-map zoom would be zero; the zoom never goes below this.
local ZOOM_FLOOR = 0.01

local options: Options
local container: Frame
local viewport: ViewportFrame
local camera: Camera
local atlasViewport: ViewportFrame
local atlasCamera: Camera
local canvas: Frame
local subBorderLayer: Frame
local regionBorderLayer: Frame
local kingdomBorderLayer: Frame
local selectionLayer: Frame
local mineLayer: Frame
local legend: Frame
local bordersToggle: TextButton
local modeButtons: { [string]: TextButton } = {}

local houses: { [string]: MapData.House } = {}
local regions: { [string]: MapData.Region } = {}
local regionColors: { [string]: Color3 } = {} -- each region's house colour (kingdom borders, hover fill)
local subs: { Sub } = {}
local subsByProvince: { [string]: { Sub } } = {}
local subsByRegion: { [string]: { Sub } } = {}
local featureFills: { FeatureFill } = {}
local glowByRegion: { [string]: Frame } = {}
local kingdomHoverByRegion: { [string]: Frame } = {}
local crests: { ViewportFrame } = {}
local houseLabels: { HouseLabel } = {}
local featureLabels: { FeatureLabel } = {}
local locations: { LocationNode } = {}

local zoom = 0.35
local offset = Vector2.zero
local styledZoom = -1
local styledBlend = -1
local atlasLook = false -- kingdom borders and the atlas hover are shown (blend past Zoom.BorderSwitch)
local mode: MapMode = "houses"
local selectedId: string? = nil
local hoveredSub: Sub? = nil
local hoveredRegionId: string? = nil
local pointerInside = false
local overLocation: TextButton? = nil -- location icon under the pointer (its tooltip wins)
local subBordersVisible = true
local mineKey = ""
local maxIncome = 1
local menByProvince: { [string]: number } = {} -- military mode: garrison plus armies standing there
local maxMen = 1

-- Camera motion: one flight or one wheel glide at a time.
local flight: Flight? = nil
local wheelTarget: number? = nil -- the zoom the wheel glides to
local wheelAnchor = Vector2.zero -- container-local point the wheel zooms about
local wheelPoint = Vector2.zero -- the map point kept under it
local cameraConnection: RBXScriptConnection? = nil
local lastSize = Vector2.zero -- map area size (virtual px) the view was last laid out for

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

-- The colour of a region's ruling house on the map: the middle shade of the region's own palette
-- (the Crownlands), else the house's primary colour.
local function regionColorOf(region: MapData.Region): Color3
	local own = region.shadeColors
	if own then
		return fromHex(own[math.ceil(#own / 2)])
	end
	local house = houses[region.houseId]
	return if house then fromHex(house.primaryColor) else Colors.Disabled
end

-- A sub-territory's atlas colour: its province's lore colour, a little lighter or darker by its
-- shade so that neighbouring sub-territories differ slightly.
local function atlasColorOf(data: MapData.SubTerritory): Color3
	local base = MapConfig.terrainColor(data.provinceId)
	local share = (((data.shade - 1) % 3) - 1) * MapConfig.Atlas.ShadeVariation
	if share > 0 then
		return base:Lerp(Color3.new(1, 1, 1), share)
	end
	return base:Lerp(Color3.new(0, 0, 0), -share)
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

--[[
	Men present in every province, for the military mode: its garrison plus the troops of the
	armies located there (an army on the road counts where it set out from). Returns true when any
	count changed, so the map is recoloured only then.
]]
local function recomputeMen(): boolean
	local store = options.store
	local counts: { [string]: number } = {}
	for _, provinceId in Content.provinceIds do
		local view = store:province(provinceId)
		counts[provinceId] = if view then view.garrisonTroops or 0 else 0
	end
	for _, army in store.campaign.armies or {} do
		if counts[army.locationId] ~= nil then
			counts[army.locationId] += army.troops or 0
		end
	end
	local changed = false
	local highest = 1
	for _, provinceId in Content.provinceIds do
		if counts[provinceId] ~= menByProvince[provinceId] then
			changed = true
		end
		highest = math.max(highest, counts[provinceId])
	end
	menByProvince = counts
	maxMen = highest
	return changed
end

local function modeColor(sub: Sub): Color3
	if mode == "houses" then
		return sub.baseColor
	end
	local store = options.store
	local provinceId = sub.data.provinceId
	local color: Color3
	if mode == "terrain" then
		-- The land's lore colour, the same as in the atlas look.
		color = MapConfig.terrainColor(provinceId)
	else
		local view = store:province(provinceId)
		if not view then
			return Colors.Disabled
		end
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
			color = Theme.mix(MapConfig.WealthPoor, MapConfig.WealthRich, t ^ MapConfig.WealthCurve)
		else
			local t = math.clamp((menByProvince[provinceId] or 0) / maxMen, 0, 1)
			color = Theme.mix(MapConfig.MenFew, MapConfig.MenMany, t ^ MapConfig.MenCurve)
		end
	end
	-- Keep sub-territories of one province distinguishable.
	return color:Lerp(Color3.new(0, 0, 0), ((sub.data.shade - 1) % 3) * MapConfig.ModeShadeStep)
end

local function paint(wedges: { WedgePart }, color: Color3)
	for _, wedge in wedges do
		wedge.Color = color
	end
end

-- Political colour on screen: hovered sub-territories are brightened (political look only).
local function displayColor(sub: Sub): Color3
	if sub == hoveredSub and not atlasLook then
		return sub.color:Lerp(Color3.new(1, 1, 1), MapConfig.HoverLighten)
	end
	return sub.color
end

local function recolorAll()
	for _, sub in subs do
		local color = modeColor(sub)
		if color ~= sub.color then
			sub.color = color
			paint(sub.wedges, displayColor(sub))
		end
	end
end

local function recolorProvince(provinceId: string)
	for _, sub in subsByProvince[provinceId] or {} do
		local color = modeColor(sub)
		if color ~= sub.color then
			sub.color = color
			paint(sub.wedges, displayColor(sub))
		end
	end
end

-- The special features keep their own colours, except in the terrain mode (their lore colours).
local function recolorFeatures()
	for _, fill in featureFills do
		local color = if mode == "terrain" then fill.terrainColor else fill.color
		if color ~= fill.shown then
			fill.shown = color
			paint(fill.wedges, color)
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
	for _, provinceId in owned do
		for _, sub in subsByProvince[provinceId] or {} do
			for _, path in sub.data.paths do
				outline(mineLayer, path, MapConfig.OwnProvinces)
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
			outline(selectionLayer, path, MapConfig.Selection)
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

--[[
	Shows or hides the highlight of a hovered region. Political look: a light glow around it.
	Atlas look: its kingdom outline drawn thicker and a faint fill in its house colour (its atlas
	triangles tinted by 1 - Atlas.HoverFillTransparency toward that colour).
]]
local function highlightRegion(regionId: string, on: boolean)
	if atlasLook then
		local hover = kingdomHoverByRegion[regionId]
		if hover then
			hover.Visible = on
		end
		local fill = 1 - MapConfig.Atlas.HoverFillTransparency
		for _, sub in subsByRegion[regionId] or {} do
			paint(sub.atlasWedges, if on then sub.atlasColor:Lerp(regionColors[regionId], fill) else sub.atlasColor)
		end
	else
		local glow = glowByRegion[regionId]
		if glow then
			glow.Visible = on
		end
	end
end

local function setHover(sub: Sub?)
	if sub == hoveredSub then
		return
	end
	local previous = hoveredSub
	hoveredSub = sub
	if not atlasLook then
		if previous then
			paint(previous.wedges, displayColor(previous))
		end
		if sub then
			paint(sub.wedges, displayColor(sub))
		end
	end
	local regionId = if sub then sub.region.id else nil
	if regionId ~= hoveredRegionId then
		if hoveredRegionId then
			highlightRegion(hoveredRegionId, false)
		end
		hoveredRegionId = regionId
		if regionId then
			highlightRegion(regionId, true)
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

-- Framing ----------------------------------------------------------------------------------------

local function viewSize(): Vector2
	return container.AbsoluteSize / options.getScale()
end

-- The zoom of the whole-map view (MapConfig.View): the frame's height fits the map area, or in
-- the "fill" mode the frame covers the map area.
local function fitZoom(): number
	local size = viewSize()
	local view = MapConfig.View
	local bounds = view.Bounds
	local fit = size.Y / (bounds.maxY - bounds.minY) * view.FitMargin
	if view.FitMode == "fill" then
		fit = math.max(fit, size.X / (bounds.maxX - bounds.minX) * view.FitMargin)
	end
	return math.max(fit, ZOOM_FLOOR)
end

-- The zoom as a multiple of the whole-map view's, the unit of the zoom levels (MapConfig.Zoom).
local function relativeZoom(): number
	local size = viewSize()
	if size.X <= 0 or size.Y <= 0 then
		return 1 -- no map area yet: count the view as the whole map
	end
	return zoom / fitZoom()
end

-- Zoom levels ------------------------------------------------------------------------------------

-- How far the atlas look has faded in: by zoom in the houses and terrain modes, never in the
-- data modes.
local function currentBlend(): number
	if mode == "houses" or mode == "terrain" then
		return MapConfig.blend(relativeZoom())
	end
	return 0
end

--[[
	The political picture fades out continuously over the atlas underneath (one property each, no
	per-triangle work). Once the fade reaches Zoom.BorderSwitch the outlines switch looks: black
	region and sub-territory borders before it, kingdom borders in the house colours from it; a
	hovered region is re-highlighted in the new look.
]]
local function applyBlend(t: number)
	viewport.ImageTransparency = t
	viewport.BackgroundTransparency = t
	viewport.Visible = t < 1
	atlasViewport.Visible = t > 0
	local atlas = t > 0 and t >= MapConfig.Zoom.BorderSwitch
	if atlas ~= atlasLook then
		local sub = hoveredSub
		setHover(nil)
		atlasLook = atlas
		subBorderLayer.Visible = subBordersVisible and not atlas
		regionBorderLayer.Visible = not atlas
		kingdomBorderLayer.Visible = atlas
		setHover(sub)
	end
end

-- Sizes and fades that follow the zoom: crests, labels, which location details are shown, and
-- the blend between the political and atlas looks.
local function styleForZoom()
	local t = currentBlend()
	if math.abs(zoom - styledZoom) < 1e-4 and t == styledBlend then
		return
	end
	styledZoom = zoom
	styledBlend = t
	applyBlend(t)
	-- Crests and house names fade out with the political colours, in BlendSteps steps.
	local steps = MapConfig.Zoom.BlendSteps
	local faded = if t >= 1 then 1 else math.floor(t * steps + 0.5) / steps
	local crestWidth = MapConfig.clamp(MapConfig.CrestUnits, zoom, MapConfig.CrestMin, MapConfig.CrestMax)
	local fade = math.clamp((zoom - MapConfig.CrestFadeFrom) / (MapConfig.CrestFadeTo - MapConfig.CrestFadeFrom), 0, 1) * MapConfig.CrestFadeMax
	for _, crest in crests do
		crest.Size = UDim2.fromOffset(crestWidth, crestWidth * 1.2)
		crest.Visible = faded < 1
		SigilView.setTransparency(crest, math.max(fade, faded))
	end
	local houseText = math.floor(MapConfig.clamp(MapConfig.HouseTextUnits, zoom, MapConfig.HouseTextMin, MapConfig.HouseTextMax) + 0.5)
	for _, entry in houseLabels do
		entry.name.TextSize = houseText
		entry.house.TextSize = math.floor(houseText * MapConfig.HouseLineRatio + 0.5)
		entry.holder.Visible = faded < 1
		entry.name.TextTransparency = faded
		entry.house.TextTransparency = faded
		for _, halo in entry.halos do
			halo.Transparency = MapConfig.HaloTransparency + (1 - MapConfig.HaloTransparency) * faded
		end
	end
	local featureText = math.floor(MapConfig.clamp(MapConfig.FeatureTextUnits, zoom, MapConfig.FeatureTextMin, MapConfig.FeatureTextMax) + 0.5)
	for _, entry in featureLabels do
		entry.label.TextSize = featureText
	end
	local showIcons = zoom >= MapConfig.LocationIconZoom
	local showLabels = zoom >= MapConfig.LocationLabelZoom
	for _, node in locations do
		node.button.Visible = showIcons
		node.label.Visible = showLabels
		local garrison = node.garrison
		if garrison then
			-- Under the holding's name when names are shown, else right under the icon.
			garrison.Position = UDim2.new(0.5, 0, 1, if showLabels then MapConfig.GarrisonBelowName else 1)
			garrison.Visible = mode == "military"
		end
	end
	ArmyLayer.setZoom(zoom)
end

-- Military mode: "Garrison 1,800" under every holding icon (the icons appear from LocationIconZoom).
local function updateGarrisonLabels()
	for _, node in locations do
		local garrison = node.garrison
		if garrison and node.provinceId then
			local view = options.store:province(node.provinceId)
			garrison.Text = `Garrison {Format.troops(if view then view.garrisonTroops or 0 else 0)}`
			garrison.Visible = mode == "military"
		end
	end
end

-- View transform ---------------------------------------------------------------------------------

local function minZoom(): number
	return math.max(fitZoom() * MapConfig.View.MinZoomFactor, ZOOM_FLOOR)
end

-- View.MaxZoom, or further in where the Close zoom level lies beyond it, so it can be reached.
local function maxZoom(): number
	return math.max(MapConfig.View.MaxZoom, fitZoom() * MapConfig.Zoom.Close, minZoom())
end

--[[
	One axis of clampOffset: `extent` px of map area showing map units [low, high] of the frame at
	zoom `z`. The two limits are the offsets that put the frame's near edge (low) and its far edge
	(high) on the map area's edges. Keeping the offset between them keeps a frame larger than the
	area covering it (no empty sea in view), and a smaller one wholly inside it (free to slide,
	never off the screen).
]]
local function clampAxis(value: number, extent: number, low: number, high: number, z: number): number
	local nearEdge = -low * z
	local farEdge = extent - high * z
	return math.clamp(value, math.min(nearEdge, farEdge), math.max(nearEdge, farEdge))
end

-- The canvas offset that keeps the view within the frame at zoom `z` (see clampAxis).
local function clampOffset(value: Vector2, z: number): Vector2
	local size = viewSize()
	local bounds = MapConfig.View.Bounds
	return Vector2.new(clampAxis(value.X, size.X, bounds.minX, bounds.maxX, z), clampAxis(value.Y, size.Y, bounds.minY, bounds.maxY, z))
end

local function clampView()
	zoom = math.clamp(zoom, minZoom(), maxZoom())
	offset = clampOffset(offset, zoom)
end

local function applyView()
	clampView()
	-- GUI offsets are whole pixels: the canvas is placed on the nearest pixel and the cameras
	-- follow the canvas as placed, so the fills sit exactly under the borders and labels.
	local origin = Vector2.new(math.round(offset.X), math.round(offset.Y))
	canvas.Position = UDim2.fromOffset(origin.X, origin.Y)
	canvas.Size = UDim2.fromOffset(math.round(MAP_WIDTH * zoom), math.round(MAP_HEIGHT * zoom))
	local size = viewSize()
	local centre = (size / 2 - origin) / zoom
	local cframe = FlatTriangles.topDownCFrame(centre.X, centre.Y, zoom, size.Y, FIELD_OF_VIEW)
	camera.CFrame = cframe
	atlasCamera.CFrame = cframe
	styleForZoom()
end

-- The map point at the middle of the map area.
local function viewCentre(): Vector2
	return (viewSize() / 2 - offset) / zoom
end

-- Shows map point `centre` in the middle of the map area at `newZoom` (then kept in the frame).
local function setView(centre: Vector2, newZoom: number)
	zoom = newZoom
	offset = viewSize() / 2 - centre * newZoom
	applyView()
end

-- Zooms by `factor`, keeping the map point under `anchor` (container-local virtual px) fixed.
local function zoomAt(factor: number, anchor: Vector2)
	local mapPoint = (anchor - offset) / zoom
	zoom = math.clamp(zoom * factor, minZoom(), maxZoom())
	offset = anchor - mapPoint * zoom
	applyView()
end

local function toLocal(screenPosition: Vector3 | Vector2): Vector2
	return (Vector2.new(screenPosition.X, screenPosition.Y) - container.AbsolutePosition) / options.getScale()
end

local function mapPointAt(screenPosition: Vector3 | Vector2): Vector2
	return (toLocal(screenPosition) - offset) / zoom
end

local function boundsCentre(): Vector2
	local bounds = MapConfig.View.Bounds
	return Vector2.new((bounds.minX + bounds.maxX) / 2, (bounds.minY + bounds.maxY) / 2)
end

-- Camera motion ----------------------------------------------------------------------------------

local function stopCamera()
	flight = nil
	wheelTarget = nil
	local connection = cameraConnection
	if connection then
		connection:Disconnect()
		cameraConnection = nil
	end
end

-- One frame of the running flight or wheel glide; disconnects when the motion has ended.
local function stepCamera(deltaTime: number)
	local current = flight
	local target = wheelTarget
	if current then
		current.elapsed += deltaTime
		local t = math.clamp(current.elapsed / current.duration, 0, 1)
		if t >= 1 then
			flight = nil
			setView(current.toCentre, current.toZoom)
		else
			local eased = 1 - (1 - t) ^ 3 -- ease-out cubic
			local logZoom = math.log(current.fromZoom) + (math.log(current.toZoom) - math.log(current.fromZoom)) * eased
			setView(current.fromCentre:Lerp(current.toCentre, eased), math.exp(logZoom))
		end
	elseif target then
		-- The zoom range moves when the map area changes size: the target follows it, so the
		-- glide always arrives.
		target = math.clamp(target, minZoom(), maxZoom())
		wheelTarget = target
		-- Exponential approach in log-zoom, keeping the map point under the pointer.
		local share = 1 - math.exp(-deltaTime / MapConfig.Camera.WheelSmoothing)
		local nextZoom = math.exp(math.log(zoom) + (math.log(target) - math.log(zoom)) * share)
		if math.abs(math.log(target / nextZoom)) < 1e-3 then
			nextZoom = target
			wheelTarget = nil
		end
		zoom = nextZoom
		offset = wheelAnchor - wheelPoint * zoom
		applyView()
	end
	if flight == nil and wheelTarget == nil then
		stopCamera()
	end
end

local function startCamera()
	if cameraConnection == nil then
		cameraConnection = RunService.RenderStepped:Connect(stepCamera)
	end
end

--[[
	Flies the view to map point `centre` at `targetZoom` over `duration` seconds (ease-out cubic,
	the zoom in log space), stopping any other camera motion. The target is first limited to what
	the frame allows, so the flight ends where it aims. A duration of zero jumps there, and so does
	a flight to where the view already is.
]]
local function flyTo(centre: Vector2, targetZoom: number, duration: number)
	stopCamera()
	local toZoom = math.clamp(targetZoom, minZoom(), maxZoom())
	local half = viewSize() / 2
	local toCentre = (half - clampOffset(half - centre * toZoom, toZoom)) / toZoom
	local already = math.abs(toZoom - zoom) < 1e-6 and (toCentre - viewCentre()).Magnitude < 1e-3
	if duration <= 0 or already then
		setView(toCentre, toZoom)
		return
	end
	flight = { fromCentre = viewCentre(), toCentre = toCentre, fromZoom = zoom, toZoom = toZoom, duration = duration, elapsed = 0 }
	startCamera()
end

-- A mouse wheel notch (+1 in, -1 out): the target zoom moves by WheelStep, anchored at the map
-- point under `anchor`; the view glides there (WheelSmoothing).
local function wheelZoom(notches: number, anchor: Vector2)
	flight = nil
	local settings = MapConfig.Camera
	local target = math.clamp((wheelTarget or zoom) * settings.WheelStep ^ notches, minZoom(), maxZoom())
	wheelAnchor = anchor
	wheelPoint = (anchor - offset) / zoom
	if settings.WheelSmoothing <= 0 then
		stopCamera()
		zoom = target
		offset = anchor - wheelPoint * zoom
		applyView()
		return
	end
	wheelTarget = target
	startCamera()
end

-- The + and - buttons: one ButtonStep about the middle of the view, building on a step still
-- under way so that quick clicks add up.
local function zoomStep(direction: number)
	local current = flight
	local fromZoom = if current then current.toZoom else zoom
	local centre = if current then current.toCentre else viewCentre()
	local step = MapConfig.Camera.ButtonStep
	flyTo(centre, if direction > 0 then fromZoom * step else fromZoom / step, MapConfig.Camera.ButtonTime)
end

-- The map area changed size (the panel was hidden or shown, the window resized): the map point
-- in the middle stays there at the same zoom, unless that zoom is now below the whole-map view.
local function onResize()
	local size = viewSize()
	local previous = lastSize
	lastSize = size
	if previous.X <= 0 or previous.Y <= 0 or zoom < minZoom() then
		setView(boundsCentre(), fitZoom())
		return
	end
	setView((previous / 2 - offset) / zoom, zoom)
end

function MapController.fitToView()
	flyTo(boundsCentre(), fitZoom(), MapConfig.Camera.FlyTime)
end

-- Flies to a map point, zooming in to at least Camera.FocusZoom unless a zoom is given.
local function focusPoint(point: Vector2, targetZoom: number?)
	flyTo(point, targetZoom or math.max(zoom, MapConfig.Camera.FocusZoom * fitZoom()), MapConfig.Camera.FlyTime)
end

-- Flies to a province; `targetZoom` is in pixels per map unit.
function MapController.focusProvince(provinceId: string, targetZoom: number?)
	local definition = Content.provinces[provinceId]
	if not definition then
		return
	end
	focusPoint(Vector2.new(definition.position.x, definition.position.y), targetZoom)
end

-- The first view of a campaign: a flight to the house seat at Camera.StartZoom.
function MapController.focusStart(provinceId: string)
	MapController.focusProvince(provinceId, MapConfig.Camera.StartZoom * fitZoom())
end

-- Centres the view on an army (where it is today, also on the road).
function MapController.focusArmy(armyId: string)
	local point = ArmyLayer.pointOf(armyId)
	if point then
		focusPoint(point, nil)
	end
end

-- The zoom level of the view: "political", "blend", "atlas" or "close" (MapConfig.level).
function MapController.zoomLevel(): MapConfig.ZoomLevel
	return MapConfig.level(relativeZoom())
end

-- How far the atlas look has faded in, from 0 to 1 (always 0 in the data modes).
function MapController.blend(): number
	return currentBlend()
end

-- Input ------------------------------------------------------------------------------------------

local beginDrag: (input: InputObject, onLocation: boolean?) -> ()

-- Pointer travel of the current or last press, in virtual px. A press that moved at least
-- Camera.ClickSlop is a drag: releasing it over a token or a holding icon (which moved along with
-- the map) must not count as a click on it. A press joined by a second finger is never a click.
local pressTravel = 0

local function wasClick(): boolean
	return pressTravel < MapConfig.Camera.ClickSlop
end

-- A right-click (mouse button 2) gives an order at the pointer: the province under it, if land.
-- Other inputs are ignored. Touch has no right-click; the army panel's Move button covers it.
local function rightClick(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then
		return
	end
	local point = mapPointAt(input.Position)
	local sub = subAt(point.X, point.Y)
	if sub then
		options.onCommand(sub.data.provinceId)
	end
end

local function bindInput(dragCatcher: TextButton)
	local dragging = false
	local dragInput: InputObject? = nil
	local otherTouch: InputObject? = nil -- a second finger pressed on the map while dragging
	local resync = false -- the dragging finger's next move only sets lastPosition (after a pinch)
	local lastPosition = Vector2.zero
	local pinching = false
	local pinchStartZoom = zoom
	local pinchMidpoint: Vector2? = nil -- container-local, for the two-finger pan
	local pressedLocation = false -- the press started on a location icon, which selects on its own

	beginDrag = function(input: InputObject, onLocation: boolean?)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				if input.UserInputType == Enum.UserInputType.Touch and input ~= dragInput and otherTouch == nil then
					-- A second finger: the start of a pinch, not a tap. It takes over the drag if
					-- the first finger lifts first.
					otherTouch = input
					pressTravel = math.huge
				end
				return
			end
			stopCamera() -- grabbing the map stops a flight or a wheel glide
			dragging = true
			dragInput = input
			resync = false
			lastPosition = Vector2.new(input.Position.X, input.Position.Y)
			pressTravel = 0
			pressedLocation = onLocation == true
			if input.UserInputType == Enum.UserInputType.Touch then
				local point = mapPointAt(input.Position)
				setHover(subAt(point.X, point.Y))
			end
		end
	end
	dragCatcher.InputBegan:Connect(function(input)
		beginDrag(input, false)
		rightClick(input)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and not pinching then
			local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement and dragInput
				and dragInput.UserInputType == Enum.UserInputType.MouseButton1
			if isMouse or input == dragInput then
				local position = Vector2.new(input.Position.X, input.Position.Y)
				if resync then
					resync = false
				else
					local delta = (position - lastPosition) / options.getScale()
					pressTravel += delta.Magnitude
					offset += delta
					applyView()
					if wheelTarget then
						-- A wheel glide under way follows the drag: it zooms about the pointer,
						-- keeping the map point now under it.
						wheelAnchor += delta
						wheelPoint = (wheelAnchor - offset) / zoom
					end
				end
				lastPosition = position
			end
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and pointerInside then
			local point = mapPointAt(input.Position)
			setHover(subAt(point.X, point.Y))
			if not overLocation then
				Tooltip.refresh(dragCatcher)
			end
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and pointerInside then
			wheelZoom(if input.Position.Z > 0 then 1 else -1, toLocal(input.Position))
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			setHover(nil) -- touch has no hover: the highlight lasts only while a finger is down
		end
		if input == otherTouch then
			otherTouch = nil
			return
		end
		if not dragging then
			return
		end
		if input == dragInput or (input.UserInputType == Enum.UserInputType.MouseButton1 and dragInput
			and dragInput.UserInputType == Enum.UserInputType.MouseButton1) then
			local other = otherTouch
			if other then
				-- The first finger lifted while a second one is still down: that one pans on.
				otherTouch = nil
				dragInput = other
				resync = true
				return
			end
			dragging = false
			dragInput = nil
			if wasClick() and not pinching and not pressedLocation then
				-- A click selects the province under the pointer; the sea clears the selection.
				local point = mapPointAt(input.Position)
				local sub = subAt(point.X, point.Y)
				options.onSelect(if sub then sub.data.provinceId else nil)
			end
		end
	end)

	-- Two fingers: the zoom follows the pinch about the fingers' midpoint, and the map follows the
	-- midpoint as it moves (two-finger pan). When the pinch ends, the finger still down drags on.
	UserInputService.TouchPinch:Connect(function(positions, pinchScale, _velocity, state)
		if not pointerInside and state == Enum.UserInputState.Begin then
			return
		end
		if state == Enum.UserInputState.Begin then
			stopCamera()
			setHover(nil)
			pinching = true
			pressTravel = math.huge -- a pinch is never a click
			pinchStartZoom = zoom
			pinchMidpoint = if #positions >= 2 then toLocal((positions[1] + positions[2]) / 2) else nil
		elseif state == Enum.UserInputState.Change and pinching then
			local anchor = viewSize() / 2
			if #positions >= 2 then
				anchor = toLocal((positions[1] + positions[2]) / 2)
				local previous = pinchMidpoint
				if previous then
					offset += anchor - previous
				end
				pinchMidpoint = anchor
			end
			zoomAt((pinchStartZoom * pinchScale) / zoom, anchor)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			if pinching then
				-- The finger still down moved during the pinch: its next move starts the drag afresh.
				resync = true
			end
			pinching = false
			pinchMidpoint = nil
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

-- Parents the triangles of one sub-territory or feature under a model named after it.
local function group(wedges: { WedgePart }, name: string, parent: Instance)
	local model = Instance.new("Model")
	model.Name = name
	FlatTriangles.parentAll(wedges, model)
	model.Parent = parent
end

-- The political and atlas pictures: the same triangles (each outline triangulated once), in each
-- look's colours, grouped by sub-territory and feature id.
local function buildFills()
	camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	atlasCamera = Instance.new("Camera")
	atlasCamera.FieldOfView = FIELD_OF_VIEW
	atlasCamera.Parent = atlasViewport
	atlasViewport.CurrentCamera = atlasCamera

	local land = Instance.new("Model")
	land.Name = "Land"
	local atlasLand = Instance.new("Model")
	atlasLand.Name = "Land"
	for _, sub in subs do
		for _, path in sub.data.paths do
			local triangles = Polygon.triangulate(path)
			FlatTriangles.addList(sub.wedges, triangles, 0, sub.color)
			FlatTriangles.addList(sub.atlasWedges, triangles, 0, sub.atlasColor)
		end
		group(sub.wedges, sub.data.id, land)
		group(sub.atlasWedges, sub.data.id, atlasLand)
	end
	for _, feature in MapData.specialFeatures do
		local color = fromHex(feature.color)
		local fill: FeatureFill = { color = color, terrainColor = MapConfig.featureColor(feature.id), shown = color, wedges = {} }
		local atlasWedges: { WedgePart } = {}
		for _, path in feature.paths do
			local triangles = Polygon.triangulate(path)
			FlatTriangles.addList(fill.wedges, triangles, 0, color)
			FlatTriangles.addList(atlasWedges, triangles, 0, fill.terrainColor)
		end
		group(fill.wedges, feature.id, land)
		group(atlasWedges, feature.id, atlasLand)
		table.insert(featureFills, fill)
	end
	land.Parent = viewport
	atlasLand.Parent = atlasViewport
end

local function buildBorders()
	subBorderLayer = layer("SubBorders", 1)
	for _, sub in subs do
		for _, path in sub.data.paths do
			outline(subBorderLayer, path, MapConfig.SubBorder)
		end
	end
	local features = layer("FeatureBorders", 2)
	for _, feature in MapData.specialFeatures do
		for _, path in feature.paths do
			outline(features, path, MapConfig.FeatureBorder)
		end
	end
	regionBorderLayer = layer("RegionBorders", 3)
	for _, region in MapData.regions do
		for _, path in region.paths do
			outline(regionBorderLayer, path, MapConfig.RegionBorder)
		end
	end
	-- The atlas look's outlines: every region in its ruling house's colour (shown instead of the
	-- black borders from the middle of the blend zone).
	kingdomBorderLayer = layer("KingdomBorders", 3)
	kingdomBorderLayer.Visible = false
	local border = MapConfig.Atlas.KingdomBorder
	for _, region in MapData.regions do
		local style = { color = regionColors[region.id]:Lerp(MapConfig.Ink, border.darken), thickness = border.thickness }
		for _, path in region.paths do
			outline(kingdomBorderLayer, path, style)
		end
	end
	local glowLayer = layer("RegionGlow", 4)
	local hoverBorder = MapConfig.Atlas.KingdomHover
	for _, region in MapData.regions do
		local glow = UI.create("Frame", {
			Name = `Glow_{region.id}`,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = false,
			Parent = glowLayer,
		})
		for _, path in region.paths do
			outline(glow, path, MapConfig.RegionGlow)
		end
		for _, path in region.paths do
			outline(glow, path, MapConfig.RegionGlowCore)
		end
		glowByRegion[region.id] = glow
		-- The atlas look's hover outline, in the house colour.
		local hover = UI.create("Frame", {
			Name = `KingdomHover_{region.id}`,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Visible = false,
			Parent = glowLayer,
		})
		local style = { color = regionColors[region.id]:Lerp(MapConfig.Ink, hoverBorder.darken), thickness = hoverBorder.thickness }
		for _, path in region.paths do
			outline(hover, path, style)
		end
		kingdomHoverByRegion[region.id] = hover
	end
	mineLayer = layer("OwnProvinces", 5)
	selectionLayer = layer("Selection", 6)
end

-- A map label with a halo; returns the label and its halo (UIStroke).
local function textLabel(props: { [string]: any }, halo: Color3): (TextLabel, UIStroke)
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
	local stroke = UI.create("UIStroke", {
		Color = halo,
		Thickness = props.HaloThickness or 1.5,
		Transparency = MapConfig.HaloTransparency,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
	return label, stroke
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
			local textColor, halo = MapConfig.contrast(fill)
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
		local textColor, halo = MapConfig.contrast(fromHex(entry.color))
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
		local houseLine, houseHalo = textLabel({ Text = entry.lines[1], TextColor3 = textColor, LayoutOrder = 1, Parent = holder }, halo)
		local nameLine, nameHalo = textLabel({ Text = entry.lines[2] or "", TextColor3 = textColor, LayoutOrder = 2, Parent = holder }, halo)
		table.insert(houseLabels, { holder = holder, house = houseLine, name = nameLine, halos = { houseHalo, nameHalo } })
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
			Size = UDim2.fromOffset(MapConfig.IconSize, MapConfig.IconSize),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = 1,
			Parent = locationLayer,
		})
		local icon = UI.create("Frame", { Name = "Icon", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 1, Parent = button })
		MapIcons.build(icon, location.type, MapConfig.Ink, MapConfig.Paper)
		local label = textLabel({
			Name = "Label",
			Text = location.name,
			TextSize = MapConfig.LocationTextSize,
			FontFace = Fonts.Serif,
			TextColor3 = MapConfig.Ink,
			HaloThickness = 1.2,
			Parent = button,
		}, MapConfig.Paper)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.new(0.5, 0, 1, 1)
		label.ZIndex = 4
		-- Military mode only: the province's garrison, under the icon (and its name when shown).
		local garrison: TextLabel? = nil
		if provinceId then
			local garrisonLabel = textLabel({
				Name = "Garrison",
				Text = "",
				TextSize = MapConfig.GarrisonTextSize,
				FontFace = Fonts.BodyBold,
				TextColor3 = MapConfig.Ink,
				HaloThickness = 1.2,
				Parent = button,
			}, MapConfig.Paper)
			garrisonLabel.AnchorPoint = Vector2.new(0.5, 0)
			garrisonLabel.Position = UDim2.new(0.5, 0, 1, 1)
			garrisonLabel.ZIndex = 4
			garrisonLabel.Visible = false
			garrison = garrisonLabel
		end

		button.InputBegan:Connect(function(input)
			beginDrag(input, true)
			if provinceId and input.UserInputType == Enum.UserInputType.MouseButton2 then
				options.onCommand(provinceId)
			elseif not provinceId then
				rightClick(input)
			end
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
			if provinceId and wasClick() then
				options.onSelect(provinceId)
			end
		end)
		Tooltip.bind(button, function()
			return locationTooltip(location)
		end)
		table.insert(locations, { button = button, label = label, garrison = garrison, provinceId = provinceId })
	end
end

-- Army tokens and routes, drawn by UI/ArmyLayer on canvas layers above the labels.
local function buildArmies()
	ArmyLayer.mount({
		store = options.store,
		layer = layer,
		scalePosition = scalePosition,
		beginDrag = function(input: InputObject, onLocation: boolean?)
			beginDrag(input, onLocation)
		end,
		commandArmy = function(armyId: string)
			options.onCommandArmy(armyId)
		end,
		hover = function(button: TextButton, inside: boolean)
			if inside then
				overLocation = button
			elseif overLocation == button then
				overLocation = nil
			end
		end,
		onSelectArmy = function(armyId: string)
			if wasClick() then
				options.onSelectArmy(armyId)
			end
		end,
	})
end

-- Overlay ----------------------------------------------------------------------------------------

local function legendRow(text: string, color: Color3, order: number, parent: Instance?)
	local row = UI.create("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = order, Parent = parent or legend })
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
		UI.label({ text = "The lands of the great houses. Shades mark the sub-territories of each region. Zoom in for the atlas of the land.", size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 1, parent = legend })
	elseif mode == "realm" then
		UI.label({ text = "Colour shows the house that holds each province today.", size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 1, parent = legend })
	elseif mode == "relations" then
		legendRow("Your house", Colors.Gold, 1)
		legendRow("Friendly (+100)", Theme.relationColor(100), 2)
		legendRow("Neutral (0)", Theme.relationColor(0), 3)
		legendRow("Hostile (-100)", Theme.relationColor(-100), 4)
	elseif mode == "wealth" then
		legendRow("Poor", MapConfig.WealthPoor, 1)
		legendRow(`Rich ({Format.gold(maxIncome)} gold/month)`, MapConfig.WealthRich, 2)
	elseif mode == "military" then
		legendRow("Few men", MapConfig.MenFew, 1)
		legendRow(`Many men ({Format.troops(maxMen)})`, MapConfig.MenMany, 2)
		UI.label({ text = "Men present: the garrison plus the armies standing in the province. Zoom in to read each garrison.", size = Theme.TextSize.Small, wrap = true, color = Colors.Ink, order = 3, parent = legend })
	else
		-- Terrain: a typical colour for each terrain type in two columns, then the regional looks.
		local grid = UI.create("Frame", {
			Name = "TerrainTypes",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = legend,
		})
		UI.create("UIGridLayout", {
			CellSize = UDim2.new(0.5, -3, 0, 16),
			CellPadding = UDim2.fromOffset(6, 3),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = grid,
		})
		for index, terrain in Content.raw.terrains do
			legendRow(terrain.name, MapConfig.TerrainSwatch[terrain.id] or Theme.fromRGB(terrain.color), index, grid)
		end
		for index, extra in MapConfig.TerrainLegendExtras do
			legendRow(extra.label, extra.color, 1 + index)
		end
	end
	UI.label({ text = "Gold outlines: your provinces (thin), the selection (thick).", size = Theme.TextSize.Small, wrap = true, color = Colors.InkMuted, order = 99, parent = legend })
end

local function setSubBordersVisible(visible: boolean)
	subBordersVisible = visible
	-- The atlas look has no sub-territory borders.
	subBorderLayer.Visible = visible and not atlasLook
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
		{ id = "houses", label = "Houses", tip = "The lands of the nine great houses. Zoom in and they fade into an atlas of the land." },
		{ id = "realm", label = "Realm", tip = "Who holds each province today." },
		{ id = "relations", label = "Relations", tip = "How each owner regards your house." },
		{ id = "wealth", label = "Wealth", tip = "Monthly income of each province." },
		{ id = "terrain", label = "Terrain", tip = "The land itself. Terrain affects income, development cost and marching time." },
		{ id = "military", label = "Military", tip = "Men present in each province: its garrison and the armies standing there." },
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
		-- "Military" is also the name of a navigation tab: the name tells the two buttons apart.
		button.Name = `Mode_{info.id}`
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
	Tooltip.setText(bordersToggle, "Show or hide the thin borders between sub-territories (the political map only; the atlas has none).")

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
		zoomStep(1)
	end)
	zoomButton("-", "Zoom out", 2, function()
		zoomStep(-1)
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
		regionColors[region.id] = regionColorOf(region)
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
		local sub: Sub = {
			data = data,
			region = region,
			house = house,
			baseColor = baseColor,
			color = baseColor,
			wedges = {},
			atlasColor = atlasColorOf(data),
			atlasWedges = {},
			bounds = bounds,
		}
		table.insert(subs, sub)
		local list = subsByProvince[data.provinceId]
		if not list then
			list = {}
			subsByProvince[data.provinceId] = list
		end
		table.insert(list, sub)
		local inRegion = subsByRegion[data.regionId]
		if not inRegion then
			inRegion = {}
			subsByRegion[data.regionId] = inRegion
		end
		table.insert(inRegion, sub)
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
	atlasViewport = UI.create("ViewportFrame", {
		Name = "AtlasFills",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = MapConfig.Atlas.Sea,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 1,
		Parent = container,
	})
	FlatTriangles.setupViewport(atlasViewport)
	viewport = UI.create("ViewportFrame", {
		Name = "Fills",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = ocean,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = container,
	})
	FlatTriangles.setupViewport(viewport)

	local dragCatcher = UI.create("TextButton", {
		Name = "DragCatcher",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 3,
		Parent = container,
	})

	canvas = UI.create("Frame", {
		Name = "Canvas",
		Size = UDim2.fromOffset(MAP_WIDTH * zoom, MAP_HEIGHT * zoom),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = container,
	})

	buildFills()
	buildBorders()
	bindInput(dragCatcher)
	buildCrestsAndLabels()
	buildLocations()
	buildArmies()
	buildOverlay()

	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(onResize)
	MapController.setMode("houses")
	-- The whole-map view, at once.
	lastSize = viewSize()
	flyTo(boundsCentre(), fitZoom(), 0)
end

function MapController.setMode(newMode: MapMode)
	mode = newMode
	for id, button in modeButtons do
		UI.setSelected(button, id == mode)
	end
	recomputeMaxIncome()
	recomputeMen()
	rebuildLegend()
	recolorAll()
	recolorFeatures()
	rebuildMine()
	updateGarrisonLabels()
	-- The blend between the political and atlas looks depends on the mode.
	styleForZoom()
end

function MapController.select(provinceId: string?)
	selectedId = provinceId
	rebuildSelection()
end

-- Highlights an army's token and shows its route (nil clears the army selection).
function MapController.selectArmy(armyId: string?)
	ArmyLayer.select(armyId)
end

-- Applies replicated changes: only affected provinces are recoloured unless the mode depends on
-- data that changed globally (relations, men present, the player's house, full resync). Army
-- tokens and routes follow every change (and every day, while armies march).
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
	if mode == "military" and (all or next(changes.provinces) ~= nil or next(changes.armies) ~= nil) then
		if recomputeMen() or all then
			rebuildLegend()
			all = true
		end
		if all or next(changes.provinces) ~= nil then
			updateGarrisonLabels()
		end
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
	ArmyLayer.refresh(changes)
end

return MapController
