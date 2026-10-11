--!strict
--[[
	Content — the single entry point to immutable content definitions.

	Builds id -> definition lookups and sorted id lists once, then freezes everything. Both the
	server and the client read content through this module. Raw definition lists are kept in
	Content.raw so the ContentValidator can detect duplicate ids, which a lookup map would hide.
]]

local GameTypes = require(script.Parent.Parent.Types.GameTypes)
local TableUtil = require(script.Parent.Parent.Util.TableUtil)

local TerrainDefinitions = require(script.Parent.World.TerrainDefinitions)
local HoldingKindDefinitions = require(script.Parent.World.HoldingKindDefinitions)
local RegionDefinitions = require(script.Parent.World.RegionDefinitions)
local ProvinceDefinitions = require(script.Parent.World.ProvinceDefinitions)
local MapData = require(script.Parent.World.MapData)
local HouseDefinitions = require(script.Parent.Houses.HouseDefinitions)
local TraitDefinitions = require(script.Parent.Characters.TraitDefinitions)
local CultureDefinitions = require(script.Parent.Characters.CultureDefinitions)
local FaithDefinitions = require(script.Parent.Characters.FaithDefinitions)
local LongSummer297 = require(script.Parent.Bookmarks.LongSummer297)

local function indexById<T>(list: { T }): { [string]: T }
	local index = {}
	for _, definition in list do
		index[(definition :: any).id] = definition
	end
	return index
end

local function sortedIds(list: { any }): { string }
	local ids = {}
	for _, definition in list do
		table.insert(ids, definition.id)
	end
	table.sort(ids)
	return ids
end

local Content = {}

Content.raw = {
	terrains = TerrainDefinitions,
	holdingKinds = HoldingKindDefinitions,
	regions = RegionDefinitions,
	provinces = ProvinceDefinitions,
	houses = HouseDefinitions,
	traits = TraitDefinitions,
	cultures = CultureDefinitions,
	faiths = FaithDefinitions,
	bookmarks = { LongSummer297 },
}

Content.terrains = indexById(TerrainDefinitions) :: { [string]: GameTypes.TerrainDefinition }
Content.holdingKinds = indexById(HoldingKindDefinitions) :: { [string]: GameTypes.HoldingKindDefinition }
Content.regions = indexById(RegionDefinitions) :: { [string]: GameTypes.RegionDefinition }
Content.provinces = indexById(ProvinceDefinitions) :: { [string]: GameTypes.ProvinceDefinition }
Content.houses = indexById(HouseDefinitions) :: { [string]: GameTypes.HouseDefinition }
Content.traits = indexById(TraitDefinitions) :: { [string]: GameTypes.TraitDefinition }
Content.cultures = indexById(CultureDefinitions) :: { [string]: GameTypes.CultureDefinition }
Content.faiths = indexById(FaithDefinitions) :: { [string]: GameTypes.NamedDefinition }
Content.bookmarks = indexById(Content.raw.bookmarks) :: { [string]: GameTypes.BookmarkDefinition }

-- Sorted id lists: iterate these (not the maps) wherever order matters.
Content.provinceIds = sortedIds(ProvinceDefinitions)
Content.houseIds = sortedIds(HouseDefinitions)

-- The world map canvas. Its drawing (outlines, colours, crests) is in MapData and only the client uses it.
Content.map = { width = MapData.width, height = MapData.height } :: GameTypes.MapDefinition

function Content.getBookmark(bookmarkId: string): GameTypes.BookmarkDefinition?
	return Content.bookmarks[bookmarkId]
end

TableUtil.deepFreeze(Content)

return Content
