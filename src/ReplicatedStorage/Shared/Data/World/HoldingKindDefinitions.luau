--!strict
-- Holding kinds. A province's principal holding determines its tax multiplier and the garrison
-- upkeep its owner pays each month. Future phases add levies, fort levels and buildings.

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.HoldingKindDefinition } = {
	{
		id = "castle",
		name = "Castle",
		description = "A lord's seat. Balanced income and a standing garrison.",
		taxMultiplier = 1.0,
		garrisonUpkeep = 0.6,
		marker = "square",
	},
	{
		id = "fortress",
		name = "Fortress",
		description = "A military stronghold guarding a chokepoint. Costly to man, poor in trade.",
		taxMultiplier = 0.8,
		garrisonUpkeep = 0.9,
		marker = "diamond",
	},
	{
		id = "city",
		name = "City",
		description = "A great town of guilds and markets. High income, city watch instead of knights.",
		taxMultiplier = 1.2,
		garrisonUpkeep = 0.4,
		marker = "circle",
	},
	{
		id = "port",
		name = "Port",
		description = "A harbour town living on trade and fishing.",
		taxMultiplier = 1.15,
		garrisonUpkeep = 0.5,
		marker = "ring",
	},
}

return definitions
