--!strict
--[[
	GameConfig — every tunable gameplay, simulation, network and persistence constant.

	Rules:
	  * Gameplay code must read constants from here instead of embedding literals.
	  * This module is replicated to clients (it lives in ReplicatedStorage). It must never contain
	    secrets. Clients may read it to explain formulas in tooltips; the server alone applies them.
	  * Formulas that use these constants live in Shared/Rules (pure) and are documented in
	    docs/GAME_DESIGN.md.
]]

local GameConfig = {}

-- Increment when the meaning of persisted campaign data changes (see CampaignSerializer).
-- 2: armies, the army id counter and province levy and garrison pools.
GameConfig.SchemaVersion = 2

GameConfig.DefaultBookmarkId = "long_summer_297"

--[[ Environment ----------------------------------------------------------------------------
	"auto": Studio runs as "development", live servers as "production".
	Development uses a separate DataStore name so test sessions can never overwrite production
	saves, enables the dev-only DebugAdvanceMonth command, and uses a fixed RNG seed.
]]
GameConfig.Environment = {
	Mode = "auto" :: "auto" | "development" | "production",
	DevelopmentSeed = 1337,
}

--[[ Clock -----------------------------------------------------------------------------------
	The campaign clock is server-authoritative. Real time accumulates on the server and is
	converted into whole in-game days. Monthly systems fire exactly once when a month ends.
	Speed 0 does not exist: pausing is a separate flag so resuming restores the previous speed.
]]
GameConfig.Clock = {
	-- Real seconds per in-game day for each speed level (index = speed).
	SecondsPerDay = { 0.40, 0.15, 0.05 },
	DefaultSpeed = 1,
	-- Upper bound on days simulated in one server step. Protects against a death spiral after a
	-- long server hitch: excess accumulated time is discarded (documented in ARCHITECTURE.md).
	MaxDaysPerStep = 10,
	-- Campaigns start paused so the player can orient themselves.
	StartPaused = true,
}

--[[ Economy ---------------------------------------------------------------------------------
	Monthly province income  = baseTax * (1 + DevelopmentIncomePerLevel * (development - 1))
	                           * terrain.taxMultiplier * holding.taxMultiplier
	House tax income         = sum(province income of controlled, unoccupied provinces)
	                           * (1 + rulerStewardship * StewardshipIncomeBonus + traitTaxBonus)
	Monthly expenses         = house.courtUpkeep * traitCourtMultiplier
	                           + sum(holding.garrisonUpkeep + AdministrationPerDevelopment * dev)
	Development cost (d->d+1) = DevelopmentCostBase * DevelopmentCostGrowth^(d-1)
	                           * terrain.developmentCostMultiplier, rounded to whole gold.
]]
GameConfig.Economy = {
	DevelopmentIncomePerLevel = 0.20,
	StewardshipIncomeBonus = 0.015,
	AdministrationPerDevelopment = 0.08,
	DevelopmentCostBase = 20,
	DevelopmentCostGrowth = 1.30,
	MinDevelopment = 1,
	MaxDevelopment = 10,
	-- Monthly ledger entries kept per house (ring buffer).
	LedgerLength = 12,
}

--[[ Diplomacy -------------------------------------------------------------------------------
	House relations are SYMMETRIC: one score per unordered pair of houses, representing the
	standing between the two houses as political entities. Directional, personal feelings belong
	to the future character-opinion system and are deliberately not stored here.

	Improve Relations gain = BaseGain + floor(actorRulerDiplomacy * DiplomacyGainFactor)
	                         + actor ruler trait "relationsGainSent" + target ruler trait
	                         "relationsGainReceived", never below MinimumGain.
	Relations drift toward their bookmark baseline by DriftPerMonth each month.
]]
GameConfig.Diplomacy = {
	MinRelation = -100,
	MaxRelation = 100,
	DriftPerMonth = 1,
	ImproveRelations = {
		GoldCost = 25,
		BaseGain = 8,
		DiplomacyGainFactor = 0.5,
		MinimumGain = 3,
		CooldownMonths = 6,
	},
	-- Ordered thresholds (score >= min) for display labels.
	Tiers = {
		{ id = "friendly", label = "Friendly", min = 50 },
		{ id = "cordial", label = "Cordial", min = 10 },
		{ id = "neutral", label = "Neutral", min = -9 },
		{ id = "cold", label = "Cold", min = -49 },
		{ id = "hostile", label = "Hostile", min = -100 },
	},
}

