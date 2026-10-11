--!strict
-- Geographic regions. Cultural, climatic and legal characteristics attach here in later phases.

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.RegionDefinition } = {
	{ id = "north", name = "The North" },
	{ id = "iron_islands", name = "The Iron Islands" },
	{ id = "riverlands", name = "The Riverlands" },
	{ id = "vale", name = "The Vale of Arryn" },
	{ id = "westerlands", name = "The Westerlands" },
	{ id = "crownlands", name = "The Crownlands" },
	{ id = "stormlands", name = "The Stormlands" },
	{ id = "reach", name = "The Reach" },
	{ id = "dorne", name = "Dorne" },
}

return definitions
