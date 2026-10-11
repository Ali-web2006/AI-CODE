--!strict
--[[
	Diplomacy — authoritative house-relation operations.

	Phase 1 implements one action, Improve Relations (send an envoy with gifts), plus monthly drift
	of every relation toward its bookmark baseline. The check/apply split is the reusable pattern
	for future actions (alliances, marriages, treaties, war declarations): `check*` validates
	prerequisites and computes costs without side effects; `apply*` mutates state exactly once.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Content = require(ReplicatedStorage.Shared.Data.Content)
local DiplomacyRules = require(ReplicatedStorage.Shared.Rules.DiplomacyRules)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local CampaignState = require(script.Parent.CampaignState)
local SimContext = require(script.Parent.SimContext)

type SimContext = SimContext.SimContext

local Codes = Protocol.ResultCodes

local Diplomacy = {}

export type ImproveCheck = {
	ok: boolean,
	code: string,
	message: string,
	cost: number?,
	gain: number?,
}

function Diplomacy.checkImproveRelations(sim: SimContext, actorHouseId: string, targetHouseId: string): ImproveCheck
	local state = sim.state
	local settings = sim.config.Diplomacy.ImproveRelations
	local actor = state.houses[actorHouseId]
	if not actor or actor.extinct then
		return { ok = false, code = Codes.NotAuthorized, message = "Your house no longer exists." }
	end
	local target = state.houses[targetHouseId]
	if not target then
		return { ok = false, code = Codes.NotFound, message = "That house does not exist." }
	end
	if target.extinct then
		return { ok = false, code = Codes.InvalidTarget, message = "That house is extinct." }
	end
	if targetHouseId == actorHouseId then
		return { ok = false, code = Codes.InvalidTarget, message = "You cannot send an envoy to your own house." }
	end
	local relation = CampaignState.relation(state, actorHouseId, targetHouseId)
	if not relation then
		return { ok = false, code = Codes.InvalidTarget, message = "No diplomatic channel exists with that house." }
	end
	local targetName = Content.houses[targetHouseId].name
	if relation.score >= sim.config.Diplomacy.MaxRelation then
		return { ok = false, code = Codes.MaxRelation, message = `Relations with {targetName} cannot improve further.` }
	end
	local currentMonth = CampaignState.currentMonthIndex(state)
	local availableFrom = relation.cooldowns[actorHouseId]
	if availableFrom and currentMonth < availableFrom then
		local months = availableFrom - currentMonth
		return {
			ok = false,
			code = Codes.OnCooldown,
			message = `An envoy recently visited {targetName}. Another may be sent in {months} month{if months == 1 then "" else "s"}.`,
		}
	end
	local cost = settings.GoldCost
	if actor.treasury < cost then
		return {
			ok = false,
			code = Codes.InsufficientFunds,
			message = `An envoy costs {cost} gold; the treasury holds {string.format("%.1f", actor.treasury)}.`,
			cost = cost,
		}
	end
	local gain = DiplomacyRules.improveRelationsGain(
		CampaignState.ruler(state, actorHouseId),
		CampaignState.ruler(state, targetHouseId),
		sim.config.Diplomacy
	)
	return { ok = true, code = Codes.Ok, message = "", cost = cost, gain = gain }
end

function Diplomacy.applyImproveRelations(sim: SimContext, actorHouseId: string, targetHouseId: string): (boolean, ImproveCheck | { [string]: any })
	local check = Diplomacy.checkImproveRelations(sim, actorHouseId, targetHouseId)
	if not check.ok then
		return false, check
	end
	local state = sim.state
	local cost = check.cost :: number
	local gain = check.gain :: number
	local actor = state.houses[actorHouseId]
	local relation = CampaignState.relation(state, actorHouseId, targetHouseId) :: any

	local before = relation.score
	actor.treasury = EconomyRules.roundGold(actor.treasury - cost)
	relation.score = DiplomacyRules.clamp(before + gain, sim.config.Diplomacy)
	relation.cooldowns[actorHouseId] = CampaignState.currentMonthIndex(state)
		+ sim.config.Diplomacy.ImproveRelations.CooldownMonths

	sim.journal:markHouse(actorHouseId)
	sim.journal:markRelation(relation.key)
	SimContext.emitEvent(sim, "RelationsImproved", "normal", nil, {
		actorHouseId = actorHouseId,
		targetHouseId = targetHouseId,
		gain = relation.score - before,
		score = relation.score,
		cost = cost,
	})
	return true, {
		targetHouseId = targetHouseId,
		before = before,
		score = relation.score,
		gain = relation.score - before,
		cost = cost,
		treasury = actor.treasury,
		availableFromMonth = relation.cooldowns[actorHouseId],
	}
end

-- Monthly: every relation drifts toward its baseline; expired cooldowns are pruned.
function Diplomacy.processMonth(sim: SimContext, monthIndex: number)
	local state = sim.state
	local nextMonth = monthIndex + 1
	for key, relation in state.relations do
		local drifted = DiplomacyRules.drift(relation.score, relation.baseline, sim.config.Diplomacy)
		local changed = drifted ~= relation.score
		relation.score = drifted
		for houseId, availableFrom in relation.cooldowns do
			if availableFrom <= nextMonth then
				relation.cooldowns[houseId] = nil
				changed = true
			end
		end
		if changed then
			sim.journal:markRelation(key)
		end
	end
end

return Diplomacy
