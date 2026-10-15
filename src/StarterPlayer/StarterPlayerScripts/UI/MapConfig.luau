--!strict
--[[
	MapConfig — the one file that tunes the 2D world map: what the whole-map view shows, how far
	it zooms, how the camera moves, what is drawn at each zoom level, and the colours of the land.
	Presentation only: nothing here changes the game itself.

	Units. Positions are map units: the map is 1000 units wide and 1900 tall (x to the right, y
	down). A zoom in pixels is screen pixels per map unit on the 1280 x 720 design layout. The
	whole-map view there is a zoom of about 0.35 (Westeros, 1900 units tall, in a map area 662
	pixels tall), so a zoom of 1.0 is about three times closer.

	Two kinds of zoom numbers. The zoom levels (Zoom) and the zooms of the first view and of a
	flight to a province (Camera) count from the whole-map view instead: 2.3 means "zoomed in 2.3
	times from the whole-map view". So the whole-map view is always the political map, on any
	screen and with either FitMode. The other zooms (MaxZoom, and the crest and location zooms
	under Political look) are about how big things are on screen, so they are in pixels per map
	unit.

	How to tune it. Every number below can be changed; the comment above it says what it does.
	Run ./scripts/verify.sh afterwards: it checks that the zoom levels are still in order, that
	the frame still holds all the land and that every region still reads as its look.
	  View              what the whole-map view frames, how it fills the screen, the zoom limits
	  Zoom              the zoom levels: Political (house colours) below BlendStart; the blend
	                    zone, where the political colours fade out and the atlas look fades in;
	                    Atlas; Notable; Close
	  Camera            how quickly the mouse wheel, the + / - buttons and flights move the view,
	                    and where they go
	  Political look    borders, hover, crests, house and feature labels, locations
	  Map mode colours  the colour ramps of the Wealth and Military map modes
	  Palette           the colours of the land, region by region (muted, like an old printed
	                    atlas). The atlas look and the Terrain map mode both use them
	                    (terrainColor and featureColor below), so the two always agree
	  Atlas look        its sea, the kingdom borders in the house colours, the hover fill

	tools/render_map_preview.py mirrors the political drawing values; keep the two in sync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Content = require(ReplicatedStorage.Shared.Data.Content)

export type FitMode = "height" | "fill"
export type ZoomLevel = "political" | "blend" | "atlas" | "close"
export type Stroke = { color: Color3, thickness: number }
export type Shift = { toward: Color3, amount: number }

local MapConfig = {}

local function hex(value: string): Color3
	return Color3.fromHex(value)
end

-- View ---------------------------------------------------------------------------------------------

MapConfig.View = {
	-- The frame, in map units: Westeros from Beyond the Wall to the tip of Dorne with a margin of
	-- sea around it. The empty sea in the east, where Essos would be, is outside it. The view
	-- can never be panned out of the frame, so you cannot scroll off into empty sea. Where the
	-- frame is narrower than the map area (the sides of the whole-map view, Westeros being tall
	-- and narrow), you can slide it sideways, but never off the screen.
	Bounds = { minX = 65, minY = 0, maxX = 1000, maxY = 1900 },
	-- "height": the whole-map view fits the frame's full height into the map area: all of
	-- Westeros, top to bottom. Westeros is about half as wide as it is tall and the map area is
	-- wider than tall, so there is sea on both sides. "fill": the frame covers the whole map
	-- area: Westeros fills its width as well and runs off the top and bottom; drag to see the
	-- rest. The zoom levels count from the whole-map view, so it is political in both modes.
	FitMode = "height" :: FitMode,
	-- Share of the map area the frame fills in the whole-map view (1 = all of it).
	FitMargin = 1.0,
	-- How far out the map zooms, as a multiple of the whole-map view (1 = not past it).
	MinZoomFactor = 1.0,
	-- How far in the map zooms, in pixels per map unit (about 11 times the whole-map view on the
	-- design layout). Where the Close zoom level lies further in (a very tall screen, or "fill"
	-- on a wide one), the map zooms in as far as Close instead.
	MaxZoom = 4.0,
}

-- Zoom levels --------------------------------------------------------------------------------------

MapConfig.Zoom = {
	-- Every level is a multiple of the whole-map view's zoom: 1 = the whole map, 2 = twice as
	-- close. (On the design layout, 2.3 is a zoom of 0.8 pixels per map unit.)
	-- Below BlendStart the map is political: house colours, crests and house names. From
	-- BlendStart to BlendEnd the political colours fade out and the atlas look fades in.
	BlendStart = 2.3,
	BlendEnd = 3.6,
	-- How far the political colours have faded (0 = not at all, 1 = gone) when the black borders
	-- give way to thin kingdom borders in the house colours, and the hover to an outline and a
	-- faint fill in the house colour (0.5 = the middle of the blend zone).
	BorderSwitch = 0.5,
	-- From Atlas: the full atlas look, with the major settlements (they come with Part C of the
	-- map upgrade).
	Atlas = 3.6,
	-- From Notable: the next rank of settlements (Part C).
	Notable = 5.2,
	-- From Close: every settlement and its name (Part C).
	Close = 7.5,
	-- Crests and house names fade out across the blend zone in this many steps, so a smooth zoom
	-- does not rewrite them on every frame.
	BlendSteps = 20,
}

-- Camera -------------------------------------------------------------------------------------------

MapConfig.Camera = {
	-- Each mouse wheel notch zooms by this factor, towards the point under the pointer.
	WheelStep = 1.15,
	-- How softly the wheel zoom glides, in seconds (0 = it jumps; larger = softer and slower).
	WheelSmoothing = 0.1,
	-- Each click on + or - zooms by this factor about the middle of the view, over ButtonTime
	-- seconds.
	ButtonStep = 1.25,
	ButtonTime = 0.2,
	-- Seconds of a flight to a province, to an army or to the whole-map view (the [ ] button).
	FlyTime = 0.45,
	-- A flight to a province or an army chosen in a panel zooms in to at least this, as a
	-- multiple of the whole-map view (below Zoom.BlendStart, so it stays political).
	FocusZoom = 2.2,
	-- The zoom of the first view of a campaign, centred on the house seat, as a multiple of the
	-- whole-map view (political).
	StartZoom = 2.15,
	-- A press that moves the pointer at least this many pixels is a drag, not a click.
	ClickSlop = 4,
}

-- Political look -----------------------------------------------------------------------------------

-- Borders (Path2D strokes: constant on-screen width at every zoom, always opaque)
MapConfig.SubBorder = { color = Color3.fromRGB(48, 48, 48), thickness = 1 } :: Stroke
MapConfig.FeatureBorder = { color = Color3.fromRGB(48, 48, 48), thickness = 1 } :: Stroke
MapConfig.RegionBorder = { color = Color3.fromRGB(14, 14, 14), thickness = 2 } :: Stroke
MapConfig.RegionGlow = { color = Color3.fromRGB(255, 232, 160), thickness = 4 } :: Stroke
MapConfig.RegionGlowCore = { color = Color3.fromRGB(255, 255, 255), thickness = 1.5 } :: Stroke
MapConfig.Selection = { color = Color3.fromRGB(250, 214, 110), thickness = 3 } :: Stroke
-- The thin gold outline around the provinces your house holds.
MapConfig.OwnProvinces = { color = Color3.fromRGB(201, 165, 76), thickness = 1.5 } :: Stroke

-- Hovered sub-territories are lightened toward white by this share.
MapConfig.HoverLighten = 0.22

-- The halo around map labels (house, feature and location names): 0 = solid, 1 = invisible.
MapConfig.HaloTransparency = 0.1

-- Crests: CrestUnits map units wide, clamped to [CrestMin, CrestMax] pixels; past FadeFrom they
-- fade (up to FadeMax transparency at FadeTo) so the land underneath stays readable. In the
-- blend zone they also fade out with the political colours.
MapConfig.CrestUnits = 110
MapConfig.CrestMin = 40
MapConfig.CrestMax = 84
MapConfig.CrestFadeFrom = 1.0
MapConfig.CrestFadeTo = 1.8
MapConfig.CrestFadeMax = 0.55

-- Great-house labels: two lines ("HOUSE" above the name), shown in the political look and fading
-- out across the blend zone.
MapConfig.HouseTextUnits = 40
MapConfig.HouseTextMin = 13
MapConfig.HouseTextMax = 24
MapConfig.HouseLineRatio = 0.62 -- size of "HOUSE" relative to the name

-- Special feature labels (The Wall, The Gift, Beyond the Wall).
MapConfig.FeatureTextUnits = 30
MapConfig.FeatureTextMin = 11
MapConfig.FeatureTextMax = 18

-- Locations: icons appear from LocationIconZoom, their small labels from LocationLabelZoom.
MapConfig.LocationIconZoom = 0.45
MapConfig.LocationLabelZoom = 0.75
MapConfig.IconSize = 14
MapConfig.LocationTextSize = 12

-- Military map mode only (not drawn by the preview tool): "Garrison 1,800" under each holding
-- icon, moved below the holding's name once names are shown.
MapConfig.GarrisonTextSize = 11
MapConfig.GarrisonBelowName = 15

MapConfig.Ink = Color3.fromRGB(24, 20, 16)
MapConfig.Paper = Color3.fromRGB(244, 236, 216)

-- Map mode colours ---------------------------------------------------------------------------------

-- The Wealth and Military modes shade each province between two colours. The curve bends the
-- ramp: 1 = even steps, below 1 = small amounts already show clearly.
MapConfig.WealthPoor = Color3.fromRGB(236, 226, 196)
MapConfig.WealthRich = Color3.fromRGB(120, 80, 20)
MapConfig.WealthCurve = 0.8
MapConfig.MenFew = Color3.fromRGB(236, 226, 196)
MapConfig.MenMany = Color3.fromRGB(128, 30, 34)
MapConfig.MenCurve = 0.7
-- In the data modes (and Terrain) the sub-territories of one province are darkened by this share
-- per shade, so they stay distinguishable.
MapConfig.ModeShadeStep = 0.06

-- Palette ------------------------------------------------------------------------------------------

-- The colours of the land. Keep them muted (moderate saturation): the atlas look should read like
-- an old printed map, never neon.
MapConfig.Palette = {
	-- Beyond the Wall, the Wall and the Gift
	snow = hex("#ECEEEA"),
	ice = hex("#D3DDE0"),
	wallGrey = hex("#C3CAC4"),
	-- The North: cold grey-green, the wolfswood darker, barrows and hills greyer, the Neck a marsh
	taiga = hex("#97A28E"),
	taigaForest = hex("#76866F"),
	northHills = hex("#979C8B"),
	marsh = hex("#6E7356"),
	-- The Iron Islands: grey rock
	rock = hex("#8D8F8B"),
	-- The Riverlands: lush green
	riverGreen = hex("#8BA46D"),
	-- The Vale: green valleys under the grey Mountains of the Moon
	valeGreen = hex("#94AB7C"),
	valeStone = hex("#A2A39D"),
	-- The Westerlands: green-brown hills, the Golden Tooth rockier
	westerHills = hex("#A1A074"),
	westerRock = hex("#968672"),
	-- The Reach: rich green and golden fields
	reachGreen = hex("#84A260"),
	reachGold = hex("#C8B670"),
	-- The Crownlands: soft green
	crownGreen = hex("#A6BA8E"),
	-- The Stormlands: dark green, the rainwood darker still
	stormGreen = hex("#7F9669"),
	rainwood = hex("#617B58"),
	-- Dorne: sand and ochre, the Greenblood's valley a touch greener, the Red Mountains
	-- reddish brown
	sand = hex("#DCC491"),
	ochre = hex("#C6A46C"),
	greenblood = hex("#CFC692"),
	redMountain = hex("#9C6A53"),
	-- The Stepstones: bare rock
	stepstones = hex("#9A958B"),
	-- The colours terrain types lean towards where a region has no colour of its own for them
	forestGreen = hex("#617B58"),
	hillBrown = hex("#9B8B6B"),
	stone = hex("#9F9E98"),
}
local Palette = MapConfig.Palette

-- Mixed looks. One province covers a large part of its region on the map (the Eyrie two thirds
-- of the Vale, Kingsgrave and Yronwood three quarters of Dorne), so these provinces only lean
-- toward their own colour and the region keeps the look it is known for. Each is the first
-- colour moved toward the second by the share (0 = the first colour, 1 = the second).
-- The Vale's mountains: its green valleys leaning toward the grey of the Mountains of the Moon.
Palette.valeMountains = Palette.valeGreen:Lerp(Palette.valeStone, 0.4)
-- The Golden Tooth: the green-brown Westerlands hills leaning toward its rock.
Palette.westerMountains = Palette.westerHills:Lerp(Palette.westerRock, 0.4)
-- The Reach's farmlands: its rich green leaning toward the gold of the fields.
Palette.reachFields = Palette.reachGreen:Lerp(Palette.reachGold, 0.3)
-- Dorne's mountain provinces (the Dornish Marches and the Red Mountains): ochre with a tint of
-- the Red Mountains' reddish brown (their full band comes with the terrain data of Part C).
Palette.dorneMountains = Palette.ochre:Lerp(Palette.redMountain, 0.35)

-- The look of each region (by game region id): `base`, plus a colour for any game terrain type
-- (plains, farmlands, forest, hills, mountains, marsh, coast, island, desert) that looks
-- different there. Terrain types not listed use TerrainShift below.
MapConfig.RegionLook = {
	north = { base = Palette.taiga, forest = Palette.taigaForest, hills = Palette.northHills, marsh = Palette.marsh },
	iron_islands = { base = Palette.rock },
	riverlands = { base = Palette.riverGreen },
	vale = { base = Palette.valeGreen, mountains = Palette.valeMountains },
	westerlands = { base = Palette.westerHills, mountains = Palette.westerMountains },
	reach = { base = Palette.reachGreen, farmlands = Palette.reachFields },
	crownlands = { base = Palette.crownGreen },
	stormlands = { base = Palette.stormGreen, forest = Palette.rainwood },
	dorne = { base = Palette.ochre, desert = Palette.sand, mountains = Palette.dorneMountains },
} :: { [string]: { [string]: Color3 } }

-- Single provinces that look different from the rest of their region and terrain.
MapConfig.ProvinceLook = {
	the_greenblood = Palette.greenblood,
} :: { [string]: Color3 }

-- A terrain type a region has no colour of its own for moves the region's base colour toward
-- `toward` by `amount` (0 = no change, 1 = that colour). Plains, coasts and islands keep the base.
MapConfig.TerrainShift = {
	forest = { toward = Palette.forestGreen, amount = 0.45 },
	hills = { toward = Palette.hillBrown, amount = 0.35 },
	mountains = { toward = Palette.stone, amount = 0.6 },
	marsh = { toward = Palette.marsh, amount = 0.8 },
	farmlands = { toward = Palette.reachGold, amount = 0.4 },
	desert = { toward = Palette.sand, amount = 1 },
} :: { [string]: Shift }

-- The special features (drawn, never owned).
MapConfig.FeatureLook = {
	beyond_the_wall = Palette.snow,
	the_wall = Palette.ice,
	the_gift = Palette.wallGrey,
	stepstones = Palette.stepstones,
} :: { [string]: Color3 }

-- The Terrain map mode's legend: a typical colour for each game terrain type, then the regional
-- looks that differ most.
MapConfig.TerrainSwatch = {
	plains = Palette.riverGreen,
	farmlands = Palette.reachFields,
	forest = Palette.rainwood,
	hills = Palette.westerHills,
	mountains = Palette.valeMountains,
	marsh = Palette.marsh,
	coast = Palette.crownGreen,
	island = Palette.rock,
	desert = Palette.sand,
} :: { [string]: Color3 }
MapConfig.TerrainLegendExtras = {
	{ label = "Dorne: desert", color = Palette.sand },
	{ label = "The Red Mountains", color = Palette.dorneMountains },
	{ label = "Beyond the Wall: snow", color = Palette.snow },
} :: { { label: string, color: Color3 } }

-- Atlas look ---------------------------------------------------------------------------------------

MapConfig.Atlas = {
	-- The sea of the atlas look (the political map keeps its dark ocean).
	Sea = hex("#A8C3BE"),
	-- Kingdom borders: every region's outline in its ruling house's colour, darkened toward ink
	-- by `darken` (0 = the pure house colour) so it reads on the pale land.
	KingdomBorder = { thickness = 1.5, darken = 0.35 },
	-- The outline of the region under the pointer, in the same colour.
	KingdomHover = { thickness = 3, darken = 0.15 },
	-- The faint fill of the region under the pointer, in its house colour: 1 = invisible,
	-- 0 = solid house colour.
	HoverFillTransparency = 0.72,
	-- The sub-territories of a region differ by up to this share of lightness (lighter and
	-- darker), so a region is not one flat slab of colour.
	ShadeVariation = 0.03,
}

-- Functions ----------------------------------------------------------------------------------------

function MapConfig.clamp(units: number, zoom: number, minimum: number, maximum: number): number
	return math.clamp(units * zoom, minimum, maximum)
end

-- Text colour and halo for a label drawn over a fill: dark on light fills, white on dark or
-- saturated ones.
function MapConfig.contrast(fill: Color3): (Color3, Color3)
	local luminance = 0.2126 * fill.R + 0.7152 * fill.G + 0.0722 * fill.B
	if luminance > 0.55 then
		return Color3.fromRGB(40, 40, 40), Color3.fromRGB(255, 255, 255)
	end
	return Color3.fromRGB(255, 255, 255), Color3.fromRGB(20, 20, 20)
end

function MapConfig.fromHex(value: string): Color3
	return hex(value)
end

-- How far the atlas look has faded in at `relativeZoom` (the zoom as a multiple of the whole-map
-- view, like the Zoom levels): 0 up to Zoom.BlendStart, 1 from Zoom.BlendEnd, easing smoothly in
-- between.
function MapConfig.blend(relativeZoom: number): number
	local levels = MapConfig.Zoom
	local t = math.clamp((relativeZoom - levels.BlendStart) / math.max(levels.BlendEnd - levels.BlendStart, 1e-6), 0, 1)
	return t * t * (3 - 2 * t)
end

-- The zoom level at `relativeZoom` (a multiple of the whole-map view).
function MapConfig.level(relativeZoom: number): ZoomLevel
	local levels = MapConfig.Zoom
	if relativeZoom >= levels.Close then
		return "close"
	elseif relativeZoom >= levels.Atlas then
		return "atlas"
	elseif relativeZoom > levels.BlendStart then
		return "blend"
	end
	return "political"
end

-- The lore colour of a province: its region's look for its game terrain type.
function MapConfig.terrainColor(provinceId: string): Color3
	local own = MapConfig.ProvinceLook[provinceId]
	if own then
		return own
	end
	local province = Content.provinces[provinceId]
	local look = if province then MapConfig.RegionLook[province.regionId] else nil
	if not province or not look then
		return Palette.stone
	end
	local terrainId = province.terrainId
	local color = look[terrainId]
	if color then
		return color
	end
	local shift = MapConfig.TerrainShift[terrainId]
	if shift then
		return look.base:Lerp(shift.toward, shift.amount)
	end
	return look.base
end

function MapConfig.featureColor(featureId: string): Color3
	return MapConfig.FeatureLook[featureId] or Palette.rock
end

return MapConfig
