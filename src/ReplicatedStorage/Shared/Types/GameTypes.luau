--!strict
--[[
	GameTypes — the typed schema of content definitions, authoritative campaign state, commands,
	events and client views.

	Entity separation (see docs/ARCHITECTURE.md):
	  * Content definitions are immutable identity/geography loaded from Shared/Data.
	  * Campaign state is everything that can change during play. It is plain, serializable data
	    keyed by stable string IDs and never stores Instance references.
	  * Characters live entirely in campaign state, because future phases create and kill them.
	  * Session state (which player controls which house) is NOT part of campaign state.
]]

export type Date = {
	year: number,
	month: number,
	day: number,
}

export type RGB = { number } -- { r, g, b } in 0..255

export type ConnectionKind = "road" | "river" | "sea" | "pass" | "wild"

-- Content definitions -----------------------------------------------------------------------

export type TerrainDefinition = {
	id: string,
	name: string,
	description: string,
	taxMultiplier: number,
	developmentCostMultiplier: number,
	-- Multiplier on the days an army needs to march INTO a province of this terrain.
	movementCost: number,
	-- Multiplier on the levies a province of this terrain can raise.
	manpower: number,
	-- Ships a province of this terrain adds per development level (before the region's naval factor).
	shipsPerDevelopment: number,
	-- Multiplier on the supply an army loses while foraging in hostile country of this terrain.
	supplyDrain: number,
	color: RGB,
}

export type HoldingKindDefinition = {
	id: string,
	name: string,
	description: string,
	taxMultiplier: number,
	garrisonUpkeep: number,
	-- Multiplier on the levies the holding can raise (fortresses and cities raise fewer men).
	levyMultiplier: number,
	-- Garrison maximum = garrisonBase + garrisonPerDevelopment * development.
	garrisonBase: number,
	garrisonPerDevelopment: number,
	-- Ships the holding adds per development level (before the region's naval factor).
	shipsPerDevelopment: number,
	-- Map marker shape drawn with plain frames (no art assets required).
	marker: "square" | "diamond" | "circle" | "ring",
}

export type RegionDefinition = {
	id: string,
	name: string,
	-- Multiplier on the levies of every province in the region.
	manpower: number,
	-- Multiplier on the ships of every province in the region (the Iron Islands live on the sea).
	naval: number,
}

export type ProvinceDefinition = {
	id: string,
	name: string,
	regionId: string,
	terrainId: string,
	holding: {
		kind: string,
		name: string,
		description: string?,
	},
	position: { x: number, y: number },
	baseTax: number,
	adjacent: { [string]: ConnectionKind },
}

export type HeraldryDivision = "plain" | "chief" | "pale" | "fess" | "quarterly" | "bordure"

export type Heraldry = {
	field: RGB,
	charge: RGB,
	division: HeraldryDivision,
	monogram: string,
}

export type HouseDefinition = {
	id: string,
	name: string,
	-- Family name used for member display names ("Eddard Stark").
	surname: string,
	tier: "great" | "minor",
	seatName: string,
	words: string,
	regionId: string,
	description: string,
	mapColor: RGB,
	heraldry: Heraldry,
	courtUpkeep: number,
	playable: boolean,
}

export type TraitModifiers = {
	taxIncome: number?,
	courtUpkeep: number?,
	relationsGainSent: number?,
	relationsGainReceived: number?,
}

export type AIWeights = {
	investment: number?,
	diplomacy: number?,
	reserveMonths: number?,
	actChance: number?,
}

export type TraitDefinition = {
	id: string,
	name: string,
	description: string,
	modifiers: TraitModifiers?,
	aiWeights: AIWeights?,
}

export type NamedDefinition = {
	id: string,
	name: string,
	description: string?,
}

export type CultureDefinition = {
	id: string,
	name: string,
	-- Surname given to acknowledged natural children of this culture ("Snow", "Sand", ...).
	bastardSurname: string,
}

export type Skills = {
	diplomacy: number,
	martial: number,
	stewardship: number,
	intrigue: number,
	learning: number,
	prowess: number,
}

export type CharacterDefinition = {
	id: string,
	givenName: string,
	houseId: string,
	sex: "male" | "female",
	birthDate: Date,
	-- Present for characters who died before the bookmark (kept for family-tree coherence).
	deathDate: Date?,
	fatherId: string?,
	motherId: string?,
	spouseId: string?,
	cultureId: string,
	faithId: string,
	skills: Skills,
	traits: { string },
	epithet: string?,
	bastard: boolean?,
}

export type BookmarkHouseSetup = {
	rulerId: string,
	treasury: number,
}

export type BookmarkProvinceSetup = {
	ownerHouseId: string,
	development: number,
}

export type BookmarkRelation = {
	a: string,
	b: string,
	value: number,
	reason: string,
}

export type BookmarkDefinition = {
	id: string,
	name: string,
	description: string,
	startDate: Date,
	houses: { [string]: BookmarkHouseSetup },
	provinces: { [string]: BookmarkProvinceSetup },
	relations: { BookmarkRelation },
	characters: { CharacterDefinition },
}

-- The world map canvas in map units (presentation only; the drawing itself is Data/World/MapData).
export type MapDefinition = {
	width: number,
	height: number,
}

-- Military content (Data/Military/UnitDefinitions) -------------------------------------------

export type UnitClass = "spear" | "archer" | "cavalry" | "siege"

-- Special circumstances in which some units fight better (hooks for the raid, landing and river
-- crossing rules of later phases).
export type UnitSituation = "raid" | "landing" | "riverDefense"

export type UnitDefinition = {
	id: string,
	name: string,
	class: UnitClass,
	description: string,
	attack: number,
	defense: number,
	-- Morale bonus (0..30) added to the army's starting morale, weighted by head count.
	morale: number,
	-- Movement multiplier: 1 = men on foot. An army moves at the speed of its slowest unit.
	speed: number,
	-- Gold upkeep factor: 1 = levy spearmen.
	upkeep: number,
	-- Damage to walls; 0 for everything but siege engines.
	siege: number,
	-- Set for the unique unit of a great house; only that house's composition may use it.
	houseId: string?,
	-- Combat multipliers on particular terrain (terrain id -> factor).
	terrain: { [string]: number }?,
	-- Combat multipliers in particular regions (region id -> factor), e.g. the snows of the North.
	regions: { [string]: number }?,
	-- Combat multipliers in particular situations (UnitSituation -> factor).
	situations: { [string]: number }?,
}

export type MilitaryDefinitions = {
	classes: { UnitClass },
	-- counters[attackerClass][targetClass] = damage multiplier; a missing entry means 1. "walls" is
	-- a pseudo-class used by sieges.
	counters: { [string]: { [string]: number } },
	units: { UnitDefinition },
	-- House id -> unit id -> share of every levy that house raises (shares sum to 1).
	compositions: { [string]: { [string]: number } },
	-- Used by houses without an entry in `compositions`.
	defaultComposition: { [string]: number },
}

-- Campaign state ----------------------------------------------------------------------------

export type LedgerEntry = {
	monthIndex: number,
	income: number,
	expenses: number,
	net: number,
	treasuryAfter: number,
}

export type HouseState = {
	id: string,
	treasury: number,
	rulerId: string,
	extinct: boolean,
	ledger: { LedgerEntry },
	ai: {
		nextEvaluationMonth: number,
	},
}

export type ProvinceState = {
	id: string,
	ownerHouseId: string,
	-- The military occupier. nil means the legal owner controls the province.
	occupierHouseId: string?,
	development: number,
	-- Men who can be raised into armies here (integer, 0..MilitaryRules.levyMax). Raising empties
	-- the pool; it refills monthly.
	levies: number,
	-- Men who hold the walls and never march (integer, 0..MilitaryRules.garrisonMax).
	garrisonTroops: number,
}

--[[
	An army in the field. Movement is stored as a route plus the day numbers of the current leg, so
	nothing changes between departure and arrival and clients interpolate the position themselves:
	  in transit  legStartDay and legEndDay set: marching from locationId to route[1]
	  waiting     both nil with a non-empty route: a sea leg is next and too few ships are free
	  idle        both nil with an empty route
]]
export type ArmyState = {
	id: string, -- "army_<serial>"
	houseId: string,
	-- Province the army was raised in; names it ("Army of <holding name>").
	originId: string,
	commanderId: string?,
	-- Where the army is; while in transit, the province it left.
	locationId: string,
	-- unitId -> men (integers > 0; never empty).
	units: { [string]: number },
	morale: number, -- integer 0..MoraleMax
	supply: number, -- integer 0..SupplyMax
	-- Remaining stops; route[1] is the next province. Empty when idle.
	route: { string },
	-- CalendarDate.toDayNumber when the current leg (locationId -> route[1]) began and ends.
	legStartDay: number?,
	legEndDay: number?,
	-- Merge into an idle army of the same house on arrival (armies answering a call to arms).
	gather: boolean,
	-- Supply has run out (set once, so the starvation event fires once).
	starving: boolean,
}

export type CharacterState = {
	id: string,
	givenName: string,
	houseId: string,
	sex: "male" | "female",
	birthDate: Date,
	deathDate: Date?,
	alive: boolean,
	fatherId: string?,
	motherId: string?,
	spouseId: string?,
	cultureId: string,
	faithId: string,
	skills: Skills,
	traits: { string },
	epithet: string?,
	bastard: boolean,
}

export type RelationState = {
	key: string,
	a: string, -- lexicographically smaller house id
	b: string,
	score: number,
	baseline: number,
	-- Per acting house: first month index at which Improve Relations may be used again.
	cooldowns: { [string]: number },
}

export type ClockState = {
	date: Date,
	speed: number,
	paused: boolean,
	lastProcessedMonthIndex: number,
}

export type CampaignState = {
	schemaVersion: number,
	campaignId: string,
	bookmarkId: string,
	seed: number,
	-- DeterministicRng state, advanced in place by every random simulation decision.
	rng: { state: number },
	clock: ClockState,
	houses: { [string]: HouseState },
	provinces: { [string]: ProvinceState },
	characters: { [string]: CharacterState },
	relations: { [string]: RelationState },
	armies: { [string]: ArmyState },
	-- Serial of the next army id ("army_<serial>"); only ever grows, so ids are never reused.
	nextArmySerial: number,
}

-- Commands & events -------------------------------------------------------------------------

export type Actor = {
	kind: "player" | "ai" | "system",
	houseId: string,
	userId: number?,
}

export type CommandResult = {
	ok: boolean,
	code: string,
	message: string,
	data: { [string]: any }?,
}

export type EventPriority = "low" | "normal" | "high"

export type GameEvent = {
	kind: string,
	priority: EventPriority,
	-- House ids that should receive this event; nil means every viewer.
	audience: { string }?,
	date: Date,
	data: { [string]: any },
}

-- Type-only module: requiring it yields an empty table; consumers use `GameTypes.X` in annotations.
return {}
