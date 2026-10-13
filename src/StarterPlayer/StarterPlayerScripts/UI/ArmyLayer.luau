--!strict
--[[
	ArmyLayer — armies on the world map: one token per army and the dotted route of armies on the
	march. MapController mounts it and owns the canvas, the view and the input; this module needs
	only the small Surface interface below, and draws on two canvas layers of its own: Routes, with
	Armies above it (both above the map labels).

	Tokens. A token is a TextButton named Army_<armyId> with a constant on-screen size: a banner in
	the house's map colour with a dark edge, the house crest (SigilView, low detail) and the troop
	count in large bold figures. It is anchored at its bottom centre a little above the army's map
	point, so the holding icon at that point stays visible; armies standing together stack upwards.
	The selected army has a gold edge and is drawn in front. A press on a token starts a map drag
	(and never selects the province underneath), a click selects the army, a right-click gives an
	order against that army (surface.commandArmy: never the land drawn under the raised banner),
	and hovering shows the army's tooltip. Each token remembers the house it was drawn for: when a
	full snapshot or a session change (a load, or a return from the lobby) gives its army id to an
	army of another house, the token is rebuilt, and tokens of armies that no longer exist go.

	Movement. The server replicates only the current leg (locationId -> route[1], legStartDay,
	legEndDay) and the campaign day number; nothing changes while an army marches. The army's point
	on a day is the linear interpolation along its leg (extrapolated into the next land leg, which
	the server starts on the day of arrival). On every clock update a moving token tweens linearly
	to its point n days ahead over those n days' real duration, n = max(1, ceil(ReplicationInterval
	/ SecondsPerDay[speed])), so the next update arrives before the tween ends. A paused clock, a new
	token and a full snapshot snap tokens into place instead. Targets are canvas scale positions
	(plus a pixel lift), so panning and zooming never disturb a tween.

	Routes. For every army of the player's house with orders, and for the selected army, round dots
	(plain inactive Frames, so clicks and hover fall through to the map) are laid every ~14 px on
	screen from the army's point through each stop to the destination, which gets a chevron
	(Path2D). The spacing follows the zoom in buckets, so a route is redrawn when the bucket, the
	army's orders or its leg change; as days pass, the dots of the current leg behind the army are
	hidden. A redraw reuses the route's dot frames, moving them and creating only the extra ones a
	closer zoom needs (spares are hidden and kept), so zooming creates no instances once every
	zoom level has been visited.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Content = require(ReplicatedStorage.Shared.Data.Content)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MapData = require(ReplicatedStorage.Shared.Data.World.MapData)
local MilitaryRules = require(ReplicatedStorage.Shared.Rules.MilitaryRules)
local ReplicaStore = require(script.Parent.Parent.Controllers.ReplicaStore)
local ArmyInfo = require(script.Parent.ArmyInfo)
local Format = require(script.Parent.Format)
local MapStyle = require(script.Parent.MapStyle)
local SigilView = require(script.Parent.SigilView)
local Theme = require(script.Parent.Theme)
local Tooltip = require(script.Parent.Tooltip)
local UI = require(script.Parent.UIComponents)

local Colors = Theme.Colors
local Fonts = Theme.Fonts

export type Surface = {
	store: ReplicaStore.ReplicaStore,
	-- Creates a full-canvas layer frame (children are placed in canvas scale units).
	layer: (name: string, zIndex: number) -> Frame,
	-- Canvas scale position of a map point.
	scalePosition: (x: number, y: number) -> UDim2,
	-- A press that started on a token: may begin a map drag, never selects the land beneath.
	beginDrag: (input: InputObject, onLocation: boolean?) -> (),
	-- A right-click on a token: an order against that army.
	commandArmy: (armyId: string) -> (),
	-- The pointer entered (true) or left (false) a token, whose tooltip then wins over the map's.
	hover: (button: TextButton, inside: boolean) -> (),
	onSelectArmy: (armyId: string) -> (),
}

