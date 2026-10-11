--!strict
-- Faiths. Doctrine, piety and religious authority are later-phase systems.

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.NamedDefinition } = {
	{ id = "old_gods", name = "The Old Gods", description = "The nameless gods of the forest, worshipped before heart trees." },
	{ id = "the_seven", name = "The Faith of the Seven", description = "The Andal faith of the Seven Who Are One." },
	{ id = "drowned_god", name = "The Drowned God", description = "The harsh god of the ironborn, who dwells beneath the waves." },
}

return definitions