--[[ AI --------------------------------------------------------------------------------------
	AI rulers are evaluated on the monthly schedule, staggered across houses. Every decision is
	submitted through the same CommandProcessor as player requests.
]]
GameConfig.AI = {
	EvaluationIntervalMonths = 1,
	-- Hard cap on AI evaluations per month; scales the AI cost with world size.
	MaxEvaluationsPerMonth = 16,
	MaxActionsPerEvaluation = 1,
	-- Baseline personality; ruler traits add modifiers (TraitDefinitions.aiWeights).
	BasePersonality = {
		investment = 1.0, -- appetite for development spending
		diplomacy = 0.6, -- appetite for relation building
		reserveMonths = 4, -- months of expenses kept as a cash reserve
		actChance = 0.65, -- probability of acting at all during an evaluation
	},
	-- A development is considered only if it repays itself within this many months...
	MaxDevelopmentPaybackMonths = 90,
	-- ...unless the house could pay for it this many times over, in which case slower investments
	-- (up to MaxWealthyPaybackMonths) are acceptable to rulers with investment appetite >= 1.
	WealthyInvestmentMultiple = 6,
	MaxWealthyPaybackMonths = 360,
	-- AI only spends on relations with houses below this score.
	RelationsTargetThreshold = 25,
	-- AI never courts houses whose historical baseline is below this (blood feuds).
	GrudgeBaseline = -50,
	-- Minimum utility score an action needs before the AI commits gold to it.
	MinimumActionScore = 0.15,
}

--[[ Network & security ----------------------------------------------------------------------]]
GameConfig.Network = {
	-- Minimum seconds between replication flushes (deltas are batched in between).
	ReplicationInterval = 0.10,
	MaxCommandNameLength = 48,
	MaxIdLength = 48,
	MaxPayloadKeys = 8,
	-- Token bucket per player: burst capacity and refill per second.
	RateLimit = {
		Capacity = 8,
		RefillPerSecond = 3,
	},
	-- Commands that touch storage are additionally throttled per player (seconds): saving and
	-- loading, and (more lightly) reading the save slot summary, so no client can drain the
	-- server's DataStore request budget.
	PersistenceCooldownSeconds = 10,
	SaveInfoCooldownSeconds = 3,
	-- Repeated identical rejection diagnostics are logged at most once per window (seconds).
	DiagnosticThrottleSeconds = 5,
	-- Chronicle entries retained on the client.
	ClientEventLogLength = 60,
}

--[[ Sessions & multiplayer -------------------------------------------------------------------
	Clock policy "host": the campaign host (the longest-connected player; the role passes to the
	next longest-connected player when the host leaves) controls speed, unpausing, saving and
	loading. When AnyPlayerMayPause is true every player who leads a house may pause. When no
	connected player leads a house the clock pauses automatically.
]]
GameConfig.Sessions = {
	ClockPolicy = "host" :: "host",
	AnyPlayerMayPause = true,
	-- A disconnected player's house is reserved for them for this many seconds; meanwhile the
	-- AI governs it.
	ReconnectReservationSeconds = 300,
	AiGovernsDisconnectedHouses = true,
}

--[[ Persistence -------------------------------------------------------------------------------
	Phase 1 persists one campaign slot per host player. Backend "auto" uses DataStoreService when
	it is reachable and falls back to an in-memory store that is explicitly labelled as
	non-persistent in the UI.
]]
GameConfig.Persistence = {
	Backend = "auto" :: "auto" | "datastore" | "memory",
	ProductionDataStoreName = "IronThrone_Campaigns_v1",
	DevelopmentDataStoreName = "IronThrone_DEV_Campaigns_v1",
	SlotKeyPrefix = "host_",
	MaxAttempts = 3,
	BackoffSeconds = { 1, 2, 4 },
	AutosaveIntervalSeconds = 300,
	-- Roblox DataStore values must stay under 4 MB; refuse to write anything above this.
	MaxSerializedBytes = 3_500_000,
}

