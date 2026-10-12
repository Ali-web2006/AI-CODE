--!strict
-- Geographic regions. Cultural, climatic and legal characteristics attach here in later phases.
-- Military (GameConfig.Military, MilitaryRules): manpower multiplies the levies of every province
-- in the region (the Vale and the Reach are populous, the Crownlands are thin outside the city);
-- naval multiplies its ships (the Iron Islands have the greatest fleet in the realm).

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.RegionDefinition } = {
	{ id = "north", name = "The North", manpower = 1.35, naval = 1 },
	{ id = "iron_islands", name = "The Iron Islands", manpower = 1.0, naval = 10 },
	{ id = "riverlands", name = "The Riverlands", manpower = 1.05, naval = 1 },
	{ id = "vale", name = "The Vale of Arryn", manpower = 1.65, naval = 1 },
	{ id = "westerlands", name = "The Westerlands", manpower = 1.3, naval = 1.3 },
	{ id = "crownlands", name = "The Crownlands", manpower = 0.9, naval = 1.6 },
	{ id = "stormlands", name = "The Stormlands", manpower = 1.15, naval = 1 },
	{ id = "reach", name = "The Reach", manpower = 1.4, naval = 1.6 },
	{ id = "dorne", name = "Dorne", manpower = 1.15, naval = 1 },
}

return definitions
