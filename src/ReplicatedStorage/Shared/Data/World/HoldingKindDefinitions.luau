--!strict
-- Holding kinds. A province's principal holding determines its tax multiplier and the garrison
-- upkeep its owner pays each month. Future phases add fort levels and buildings.
-- Military (GameConfig.Military, MilitaryRules): levyMultiplier scales the levies the province can
-- raise (fortresses and cities raise fewer men); its garrison maximum is garrisonBase +
-- garrisonPerDevelopment * development (fortresses keep the largest); shipsPerDevelopment adds
-- ships per development level (ports).

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.HoldingKindDefinition } = {
	{
		id = "castle",
		name = "Castle",
		description = "A lord's seat. Balanced income and a standing garrison.",
		taxMultiplier = 1.0,
		garrisonUpkeep = 0.6,
		levyMultiplier = 1.0,
		garrisonBase = 500,
		garrisonPerDevelopment = 100,
		shipsPerDevelopment = 0,
		marker = "square",
	},
	{
		id = "fortress",
		name = "Fortress",
		description = "A military stronghold guarding a chokepoint. Costly to man, poor in trade.",
		taxMultiplier = 0.8,
		garrisonUpkeep = 0.9,
		levyMultiplier = 0.5,
		garrisonBase = 1500,
		garrisonPerDevelopment = 300,
		shipsPerDevelopment = 0,
		marker = "diamond",
	},
	{
		id = "city",
		name = "City",
		description = "A great town of guilds and markets. High income, city watch instead of knights.",
		taxMultiplier = 1.2,
		garrisonUpkeep = 0.4,
		levyMultiplier = 0.6,
		garrisonBase = 1200,
		garrisonPerDevelopment = 250,
		shipsPerDevelopment = 0,
		marker = "circle",
	},
	{
		id = "port",
		name = "Port",
		description = "A harbour town living on trade and fishing.",
		taxMultiplier = 1.15,
		garrisonUpkeep = 0.5,
		levyMultiplier = 0.8,
		garrisonBase = 600,
		garrisonPerDevelopment = 120,
		shipsPerDevelopment = 3,
		marker = "ring",
	},
}

return definitions