--[[ Military --------------------------------------------------------------------------------
	Every province musters levies (men who can be raised into armies) and keeps a garrison (men
	who never leave its walls). Unit stats and house compositions live in
	Data/Military/UnitDefinitions; the formulas are in Shared/Rules/MilitaryRules and
	MovementRules.

	Levy maximum        = (LevyBase + LevyPerDevelopment * development) * holding.levyMultiplier
	                      * terrain.manpower * region.manpower * levyMultiplier (buildings hook,
	                      MilitaryRules.poolModifiers: 1 today), rounded to LevyRounding men
	Garrison maximum    = (holding.garrisonBase + holding.garrisonPerDevelopment * development)
	                      * garrisonMultiplier + garrisonFlat (buildings hook: 1 and 0 today),
	                      rounded to GarrisonRounding men
	Ships               = round((terrain.shipsPerDevelopment + holding.shipsPerDevelopment)
	                      * development * region.naval), summed over a house's unoccupied provinces
	Monthly refill      = ceil(maximum * LevyReplenishPerMonth) levies (GarrisonReplenishPerMonth for
	                      garrisons), never above the maximum
	Raised levy units   = the levy split by the house composition (largest remainder, exact total)
	Army upkeep (gold)  = sum over units (men / 1000 * unit.upkeep) * UpkeepPerThousandPerMonth a
	                      month, accrued day by day and charged pro rata (days in the field / days
	                      in the month) in the monthly settlement
	Army speed          = men / sum over units (men / unit.speed): the head-count-weighted
	                      harmonic mean, the pace of the army's average man
	Land leg (days)     = ceil(max(1, distance / MarchUnitsPerDay * ConnectionCost[kind]
	                      * destination terrain.movementCost / army speed))
	Sea leg (days)      = ceil(max(1, distance / SailUnitsPerDay)) (no terrain, no unit speed)
	Ships needed        = ceil(men / ShipCapacity)
	Starting morale     = MoraleBase + head-count-weighted unit morale bonus, within [0, MoraleMax]
	Strength (display)  = sum(men * (attack + defense) / 2) / 1000
	                      * (1 + StrengthPerMartial * (commander martial - CommanderMartialBaseline))
	Every SupplyTickDays days: at home supply += SupplyGainHome and morale += MoraleRecoveryHome;
	in hostile country supply -= ceil(SupplyLossForeign * terrain.supplyDrain); at zero supply the
	army loses ceil(men * AttritionStarving) men and MoraleLossStarving morale.
]]
GameConfig.Military = {
	LevyBase = 1200,
	LevyPerDevelopment = 1700,
	LevyRounding = 50,
	GarrisonRounding = 10,
	-- Share of the maximum refilled per month.
	LevyReplenishPerMonth = 0.08,
	GarrisonReplenishPerMonth = 0.15,
	-- Smallest army that can be raised or split off.
	MinArmySize = 100,
	MaxArmiesPerHouse = 12,
	-- Gold per 1,000 raised men per month, times the unit's upkeep factor.
	UpkeepPerThousandPerMonth = 1.5,
	-- Map units per day for speed-1.0 troops.
	MarchUnitsPerDay = 12,
	-- Multiplier on travel days per connection kind. Sea legs are timed by SailUnitsPerDay alone;
	-- the sea entry only keeps the table complete.
	ConnectionCost = { road = 0.8, river = 1.0, pass = 1.6, wild = 1.5, sea = 1.0 },
	-- Map units per day at sea; sea legs ignore terrain and unit speed.
	SailUnitsPerDay = 30,
	-- Men carried per ship.
	ShipCapacity = 100,
	-- Youngest age at which a character may command an army.
	MinCommanderAge = 16,
	-- Commander martial at which the strength rating is unmodified, and the change per point.
	CommanderMartialBaseline = 10,
	StrengthPerMartial = 0.02,
	-- Supply, morale and attrition are processed every this many days.
	SupplyTickDays = 5,
	SupplyMax = 100,
	SupplyGainHome = 20,
	SupplyLossForeign = 8,
	MoraleMax = 100,
	MoraleBase = 60,
	MoraleRecoveryHome = 2,
	MoraleLossStarving = 5,
	-- Share of men lost per supply tick at zero supply.
	AttritionStarving = 0.03,
}

GameConfig.Debug = {
	-- Print the monthly ledger of every house to the server output.
	LogMonthlyLedger = false,
	-- Print every AI decision.
	LogAIDecisions = false,
}

-- Deep-freeze so no system can mutate shared configuration at runtime. Tests that need different
-- values build a modified copy with TableUtil.deepCopy and pass it to Simulation.new.
local function deepFreeze(t: { [any]: any })
	for _, value in t do
		if type(value) == "table" and not table.isfrozen(value) then
			deepFreeze(value)
		end
	end
	table.freeze(t)
end

deepFreeze(GameConfig :: any)

return GameConfig
