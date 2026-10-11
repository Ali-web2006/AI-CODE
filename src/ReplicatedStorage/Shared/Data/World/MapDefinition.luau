--!strict
--[[
	Presentation data for the strategic map canvas. Nothing here affects the simulation.

	The landmass silhouette is approximated with overlapping circles so the prototype needs no
	image assets. A later art pass can replace this with an image or mesh without touching the
	province data, which is positioned in the same map-unit coordinate space.
]]

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local map: GameTypes.MapDefinition = {
	width = 1000,
	height = 1500,
	landmass = {
		-- The North
		{ x = 470, y = 130, r = 170 },
		{ x = 320, y = 190, r = 150 },
		{ x = 630, y = 170, r = 150 },
		{ x = 270, y = 320, r = 125 },
		{ x = 460, y = 300, r = 180 },
		{ x = 660, y = 310, r = 135 },
		{ x = 745, y = 225, r = 85 },
		{ x = 380, y = 450, r = 145 },
		{ x = 585, y = 450, r = 130 },
		{ x = 480, y = 520, r = 105 },
		-- The Neck
		{ x = 480, y = 600, r = 70 },
		{ x = 465, y = 645, r = 70 },
		-- The Riverlands
		{ x = 410, y = 720, r = 100 },
		{ x = 520, y = 740, r = 105 },
		{ x = 430, y = 830, r = 105 },
		{ x = 560, y = 850, r = 95 },
		-- The Vale
		{ x = 650, y = 745, r = 75 },
		{ x = 720, y = 715, r = 95 },
		{ x = 790, y = 785, r = 65 },
		{ x = 745, y = 800, r = 75 },
		-- The Westerlands
		{ x = 300, y = 875, r = 95 },
		{ x = 220, y = 915, r = 75 },
		{ x = 250, y = 990, r = 75 },
		{ x = 320, y = 1000, r = 95 },
		-- The Crownlands
		{ x = 640, y = 935, r = 105 },
		{ x = 705, y = 895, r = 60 },
		-- The Stormlands
		{ x = 670, y = 1080, r = 90 },
		{ x = 760, y = 1120, r = 75 },
		{ x = 600, y = 1170, r = 90 },
		-- The Reach
		{ x = 430, y = 1080, r = 120 },
		{ x = 360, y = 1185, r = 130 },
		{ x = 480, y = 1215, r = 100 },
		{ x = 290, y = 1290, r = 100 },
		{ x = 240, y = 1335, r = 68 },
		{ x = 400, y = 1300, r = 100 },
		-- Dorne
		{ x = 550, y = 1330, r = 70 },
		{ x = 640, y = 1340, r = 90 },
		{ x = 720, y = 1380, r = 90 },
		{ x = 820, y = 1410, r = 70 },
		{ x = 760, y = 1430, r = 60 },
		-- Islands
		{ x = 190, y = 720, r = 40 },
		{ x = 250, y = 640, r = 42 },
		{ x = 830, y = 915, r = 36 },
		{ x = 150, y = 1420, r = 45 },
	},
	labels = {
		{ text = "THE NORTH", x = 470, y = 165 },
		{ text = "THE IRON ISLANDS", x = 175, y = 585 },
		{ text = "THE RIVERLANDS", x = 395, y = 760 },
		{ text = "THE VALE", x = 770, y = 655 },
		{ text = "THE WESTERLANDS", x = 200, y = 1045 },
		{ text = "THE CROWNLANDS", x = 760, y = 985 },
		{ text = "THE STORMLANDS", x = 735, y = 1205 },
		{ text = "THE REACH", x = 340, y = 1110 },
		{ text = "DORNE", x = 615, y = 1455 },
		{ text = "THE SUNSET SEA", x = 95, y = 1150 },
		{ text = "THE NARROW SEA", x = 905, y = 560 },
		{ text = "THE SUMMER SEA", x = 420, y = 1475 },
	},
}

return map
