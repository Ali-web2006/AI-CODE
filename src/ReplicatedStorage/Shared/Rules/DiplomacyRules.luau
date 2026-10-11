--!strict
--[[
	DiplomacyRules — pure formulas for house-level relations (docs/GAME_DESIGN.md §Diplomacy).

	House relations are symmetric: one record per unordered pair, addressed by a canonical key
	"<smallerId>|<largerId>". This keeps a single source of truth for treaties that will attach to
	the pair later (alliances, marriages, wars). Directional, personal opinion is a separate,
	future character-level system.
]]

local GameTypes = require(script.Parent.Parent.Types.GameTypes)
local TraitRules = require(script.Parent.TraitRules)

export type DiplomacyConfig = {
	MinRelation: number,
	MaxRelation: number,
	DriftPerMonth: number,
	ImproveRelations: {
		GoldCost: number,
		BaseGain: number,
		DiplomacyGainFactor: number,
		MinimumGain: number,
		CooldownMonths: number,
	},
	Tiers: { { id: string, label: string, min: number } },
}

export type BreakdownLine = {
	label: string,
	value: number,
}

export type CharacterLike = {
	givenName: string,
	skills: GameTypes.Skills,
	traits: { string },
}

local DiplomacyRules = {}

function DiplomacyRules.relationKey(houseA: string, houseB: string): string
	if houseA < houseB then
		return `{houseA}|{houseB}`
	end
	return `{houseB}|{houseA}`
end

function DiplomacyRules.clamp(score: number, config: DiplomacyConfig): number
	return math.clamp(score, config.MinRelation, config.MaxRelation)
end

function DiplomacyRules.tierFor(score: number, config: DiplomacyConfig): { id: string, label: string, min: number }
	for _, tier in config.Tiers do
		if score >= tier.min then
			return tier
		end
	end
	return config.Tiers[#config.Tiers]
end

-- Relation gained by one Improve Relations envoy, with an explanation of every component.
function DiplomacyRules.improveRelationsGain(
	actorRuler: CharacterLike?,
	targetRuler: CharacterLike?,
	config: DiplomacyConfig
): (number, { BreakdownLine })
	local settings = config.ImproveRelations
	local lines: { BreakdownLine } = { { label = "Envoy", value = settings.BaseGain } }
	local gain = settings.BaseGain

	if actorRuler then
		local diplomacyBonus = math.floor(actorRuler.skills.diplomacy * settings.DiplomacyGainFactor)
		gain += diplomacyBonus
		table.insert(lines, { label = `{actorRuler.givenName}'s Diplomacy ({actorRuler.skills.diplomacy})`, value = diplomacyBonus })
		local _, sources = TraitRules.sumModifier(actorRuler.traits, "relationsGainSent")
		for _, source in sources do
			gain += source.value
			table.insert(lines, { label = `Sender is {source.label}`, value = source.value })
		end
	end

	if targetRuler then
		local _, sources = TraitRules.sumModifier(targetRuler.traits, "relationsGainReceived")
		for _, source in sources do
			gain += source.value
			table.insert(lines, { label = `Recipient is {source.label}`, value = source.value })
		end
	end

	if gain < settings.MinimumGain then
		table.insert(lines, { label = "Minimum effect", value = settings.MinimumGain - gain })
		gain = settings.MinimumGain
	end
	return gain, lines
end

-- One month of drift toward the baseline; never overshoots.
function DiplomacyRules.drift(score: number, baseline: number, config: DiplomacyConfig): number
	if score > baseline then
		return math.max(baseline, score - config.DriftPerMonth)
	elseif score < baseline then
		return math.min(baseline, score + config.DriftPerMonth)
	end
	return score
end

return DiplomacyRules
