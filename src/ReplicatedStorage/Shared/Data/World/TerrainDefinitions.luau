--!strict
-- Terrain categories. taxMultiplier scales province income; developmentCostMultiplier scales the
-- price of developing a province. Future phases add movement, supply and combat modifiers here.

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.TerrainDefinition } = {
	{
		id = "plains",
		name = "Plains",
		description = "Open, settled country. Easy to farm and to administer.",
		taxMultiplier = 1.0,
		developmentCostMultiplier = 1.0,
		color = { 196, 184, 132 },
	},
	{
		id = "farmlands",
		name = "Farmlands",
		description = "The richest soil in the realm. Fields yield more and are cheaper to improve.",
		taxMultiplier = 1.15,
		developmentCostMultiplier = 0.95,
		color = { 178, 182, 108 },
	},
	{
		id = "forest",
		name = "Forest",
		description = "Dense woodland. Sparse settlement and costly clearance.",
		taxMultiplier = 0.85,
		developmentCostMultiplier = 1.1,
		color = { 112, 132, 88 },
	},
	{
		id = "hills",
		name = "Hills",
		description = "Rugged uplands with scattered holdfasts and mines.",
		taxMultiplier = 0.9,
		developmentCostMultiplier = 1.15,
		color = { 164, 140, 102 },
	},
	{
		id = "mountains",
		name = "Mountains",
		description = "High passes and stone keeps. Poor tax base and expensive works.",
		taxMultiplier = 0.75,
		developmentCostMultiplier = 1.35,
		color = { 136, 124, 114 },
	},
	{
		id = "marsh",
		name = "Marsh",
		description = "Bog and fen. Little can be taxed and little can be built.",
		taxMultiplier = 0.7,
		developmentCostMultiplier = 1.25,
		color = { 112, 128, 104 },
	},
	{
		id = "coast",
		name = "Coast",
		description = "Fishing villages and harbours along the shore.",
		taxMultiplier = 1.05,
		developmentCostMultiplier = 1.0,
		color = { 176, 178, 150 },
	},
	{
		id = "island",
		name = "Island",
		description = "Wind-battered isles. Everything must come by ship.",
		taxMultiplier = 0.9,
		developmentCostMultiplier = 1.2,
		color = { 132, 140, 146 },
	},
	{
		id = "desert",
		name = "Desert",
		description = "Sand and scrub, settled only along rivers and coasts.",
		taxMultiplier = 0.8,
		developmentCostMultiplier = 1.2,
		color = { 214, 178, 120 },
	},
}

return definitions
