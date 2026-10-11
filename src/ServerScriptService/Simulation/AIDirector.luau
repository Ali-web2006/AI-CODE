--!strict
--[[
	AIDirector — monthly decision-making for houses not governed by a connected player.

	Scheduling: each house has ai.nextEvaluationMonth. At most AI.MaxEvaluationsPerMonth houses are
	evaluated per month, starting from a rotating offset so no house is permanently starved. The
	cost of the AI therefore scales with a configurable budget, not with world size.

	Decision: an evaluation builds a list of candidate actions, scores each one from the ruler's
	personality (base personality + trait aiWeights), discards anything that would breach the
	house's cash reserve, and submits the best candidate through CommandProcessor.submit — the
	same validated path players use. Phase 1 behaviours: invest in development, improve relations.
	New behaviours are added as further candidate generators.

	Randomness comes only from the campaign's DeterministicRng, so a given seed always reproduces
	the same AI choices.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DeterministicRng = require(ReplicatedStorage.Shared.Util.DeterministicRng)
local EconomyRules = require(ReplicatedStorage.Shared.Rules.EconomyRules)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local TraitRules = require(ReplicatedStorage.Shared.Rules.TraitRules)
local CampaignState = require(script.Parent.CampaignState)
local CommandProcessor = require(script.Parent.CommandProcessor)
local Diplomacy = require(script.Parent.Diplomacy)
local Economy = require(script.Parent.Economy)
local SimContext = require(script.Parent.SimContext)

type SimContext = SimContext.SimContext

export type Personality = {
	investment: number,
	diplomacy: number,
	reserveMonths: number,
	actChance: number,
}

export type Candidate = {
	command: string,
	payload: { [string]: any },
	score: number,
	cost: number,
	reason: string,
}

local AIDirector = {}

function AIDirector.personality(sim: SimContext, houseId: string): Personality
	local base = sim.config.AI.BasePersonality
	local ruler = CampaignState.ruler(sim.state, houseId)
	local traits = ruler and ruler.traits
	return {
		investment = math.max(0, base.investment + TraitRules.sumAIWeight(traits, "investment")),
		diplomacy = math.max(0, base.diplomacy + TraitRules.sumAIWeight(traits, "diplomacy")),
		reserveMonths = math.max(0, base.reserveMonths + TraitRules.sumAIWeight(traits, "reserveMonths")),
		actChance = math.clamp(base.actChance + TraitRules.sumAIWeight(traits, "actChance"), 0, 1),
	}
end

local function developmentCandidates(sim: SimContext, houseId: string, personality: Personality, spendable: number): { Candidate }
	local candidates = {}
	local ai = sim.config.AI
	local ruler = CampaignState.ruler(sim.state, houseId)
	for _, province in CampaignState.ownedProvinces(sim.state, houseId) do
		local check = Economy.checkDevelop(sim, houseId, province.id)
		local cost = check.cost
		if check.ok and cost and cost <= spendable then
			local gain = EconomyRules.developmentNetGain(province.id, province.development, ruler, sim.config.Economy)
			if gain > 0 then
				local payback = cost / gain
				local wealthy = spendable >= cost * ai.WealthyInvestmentMultiple
				local limit = if wealthy then ai.MaxWealthyPaybackMonths else ai.MaxDevelopmentPaybackMonths
				if payback <= limit then
					-- Faster payback scores higher; 30 months of payback scores 1.0 at investment 1.
					local score = personality.investment * (30 / payback)
					if wealthy then
						-- Idle gold makes slow investments worthwhile, scaled by the ruler's appetite.
						score = math.max(score, ai.MinimumActionScore * personality.investment)
					end
					table.insert(candidates, {
						command = Protocol.Commands.DevelopProvince,
						payload = { provinceId = province.id },
						score = score,
						cost = cost,
						reason = `develop {province.id} (payback {math.floor(payback)} months)`,
					})
				end
			end
		end
	end
	return candidates
end

local function relationCandidates(sim: SimContext, houseId: string, personality: Personality, spendable: number): { Candidate }
	local candidates = {}
	local diplomacy = sim.config.Diplomacy
	local threshold = sim.config.AI.RelationsTargetThreshold
	local neighbours = CampaignState.neighbouringHouses(sim.state, houseId)
	for _, otherId in CampaignState.activeHouseIds(sim.state) do
		if otherId == houseId then
			continue
		end
		local relation = CampaignState.relation(sim.state, houseId, otherId)
		if not relation or relation.score >= threshold or relation.baseline < sim.config.AI.GrudgeBaseline then
			continue
		end
		local check = Diplomacy.checkImproveRelations(sim, houseId, otherId)
		local cost = check.cost
		if check.ok and cost and cost <= spendable then
			-- Neighbours matter far more than distant houses; worse relations matter more.
			local proximity = if neighbours[otherId] then 1.0 else 0.35
			local urgency = (threshold - relation.score) / (threshold - diplomacy.MinRelation)
			table.insert(candidates, {
				command = Protocol.Commands.ImproveRelations,
				payload = { targetHouseId = otherId },
				score = personality.diplomacy * proximity * urgency * 1.5,
				cost = cost,
				reason = `improve relations with {otherId} (score {relation.score})`,
			})
		end
	end
	return candidates
end

-- Builds and scores every candidate action for a house (exposed for tests and debugging).
function AIDirector.candidates(sim: SimContext, houseId: string): ({ Candidate }, Personality, number)
	local personality = AIDirector.personality(sim, houseId)
	local house = sim.state.houses[houseId]
	local budget = Economy.budgetFor(sim, houseId)
	local reserve = math.max(0, budget.expenses * personality.reserveMonths)
	local spendable = house.treasury - reserve

	local candidates = {}
	if spendable > 0 then
		for _, candidate in developmentCandidates(sim, houseId, personality, spendable) do
			table.insert(candidates, candidate)
		end
		for _, candidate in relationCandidates(sim, houseId, personality, spendable) do
			table.insert(candidates, candidate)
		end
	end
	-- Deterministic ordering: score descending, then command and payload as tie-breakers.
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.reason < b.reason
	end)
	return candidates, personality, spendable
end

function AIDirector.evaluateHouse(sim: SimContext, houseId: string)
	local personality = AIDirector.personality(sim, houseId)
	if not DeterministicRng.chance(sim.state.rng, personality.actChance) then
		return
	end
	local candidates = AIDirector.candidates(sim, houseId)
	local actions = 0
	for _, candidate in candidates do
		if actions >= sim.config.AI.MaxActionsPerEvaluation or candidate.score < sim.config.AI.MinimumActionScore then
			break
		end
		local result = CommandProcessor.submit(sim, { kind = "ai", houseId = houseId }, candidate.command, candidate.payload)
		if result.ok then
			actions += 1
			if sim.config.Debug.LogAIDecisions then
				sim.diagnostics:info("AI", `{houseId}: {candidate.reason} (score {string.format("%.2f", candidate.score)})`)
			end
		else
			-- Candidates are pre-validated, so a rejection here signals an AI logic error.
			sim.diagnostics:warn("AI", `{houseId}: {candidate.reason} was rejected ({result.code}): {result.message}`)
		end
	end
end

function AIDirector.processMonth(sim: SimContext, monthIndex: number)
	local houseIds = CampaignState.activeHouseIds(sim.state)
	local count = #houseIds
	if count == 0 then
		return
	end
	local interval = math.max(1, sim.config.AI.EvaluationIntervalMonths)
	local budget = sim.config.AI.MaxEvaluationsPerMonth
	local evaluations = 0
	local start = monthIndex % count
	for offset = 0, count - 1 do
		if evaluations >= budget then
			break
		end
		local houseId = houseIds[(start + offset) % count + 1]
		local house = sim.state.houses[houseId]
		if sim.isHumanControlled(houseId) or house.ai.nextEvaluationMonth > monthIndex then
			continue
		end
		evaluations += 1
		house.ai.nextEvaluationMonth = monthIndex + interval
		AIDirector.evaluateHouse(sim, houseId)
	end
end

return AIDirector