type Token = {
	houseId: string, -- the house whose banner and crest it shows
	button: TextButton,
	banner: Frame,
	edge: UIStroke,
	count: TextLabel,
	pole: Frame,
	target: UDim2?, -- the position last assigned or tweened to
}

type LegDot = { dot: Frame, t: number }

type Route = {
	holder: Frame,
	key: string, -- the orders, leg, zoom bucket and viewer it was drawn for
	dots: { Frame }, -- every dot frame of the holder: the first `used` are drawn, the rest spare
	used: number,
	legDots: { LegDot }, -- dots on the current leg, with their share of it
	progress: number, -- share of the current leg behind the army when the dots were last hidden
}

local ArmyLayer = {}

local MAP_WIDTH = MapData.width
local MAP_HEIGHT = MapData.height

-- Tokens (virtual pixels, constant on screen).
local TOKEN_WIDTH = 82
local TOKEN_HEIGHT = 30
local LIFT = 14 -- bottom of the lowest token above the army's point (the holding icon is 14 px)
local STACK_GAP = 3
local POLE_LENGTH = 6
local COUNT_TEXT_SIZE = 19
local EDGE = Color3.fromRGB(28, 22, 18)
local EDGE_THICKNESS = 1.5
local SELECTED_THICKNESS = 2.5

-- Routes.
local DOT_SPACING = 14 -- on-screen pixels between dots
local DOT_SIZE = 6
local MAX_DOTS = 320 -- per route; the spacing widens beyond it
local BUCKETS_PER_DOUBLING = 4 -- zoom buckets: the spacing stays within about 19% of DOT_SPACING
local CHEVRON_LENGTH = 10
local CHEVRON_HALF_WIDTH = 7
local OWN_ROUTE = Colors.GoldBright
local FOREIGN_ROUTE = Color3.fromRGB(226, 112, 96)

local surface: Surface
local armyLayer: Frame
local routeLayer: Frame
local tokens: { [string]: Token } = {}
local routes: { [string]: Route } = {}
local selectedId: string? = nil
local zoomBucket = 0
local hoveredButton: TextButton? = nil
local wasPaused = true -- the clock's state at the last refresh

-- Geometry -----------------------------------------------------------------------------------------

local function pointOfProvince(provinceId: string?): Vector2?
	local definition = provinceId and Content.provinces[provinceId]
	return if definition then Vector2.new(definition.position.x, definition.position.y) else nil
end

local function lerp(a: Vector2, b: Vector2, t: number): Vector2
	return a + (b - a) * t
end

local function length(v: Vector2): number
	return math.sqrt(v.X * v.X + v.Y * v.Y)
end

-- Share of the current leg already behind the army on `day` (0 when not marching).
local function legProgress(army: { [string]: any }, day: number?): number
	local start, finish = army.legStartDay, army.legEndDay
	if day == nil or start == nil or finish == nil then
		return 0
	end
	return math.clamp((day - start) / math.max(1, finish - start), 0, 1)
end

--[[
	The army's map point on `day`. Marching: along the current leg, then along the following land
	legs, which the server starts on the day of arrival (a sea leg may wait for ships, so the point
	stops at the port). Idle, waiting, or without a day number: its location.
]]
local function pointAt(army: { [string]: any }, day: number?): Vector2
	local here = pointOfProvince(army.locationId) or Vector2.zero
	local route: { string } = army.route
	local start, finish = army.legStartDay, army.legEndDay
	if #route == 0 or start == nil or finish == nil or day == nil then
		return here
	end
	local from, to = here, pointOfProvince(route[1]) or here
	local index = 1
	while day >= finish and index < #route do
		local fromId, nextId = route[index], route[index + 1]
		local definition = Content.provinces[fromId]
		local days = MilitaryRules.legDays(fromId, nextId, army.units, GameConfig.Military)
		if not definition or definition.adjacent[nextId] == "sea" or not days then
			return to
		end
		start, finish = finish, finish + days
		from, to = to, pointOfProvince(nextId) or to
		index += 1
	end
	return lerp(from, to, math.clamp((day - start) / math.max(1, finish - start), 0, 1))
