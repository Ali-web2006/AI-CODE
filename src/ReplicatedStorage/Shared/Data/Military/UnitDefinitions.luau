--!strict
--[[
	Unit types and the levy compositions of the great houses: the ONE table that holds every
	military stat. Rules code reads it through Content.military / Content.units; nothing else
	embeds unit numbers.

	classes:      the unit classes. Counters work on classes, so a new unit only needs a class.
	counters:     counters[attackerClass][targetClass] = damage multiplier (a missing entry means 1).
	              "walls" is a pseudo-class used by sieges.
	units:        every unit type. attack and defence are per-man ratings; morale is a bonus (0..30)
	              to the army's starting morale weighted by head count; speed multiplies march speed
	              (1 = men on foot; an army moves at the pace of its slowest unit); upkeep is the gold
	              factor (1 = levy spearmen); siege is damage to walls. houseId marks the unique unit
	              of a great house. terrain, regions and situations are combat multipliers in
	              particular terrain, regions (the snows of the North) and situations ("raid",
	              "landing", "riverDefense").
	compositions: house id -> unit id -> share of every levy the house raises (shares sum to 1).
	              A house's unique unit may appear only in that house's composition.
	defaultComposition: used by houses without an entry (the minor houses).

	The ContentValidator checks all of this at startup.
]]

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

local definitions: GameTypes.MilitaryDefinitions = {
	classes = { "spear", "archer", "cavalry", "siege" },

	counters = {
		spear = { cavalry = 1.5 },
		cavalry = { archer = 1.5 },
		archer = { spear = 1.5 },
		siege = { walls = 4.0 },
	},

	units = {
		-- Common troops, raised by every house -----------------------------------------------
		{
			id = "levy_spearmen",
			name = "Levy spearmen",
			class = "spear",
			description = "Smallfolk called from the fields with spear and shield. Steady against horse, little else.",
			attack = 8,
			defense = 10,
			morale = 0,
			speed = 1.0,
			upkeep = 1.0,
			siege = 0,
		},
		{
			id = "archers",
			name = "Archers",
			class = "archer",
			description = "Bowmen and crossbowmen who thin the enemy ranks before the lines meet.",
			attack = 10,
			defense = 6,
			morale = 0,
			speed = 1.0,
			upkeep = 1.1,
			siege = 0,
		},
		{
			id = "light_cavalry",
			name = "Mounted knights",
			class = "cavalry",
			description = "Knights and outriders on horseback. Swift, and deadly to archers caught in the open.",
			attack = 14,
			defense = 9,
			morale = 5,
			speed = 1.35,
			upkeep = 2.0,
			siege = 0,
		},
		{
			id = "siege_engines",
			name = "Siege engines",
			class = "siege",
			description = "Trebuchets, rams and their crews. Slow and helpless in the field, but walls fall to them.",
			attack = 2,
			defense = 3,
			morale = 0,
			speed = 0.85,
			upkeep = 3.0,
			siege = 10,
		},

		-- Unique units of the great houses ---------------------------------------------------
		{
			id = "northern_clansmen",
			name = "Northern clansmen",
			class = "spear",
			description = "Hard men of the northern hills and wolfswoods, at home in forest, hill and snow.",
			attack = 11,
			defense = 11,
			morale = 10,
			speed = 1.05,
			upkeep = 1.0,
			siege = 0,
			houseId = "stark",
			terrain = { forest = 1.3, hills = 1.15 },
			regions = { north = 1.25 },
		},
		{
			id = "lannister_heavy_knights",
			name = "Lannister heavy knights",
			class = "cavalry",
			description = "Westerland knights in gilded plate on barded destriers, paid for with the gold of the Rock.",
			attack = 22,
			defense = 14,
			morale = 10,
			speed = 1.15,
			upkeep = 3.0,
			siege = 0,
			houseId = "lannister",
		},
		{
			id = "ironborn_reavers",
			name = "Ironborn reavers",
			class = "spear",
			description = "Raiders of the longships who pay the iron price. Fiercest when they come ashore.",
			attack = 15,
			defense = 8,
			morale = 15,
			speed = 1.1,
			upkeep = 1.2,
			siege = 0,
			houseId = "greyjoy",
			terrain = { coast = 1.2, island = 1.2 },
			situations = { raid = 1.4, landing = 1.4 },
		},
		{
			id = "reach_cavalry",
			name = "Reach cavalry",
			class = "cavalry",
			description = "The flower of the Reach's chivalry. Lightly armoured, but cheap and very numerous.",
			attack = 12,
			defense = 7,
			morale = 0,
			speed = 1.35,
			upkeep = 1.3,
			siege = 0,
			houseId = "tyrell",
		},
		{
			id = "dornish_spearmen",
			name = "Dornish spearmen",
			class = "spear",
			description = "Lightly armed spearmen of the sands, untiring in desert heat and mountain passes.",
			attack = 11,
			defense = 11,
			morale = 5,
			speed = 1.25,
			upkeep = 1.1,
			siege = 0,
			houseId = "martell",
			terrain = { desert = 1.35, mountains = 1.15 },
		},
		{
			id = "knights_of_the_vale",
			name = "Knights of the Vale",
			class = "cavalry",
			description = "The proud heavy horse of the Vale, said to be the finest knights in the realm.",
			attack = 24,
			defense = 18,
			morale = 15,
			speed = 1.15,
			upkeep = 3.5,
			siege = 0,
			houseId = "arryn",
		},
		{
			id = "river_archers",
			name = "River archers",
			class = "archer",
			description = "Longbowmen of the Riverlands who hold the fords and crossings against all comers.",
			attack = 12,
			defense = 7,
			morale = 5,
			speed = 1.0,
			upkeep = 1.2,
			siege = 0,
			houseId = "tully",
			situations = { riverDefense = 1.4 },
		},
		{
			id = "stormland_warhammers",
			name = "Stormland warhammers",
			class = "spear",
			description = "Stormlanders with hammer and axe in the fashion of their lords. Slow, but they hit hard.",
			attack = 18,
			defense = 9,
			morale = 10,
			speed = 0.95,
			upkeep = 1.8,
			siege = 0,
			houseId = "baratheon",
		},
	},

	-- Share of every raised levy, per house.
	compositions = {
		stark = { levy_spearmen = 0.35, archers = 0.15, light_cavalry = 0.10, northern_clansmen = 0.40 },
		lannister = {
			levy_spearmen = 0.40,
			archers = 0.20,
			light_cavalry = 0.10,
			lannister_heavy_knights = 0.25,
			siege_engines = 0.05,
		},
		greyjoy = { levy_spearmen = 0.25, archers = 0.15, ironborn_reavers = 0.60 },
		tyrell = { levy_spearmen = 0.35, archers = 0.20, reach_cavalry = 0.40, siege_engines = 0.05 },
		martell = { levy_spearmen = 0.20, archers = 0.25, light_cavalry = 0.10, dornish_spearmen = 0.45 },
		arryn = { levy_spearmen = 0.45, archers = 0.20, light_cavalry = 0.10, knights_of_the_vale = 0.25 },
		tully = { levy_spearmen = 0.45, archers = 0.10, light_cavalry = 0.15, river_archers = 0.30 },
		baratheon = {
			levy_spearmen = 0.35,
			archers = 0.20,
			light_cavalry = 0.15,
			stormland_warhammers = 0.25,
			siege_engines = 0.05,
		},
	},

	defaultComposition = { levy_spearmen = 0.60, archers = 0.25, light_cavalry = 0.15 },
}

return definitions
