--!strict
--[[
	Seed characters for "The Long Summer" (297 AC).

	Each entry uses the `character` helper below:
	  skills order: { diplomacy, martial, stewardship, intrigue, learning, prowess }
	  extra fields: father, mother, spouse, died = { y, m, d }, epithet, bastard

	houseId is the house a character belongs to by birth. Phase 1 lists spouses who married in from
	houses outside the map (Olenna, Joanna) under the house they married into; the character phase
	introduces separate dynasty and birth-house fields.
	Spouse links must be symmetric; the ContentValidator enforces this along with parent ages.
]]

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)

type Extra = {
	father: string?,
	mother: string?,
	spouse: string?,
	died: { number }?,
	epithet: string?,
	bastard: boolean?,
}

local function character(
	id: string,
	givenName: string,
	houseId: string,
	sex: "male" | "female",
	born: { number },
	cultureId: string,
	faithId: string,
	skills: { number },
	traits: { string },
	extra: Extra?
): GameTypes.CharacterDefinition
	local e: Extra = extra or {}
	local died = e.died
	return {
		id = id,
		givenName = givenName,
		houseId = houseId,
		sex = sex,
		birthDate = { year = born[1], month = born[2], day = born[3] },
		deathDate = if died then { year = died[1], month = died[2], day = died[3] } else nil,
		fatherId = e.father,
		motherId = e.mother,
		spouseId = e.spouse,
		cultureId = cultureId,
		faithId = faithId,
		skills = {
			diplomacy = skills[1],
			martial = skills[2],
			stewardship = skills[3],
			intrigue = skills[4],
			learning = skills[5],
			prowess = skills[6],
		},
		traits = traits,
		epithet = e.epithet,
		bastard = e.bastard,
	}
end

local M, F = "male" :: "male", "female" :: "female"