end

-- Armies that stand together share a stack: idle or waiting ones by province, marching ones by leg.
local function stackKey(army: { [string]: any }): string
	if army.legStartDay ~= nil and #army.route > 0 then
		return `{army.locationId}>{army.route[1]}@{army.legStartDay}`
	end
	return army.locationId
end

local function sortedArmyIds(armies: { [string]: any }): { string }
	local ids = {}
	for armyId in armies do
		table.insert(ids, armyId)
	end
	table.sort(ids)
	return ids
end

local function houseColor(houseId: string): Color3
	local house = Content.houses[houseId]
	return if house then Theme.fromRGB(house.mapColor) else Colors.Disabled
end

-- Tokens -------------------------------------------------------------------------------------------

local function styleToken(token: Token, selected: boolean)
	token.edge.Color = if selected then Colors.GoldBright else EDGE
	token.edge.Thickness = if selected then SELECTED_THICKNESS else EDGE_THICKNESS
	token.button.ZIndex = if selected then 2 else 1
end

local function createToken(army: { [string]: any }): Token
	local armyId: string = army.id
	local color = houseColor(army.houseId)
	local textColor, halo = MapStyle.contrast(color)
	local button = UI.create("TextButton", {
		Name = `Army_{armyId}`,
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.fromOffset(TOKEN_WIDTH, TOKEN_HEIGHT),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 1,
		Parent = armyLayer,
	})
	local banner = UI.create("Frame", {
		Name = "Banner",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Active = false,
		Parent = button,
	})
	UI.corner(banner, 4)
	local edge = UI.create("UIStroke", {
		Color = EDGE,
		Thickness = EDGE_THICKNESS,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = banner,
	})
	SigilView.new(army.houseId, {
		name = "Crest",
		detail = "low",
		size = UDim2.fromOffset(20, 24),
		position = UDim2.fromOffset(4, 3),
		fallbackColor = color:Lerp(EDGE, 0.35),
		zIndex = 2,
		parent = banner,
	})
	local count = UI.create("TextLabel", {
		Name = "Count",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(26, 1),
		Size = UDim2.new(1, -30, 1, -2),
		FontFace = Fonts.BodyBold,
		TextScaled = true,
		TextSize = COUNT_TEXT_SIZE,
		TextColor3 = textColor,
		Text = Format.troops(army.troops),
		ZIndex = 3,
		Parent = banner,
	})
	UI.create("UITextSizeConstraint", { MaxTextSize = COUNT_TEXT_SIZE, MinTextSize = 10, Parent = count })
	UI.create("UIStroke", {
		Color = halo,
		Thickness = 1,
		Transparency = 0.35,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = count,
	})
	-- A short staff from the lowest banner of a stack towards the army's point.
	local pole = UI.create("Frame", {
		Name = "Pole",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(2, POLE_LENGTH),
		BackgroundColor3 = EDGE,
		BorderSizePixel = 0,
		Active = false,
		Parent = button,
	})

	button.InputBegan:Connect(function(input)
		surface.beginDrag(input, true)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			surface.commandArmy(armyId)
		end
	end)
	button.MouseEnter:Connect(function()
		hoveredButton = button
		surface.hover(button, true)
	end)
	button.MouseLeave:Connect(function()
		if hoveredButton == button then
			hoveredButton = nil
		end
		surface.hover(button, false)
	end)
	button.Activated:Connect(function()
		surface.onSelectArmy(armyId)
	end)
	Tooltip.bind(button, function()
		local current = surface.store:army(armyId)
		return if current then ArmyInfo.tooltip(surface.store, current) else nil
	end)

	local token: Token = { houseId = army.houseId, button = button, banner = banner, edge = edge, count = count, pole = pole, target = nil }
	styleToken(token, armyId == selectedId)
	return token
