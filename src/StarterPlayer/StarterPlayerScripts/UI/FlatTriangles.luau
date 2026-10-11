--!strict
--[[
	FlatTriangles — draws flat-coloured 2D triangles inside a ViewportFrame. Roblox GUI has no
	polygon fill, so each triangle is made of two WedgeParts lying on the ground plane and the
	ViewportFrame looks straight down at them: flat colours, exact shapes, crisp at any zoom.

	Plane coordinates (x, y) map to world (x, height, y). Layers are separated by `height` and the
	top-down camera draws higher ones on top.

	FlatTriangles.setupViewport makes a ViewportFrame render part colours exactly (full ambient
	light, no directional light).
]]

local FlatTriangles = {}

local THICKNESS = 0.05
-- Triangles are grown by this many units so neighbouring triangles overlap slightly and no
-- background shows through the seams between them.
local OVERLAP = 0.06

function FlatTriangles.setupViewport(viewport: ViewportFrame)
	viewport.Ambient = Color3.new(1, 1, 1)
	viewport.LightColor = Color3.new(0, 0, 0)
	viewport.LightDirection = Vector3.new(0, -1, 0)
end

-- A top-down camera for a ViewportFrame of the given pixel height, centred on plane point
-- (cx, cy) at `pixelsPerUnit`.
function FlatTriangles.topDownCFrame(cx: number, cy: number, pixelsPerUnit: number, viewportHeight: number, fieldOfView: number): CFrame
	local distance = viewportHeight / (2 * math.tan(math.rad(fieldOfView) / 2) * math.max(pixelsPerUnit, 1e-4))
	return CFrame.lookAt(Vector3.new(cx, distance, cy), Vector3.new(cx, 0, cy), Vector3.new(0, 0, -1))
end

local function newWedge(color: Color3): WedgePart
	local wedge = Instance.new("WedgePart")
	wedge.Anchored = true
	wedge.CanCollide = false
	wedge.CanQuery = false
	wedge.CanTouch = false
	wedge.CastShadow = false
	wedge.Material = Enum.Material.SmoothPlastic
	wedge.TopSurface = Enum.SurfaceType.Smooth
	wedge.BottomSurface = Enum.SurfaceType.Smooth
	wedge.Color = color
	return wedge
end

--[[
	Appends the wedges of one triangle to `out` (unparented; the caller parents them in bulk).
	Uses the classic two-wedge construction: split the triangle at the foot of the altitude onto
	its longest edge into two right triangles, one WedgePart each.
]]
function FlatTriangles.add(out: { WedgePart }, ax: number, ay: number, bx: number, by: number, cx: number, cy: number, height: number, color: Color3)
	local a = Vector3.new(ax, height, ay)
	local b = Vector3.new(bx, height, by)
	local c = Vector3.new(cx, height, cy)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- Reorder so that bc is the longest edge.
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-6 then
		return -- degenerate
	end
	local right = normal.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local altitude = math.abs(ab:Dot(up))
	local depth1 = math.abs(ab:Dot(back))
	local depth2 = math.abs(ac:Dot(back))

	if depth1 > 1e-4 then
		local w1 = newWedge(color)
		w1.Size = Vector3.new(THICKNESS, altitude + OVERLAP, depth1 + OVERLAP)
		w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
		table.insert(out, w1)
	end
	if depth2 > 1e-4 then
		local w2 = newWedge(color)
		w2.Size = Vector3.new(THICKNESS, altitude + OVERLAP, depth2 + OVERLAP)
		w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
		table.insert(out, w2)
	end
end

-- Appends the wedges of a flat triangle list { x1, y1, x2, y2, x3, y3, ... }.
function FlatTriangles.addList(out: { WedgePart }, triangles: { number }, height: number, color: Color3, scale: number?, offsetX: number?, offsetY: number?)
	local k = scale or 1
	local ox, oy = offsetX or 0, offsetY or 0
	for i = 1, #triangles - 5, 6 do
		FlatTriangles.add(
			out,
			ox + triangles[i] * k,
			oy + triangles[i + 1] * k,
			ox + triangles[i + 2] * k,
			oy + triangles[i + 3] * k,
			ox + triangles[i + 4] * k,
			oy + triangles[i + 5] * k,
			height,
			color
		)
	end
end

function FlatTriangles.parentAll(parts: { WedgePart }, parent: Instance)
	for _, part in parts do
		part.Parent = parent
	end
end

return FlatTriangles
