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
	color: RGB,
}

export type HoldingKindDefinition = {
	id: string,
	name: string,
	description: string,
	taxMultiplier: number,
	garrisonUpkeep: number,
	-- Map marker shape drawn with plain frames (no art assets required).
	marker: "square" | "diamond" | "circle" | "ring",
}

export type RegionDefinition = {
	id: string,
	name: string,
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