end

local function destroyToken(armyId: string)
	local token = tokens[armyId]
	if not token then
		return
	end
	if hoveredButton == token.button then
		hoveredButton = nil
		surface.hover(token.button, false)
	end
	token.button:Destroy()
	tokens[armyId] = nil
end

-- Snaps a token into place, cancelling any tween still running on it (a new tween on the same
-- property replaces the old one), and assigns the position directly as well.
local function snap(token: Token, target: UDim2)
	TweenService:Create(token.button, TweenInfo.new(0), { Position = target }):Play()
	token.button.Position = target
	token.target = target
end

local function glide(token: Token, target: UDim2, seconds: number)
	TweenService:Create(token.button, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Position = target }):Play()
	token.target = target
end

--[[
	Places every token: snapped when `snapAll`, when the clock is paused or for a new token,
	otherwise tweened towards its point `ahead` days from now. Tokens whose target did not change
	are left alone.
]]
local function placeTokens(snapAll: boolean)
	local store = surface.store
	local armies: { [string]: any } = store.campaign.armies or {}
	local clock = store.campaign.clock
	local today: number? = if clock then clock.dayNumber else nil
	local paused = clock == nil or clock.paused == true or today == nil
	local secondsPerDay = GameConfig.Clock.SecondsPerDay[if clock then clock.speed else 1] or GameConfig.Clock.SecondsPerDay[1]
	local ahead = math.max(1, math.ceil(GameConfig.Network.ReplicationInterval / secondsPerDay))
	local stacks: { [string]: number } = {}
	for _, armyId in sortedArmyIds(armies) do
		local army = armies[armyId]
		local token = tokens[armyId]
		if token then
			local key = stackKey(army)
			local index = stacks[key] or 0
			stacks[key] = index + 1
			local day = if paused or today == nil then today else today + ahead
			local point = pointAt(army, day)
			local target = UDim2.new(point.X / MAP_WIDTH, 0, point.Y / MAP_HEIGHT, -(LIFT + index * (TOKEN_HEIGHT + STACK_GAP)))
			token.pole.Visible = index == 0
			if snapAll or token.target == nil then
				snap(token, target)
			elseif target ~= token.target then
				if paused then
					snap(token, target)
				else
					glide(token, target, ahead * secondsPerDay)
				end
			end
		end
	end
end

-- Routes -------------------------------------------------------------------------------------------

local function bucketZoom(): number
	return 2 ^ (zoomBucket / BUCKETS_PER_DOUBLING)
end

local function routeShown(army: { [string]: any }): boolean
	if #army.route == 0 then
		return false
	end
	return army.id == selectedId or army.houseId == surface.store:myHouseId()
end

local function routeKey(army: { [string]: any }): string
	return table.concat({
		army.locationId,
		table.concat(army.route, ","),
		tostring(army.legStartDay),
		tostring(army.legEndDay),
		tostring(zoomBucket),
		tostring(army.houseId == surface.store:myHouseId()),
	}, "|")
end

local function newDot(holder: Frame): Frame
	local frame = UI.create("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE),
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 1,
		Parent = holder,
	})
	UI.create("UICorner", { CornerRadius = UDim.new(1, 0), Parent = frame })
	UI.create("UIStroke", { Color = EDGE, Thickness = 1, Transparency = 0.2, Parent = frame })
	return frame
end

