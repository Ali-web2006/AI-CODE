--!strict
--[[
	Theme — the visual language of the interface: dark charcoal and burgundy chrome, parchment
	documents, restrained gold accents, serif headings and a legible sans body.

	All sizes are in virtual pixels of the 1280x720 design resolution; UIController applies a
	single UIScale so the layout fits any screen.
]]

local Theme = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

Theme.Colors = {
	-- Chrome
	Backdrop = rgb(20, 17, 17),
	Chrome = rgb(33, 27, 26),
	ChromeRaised = rgb(46, 37, 35),
	ChromeBorder = rgb(92, 72, 52),
	Burgundy = rgb(98, 28, 34),
	BurgundyBright = rgb(132, 40, 46),
	TextOnDark = rgb(237, 227, 206),
	MutedOnDark = rgb(168, 154, 128),

	-- Parchment documents
	Parchment = rgb(233, 223, 199),
	ParchmentDeep = rgb(218, 203, 170),
	ParchmentEdge = rgb(160, 132, 92),
	Ink = rgb(43, 33, 22),
	InkMuted = rgb(108, 90, 66),

	-- Accents
	Gold = rgb(201, 165, 76),
	GoldBright = rgb(232, 198, 110),
	Positive = rgb(84, 140, 70),
	PositiveOnDark = rgb(132, 186, 112),
	Negative = rgb(176, 64, 52),
	NegativeOnDark = rgb(222, 112, 96),
	Disabled = rgb(120, 110, 96),

	-- Map
	Sea = rgb(124, 150, 152),
	SeaDeep = rgb(104, 130, 134),
	Land = rgb(228, 214, 180),
	Coast = rgb(176, 156, 112),
	MapLabel = rgb(92, 72, 48),
	Road = rgb(128, 96, 64),
	River = rgb(70, 110, 150),
	SeaLane = rgb(232, 240, 240),
	Pass = rgb(90, 70, 60),
	Wild = rgb(110, 120, 80),
	Selection = rgb(250, 214, 110),
}

-- Font families are taken from the engine's own Enum.Font mapping (no hard-coded asset paths);
-- only the weight and style are changed.
local function fontFrom(enumFont: Enum.Font, weight: Enum.FontWeight?, style: Enum.FontStyle?): Font
	local base = Font.fromEnum(enumFont)
	return Font.new(base.Family, weight or Enum.FontWeight.Regular, style or Enum.FontStyle.Normal)
end

Theme.Fonts = {
	Title = fontFrom(Enum.Font.GrenzeGotisch),
	Heading = fontFrom(Enum.Font.Merriweather, Enum.FontWeight.Bold),
	Serif = fontFrom(Enum.Font.Merriweather),
	SerifItalic = fontFrom(Enum.Font.Merriweather, Enum.FontWeight.Regular, Enum.FontStyle.Italic),
	Body = fontFrom(Enum.Font.SourceSans),
	BodyBold = fontFrom(Enum.Font.SourceSans, Enum.FontWeight.Bold),
	BodySemibold = fontFrom(Enum.Font.SourceSans, Enum.FontWeight.SemiBold),
}

Theme.TextSize = {
	Small = 13,
	Body = 15,
	Large = 17,
	Heading = 19,
	Title = 24,
	Display = 46,
}

Theme.Layout = {
	DesignWidth = 1280,
	DesignHeight = 720,
	TopBarHeight = 58,
	NavWidth = 92,
	PanelWidth = 372,
	CompactPanelWidth = 320,
	CompactBreakpoint = 1100, -- virtual width below which the compact layout is used
	Corner = 6,
	Gap = 8,
}

function Theme.fromRGB(color: { number }): Color3
	return Color3.fromRGB(color[1], color[2], color[3])
end

-- Interpolates between two colours (t in 0..1).
function Theme.mix(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

-- Colour of a relation score on a red - grey - green scale.
function Theme.relationColor(score: number): Color3
	local neutral = Color3.fromRGB(176, 166, 146)
	if score >= 0 then
		return Theme.mix(neutral, Color3.fromRGB(70, 140, 70), score / 100)
	end
	return Theme.mix(neutral, Color3.fromRGB(170, 50, 44), -score / 100)
end

return Theme
