--!strict
--[[
	ContentValidator — validates content definitions and a bookmark before a campaign starts.

	It works on raw definition lists (not lookup maps) so duplicate ids are detected. Every problem
	is reported with the entity and field at fault, e.g.
	  "province 'riverrun': adjacency to 'seagard' is not symmetric".
	The server refuses to start a campaign while errors exist; warnings are logged only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CalendarDate = require(ReplicatedStorage.Shared.Util.CalendarDate)
local GameTypes = require(ReplicatedStorage.Shared.Types.GameTypes)
local SimContext = require(script.Parent.SimContext)

export type ContentInput = {
	terrains: { GameTypes.TerrainDefinition },
	holdingKinds: { GameTypes.HoldingKindDefinition },
	regions: { GameTypes.RegionDefinition },
	provinces: { GameTypes.ProvinceDefinition },
	houses: { GameTypes.HouseDefinition },
	traits: { GameTypes.TraitDefinition },
	cultures: { GameTypes.CultureDefinition },
	faiths: { GameTypes.NamedDefinition },
	map: GameTypes.MapDefinition,
}

export type Report = {
	errors: { string },
	warnings: { string },
}

type ValidationConfig = SimContext.Config

local CONNECTION_KINDS = { road = true, river = true, sea = true, pass = true, wild = true }
local HERALDRY_DIVISIONS = { plain = true, chief = true, pale = true, fess = true, quarterly = true, bordure = true }
local TRAIT_MODIFIERS = { taxIncome = true, courtUpkeep = true, relationsGainSent = true, relationsGainReceived = true }
local AI_WEIGHTS = { investment = true, diplomacy = true, reserveMonths = true, actChance = true }
local MIN_PARENT_AGE = 12

local ContentValidator = {}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isValidRGB(value: any): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for _, channel in value do
		if not isFiniteNumber(channel) or channel < 0 or channel > 255 then
			return false
		end
	end
	return true
end

-- Indexes a list by id, reporting missing, malformed and duplicate ids.
local function indexList(report: Report, kind: string, list: { any }, maxIdLength: number): { [string]: any }
	local index = {}
	if type(list) ~= "table" then
		table.insert(report.errors, `{kind}: definition list is missing`)
		return index
	end
	for position, definition in list do
		local id = type(definition) == "table" and definition.id
		if type(id) ~= "string" then
			table.insert(report.errors, `{kind} #{position}: missing string id`)
		elseif #id == 0 or #id > maxIdLength or not string.match(id, "^[a-z][a-z0-9_]*$") then
			table.insert(report.errors, `{kind} '{id}': id must be lower_snake_case and at most {maxIdLength} characters`)
		elseif index[id] then
			table.insert(report.errors, `{kind} '{id}': duplicate id`)
		else
			index[id] = definition
		end
	end
	return index
end

local function validateProvinces(report: Report, input: ContentInput, idx: { [string]: { [string]: any } })
	local provinces = idx.provinces
	for id, province in provinces do
		local where = `province '{id}'`
		if type(province.name) ~= "string" or province.name == "" then
			table.insert(report.errors, `{where}: missing name`)
		end
		if not idx.regions[province.regionId] then
			table.insert(report.errors, `{where}: unknown region '{tostring(province.regionId)}'`)
		end
		if not idx.terrains[province.terrainId] then
			table.insert(report.errors, `{where}: unknown terrain '{tostring(province.terrainId)}'`)
		end
		if type(province.holding) ~= "table" or not idx.holdingKinds[province.holding.kind] then
			table.insert(report.errors, `{where}: unknown holding kind`)
		elseif type(province.holding.name) ~= "string" or province.holding.name == "" then
			table.insert(report.errors, `{where}: holding has no name`)
		end
		if not isFiniteNumber(province.baseTax) or province.baseTax <= 0 then
			table.insert(report.errors, `{where}: baseTax must be a positive number`)
		end
		local position = province.position
		if type(position) ~= "table" or not isFiniteNumber(position.x) or not isFiniteNumber(position.y) then
			table.insert(report.errors, `{where}: invalid map position`)
		elseif position.x < 0 or position.y < 0 or position.x > input.map.width or position.y > input.map.height then
			table.insert(report.errors, `{where}: map position lies outside the {input.map.width}x{input.map.height} canvas`)
		end

		if type(province.adjacent) ~= "table" or next(province.adjacent) == nil then
			table.insert(report.errors, `{where}: has no adjacent provinces`)
			continue
		end
		for neighbourId, kind in province.adjacent do
			if neighbourId == id then
				table.insert(report.errors, `{where}: is adjacent to itself`)
			elseif not provinces[neighbourId] then
				table.insert(report.errors, `{where}: adjacency references unknown province '{tostring(neighbourId)}'`)
			elseif not CONNECTION_KINDS[kind] then
				table.insert(report.errors, `{where}: adjacency to '{neighbourId}' has invalid kind '{tostring(kind)}'`)
			else
				local reverse = provinces[neighbourId].adjacent
				local reverseKind = type(reverse) == "table" and reverse[id]
				if reverseKind == nil then
					table.insert(report.errors, `{where}: adjacency to '{neighbourId}' is not symmetric`)
				elseif reverseKind ~= kind then
					table.insert(report.errors, `{where}: adjacency to '{neighbourId}' is '{kind}' but the reverse is '{tostring(reverseKind)}'`)
				end
			end
		end
	end

	-- Connectivity: every province should be reachable from every other (sea lanes included).
	local first = next(provinces)
	if first then
		local visited = { [first] = true }
		local queue = { first }
		while #queue > 0 do
			local current = table.remove(queue) :: string
			local adjacent = provinces[current].adjacent
			if type(adjacent) == "table" then
				for neighbourId in adjacent do
					if provinces[neighbourId] and not visited[neighbourId] then
						visited[neighbourId] = true
						table.insert(queue, neighbourId)
					end
				end
			end
		end
		for id in provinces do
			if not visited[id] then
				table.insert(report.warnings, `province '{id}': unreachable from the rest of the map`)
			end
		end
	end
end

local function validateHouses(report: Report, idx: { [string]: { [string]: any } })
	for id, house in idx.houses do
		local where = `house '{id}'`
		for _, field in { "name", "surname", "seatName", "words", "description" } do
			if type(house[field]) ~= "string" or house[field] == "" then
				table.insert(report.errors, `{where}: missing {field}`)
			end
		end
		if house.tier ~= "great" and house.tier ~= "minor" then
			table.insert(report.errors, `{where}: tier must be 'great' or 'minor'`)
		end
		if not idx.regions[house.regionId] then
			table.insert(report.errors, `{where}: unknown region '{tostring(house.regionId)}'`)
		end
		if not isValidRGB(house.mapColor) then
			table.insert(report.errors, `{where}: mapColor must be three channels in 0..255`)
		end
		local heraldry = house.heraldry
		if type(heraldry) ~= "table" or not isValidRGB(heraldry.field) or not isValidRGB(heraldry.charge) then
			table.insert(report.errors, `{where}: heraldry colours are invalid`)
		elseif not HERALDRY_DIVISIONS[heraldry.division] then
			table.insert(report.errors, `{where}: unknown heraldry division '{tostring(heraldry.division)}'`)
		elseif type(heraldry.monogram) ~= "string" or #heraldry.monogram == 0 then
			table.insert(report.errors, `{where}: heraldry monogram is missing`)
		end
		if not isFiniteNumber(house.courtUpkeep) or house.courtUpkeep < 0 then
			table.insert(report.errors, `{where}: courtUpkeep must be a non-negative number`)
		end
		if type(house.playable) ~= "boolean" then
			table.insert(report.errors, `{where}: playable must be a boolean`)
		end
	end
end

local function validateTraits(report: Report, idx: { [string]: { [string]: any } })
	for id, trait in idx.traits do
		if type(trait.modifiers) == "table" then
			for key, value in trait.modifiers do
				if not TRAIT_MODIFIERS[key] or not isFiniteNumber(value) then
					table.insert(report.errors, `trait '{id}': invalid modifier '{tostring(key)}'`)
				end
			end
		end
		if type(trait.aiWeights) == "table" then
			for key, value in trait.aiWeights do
				if not AI_WEIGHTS[key] or not isFiniteNumber(value) then
					table.insert(report.errors, `trait '{id}': invalid aiWeight '{tostring(key)}'`)
				end
			end
		end
	end
end

local function validateCharacters(
	report: Report,
	bookmark: GameTypes.BookmarkDefinition,
	idx: { [string]: { [string]: any } },
	maxIdLength: number
): { [string]: any }
	local characters = indexList(report, "character", bookmark.characters, maxIdLength)
	for id, character in characters do
		local where = `character '{id}'`
		if type(character.givenName) ~= "string" or character.givenName == "" then
			table.insert(report.errors, `{where}: missing givenName`)
		end
		if not idx.houses[character.houseId] then
			table.insert(report.errors, `{where}: unknown house '{tostring(character.houseId)}'`)
		end
		if character.sex ~= "male" and character.sex ~= "female" then
			table.insert(report.errors, `{where}: sex must be 'male' or 'female'`)
		end
		if not idx.cultures[character.cultureId] then
			table.insert(report.errors, `{where}: unknown culture '{tostring(character.cultureId)}'`)
		end
		if not idx.faiths[character.faithId] then
			table.insert(report.errors, `{where}: unknown faith '{tostring(character.faithId)}'`)
		end
		if type(character.traits) ~= "table" then
			table.insert(report.errors, `{where}: traits must be a list`)
		else
			for _, traitId in character.traits do
				if not idx.traits[traitId] then
					table.insert(report.errors, `{where}: unknown trait '{tostring(traitId)}'`)
				end
			end
		end
		local skills = character.skills
		if type(skills) ~= "table" then
			table.insert(report.errors, `{where}: skills are missing`)
		else
			for _, skill in { "diplomacy", "martial", "stewardship", "intrigue", "learning", "prowess" } do
				if not isFiniteNumber(skills[skill]) or skills[skill] < 0 then
					table.insert(report.errors, `{where}: skill '{skill}' must be a non-negative number`)
				end
			end
		end
		if not CalendarDate.isValid(character.birthDate) then
			table.insert(report.errors, `{where}: invalid birthDate`)
		elseif CalendarDate.isValid(bookmark.startDate) and CalendarDate.compare(character.birthDate, bookmark.startDate) > 0 then
			table.insert(report.errors, `{where}: born after the bookmark start date`)
		end
		if character.deathDate ~= nil then
			if not CalendarDate.isValid(character.deathDate) then
				table.insert(report.errors, `{where}: invalid deathDate`)
			elseif CalendarDate.isValid(character.birthDate) and CalendarDate.compare(character.deathDate, character.birthDate) < 0 then
				table.insert(report.errors, `{where}: dies before being born`)
			elseif CalendarDate.isValid(bookmark.startDate) and CalendarDate.compare(character.deathDate, bookmark.startDate) > 0 then
				table.insert(report.errors, `{where}: deathDate lies after the bookmark start date`)
			end
		end
	end

	-- Relationship links are checked after every character has been indexed.
	for id, character in characters do
		local where = `character '{id}'`
		for _, link in { "fatherId", "motherId" } do
			local parentId = character[link]
			if parentId ~= nil then
				local parent = characters[parentId]
				if not parent then
					table.insert(report.errors, `{where}: {link} references unknown character '{tostring(parentId)}'`)
				elseif parentId == id then
					table.insert(report.errors, `{where}: is their own parent`)
				elseif CalendarDate.isValid(parent.birthDate) and CalendarDate.isValid(character.birthDate) then
					if CalendarDate.yearsBetween(parent.birthDate, character.birthDate) < MIN_PARENT_AGE then
						table.insert(report.errors, `{where}: parent '{parentId}' is younger than {MIN_PARENT_AGE} at the birth`)
					end
				end
				local expectedSex = if link == "fatherId" then "male" else "female"
				if parent and parent.sex ~= expectedSex then
					table.insert(report.errors, `{where}: {link} '{parentId}' is not {expectedSex}`)
				end
			end
		end
		if character.spouseId ~= nil then
			local spouse = characters[character.spouseId]
			if not spouse then
				table.insert(report.errors, `{where}: spouse references unknown character '{tostring(character.spouseId)}'`)
			elseif spouse.spouseId ~= id then
				table.insert(report.errors, `{where}: spouse link to '{character.spouseId}' is not reciprocated`)
			end
		end
	end
	return characters
end

local function validateBookmark(
	report: Report,
	bookmark: GameTypes.BookmarkDefinition,
	idx: { [string]: { [string]: any } },
	config: ValidationConfig
)
	local where = `bookmark '{tostring(bookmark.id)}'`
	if not CalendarDate.isValid(bookmark.startDate) then
		table.insert(report.errors, `{where}: invalid startDate`)
	end

	local characters = validateCharacters(report, bookmark, idx, config.Network.MaxIdLength)

	if type(bookmark.houses) ~= "table" or next(bookmark.houses) == nil then
		table.insert(report.errors, `{where}: defines no houses`)
		return
	end
	local provinceCounts: { [string]: number } = {}
	for houseId, setup in bookmark.houses do
		provinceCounts[houseId] = 0
		local houseWhere = `{where} house '{houseId}'`
		if not idx.houses[houseId] then
			table.insert(report.errors, `{houseWhere}: house is not defined in HouseDefinitions`)
		end
		if not isFiniteNumber(setup.treasury) or setup.treasury < 0 then
			table.insert(report.errors, `{houseWhere}: treasury must be a non-negative number`)
		end
		local ruler = characters[setup.rulerId]
		if not ruler then
			table.insert(report.errors, `{houseWhere}: ruler '{tostring(setup.rulerId)}' is not a bookmark character`)
		else
			if ruler.deathDate ~= nil then
				table.insert(report.errors, `{houseWhere}: ruler '{setup.rulerId}' is dead at the start date`)
			end
			if ruler.houseId ~= houseId then
				table.insert(report.errors, `{houseWhere}: ruler '{setup.rulerId}' belongs to house '{tostring(ruler.houseId)}'`)
			end
		end
	end

	for provinceId in idx.provinces do
		local setup = bookmark.provinces[provinceId]
		if not setup then
			table.insert(report.errors, `{where}: province '{provinceId}' has no owner`)
		end
	end
	for provinceId, setup in bookmark.provinces do
		local provinceWhere = `{where} province '{tostring(provinceId)}'`
		if not idx.provinces[provinceId] then
			table.insert(report.errors, `{provinceWhere}: province is not defined in ProvinceDefinitions`)
		end
		if not bookmark.houses[setup.ownerHouseId] then
			table.insert(report.errors, `{provinceWhere}: owner '{tostring(setup.ownerHouseId)}' is not a bookmark house`)
		else
			provinceCounts[setup.ownerHouseId] += 1
		end
		local development = setup.development
		if not isFiniteNumber(development) or math.floor(development) ~= development
			or development < config.Economy.MinDevelopment or development > config.Economy.MaxDevelopment then
			table.insert(report.errors, `{provinceWhere}: development must be an integer in [{config.Economy.MinDevelopment}, {config.Economy.MaxDevelopment}]`)
		end
	end
	for houseId, count in provinceCounts do
		if count == 0 then
			table.insert(report.errors, `{where} house '{houseId}': owns no provinces`)
		end
	end

	local seenPairs = {}
	for position, relation in bookmark.relations do
		local relationWhere = `{where} relation #{position}`
		if not bookmark.houses[relation.a] or not bookmark.houses[relation.b] then
			table.insert(report.errors, `{relationWhere}: references a house outside the bookmark`)
		elseif relation.a == relation.b then
			table.insert(report.errors, `{relationWhere}: a house cannot have relations with itself`)
		else
			local key = if relation.a < relation.b then `{relation.a}|{relation.b}` else `{relation.b}|{relation.a}`
			if seenPairs[key] then
				table.insert(report.errors, `{relationWhere}: duplicate relation for {key}`)
			end
			seenPairs[key] = true
		end
		if not isFiniteNumber(relation.value)
			or relation.value < config.Diplomacy.MinRelation or relation.value > config.Diplomacy.MaxRelation then
			table.insert(report.errors, `{relationWhere}: value outside [{config.Diplomacy.MinRelation}, {config.Diplomacy.MaxRelation}]`)
		end
	end
end

function ContentValidator.validate(input: ContentInput, bookmark: GameTypes.BookmarkDefinition, config: ValidationConfig): Report
	local report: Report = { errors = {}, warnings = {} }
	local maxIdLength = config.Network.MaxIdLength
	local idx: { [string]: { [string]: any } } = {
		terrains = indexList(report, "terrain", input.terrains, maxIdLength),
		holdingKinds = indexList(report, "holding kind", input.holdingKinds, maxIdLength),
		regions = indexList(report, "region", input.regions, maxIdLength),
		provinces = indexList(report, "province", input.provinces, maxIdLength),
		houses = indexList(report, "house", input.houses, maxIdLength),
		traits = indexList(report, "trait", input.traits, maxIdLength),
		cultures = indexList(report, "culture", input.cultures, maxIdLength),
		faiths = indexList(report, "faith", input.faiths, maxIdLength),
	}
	validateProvinces(report, input, idx)
	validateHouses(report, idx)
	validateTraits(report, idx)
	validateBookmark(report, bookmark, idx, config)
	table.sort(report.errors)
	table.sort(report.warnings)
	return report
end

return ContentValidator
