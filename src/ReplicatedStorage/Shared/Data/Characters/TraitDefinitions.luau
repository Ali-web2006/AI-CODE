--!strict
--[[
	Character traits. Phase 1 uses two kinds of effect, both explained in tooltips:

	modifiers (applied by the economy and diplomacy rules):
	  taxIncome              additive bonus to the house tax multiplier (0.05 = +5%)
	  courtUpkeep            additive change to the court upkeep multiplier (0.35 = +35%)
	  relationsGainSent      flat change to relations gained when this ruler sends an envoy
	  relationsGainReceived  flat change to relations gained when this ruler receives an envoy

	aiWeights (added to the AI base personality when this character rules an AI house):
	  investment, diplomacy, reserveMonths, actChance

	Traits without modifiers are descriptive in Phase 1; the character phase adds health,
	opinion and stress effects.
]]

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: { GameTypes.TraitDefinition } = {
	{
		id = "honest",
		name = "Honest",
		description = "Speaks plainly and keeps their word. Envoys are trusted.",
		modifiers = { relationsGainSent = 2 },
		aiWeights = { diplomacy = 0.1 },
	},
	{
		id = "just",
		name = "Just",
		description = "Rules by law and custom. Fair administration yields steady revenue.",
		modifiers = { taxIncome = 0.05 },
	},
	{
		id = "patient",
		name = "Patient",
		description = "Waits for the right moment. Keeps larger reserves and acts less often.",
		aiWeights = { reserveMonths = 2, actChance = -0.1 },
	},
	{
		id = "diligent",
		name = "Diligent",
		description = "Works tirelessly at the business of ruling.",
		modifiers = { taxIncome = 0.05 },
		aiWeights = { investment = 0.2 },
	},
	{
		id = "ambitious",
		name = "Ambitious",
		description = "Hungers for more and is willing to spend to get it.",
		aiWeights = { investment = 0.3, actChance = 0.15 },
	},
	{
		id = "proud",
		name = "Proud",
		description = "Will not stoop. Neither gives nor accepts courtesies graciously.",
		modifiers = { relationsGainSent = -2, relationsGainReceived = -2 },
	},
	{
		id = "wrathful",
		name = "Wrathful",
		description = "Quick to anger and slow to forgive.",
		modifiers = { relationsGainSent = -2 },
		aiWeights = { diplomacy = -0.2 },
	},
	{
		id = "brave",
		name = "Brave",
		description = "Fearless, sometimes recklessly so.",
		aiWeights = { actChance = 0.1 },
	},
	{
		id = "gregarious",
		name = "Gregarious",
		description = "Charming company who makes friends easily.",
		modifiers = { relationsGainSent = 3 },
		aiWeights = { diplomacy = 0.3 },
	},
	{
		id = "shy",
		name = "Shy",
		description = "Uncomfortable at court and in negotiation.",
		modifiers = { relationsGainSent = -2 },
		aiWeights = { diplomacy = -0.2 },
	},
	{
		id = "deceitful",
		name = "Deceitful",
		description = "A practised liar. Envoys are received with suspicion.",
		modifiers = { relationsGainSent = -1 },
		aiWeights = { diplomacy = 0.1 },
	},
	{
		id = "greedy",
		name = "Greedy",
		description = "Squeezes every coin from the land and parts with none.",
		modifiers = { taxIncome = 0.1, courtUpkeep = -0.1 },
		aiWeights = { reserveMonths = 3, investment = -0.1 },
	},
	{
		id = "profligate",
		name = "Profligate",
		description = "Feasts, tourneys and hunts without end. The court costs far more than it should.",
		modifiers = { courtUpkeep = 0.35 },
		aiWeights = { reserveMonths = -2 },
	},
	{
		id = "cruel",
		name = "Cruel",
		description = "Takes pleasure in the suffering of others. Feared, never trusted.",
		modifiers = { relationsGainSent = -3 },
	},
	{
		id = "content",
		name = "Content",
		description = "Satisfied with what they have.",
		aiWeights = { investment = -0.2, actChance = -0.15 },
	},
	{
		id = "frail",
		name = "Frail",
		description = "In poor health. (Health and mortality arrive with the character phase.)",
	},
}

return definitions
