--!strict
--[[
	Bookmark: "The Long Summer", 1 January 297 AC.

	A bookmark is a scenario: start date, which houses exist and who rules them, starting
	treasuries, province ownership and development, and baseline relations. It references content
	(houses, provinces, characters) only by stable id. The ContentValidator checks every reference
	when the server starts.

	Scope note: this prototype models ten houses as independent political actors on a 34-province
	map. Historically all of them owe fealty to the Iron Throne; the feudal hierarchy arrives in
	Phase 3. The bookmark is internally consistent rather than a complete historical reconstruction.

	Relations are symmetric baselines. Monthly drift pulls the current score back toward them.
]]

local GameTypes = require(script.Parent.Parent.Parent.Types.GameTypes)
local Characters = require(script.Parent.LongSummer297Characters)

local function setup(ownerHouseId: string, development: number): GameTypes.BookmarkProvinceSetup
	return { ownerHouseId = ownerHouseId, development = development }
end

local bookmark: GameTypes.BookmarkDefinition = {
	id = "long_summer_297",
	name = "The Long Summer",
	description = "Nine years of uneasy peace under King Robert. The Hand, Jon Arryn, holds the realm together; "
		.. "old grudges from the Rebellion and the Greyjoy uprising still smoulder.",
	startDate = { year = 297, month = 1, day = 1 },

	houses = {
		stark = { rulerId = "eddard_stark", treasury = 140 },
		lannister = { rulerId = "tywin_lannister", treasury = 320 },
		baratheon = { rulerId = "robert_baratheon", treasury = 110 },
		tyrell = { rulerId = "mace_tyrell", treasury = 230 },
		martell = { rulerId = "doran_martell", treasury = 170 },
		arryn = { rulerId = "jon_arryn", treasury = 160 },
		tully = { rulerId = "hoster_tully", treasury = 130 },
		greyjoy = { rulerId = "balon_greyjoy", treasury = 90 },
		frey = { rulerId = "walder_frey", treasury = 180 },
		bolton = { rulerId = "roose_bolton", treasury = 85 },
	},

	provinces = {
		-- The North
		winterfell = setup("stark", 4),
		wolfswood = setup("stark", 2),
		white_harbor = setup("stark", 5),
		barrowlands = setup("stark", 2),
		moat_cailin = setup("stark", 1),
		dreadfort = setup("bolton", 3),
		-- The Iron Islands
		harlaw = setup("greyjoy", 3),
		pyke = setup("greyjoy", 2),
		-- The Riverlands
		seagard = setup("tully", 3),
		riverrun = setup("tully", 4),
		harrenhal = setup("tully", 2),
		the_twins = setup("frey", 4),
		-- The Vale
		bloody_gate = setup("arryn", 2),
		the_eyrie = setup("arryn", 3),
		gulltown = setup("arryn", 5),
		-- The Westerlands
		golden_tooth = setup("lannister", 3),
		casterly_rock = setup("lannister", 6),
		lannisport = setup("lannister", 6),
		crakehall = setup("lannister", 3),
		-- The Crownlands
		duskendale = setup("baratheon", 3),
		dragonstone = setup("baratheon", 2),
		kings_landing = setup("baratheon", 7),
		-- The Stormlands
		bronzegate = setup("baratheon", 2),
		storms_end = setup("baratheon", 4),
		the_marches = setup("baratheon", 2),
		-- The Reach
		bitterbridge = setup("tyrell", 3),
		highgarden = setup("tyrell", 6),
		horn_hill = setup("tyrell", 3),
		oldtown = setup("tyrell", 7),
		the_arbor = setup("tyrell", 4),
		-- Dorne
		kingsgrave = setup("martell", 2),
		yronwood = setup("martell", 3),
		the_greenblood = setup("martell", 3),
		sunspear = setup("martell", 5),
	},

	relations = {
		{ a = "stark", b = "baratheon", value = 55, reason = "Robert and Eddard fought side by side in the Rebellion." },
		{ a = "stark", b = "tully", value = 45, reason = "Eddard Stark wed Catelyn Tully." },
		{ a = "stark", b = "arryn", value = 50, reason = "Jon Arryn fostered Eddard Stark at the Eyrie." },
		{ a = "arryn", b = "tully", value = 40, reason = "Jon Arryn wed Lysa Tully." },
		{ a = "arryn", b = "baratheon", value = 55, reason = "Jon Arryn fostered Robert and now serves as his Hand." },
		{ a = "baratheon", b = "lannister", value = 30, reason = "King Robert wed Cersei Lannister." },
		{ a = "baratheon", b = "tully", value = 20, reason = "Riverrun declared for Robert during the Rebellion." },
		{ a = "baratheon", b = "tyrell", value = -5, reason = "The Tyrells besieged Storm's End during the Rebellion." },
		{ a = "baratheon", b = "martell", value = -35, reason = "Dorne has not forgiven the deaths of Elia's children." },
		{ a = "baratheon", b = "frey", value = -5, reason = "Lord Walder held back his levies until the Rebellion was won." },
		{ a = "baratheon", b = "greyjoy", value = -50, reason = "Robert crushed the Greyjoy Rebellion." },
		{ a = "lannister", b = "martell", value = -70, reason = "Princess Elia was murdered during the Lannister sack of King's Landing." },
		{ a = "lannister", b = "stark", value = -10, reason = "Eddard Stark condemned the Kingslayer." },
		{ a = "lannister", b = "tully", value = -15, reason = "An old rivalry across the Golden Tooth." },
		{ a = "lannister", b = "greyjoy", value = -35, reason = "The ironborn burned the Lannister fleet at Lannisport." },
		{ a = "tyrell", b = "martell", value = -30, reason = "Centuries of border war across the Dornish Marches." },
		{ a = "greyjoy", b = "stark", value = -40, reason = "Theon Greyjoy is held at Winterfell as a ward after the Greyjoy Rebellion." },
		{ a = "greyjoy", b = "tully", value = -20, reason = "Ironborn raids along the Riverlands coast." },
		{ a = "frey", b = "tully", value = 5, reason = "The Freys came late to the Trident; Lord Hoster has not forgotten." },
		{ a = "frey", b = "stark", value = 10, reason = "The Freys hold the only crossing between the North and the South." },
		{ a = "bolton", b = "stark", value = 20, reason = "The Boltons have knelt to Winterfell for centuries, though old grudges linger." },
	},

	characters = Characters,
}

return bookmark
