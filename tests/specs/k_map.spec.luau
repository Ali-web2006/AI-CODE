-- Scenario K — World map configuration (Data/World/MapData, SigilArt) and the polygon helpers the
-- map renderer relies on. Presentation data only, but every reference must resolve: a broken id
-- would leave land unclickable or unpainted.

return function(t)
	local fx, expect, vr = t.fx, t.expect, t.vr
	local MapData = vr.require("ReplicatedStorage.Shared.Data.World.MapData")
	local SigilArt = vr.require("ReplicatedStorage.Shared.Data.World.SigilArt")
	local Polygon = vr.require("ReplicatedStorage.Shared.Util.Polygon")
	local Content = fx.Content

	-- The palettes the map must use, exactly. House Stark has a steel-blue house colour (not grey,
	-- which read as unowned land) and the Crownlands use the crown's own gold palette.
	local PALETTES = {
		stark = { "#DDE7F0", "#BCCEDF", "#9CB5CC", "#7E9CB8", "#6585A3", "#4F6E8C" },
		arryn = { "#BFF3FF", "#7FE0F5", "#35C6E8", "#1FA3C4", "#0F7A99" },
		tully = { "#4A63FF", "#2F45E0", "#2433B8", "#1C2490", "#3A2FD0" },
		greyjoy = { "#2E2E22", "#4A4A2E", "#6B6A3A", "#A99B4A", "#D9C25A" },
		lannister = { "#FF1E1E", "#E01010", "#B80D0D", "#F25C6A", "#FF8A8A" },
		tyrell = { "#3DFF3D", "#1FD11F", "#12A812", "#7CFC5A", "#0B7A0B" },
		baratheon = { "#FFF34D", "#F5DC1F", "#E8C40E", "#FFE680", "#C9A300" },
		martell = { "#FFB04D", "#FF8A1F", "#F06A0A", "#FF9E5C", "#C9520A" },
	}
	local SEATS = {
		stark = "Winterfell", arryn = "The Eyrie", tully = "Riverrun", greyjoy = "Pyke", lannister = "Casterly Rock",
		tyrell = "Highgarden", baratheon = "Storm's End", martell = "Sunspear",
	}
	local CROWN_PALETTE = { "#E8BE52", "#D9A21B", "#B9850F", "#94680A", "#CC9433" }

	local function isHex(value: any): boolean
		return type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil
	end

	local function insideCanvas(x: number, y: number): boolean
		return x >= 0 and y >= 0 and x <= MapData.width and y <= MapData.height
	end

	local function validPath(path: { number }, where: string)
		expect.truthy(#path >= 6 and #path % 2 == 0, `{where}: a path needs at least 3 points`)
		for i = 1, #path - 1, 2 do
			expect.truthy(insideCanvas(path[i], path[i + 1]), `{where}: point {path[i]},{path[i + 1]} is outside the canvas`)
		end
		expect.truthy(Polygon.area(path) > 0, `{where}: zero area`)
	end

	local houses, regions = {}, {}
	for _, house in MapData.houses do
		houses[house.id] = house
	end
	for _, region in MapData.regions do
		regions[region.id] = region
	end

	local boundsOf = setmetatable({}, { __mode = "k" })
	local function containedIn(paths: { { number } }, x: number, y: number): boolean
		for _, path in paths do
			local b = boundsOf[path]
			if not b then
				b = Polygon.bounds(path)
				boundsOf[path] = b
			end
			if x >= b.minX and x <= b.maxX and y >= b.minY and y <= b.maxY and Polygon.contains(path, x, y) then
				return true
			end
		end
		return false
	end

	t.test("the map has exactly the great houses of 297 AC with the specified palettes", function()
		local great = 0
		for _, house in MapData.houses do
			if not house.minor then
				great += 1
			end
		end
		expect.equal(great, 8, "eight great houses; the Targaryens are in exile (minor houses are flagged minor)")
		expect.falsy(houses.targaryen, "House Targaryen is not on the 297 AC map")
		for id, palette in PALETTES do
			local house = houses[id]
			expect.truthy(house ~= nil, `house {id} is on the map`)
			expect.deepEqual(house.shadeColors, palette, `{id} shadeColors`)
			expect.truthy(table.find(palette, house.primaryColor) ~= nil, `{id} primaryColor is one of its shades`)
			expect.equal(house.seat, SEATS[id], `{id} seat`)
			for _, field in { "name", "regionName", "sigil", "words" } do
				expect.truthy(type(house[field]) == "string" and house[field] ~= "", `{id} has a {field}`)
			end
			expect.truthy(house.label and insideCanvas(house.label.x, house.label.y), `{id} label position`)
			expect.truthy(house.crest and insideCanvas(house.crest.x, house.crest.y), `{id} crest position`)
		end
	end)

	t.test("every region references a valid house, and regions match the game's regions", function()
		expect.equal(#MapData.regions, #Content.raw.regions, "one map region per game region")
		local claimed = {}
		for _, region in MapData.regions do
			expect.truthy(houses[region.houseId] ~= nil, `region {region.id} references house {region.houseId}`)
			expect.truthy(Content.regions[region.id] ~= nil, `region {region.id} is a game region`)
			claimed[region.houseId] = true
			-- The ruling house really holds land there at the start of the campaign.
			local holds = false
			for provinceId, setup in Content.getBookmark("long_summer_297").provinces do
				if Content.provinces[provinceId].regionId == region.id and setup.ownerHouseId == region.houseId then
					holds = true
				end
			end
			expect.truthy(holds, `{region.houseId} holds a province in {region.id} in 297 AC`)
			expect.truthy(#region.paths >= 1, `region {region.id} has an outline`)
			for index, path in region.paths do
				validPath(path, `region {region.id} path {index}`)
			end
		end
		for id in PALETTES do
			expect.truthy(claimed[id], `{id} rules a region`)
		end
		local crownlands = regions.crownlands
		expect.equal(crownlands.houseId, "baratheon", "the Crownlands belong to the crown, House Baratheon")
		expect.deepEqual(crownlands.shadeColors, CROWN_PALETTE, "the Crownlands palette")
		expect.truthy(crownlands.title and crownlands.label and crownlands.crest, "the Crownlands have their own title and crest")
	end)

	t.test("sub-territories split each region 4-10 ways and select real provinces of that region", function()
		local perRegion, perProvince, ids = {}, {}, {}
		for _, sub in MapData.subTerritories do
			expect.falsy(ids[sub.id], `duplicate sub-territory {sub.id}`)
			ids[sub.id] = true
			local region = regions[sub.regionId]
			expect.truthy(region ~= nil, `{sub.id} region`)
			local province = Content.provinces[sub.provinceId]
			expect.truthy(province ~= nil, `{sub.id} province {sub.provinceId}`)
			expect.equal(province.regionId, sub.regionId, `{sub.id} province lies in its region`)
			local house = houses[sub.houseId or region.houseId]
			expect.truthy(house ~= nil, `{sub.id} house`)
			local palette = if sub.houseId == nil and region.shadeColors then region.shadeColors else house.shadeColors
			expect.truthy(sub.shade >= 1 and sub.shade <= #palette, `{sub.id} shade index`)
			for index, path in sub.paths do
				validPath(path, `{sub.id} path {index}`)
			end
			perRegion[sub.regionId] = (perRegion[sub.regionId] or 0) + 1
			perProvince[sub.provinceId] = true
		end
		for _, region in MapData.regions do
			local count = perRegion[region.id] or 0
			expect.truthy(count >= 4 and count <= 10, `{region.id} has {count} sub-territories`)
		end
		for _, provinceId in Content.provinceIds do
			expect.truthy(perProvince[provinceId], `province {provinceId} has land on the map`)
		end
	end)

	t.test("areas never overlap and region outlines enclose exactly their sub-territories", function()
		local step = 9
		local checked = 0
		for y = 3, MapData.height, step do
			for x = 2, MapData.width, step do
				local owners = 0
				local subRegion = nil
				for _, sub in MapData.subTerritories do
					if containedIn(sub.paths, x, y) then
						owners += 1
						subRegion = sub.regionId
					end
				end
				for _, feature in MapData.specialFeatures do
					if containedIn(feature.paths, x, y) then
						owners += 1
					end
				end
				expect.truthy(owners <= 1, `point {x},{y} is covered {owners} times`)
				for _, region in MapData.regions do
					local inRegion = containedIn(region.paths, x, y)
					expect.equal(inRegion, subRegion == region.id, `point {x},{y}: region {region.id} outline agrees with its sub-territories`)
				end
				checked += 1
			end
		end
		expect.truthy(checked > 20000, "sampled the whole canvas")
	end)

	t.test("locations: required places, valid kinds, and each holding sits in its own province", function()
		local byName, ids, holdings = {}, {}, {}
		for _, location in MapData.locations do
			expect.falsy(ids[location.id], `duplicate location {location.id}`)
			ids[location.id] = true
			byName[location.name] = location
			expect.truthy(table.find({ "seat", "city", "port", "landmark" }, location.type) ~= nil, `{location.id} type`)
			expect.truthy(insideCanvas(location.x, location.y), `{location.id} position`)
			local provinceId = location.provinceId
			if provinceId then
				expect.falsy(holdings[provinceId], `{provinceId} has one holding on the map`)
				holdings[provinceId] = location
				local inside = false
				for _, sub in MapData.subTerritories do
					if sub.provinceId == provinceId and containedIn(sub.paths, location.x, location.y) then
						inside = true
					end
				end
				expect.truthy(inside, `{location.name} lies on its province's land`)
				local province = Content.provinces[provinceId]
				expect.equal(province.position.x, location.x, `{provinceId} position x matches the map`)
				expect.equal(province.position.y, location.y, `{provinceId} position y matches the map`)
				expect.equal(location.name, province.holding.name, `{provinceId} holding name`)
			end
		end
		for _, name in {
			"Castle Black", "Winterfell", "White Harbor", "Moat Cailin", "The Twins", "Riverrun", "The Eyrie", "Gulltown",
			"Pyke", "Casterly Rock", "Lannisport", "King's Landing", "Dragonstone", "Highgarden", "Oldtown", "Storm's End", "Sunspear",
		} do
			expect.truthy(byName[name] ~= nil, `location {name}`)
		end
		for _, provinceId in Content.provinceIds do
			expect.truthy(holdings[provinceId] ~= nil, `{provinceId} has a clickable holding`)
		end
		for id, seat in SEATS do
			local location = byName[seat]
			expect.truthy(location.type == "seat" or location.type == "city", `{seat} is drawn as a seat or city ({id})`)
		end
	end)

	t.test("special features: Beyond the Wall, the Wall band, the Gift and the Stepstones", function()
		local features = {}
		for _, feature in MapData.specialFeatures do
			features[feature.id] = feature
			expect.truthy(isHex(feature.color), `{feature.id} colour`)
			expect.truthy(#feature.paths >= 1, `{feature.id} has an outline`)
		end
		expect.equal(features.beyond_the_wall.color, "#9A9A9A")
		expect.equal(features.the_wall.color, "#000000")
		expect.equal(features.the_gift.color, "#000000")
		local wall = Polygon.bounds(features.the_wall.paths[1])
		expect.near(wall.minY, 80, 1.5, "the Wall starts at y=80")
		expect.near(wall.maxY, 130, 1.5, "the Wall ends at y=130")
		local continent = { minX = math.huge, maxX = -math.huge }
		for _, path in features.beyond_the_wall.paths do
			local b = Polygon.bounds(path)
			continent.minX = math.min(continent.minX, b.minX)
			continent.maxX = math.max(continent.maxX, b.maxX)
		end
		expect.truthy(wall.maxX - wall.minX >= 0.6 * (continent.maxX - continent.minX), "the Wall spans the continent")
		local gift = features.the_gift.paths[1]
		local gx, gy = Polygon.centroid(gift)
		expect.truthy(gy > 130 and gy < 190, "the Gift lies just south of the Wall")
		expect.truthy(gx > wall.minX and gx < wall.maxX, "the Gift is under the Wall")
		expect.truthy(#features.stepstones.paths >= 3, "the Stepstones are a scatter of islets")
	end)

	t.test("crests: art for every great house, inside the 100x120 shield box", function()
		for id in PALETTES do
			local art = SigilArt[id]
			expect.truthy(art ~= nil and #art.layers >= 3, `{id} has sigil art`)
			local triangles = 0
			for _, layer in art.layers do
				expect.truthy(isHex(layer.color), `{id} layer colour`)
				expect.equal(#layer.tris % 6, 0, `{id} triangles are complete`)
				for i = 1, #layer.tris - 1, 2 do
					local x, y = layer.tris[i], layer.tris[i + 1]
					expect.truthy(x >= 0 and x <= 100 and y >= 0 and y <= 120, `{id} art stays in its box`)
				end
				triangles += #layer.tris // 6
			end
			expect.truthy(triangles <= 260, `{id} art is light enough to render ({triangles} triangles)`)
		end
		local function over(region, crest, label: string)
			local box = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
			for _, path in region.paths do
				local b = Polygon.bounds(path)
				box = { minX = math.min(box.minX, b.minX), minY = math.min(box.minY, b.minY), maxX = math.max(box.maxX, b.maxX), maxY = math.max(box.maxY, b.maxY) }
			end
			expect.truthy(crest.x >= box.minX and crest.x <= box.maxX and crest.y >= box.minY and crest.y <= box.maxY, label)
		end
		for _, region in MapData.regions do
			local house = houses[region.houseId]
			if house.regionName == region.name then
				over(region, house.crest, `{house.id} crest sits over {region.id}`)
			elseif region.crest then
				over(region, region.crest, `{region.id} crest sits over its region`)
			end
		end
	end)

	t.test("polygon helpers: exact triangulation of every map outline and of awkward shapes", function()
		local function triangleArea(tris: { number }): number
			local sum = 0
			for i = 1, #tris, 6 do
				sum += math.abs((tris[i + 2] - tris[i]) * (tris[i + 5] - tris[i + 1]) - (tris[i + 3] - tris[i + 1]) * (tris[i + 4] - tris[i])) / 2
			end
			return sum
		end
		local shapes = {
			{ 0, 0, 10, 0, 10, 10, 0, 10 }, -- square
			{ 0, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10 }, -- concave L
			{ 0, 0, 5, 0, 10, 0, 10, 10, 0, 10 }, -- collinear point
			{ 0, 10, 10, 10, 10, 0, 0, 0 }, -- other winding
			{ 0, 0, 6, 2, 12, 0, 10, 6, 12, 12, 6, 9, 0, 12, 2, 6 }, -- star-like
		}
		for _, sub in MapData.subTerritories do
			for _, path in sub.paths do
				table.insert(shapes, path)
			end
		end
		for _, feature in MapData.specialFeatures do
			for _, path in feature.paths do
				table.insert(shapes, path)
			end
		end
		for index, path in shapes do
			local tris = Polygon.triangulate(path)
			local area = Polygon.area(path)
			expect.near(triangleArea(tris), area, area * 1e-6 + 1e-6, `shape {index} is covered exactly`)
		end
		expect.truthy(Polygon.contains({ 0, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10 }, 2, 8), "inside the L")
		expect.falsy(Polygon.contains({ 0, 0, 10, 0, 10, 4, 4, 4, 4, 10, 0, 10 }, 8, 8), "outside the L")
	end)
end