-- An open chevron pointing along from -> to, with its tip on `to` (constant size on screen).
local function chevron(holder: Frame, from: Vector2, to: Vector2, color: Color3)
	local direction = to - from
	local size = length(direction)
	local dx, dy = 0, 1
	if size > 1e-6 then
		dx, dy = direction.X / size, direction.Y / size
	end
	local function at(back: number, side: number): Path2DControlPoint
		local ox = -dx * back - dy * side
		local oy = -dy * back + dx * side
		return Path2DControlPoint.new(UDim2.new(to.X / MAP_WIDTH, ox, to.Y / MAP_HEIGHT, oy))
	end
	local points = { at(CHEVRON_LENGTH, CHEVRON_HALF_WIDTH), at(0, 0), at(CHEVRON_LENGTH, -CHEVRON_HALF_WIDTH) }
	for index, style in { { color = EDGE, thickness = 5, z = 2 }, { color = color, thickness = 2.5, z = 3 } } do
		local path = Instance.new("Path2D")
		path.Name = if index == 1 then "ArrowEdge" else "Arrow"
		path.Color3 = style.color
		path.Thickness = style.thickness
		path.Closed = false
		path.ZIndex = style.z
		path:SetControlPoints(points)
		path.Parent = holder
	end
end

--[[
	Draws an army's route. Given the route drawn before (`previous`), it redraws in the same holder,
	reusing its dot frames: they move to their new points, extra ones are created only when this
	drawing needs more, and the rest are hidden as spares (named "Spare").
]]
local function drawRoute(army: { [string]: any }, previous: Route?): Route
	local holder: Frame
	local pool: { Frame }
	if previous then
		holder = previous.holder
		pool = previous.dots
		for _, child in holder:GetChildren() do
			if child:IsA("Path2D") then
				child:Destroy() -- the old chevron
			end
		end
	else
		holder = UI.create("Frame", {
			Name = `Route_{army.id}`,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Active = false,
			Parent = routeLayer,
		})
		pool = {}
	end
	local used = 0
	local function dot(point: Vector2, color: Color3): Frame
		used += 1
		local frame = pool[used]
		if frame == nil then
			frame = newDot(holder)
			pool[used] = frame
		end
		frame.Name = "Dot"
		frame.Position = surface.scalePosition(point.X, point.Y)
		frame.BackgroundColor3 = color
		frame.Visible = true
		return frame
	end
	local color = if army.houseId == surface.store:myHouseId() then OWN_ROUTE else FOREIGN_ROUTE
	local stops: { Vector2 } = { pointOfProvince(army.locationId) or Vector2.zero }
	local total = 0
	for _, stopId in army.route do
		local point = pointOfProvince(stopId) or stops[#stops]
		total += length(point - stops[#stops])
		table.insert(stops, point)
	end
	-- Map units between dots: DOT_SPACING on screen at this zoom bucket, wider for very long routes.
	local spacing = math.max(DOT_SPACING / bucketZoom(), total / MAX_DOTS)
	local legDots: { LegDot } = {}
	local offset = spacing * 0.6 -- distance into the segment of its first dot
	for segment = 1, #stops - 1 do
		local a, b = stops[segment], stops[segment + 1]
		local span = length(b - a)
		local last = segment == #stops - 1
		-- Keep the last dots clear of the chevron.
		local limit = if last then span - spacing * 0.6 else span
		local distance = offset
		while distance <= limit and span > 0 do
			local t = distance / span
			local frame = dot(lerp(a, b, t), color)
			if segment == 1 then
				table.insert(legDots, { dot = frame, t = t })
			end
			distance += spacing
		end
		offset = distance - span
	end
	for index = used + 1, #pool do
		pool[index].Name = "Spare"
		pool[index].Visible = false
	end
	if #stops >= 2 then
		chevron(holder, stops[#stops - 1], stops[#stops], color)
	end
	return { holder = holder, key = routeKey(army), dots = pool, used = used, legDots = legDots, progress = -1 }
end

-- Hides the current leg's dots that the army has already passed.
local function hidePassedDots(route: Route, army: { [string]: any }, today: number?)
	local progress = legProgress(army, today)
	if progress == route.progress then
		return
	end
	route.progress = progress
	for _, entry in route.legDots do
		entry.dot.Visible = entry.t > progress
	end
end

local function destroyRoute(armyId: string)
	local route = routes[armyId]
	if route then
		route.holder:Destroy()
		routes[armyId] = nil
	end
end

local function updateRoutes(rebuildAll: boolean)
	local store = surface.store
	local armies: { [string]: any } = store.campaign.armies or {}
	local today = ArmyInfo.today(store)
	for armyId in routes do
		local army = armies[armyId]
		if army == nil or not routeShown(army) then
			destroyRoute(armyId)
		end
	end
	for _, armyId in sortedArmyIds(armies) do
		local army = armies[armyId]
		if routeShown(army) then
			local route = routes[armyId]
			if route == nil or rebuildAll or route.key ~= routeKey(army) then
				route = drawRoute(army, route)
				routes[armyId] = route
			end
			hidePassedDots(route :: Route, army, today)
		end
	end
end

-- Public -------------------------------------------------------------------------------------------

function ArmyLayer.mount(mapSurface: Surface)
	surface = mapSurface
	routeLayer = surface.layer("Routes", 10)
	armyLayer = surface.layer("Armies", 11)
end

-- Applies replicated changes: creates, updates and removes tokens, moves them and redraws routes.
function ArmyLayer.refresh(changes: ReplicaStore.ChangeSet)
	local store = surface.store
	local armies: { [string]: any } = store.campaign.armies or {}
	-- A full snapshot, or the session change on returning from the lobby (snapshots that arrive
	-- in the lobby never reach the map), may have replaced every army: reconcile all tokens.
	local reconcile = changes.full or changes.session
	local structural = reconcile or next(changes.armies) ~= nil
	if not structural and not changes.clock then
		return
	end
	-- Drop the tokens of armies that are gone, and of ids now held by another house's army (a
	-- loaded campaign reuses ids), whose banner, crest and colours would be wrong.
	local function stale(armyId: string): boolean
		local army = armies[armyId]
		local token = tokens[armyId]
		return token ~= nil and (army == nil or army.houseId ~= token.houseId)
	end
	if reconcile then
		for armyId in tokens do
			if stale(armyId) then
				destroyToken(armyId)
			end
		end
	end
	for armyId in changes.armies do
		if stale(armyId) then
			destroyToken(armyId)
		end
	end
	if structural then
		for _, armyId in sortedArmyIds(armies) do
			local army = armies[armyId]
			local token = tokens[armyId]
			if token == nil then
				tokens[armyId] = createToken(army)
			elseif reconcile or changes.armies[armyId] then
				token.count.Text = Format.troops(army.troops)
			end
		end
	end
	-- The moment the clock stops, every token snaps to where its army is today, cutting short any
	-- tween towards a point a few days ahead.
	local clock = store.campaign.clock
	local paused = clock == nil or clock.paused == true
	local justPaused = paused and not wasPaused
	wasPaused = paused
	placeTokens(changes.full or justPaused)
	updateRoutes(reconcile)
end

-- Highlights the selected army (nil clears it) and shows its route.
function ArmyLayer.select(armyId: string?)
	selectedId = armyId
	for id, token in tokens do
		styleToken(token, id == armyId)
	end
	if surface then
		updateRoutes(false)
	end
end

-- Called whenever the map zoom changes; routes are redrawn when the zoom bucket changes.
function ArmyLayer.setZoom(zoom: number)
	local bucket = math.floor(math.log(math.max(zoom, 1e-3), 2) * BUCKETS_PER_DOUBLING + 0.5)
	if bucket ~= zoomBucket then
		zoomBucket = bucket
		if surface then
			updateRoutes(false)
		end
	end
end

-- The army's map point today (map units), or nil when the army is unknown.
function ArmyLayer.pointOf(armyId: string): Vector2?
	local army = surface and surface.store:army(armyId)
	if not army then
		return nil
	end
	return pointAt(army, ArmyInfo.today(surface.store))
end

return ArmyLayer