local characters: { GameTypes.CharacterDefinition } = {
	-- House Stark ---------------------------------------------------------------------------
	character("rickard_stark", "Rickard", "stark", M, { 230, 6, 1 }, "northman", "old_gods", { 9, 10, 8, 6, 7, 9 }, { "proud", "ambitious" }, { died = { 282, 3, 10 } }),
	character("eddard_stark", "Eddard", "stark", M, { 263, 4, 14 }, "northman", "old_gods", { 8, 13, 7, 3, 7, 12 }, { "honest", "just", "patient" }, { father = "rickard_stark", spouse = "catelyn_tully", epithet = "the Quiet Wolf" }),
	character("benjen_stark", "Benjen", "stark", M, { 267, 2, 2 }, "northman", "old_gods", { 6, 11, 5, 6, 7, 12 }, { "brave", "just" }, { father = "rickard_stark" }),
	character("robb_stark", "Robb", "stark", M, { 283, 2, 10 }, "northman", "old_gods", { 6, 9, 6, 3, 5, 10 }, { "brave", "honest" }, { father = "eddard_stark", mother = "catelyn_tully" }),
	character("jon_snow", "Jon", "stark", M, { 283, 1, 20 }, "northman", "old_gods", { 5, 10, 4, 3, 6, 11 }, { "brave", "shy" }, { father = "eddard_stark", bastard = true }),
	character("sansa_stark", "Sansa", "stark", F, { 286, 7, 12 }, "northman", "the_seven", { 7, 1, 4, 3, 6, 1 }, { "gregarious" }, { father = "eddard_stark", mother = "catelyn_tully" }),
	character("arya_stark", "Arya", "stark", F, { 289, 3, 3 }, "northman", "old_gods", { 3, 4, 2, 5, 4, 5 }, { "brave", "wrathful" }, { father = "eddard_stark", mother = "catelyn_tully" }),
	character("bran_stark", "Brandon", "stark", M, { 290, 5, 21 }, "northman", "old_gods", { 4, 3, 3, 2, 7, 3 }, { "brave" }, { father = "eddard_stark", mother = "catelyn_tully", epithet = "Bran" }),
	character("rickon_stark", "Rickon", "stark", M, { 295, 8, 10 }, "northman", "old_gods", { 1, 1, 0, 0, 0, 1 }, { "wrathful" }, { father = "eddard_stark", mother = "catelyn_tully" }),

	-- House Lannister -----------------------------------------------------------------------
	character("tywin_lannister", "Tywin", "lannister", M, { 242, 2, 20 }, "westerman", "the_seven", { 12, 15, 18, 14, 12, 8 }, { "proud", "ambitious", "diligent" }, { spouse = "joanna_lannister" }),
	character("joanna_lannister", "Joanna", "lannister", F, { 245, 9, 1 }, "westerman", "the_seven", { 11, 2, 9, 8, 8, 1 }, { "gregarious" }, { spouse = "tywin_lannister", died = { 273, 11, 15 } }),
	character("kevan_lannister", "Kevan", "lannister", M, { 244, 3, 3 }, "westerman", "the_seven", { 9, 12, 13, 6, 9, 9 }, { "diligent", "patient" }),
	character("cersei_lannister", "Cersei", "lannister", F, { 266, 10, 1 }, "westerman", "the_seven", { 9, 3, 6, 14, 7, 2 }, { "ambitious", "proud", "deceitful" }, { father = "tywin_lannister", mother = "joanna_lannister", spouse = "robert_baratheon" }),
	character("jaime_lannister", "Jaime", "lannister", M, { 266, 10, 1 }, "westerman", "the_seven", { 7, 16, 4, 5, 6, 19 }, { "brave", "proud" }, { father = "tywin_lannister", mother = "joanna_lannister", epithet = "the Kingslayer" }),
	character("tyrion_lannister", "Tyrion", "lannister", M, { 273, 11, 15 }, "westerman", "the_seven", { 13, 6, 15, 15, 17, 2 }, { "gregarious", "ambitious" }, { father = "tywin_lannister", mother = "joanna_lannister", epithet = "the Imp" }),

	-- House Baratheon -----------------------------------------------------------------------
	character("steffon_baratheon", "Steffon", "baratheon", M, { 246, 1, 1 }, "stormlander", "the_seven", { 10, 10, 9, 5, 8, 10 }, { "honest", "brave" }, { died = { 278, 7, 1 } }),
	character("robert_baratheon", "Robert", "baratheon", M, { 262, 3, 25 }, "stormlander", "the_seven", { 11, 16, 3, 4, 5, 17 }, { "profligate", "brave", "wrathful", "gregarious" }, { father = "steffon_baratheon", spouse = "cersei_lannister", epithet = "the Usurper" }),
	character("stannis_baratheon", "Stannis", "baratheon", M, { 264, 9, 12 }, "stormlander", "the_seven", { 5, 15, 10, 6, 9, 10 }, { "just", "diligent" }, { father = "steffon_baratheon" }),
	character("renly_baratheon", "Renly", "baratheon", M, { 277, 12, 12 }, "stormlander", "the_seven", { 14, 7, 8, 6, 8, 9 }, { "gregarious", "ambitious" }, { father = "steffon_baratheon" }),
	character("joffrey_baratheon", "Joffrey", "baratheon", M, { 286, 3, 1 }, "crownlander", "the_seven", { 3, 5, 2, 6, 3, 6 }, { "cruel", "wrathful", "proud" }, { father = "robert_baratheon", mother = "cersei_lannister" }),
	character("myrcella_baratheon", "Myrcella", "baratheon", F, { 290, 4, 4 }, "crownlander", "the_seven", { 8, 1, 3, 3, 6, 1 }, { "honest" }, { father = "robert_baratheon", mother = "cersei_lannister" }),
	character("tommen_baratheon", "Tommen", "baratheon", M, { 291, 6, 6 }, "crownlander", "the_seven", { 6, 2, 3, 2, 4, 2 }, { "content", "shy" }, { father = "robert_baratheon", mother = "cersei_lannister" }),

	-- House Tyrell --------------------------------------------------------------------------
	character("olenna_tyrell", "Olenna", "tyrell", F, { 230, 2, 2 }, "reachman", "the_seven", { 15, 3, 12, 18, 14, 1 }, { "deceitful", "patient" }, { epithet = "the Queen of Thorns" }),
	character("mace_tyrell", "Mace", "tyrell", M, { 256, 7, 7 }, "reachman", "the_seven", { 7, 6, 9, 4, 5, 7 }, { "ambitious", "gregarious" }, { mother = "olenna_tyrell" }),
	character("willas_tyrell", "Willas", "tyrell", M, { 276, 1, 1 }, "reachman", "the_seven", { 10, 2, 12, 6, 13, 2 }, { "diligent", "honest", "frail" }, { father = "mace_tyrell" }),
	character("garlan_tyrell", "Garlan", "tyrell", M, { 278, 5, 5 }, "reachman", "the_seven", { 9, 13, 7, 5, 7, 14 }, { "brave", "just" }, { father = "mace_tyrell", epithet = "the Gallant" }),
	character("loras_tyrell", "Loras", "tyrell", M, { 282, 4, 4 }, "reachman", "the_seven", { 6, 11, 3, 3, 5, 16 }, { "brave", "proud" }, { father = "mace_tyrell", epithet = "the Knight of Flowers" }),
	character("margaery_tyrell", "Margaery", "tyrell", F, { 283, 8, 8 }, "reachman", "the_seven", { 15, 2, 8, 13, 9, 1 }, { "gregarious", "ambitious" }, { father = "mace_tyrell" }),

	-- House Martell -------------------------------------------------------------------------
	character("doran_martell", "Doran", "martell", M, { 247, 1, 15 }, "dornish", "the_seven", { 14, 6, 12, 16, 13, 3 }, { "patient", "deceitful", "frail" }),
	character("elia_martell", "Elia", "martell", F, { 255, 5, 5 }, "dornish", "the_seven", { 12, 1, 7, 5, 9, 1 }, { "gregarious", "frail" }, { died = { 283, 6, 15 } }),
	character("oberyn_martell", "Oberyn", "martell", M, { 257, 6, 6 }, "dornish", "the_seven", { 11, 14, 6, 12, 15, 17 }, { "wrathful", "brave" }, { epithet = "the Red Viper" }),
	character("arianne_martell", "Arianne", "martell", F, { 276, 2, 2 }, "dornish", "the_seven", { 13, 4, 8, 12, 9, 4 }, { "ambitious", "gregarious" }, { father = "doran_martell" }),
	character("quentyn_martell", "Quentyn", "martell", M, { 281, 3, 3 }, "dornish", "the_seven", { 8, 6, 9, 4, 8, 7 }, { "diligent", "shy" }, { father = "doran_martell" }),
	character("trystane_martell", "Trystane", "martell", M, { 286, 9, 9 }, "dornish", "the_seven", { 7, 5, 4, 3, 5, 6 }, { "honest" }, { father = "doran_martell" }),

	-- House Tully ---------------------------------------------------------------------------
	character("hoster_tully", "Hoster", "tully", M, { 238, 11, 11 }, "riverlander", "the_seven", { 10, 11, 9, 7, 7, 6 }, { "proud", "frail" }),
	character("brynden_tully", "Brynden", "tully", M, { 245, 1, 1 }, "riverlander", "the_seven", { 9, 17, 7, 8, 8, 15 }, { "brave", "honest" }, { epithet = "the Blackfish" }),
	character("catelyn_tully", "Catelyn", "tully", F, { 264, 6, 5 }, "riverlander", "the_seven", { 10, 3, 9, 6, 8, 2 }, { "honest", "proud" }, { father = "hoster_tully", spouse = "eddard_stark" }),
	character("lysa_tully", "Lysa", "tully", F, { 267, 3, 3 }, "riverlander", "the_seven", { 5, 2, 4, 9, 5, 1 }, { "wrathful", "deceitful" }, { father = "hoster_tully", spouse = "jon_arryn" }),
	character("edmure_tully", "Edmure", "tully", M, { 274, 4, 4 }, "riverlander", "the_seven", { 8, 8, 5, 3, 5, 10 }, { "gregarious", "brave" }, { father = "hoster_tully" }),

	-- House Arryn ---------------------------------------------------------------------------
	character("jon_arryn", "Jon", "arryn", M, { 217, 5, 5 }, "valeman", "the_seven", { 15, 9, 14, 8, 12, 4 }, { "just", "honest", "diligent" }, { spouse = "lysa_tully", epithet = "Hand of the King" }),
	character("robert_arryn", "Robert", "arryn", M, { 292, 9, 9 }, "valeman", "the_seven", { 1, 0, 1, 1, 2, 0 }, { "frail" }, { father = "jon_arryn", mother = "lysa_tully", epithet = "Sweetrobin" }),

	-- House Greyjoy -------------------------------------------------------------------------
	character("balon_greyjoy", "Balon", "greyjoy", M, { 248, 8, 8 }, "ironborn", "drowned_god", { 6, 14, 7, 9, 4, 13 }, { "ambitious", "proud", "wrathful" }),
	character("euron_greyjoy", "Euron", "greyjoy", M, { 255, 10, 10 }, "ironborn", "drowned_god", { 10, 15, 6, 16, 9, 15 }, { "deceitful", "ambitious", "cruel" }, { epithet = "Crow's Eye" }),
	character("victarion_greyjoy", "Victarion", "greyjoy", M, { 256, 11, 11 }, "ironborn", "drowned_god", { 4, 15, 5, 2, 3, 16 }, { "brave", "wrathful" }),
	character("asha_greyjoy", "Asha", "greyjoy", F, { 275, 3, 3 }, "ironborn", "drowned_god", { 9, 13, 8, 7, 7, 12 }, { "ambitious", "brave" }, { father = "balon_greyjoy" }),
	character("theon_greyjoy", "Theon", "greyjoy", M, { 280, 4, 4 }, "ironborn", "drowned_god", { 7, 9, 4, 6, 5, 10 }, { "proud" }, { father = "balon_greyjoy", epithet = "Ward of Winterfell" }),

	-- House Frey ----------------------------------------------------------------------------
	character("walder_frey", "Walder", "frey", M, { 208, 2, 2 }, "riverlander", "the_seven", { 10, 5, 14, 13, 8, 2 }, { "greedy", "deceitful" }, { epithet = "the Late Lord Frey" }),
	character("stevron_frey", "Stevron", "frey", M, { 232, 3, 3 }, "riverlander", "the_seven", { 7, 8, 10, 6, 8, 6 }, { "patient", "diligent" }, { father = "walder_frey" }),
	character("lothar_frey", "Lothar", "frey", M, { 259, 7, 7 }, "riverlander", "the_seven", { 11, 5, 11, 13, 9, 2 }, { "deceitful", "diligent" }, { father = "walder_frey", epithet = "Lame Lothar" }),
	character("walder_rivers", "Walder", "frey", M, { 263, 5, 5 }, "riverlander", "the_seven", { 6, 12, 5, 7, 5, 12 }, { "wrathful", "brave" }, { father = "walder_frey", bastard = true }),

	-- House Bolton --------------------------------------------------------------------------
	character("roose_bolton", "Roose", "bolton", M, { 252, 9, 9 }, "northman", "old_gods", { 9, 12, 10, 17, 9, 8 }, { "patient", "deceitful", "cruel" }),
	character("ramsay_snow", "Ramsay", "bolton", M, { 282, 2, 2 }, "northman", "old_gods", { 4, 11, 5, 9, 3, 13 }, { "cruel", "wrathful", "ambitious" }, { father = "roose_bolton", bastard = true }),
}

return characters
