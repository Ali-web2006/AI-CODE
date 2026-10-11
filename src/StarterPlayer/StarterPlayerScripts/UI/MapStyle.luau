--!strict
--[[
	MapStyle — the world map's drawing rules: border weights, label and crest sizing by zoom, and
	the zoom thresholds at which detail appears. Zoom is measured in virtual pixels per map unit
	(the map is 1000 x 1900 units; fitting it on a 1280x720 layout gives a zoom of about 0.35).

	tools/render_map_preview.py mirrors these values; keep the two in sync.
]]

local MapStyle = {}

MapStyle.MaxZoom = 2.6
MapStyle.FitMargin = 0.98 -- share of the map area's height the whole map fills when fitted

-- Borders (Path2D strokes: constant on-screen width at every zoom, always opaque)
MapStyle.SubBorder = { color = Color3.fromRGB(48, 48, 48), thickness = 1 }
MapStyle.FeatureBorder = { color = Color3.fromRGB(48, 48, 48), thickness = 1 }
MapStyle.RegionBorder = { color = Color3.fromRGB(14, 14, 14), thickness = 2 }
MapStyle.RegionGlow = { color = Color3.fromRGB(255, 232, 160), thickness = 4 }
MapStyle.RegionGlowCore = { color = Color3.fromRGB(255, 255, 255), thickness = 1.5 }
MapStyle.Selection = { color = Color3.fromRGB(250, 214, 110), thickness = 3 }

-- Hovered sub-territories are lightened toward white by this share.
MapStyle.HoverLighten = 0.22

-- Crests: CrestUnits map units wide, clamped to [CrestMin, CrestMax] pixels; past FadeFrom they
-- fade (up to FadeMax transparency at FadeTo) so the land underneath stays readable.
MapStyle.CrestUnits = 110
MapStyle.CrestMin = 40
MapStyle.CrestMax = 84
MapStyle.CrestFadeFrom = 1.0
MapStyle.CrestFadeTo = 1.8
MapStyle.CrestFadeMax = 0.55

-- Great-house labels: always visible, two lines ("HOUSE" above the name).
MapStyle.HouseTextUnits = 40
MapStyle.HouseTextMin = 13
MapStyle.HouseTextMax = 24
MapStyle.HouseLineRatio = 0.62 -- size of "HOUSE" relative to the name

-- Special feature labels (The Wall, The Gift, Beyond the Wall).
MapStyle.FeatureTextUnits = 30
MapStyle.FeatureTextMin = 11
MapStyle.FeatureTextMax = 18

-- Locations: icons appear from LocationIconZoom, their small labels from LocationLabelZoom.
MapStyle.LocationIconZoom = 0.45
MapStyle.LocationLabelZoom = 0.75
MapStyle.IconSize = 14
MapStyle.LocationTextSize = 12

MapStyle.Ink = Color3.fromRGB(24, 20, 16)
MapStyle.Paper = Color3.fromRGB(244, 236, 216)

function MapStyle.clamp(units: number, zoom: number, minimum: number, maximum: number): number
	return math.clamp(units * zoom, minimum, maximum)
end

-- Text colour and halo for a label drawn over a fill: dark on light fills, white on dark or
-- saturated ones.
function MapStyle.contrast(fill: Color3): (Color3, Color3)
	local luminance = 0.2126 * fill.R + 0.7152 * fill.G + 0.0722 * fill.B
	if luminance > 0.55 then
		return Color3.fromRGB(40, 40, 40), Color3.fromRGB(255, 255, 255)
	end
	return Color3.fromRGB(255, 255, 255), Color3.fromRGB(20, 20, 20)
end

function MapStyle.fromHex(hex: string): Color3
	return Color3.fromHex(hex)
end

return MapStyle
