-- Dumps the world map configuration (MapData) and the sigil art as JSON, for the preview renderer.
-- Usage: lune run tests/map_dump.luau > build/map.json
local process = require("@lune/process")
local serde = require("@lune/serde")
local VirtualRoblox = require("./harness/VirtualRoblox")
local vr = VirtualRoblox.new(process.cwd)
local Content = vr.require("ReplicatedStorage.Shared.Data.Content")
local MapData = vr.require("ReplicatedStorage.Shared.Data.World.MapData")
local SigilArt = vr.require("ReplicatedStorage.Shared.Data.World.SigilArt")
local provinces = {}
for _, id in Content.provinceIds do
	local p = Content.provinces[id]
	provinces[id] = { name = p.name, x = p.position.x, y = p.position.y }
end
print(serde.encode("json", { map = MapData, sigils = SigilArt, provinces = provinces }))
