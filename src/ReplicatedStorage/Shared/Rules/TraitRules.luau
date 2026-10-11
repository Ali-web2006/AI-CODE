--!strict
--[[
	TraitRules — aggregates trait modifiers with their sources so every number shown to the player
	can be traced back to the trait that produced it.
]]

local Content = require(script.Parent.Parent.Data.Content)

export type ModifierSource = {
	traitId: string,
	label: string,
	value: number,
}

local TraitRules = {}

-- Sums one modifier field across a character's traits. Unknown trait ids contribute nothing
-- (the ContentValidator rejects them at startup, so this is defensive only).
function TraitRules.sumModifier(traitIds: { string }?, field: string): (number, { ModifierSource })
	local total = 0
	local sources: { ModifierSource } = {}
	if not traitIds then
		return total, sources
	end
	for _, traitId in traitIds do
		local trait = Content.traits[traitId]
		local modifiers = trait and trait.modifiers
		local value = modifiers and (modifiers :: any)[field]
		if type(value) == "number" and value ~= 0 then
			total += value
			table.insert(sources, { traitId = traitId, label = trait.name, value = value })
		end
	end
	return total, sources
end

-- Sums one AI weight field across a character's traits.
function TraitRules.sumAIWeight(traitIds: { string }?, field: string): number
	local total = 0
	if not traitIds then
		return total
	end
	for _, traitId in traitIds do
		local trait = Content.traits[traitId]
		local weights = trait and trait.aiWeights
		local value = weights and (weights :: any)[field]
		if type(value) == "number" then
			total += value
		end
	end
	return total
end

return TraitRules
