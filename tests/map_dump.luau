-- Dumps map geometry and starting ownership as JSON (used to render a preview image of the map).
-- Usage: lune run tests/map_dump.luau > build/map.json
local process = require("@lune/process")
local serde = require("@lune/serde")
local VirtualRoblox = require("./harness/VirtualRoblox")
local vr = VirtualRoblox.new(process.cwd)
local Content = vr.require("ReplicatedStorage.Shared.Data.Content")
local bookmark = Content.getBookmark("long_summer_297")
local provinces = {}
for _, id in Content.provinceIds do
	local p = Content.provinces[id]
	local owner = Content.houses[bookmark.provinces[id].ownerHouseId]
	table.insert(provinces, { id = id, name = p.name, x = p.position.x, y = p.position.y, adjacent = p.adjacent, color = owner.mapColor, marker = Content.holdingKinds[p.holding.kind].marker })
end
print(serde.encode("json", { map = Content.map, provinces = provinces }))
