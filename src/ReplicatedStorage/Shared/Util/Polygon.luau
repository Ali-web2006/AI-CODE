--!strict
--[[
	Polygon — pure 2D polygon helpers for the map. A path is a flat list of coordinates
	{ x1, y1, x2, y2, ... } describing a simple polygon (no self-intersections, no holes) in either
	winding order. No Roblox types are used, so the tests run these headlessly.
]]

local Polygon = {}

export type Path = { number }
export type Bounds = { minX: number, minY: number, maxX: number, maxY: number }

-- Twice the signed area (positive when counter-clockwise in a y-up frame).
function Polygon.signedArea2(path: Path): number
	local n = #path // 2
	local sum = 0
	for i = 1, n do
		local j = if i == n then 1 else i + 1
		local x1, y1 = path[2 * i - 1], path[2 * i]
		local x2, y2 = path[2 * j - 1], path[2 * j]
		sum += x1 * y2 - x2 * y1
	end
	return sum
end

function Polygon.area(path: Path): number
	return math.abs(Polygon.signedArea2(path)) / 2
end

function Polygon.bounds(path: Path): Bounds
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for i = 1, #path - 1, 2 do
		local x, y = path[i], path[i + 1]
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minY, maxY = math.min(minY, y), math.max(maxY, y)
	end
	return { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

-- Even-odd rule: true when (x, y) lies inside the polygon.
function Polygon.contains(path: Path, x: number, y: number): boolean
	local inside = false
	local n = #path // 2
	local j = n
	for i = 1, n do
		local xi, yi = path[2 * i - 1], path[2 * i]
		local xj, yj = path[2 * j - 1], path[2 * j]
		if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then
			inside = not inside
		end
		j = i
	end
	return inside
end

-- Area-weighted centroid.
function Polygon.centroid(path: Path): (number, number)
	local n = #path // 2
	local a, cx, cy = 0, 0, 0
	for i = 1, n do
		local j = if i == n then 1 else i + 1
		local x1, y1 = path[2 * i - 1], path[2 * i]
		local x2, y2 = path[2 * j - 1], path[2 * j]
		local cross = x1 * y2 - x2 * y1
		a += cross
		cx += (x1 + x2) * cross
		cy += (y1 + y2) * cross
	end
	if a == 0 then
		return path[1], path[2]
	end
	return cx / (3 * a), cy / (3 * a)
end

local function cross(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number
	return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

local function pointInTriangle(px: number, py: number, ax: number, ay: number, bx: number, by: number, cx: number, cy: number): boolean
	local d1 = cross(px, py, ax, ay, bx, by)
	local d2 = cross(px, py, bx, by, cx, cy)
	local d3 = cross(px, py, cx, cy, ax, ay)
	local hasNegative = d1 < 0 or d2 < 0 or d3 < 0
	local hasPositive = d1 > 0 or d2 > 0 or d3 > 0
	return not (hasNegative and hasPositive)
end

--[[
	Ear-clipping triangulation. Returns a flat list of triangles { x1, y1, x2, y2, x3, y3, ... }
	covering the polygon exactly (n - 2 triangles for n non-collinear vertices). Collinear and
	duplicate vertices are tolerated; if the polygon is not simple the remaining vertices are fanned
	so the result still covers the outline instead of failing.
]]
function Polygon.triangulate(path: Path): { number }
	local n = #path // 2
	local out: { number } = {}
	if n < 3 then
		return out
	end
	-- Work on indices in counter-clockwise order (y-up sense) so ears are left turns.
	local indices: { number } = {}
	if Polygon.signedArea2(path) > 0 then
		for i = 1, n do
			indices[i] = i
		end
	else
		for i = 1, n do
			indices[i] = n - i + 1
		end
	end

	local function px(i: number): number
		return path[2 * i - 1]
	end
	local function py(i: number): number
		return path[2 * i]
	end

	local guard = 0
	while #indices > 3 do
		local count = #indices
		local clipped = false
		for k = 1, count do
			local ia = indices[if k == 1 then count else k - 1]
			local ib = indices[k]
			local ic = indices[if k == count then 1 else k + 1]
			local ax, ay, bx, by, cx, cy = px(ia), py(ia), px(ib), py(ib), px(ic), py(ic)
			local turn = cross(ax, ay, bx, by, cx, cy)
			if turn == 0 then
				-- A collinear (or repeated) vertex adds nothing: drop it.
				table.remove(indices, k)
				clipped = true
				break
			elseif turn > 0 then
				local blocked = false
				for m = 1, count do
					local im = indices[m]
					if im ~= ia and im ~= ib and im ~= ic then
						local mx, my = px(im), py(im)
						if not ((mx == ax and my == ay) or (mx == bx and my == by) or (mx == cx and my == cy))
							and pointInTriangle(mx, my, ax, ay, bx, by, cx, cy)
						then
							blocked = true
							break
						end
					end
				end
				if not blocked then
					table.insert(out, ax)
					table.insert(out, ay)
					table.insert(out, bx)
					table.insert(out, by)
					table.insert(out, cx)
					table.insert(out, cy)
					table.remove(indices, k)
					clipped = true
					break
				end
			end
		end
		if not clipped then
			guard += 1
			if guard > 2 then
				break
			end
			-- Not a simple polygon: fan what is left so the area is still covered.
			for k = 2, #indices - 1 do
				local ia, ib, ic = indices[1], indices[k], indices[k + 1]
				table.insert(out, px(ia))
				table.insert(out, py(ia))
				table.insert(out, px(ib))
				table.insert(out, py(ib))
				table.insert(out, px(ic))
				table.insert(out, py(ic))
			end
			return out
		end
	end
	if #indices == 3 then
		local ia, ib, ic = indices[1], indices[2], indices[3]
		if cross(px(ia), py(ia), px(ib), py(ib), px(ic), py(ic)) ~= 0 then
			table.insert(out, px(ia))
			table.insert(out, py(ia))
			table.insert(out, px(ib))
			table.insert(out, py(ib))
			table.insert(out, px(ic))
			table.insert(out, py(ic))
		end
	end
	return out
end

return Polygon
