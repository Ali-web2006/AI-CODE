--!strict
-- Cultures. bastardSurname is the regional surname given to acknowledged natural children.

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.CultureDefinition } = {
	{ id = "northman", name = "Northman", bastardSurname = "Snow" },
	{ id = "ironborn", name = "Ironborn", bastardSurname = "Pyke" },
	{ id = "riverlander", name = "Riverlander", bastardSurname = "Rivers" },
	{ id = "valeman", name = "Valeman", bastardSurname = "Stone" },
	{ id = "westerman", name = "Westerman", bastardSurname = "Hill" },
	{ id = "crownlander", name = "Crownlander", bastardSurname = "Waters" },
	{ id = "stormlander", name = "Stormlander", bastardSurname = "Storm" },
	{ id = "reachman", name = "Reachman", bastardSurname = "Flowers" },
	{ id = "dornish", name = "Dornish", bastardSurname = "Sand" },
}

return definitions
