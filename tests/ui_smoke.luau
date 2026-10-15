--[[
	UI smoke test (Lune): runs the real client code against the real server pipeline, headlessly.

	How it works:
	  * Every Instance the client creates is a real @lune/roblox Instance behind a thin proxy, so
	    every property assignment is validated against Roblox's reflection database (unknown
	    property names and wrong value types raise errors).
	  * The proxy emulates what Lune lacks: signals (Activated, MouseEnter, ...), attribute and
	    property-changed signals, AbsoluteSize, Players.LocalPlayer, UserInputService, TweenService,
	    GuiService.MenuOpened.
	  * RemoteFunction:InvokeServer is routed to an in-process CampaignHost; replication messages
	    are deep-copied (as the network would) and fired through StateDelta.OnClientEvent.
	  * The test then plays the core loop by "clicking" real buttons found by their text.

	It verifies that the client code runs without errors and that clicks produce the right server
	requests and on-screen results. Visual layout and real input devices still need Studio
	(docs/TEST_PLAN.md).

	Usage:
	  rojo build default.project.json -o build/IronThrone.rbxl
	  lune run tests/ui_smoke.luau build/IronThrone.rbxl
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local placePath = process.args[1] or "build/IronThrone.rbxl"
local place = roblox.deserializePlace(fs.readFile(placePath))

local failures = 0
local handlerErrors = {}
local function check(condition: any, message: string)
	if condition then
		print(`  ok    {message}`)
	else
		failures += 1
		print(`  FAIL  {message}`)
	end
end

-- Signals --------------------------------------------------------------------------------------

local function newSignal()
	local handlers = {}
	local signal = {}
	function signal:Connect(fn)
		local entry = { fn = fn, connected = true }
		table.insert(handlers, entry)
		return {
			Disconnect = function()
				entry.connected = false
			end,
		}
	end
	function signal:Fire(...)
		for _, entry in table.clone(handlers) do
			if entry.connected then
				local ok, err = xpcall(entry.fn, debug.traceback, ...)
				if not ok then
					table.insert(handlerErrors, tostring(err))
				end
			end
		end
	end
	-- How many handlers are connected (the test's view of whether anything listens).
	function signal:connectedCount(): number
		local count = 0
		for _, entry in handlers do
			if entry.connected then
				count += 1
			end
		end
		return count
	end
	return signal
end

-- Instance proxies -----------------------------------------------------------------------------

local EVENTS = {
	MouseEnter = true, MouseLeave = true, Activated = true, MouseButton1Click = true, InputBegan = true,
	InputChanged = true, InputEnded = true, TouchLongPress = true, AncestryChanged = true, Changed = true,
	OnClientEvent = true, OnServerEvent = true, ChildAdded = true, ChildRemoved = true,
}
local VIEWPORT = roblox.Vector2.new(1280, 720)

local reals = setmetatable({}, { __mode = "k" })
local sizeOverrides = setmetatable({}, { __mode = "k" }) -- AbsoluteSize of a proxy other than VIEWPORT
local proxies = setmetatable({}, { __mode = "k" })
local signals = setmetatable({}, { __mode = "k" })
local remoteRouter: { [string]: (...any) -> ...any } = {}

local wrap
local function unwrap(value)
	if type(value) == "table" and reals[value] then
		return reals[value]
	end
	return value
end

local function signalFor(proxy, key: string)
	local set = signals[proxy]
	if not set then
		set = {}
		signals[proxy] = set
	end
	if not set[key] then
		set[key] = newSignal()
	end
	return set[key]
end

local methods = {}
function methods.WaitForChild(self, name)
	local child = reals[self]:FindFirstChild(name)
	if not child then
		error(`WaitForChild would wait forever for {name} under {reals[self]:GetFullName()}`, 2)
	end
	return wrap(child)
end
function methods.FindFirstChild(self, name, recursive)
	local child = reals[self]:FindFirstChild(name, recursive)
	return child and wrap(child)
end
function methods.GetChildren(self)
	local list = {}
	for _, child in reals[self]:GetChildren() do
		table.insert(list, wrap(child))
	end
	return list
end
function methods.GetDescendants(self)
	local list = {}
	for _, child in reals[self]:GetDescendants() do
		table.insert(list, wrap(child))
	end
	return list
end
function methods.IsA(self, className)
	return reals[self]:IsA(className)
end
function methods.Destroy(self)
	reals[self]:Destroy()
end
function methods.ClearAllChildren(self)
	reals[self]:ClearAllChildren()
end
function methods.IsDescendantOf(self, other)
	local target = unwrap(other)
	if type(target) == "table" then
		return true -- the fake DataModel
	end
	return reals[self]:IsDescendantOf(target)
end
function methods.GetFullName(self)
	return reals[self]:GetFullName()
end
function methods.SetAttribute(self, name, value)
	reals[self]:SetAttribute(name, value)
	signalFor(self, `attr:{name}`):Fire()
end
function methods.GetAttribute(self, name)
	return reals[self]:GetAttribute(name)
end
function methods.GetAttributeChangedSignal(self, name)
	return signalFor(self, `attr:{name}`)
end
function methods.GetPropertyChangedSignal(self, name)
	return signalFor(self, `prop:{name}`)
end
-- Path2D's control points are a datatype Lune does not have; the shim keeps them on the proxy.
local controlPoints = setmetatable({}, { __mode = "k" })
function methods.SetControlPoints(self, points)
	assert(reals[self].ClassName == "Path2D", "SetControlPoints on a non-Path2D")
	assert(type(points) == "table" and #points >= 2, "a Path2D needs at least two control points")
	for _, point in points do
		assert(type(point) == "table" and point.isControlPoint, "control points must be Path2DControlPoint values")
	end
	controlPoints[self] = points
end
function methods.GetControlPoints(self)
	return controlPoints[self] or {}
end
function methods.GetMaxControlPoints(_self)
	return 64 -- small, so the test also exercises splitting long outlines
end
function methods.InvokeServer(self, ...)
	local route = remoteRouter[reals[self].Name]
	assert(route, `no server route for remote {reals[self].Name}`)
	return route(...)
end

local Proxy = {}
Proxy.__index = function(self, key)
	local method = methods[key]
	if method then
		return method
	end
	if EVENTS[key] then
		return signalFor(self, key)
	end
	if key == "AbsoluteSize" then
		return sizeOverrides[self] or VIEWPORT
	elseif key == "AbsolutePosition" then
		return roblox.Vector2.zero
	end
	local real = reals[self]
	local value = real[key]
	if typeof(value) == "Instance" then
		return wrap(value)
	end
	return value
end
Proxy.__newindex = function(self, key, value)
	local real = reals[self]
	real[key] = unwrap(value)
	local set = signals[self]
	if set and set[`prop:{key}`] then
		set[`prop:{key}`]:Fire()
	end
end
Proxy.__tostring = function(self)
	return reals[self].Name
end

wrap = function(real)
	local proxy = proxies[real]
	if not proxy then
		proxy = setmetatable({}, Proxy)
		proxies[real] = proxy
		reals[proxy] = real
	end
	return proxy
end

local ShimInstance = {
	new = function(className, parent)
		local proxy = wrap(roblox.Instance.new(className))
		if parent then
			proxy.Parent = parent
		end
		return proxy
	end,
}

-- Fake engine services -------------------------------------------------------------------------

local playerGui = wrap(roblox.Instance.new("Folder"))
playerGui.Name = "PlayerGui"
local camera = { ViewportSize = VIEWPORT }
function camera:GetPropertyChangedSignal()
	return newSignal()
end
local services = {
	Players = {
		LocalPlayer = {
			Name = "Tester",
			DisplayName = "Tester",
			UserId = 1,
			WaitForChild = function(_, name)
				assert(name == "PlayerGui", name)
				return playerGui
			end,
		},
	},
	UserInputService = {
		InputBegan = newSignal(),
		InputChanged = newSignal(),
		InputEnded = newSignal(),
		TouchPinch = newSignal(),
		GetMouseLocation = function()
			return roblox.Vector2.zero
		end,
	},
	TweenService = {
		Create = function()
			return { Play = function() end }
		end,
	},
	StarterGui = { SetCoreGuiEnabled = function() end },
	-- The Roblox menu (Esc opens it); the test fires MenuOpened to stand for it.
	GuiService = { MenuOpened = newSignal() },
	Workspace = {
		CurrentCamera = camera,
		GetPropertyChangedSignal = function()
			return newSignal()
		end,
	},
	RunService = {
		IsStudio = function()
			return true
		end,
		-- Frames: the test fires RenderStepped itself (settle(), below).
		RenderStepped = newSignal(),
	},
}

-- Runs frames of 1/60 s until the map camera's motion has ended (it disconnects from
-- RenderStepped then); at most ten seconds of frames. Returns whether it ended.
local renderStepped = services.RunService.RenderStepped
local function settle(): boolean
	for _ = 1, 600 do
		if renderStepped:connectedCount() == 0 then
			return true
		end
		renderStepped:Fire(1 / 60)
	end
	return renderStepped:connectedCount() == 0
end
local fakeGame = {}
function fakeGame:GetService(name)
	if services[name] then
		return services[name]
	end
	return wrap(place:GetService(name))
end

-- Module loader --------------------------------------------------------------------------------

local datatypes = {
	"Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Enum", "Faces", "Font",
	"NumberRange", "NumberSequence", "NumberSequenceKeypoint", "Rect", "UDim", "UDim2", "Vector2", "Vector3",
}
local cache = {}
local function requireModule(module)
	local real = unwrap(module)
	if cache[real] then
		return cache[real].value
	end
	assert(real.ClassName == "ModuleScript", `require target {real:GetFullName()} is not a ModuleScript`)
	local env = {
		script = wrap(real),
		game = fakeGame,
		workspace = services.Workspace,
		require = requireModule,
		Instance = ShimInstance,
		task = task,
		warn = function(...)
			local parts = table.pack(...)
			local text = {}
			for i = 1, parts.n do
				table.insert(text, tostring(parts[i]))
			end
			table.insert(handlerErrors, table.concat(text, " "))
		end,
	}
	for _, name in datatypes do
		env[name] = (roblox :: any)[name]
	end
	env.Path2DControlPoint = {
		new = function(position, left, right)
			assert(typeof(position) == "UDim2", "Path2DControlPoint position must be a UDim2")
			return { isControlPoint = true, Position = position, LeftTangent = left, RightTangent = right }
		end,
	}
	-- Lune has no TweenInfo datatype; tweens are inert in this test (TweenService is faked).
	env.TweenInfo = {
		new = function(...)
			return table.pack(...)
		end,
	}
	local value = luau.load(real.Source, { debugName = real:GetFullName(), environment = env })()
	cache[real] = { value = value }
	return value
end

local function requirePath(path: string)
	local node = place
	for part in string.gmatch(path, "[^%.]+") do
		node = node:FindFirstChild(part) or error(`missing {part} in {path}`)
	end
	return requireModule(node)
end

-- Server: an in-process campaign host with in-memory persistence -------------------------------

local GameConfig = requirePath("ReplicatedStorage.Shared.Config.GameConfig")
local Diagnostics = requirePath("ServerScriptService.Simulation.Diagnostics")
local CampaignHost = requirePath("ServerScriptService.App.CampaignHost")
local CampaignRepository = requirePath("ServerScriptService.App.CampaignRepository")
local InMemoryBackend = requirePath("ServerScriptService.App.InMemoryBackend")
local Protocol = requirePath("ReplicatedStorage.Shared.Net.Protocol")

local codec = {
	encode = function(value)
		return serde.encode("json", value)
	end,
	decode = function(text)
		return serde.decode("json", text)
	end,
}
local clock = { now = 0 }
local serverLog = {}
local backend = InMemoryBackend.new(codec)
local host = CampaignHost.new({
	config = GameConfig,
	environment = "development",
	seed = 1337,
	campaignId = "ui-smoke",
	now = function()
		return clock.now
	end,
	wallClock = function()
		return 1700000000
	end,
	diagnostics = Diagnostics.new(function(level, line)
		table.insert(serverLog, `{level}: {line}`)
	end, function()
		return clock.now
	end, 0),
	repository = CampaignRepository.new({
		backend = backend,
		codec = codec,
		config = GameConfig.Persistence,
		sleep = function() end,
		sessionId = "ui-smoke",
	}),
	persistence = { available = true, backendName = backend.name, persistent = false, reason = "in-memory storage" },
})

-- Remotes as the server would create them.
local net = roblox.Instance.new("Folder")
net.Name = Protocol.RemoteFolderName
for _, spec in { { "RemoteFunction", Protocol.Remotes.Command }, { "RemoteFunction", Protocol.Remotes.Sync }, { "RemoteEvent", Protocol.Remotes.StateDelta } } do
	local remote = roblox.Instance.new(spec[1])
	remote.Name = spec[2]
	remote.Parent = net
end
net.Parent = place:GetService("ReplicatedStorage")

local function networkCopy(value)
	return serde.decode("json", serde.encode("json", value))
end
local requestLog = {}
remoteRouter[Protocol.Remotes.Command] = function(commandName, payload)
	table.insert(requestLog, commandName)
	return networkCopy(host:handleRequest(1, commandName, networkCopy(payload)))
end
remoteRouter[Protocol.Remotes.Sync] = function()
	return networkCopy(host:requestSync(1))
end
local deltaRemote = wrap(net:FindFirstChild(Protocol.Remotes.StateDelta))

local function pump()
	for _, message in host:collectReplication(true) do
		if message.userId == 1 then
			deltaRemote.OnClientEvent:Fire(networkCopy(message.payload))
		end
	end
end

-- Client --------------------------------------------------------------------------------------

host:playerJoined(1, "Tester")
local NetClient = requirePath("StarterPlayer.StarterPlayerScripts.Controllers.NetClient")
local StateController = requirePath("StarterPlayer.StarterPlayerScripts.Controllers.StateController")
local UIController = requirePath("StarterPlayer.StarterPlayerScripts.Controllers.UIController")

print("Client startup")
NetClient.connect()
UIController.start()
StateController.start()
pump()

local store = StateController.store
check(store.ready, "client received the full snapshot")

local function guiRoot()
	return playerGui:FindFirstChild("IronThroneMain")
end

local function findByText(text: string, className: string?)
	for _, descendant in reals[playerGui]:GetDescendants() do
		local ok, value = pcall(function()
			return descendant.Text
		end)
		if ok and value == text and (className == nil or descendant.ClassName == className) then
			local visible = true
			local node = descendant
			while node and node ~= reals[playerGui] do
				local hasVisible, isVisible = pcall(function()
					return node.Visible
				end)
				if hasVisible and isVisible == false then
					visible = false
					break
				end
				node = node.Parent
			end
			if visible then
				return wrap(descendant)
			end
		end
	end
	return nil
end

local function findContaining(fragment: string)
	for _, descendant in reals[playerGui]:GetDescendants() do
		local ok, value = pcall(function()
			return descendant.Text
		end)
		if ok and type(value) == "string" and string.find(value, fragment, 1, true) then
			return wrap(descendant)
		end
	end
	return nil
end

local function click(button)
	button.Activated:Fire()
	pump()
end

-- Lobby: choose House Stark.
local lobby = guiRoot().Root.Lobby
check(lobby.Visible, "lobby is shown before a house is chosen")
local starkName = findByText("House Stark", "TextLabel")
check(starkName ~= nil, "lobby lists House Stark")
click(starkName.Parent)
local lead = findByText("Lead House Stark", "TextButton")
check(lead ~= nil, "selecting the card shows 'Lead House Stark'")
click(lead)
check(store:myHouseId() == "stark", "server confirmed the house selection")
check(guiRoot().Root.Game.Visible and not lobby.Visible, "game screen replaced the lobby")
-- The first view glides to the house seat: a flight on RenderStepped, then it lets go.
local startSettled = renderStepped:connectedCount() == 1 and settle()
check(findByText("House Stark", "TextLabel") ~= nil, "top bar shows the house")
check(findByText("1 January 297 AC", "TextLabel") ~= nil, "top bar shows the campaign date")
check(findByText("140.0", "TextLabel") ~= nil, "top bar shows the starting treasury")

-- Province inspection and development (Winterfell is pre-selected as the seat).
check(findByText("Winterfell", "TextLabel") ~= nil, "province panel shows the seat")
local develop = findByText("Develop (44 gold)", "TextButton")
check(develop ~= nil, "Develop button shows the server-supplied cost")
click(develop)
check(store:province("winterfell").development == 5, "development rose to 5")
check(findByText("5 / 10", "TextLabel") ~= nil, "province panel shows the new development")
check(findByText("96.0", "TextLabel") ~= nil, "treasury dropped by the cost")

-- Inspect a foreign province by clicking its map node.
local riverrunNode = guiRoot():FindFirstChild("Province_riverrun", true)
check(riverrunNode ~= nil, "map has a node for Riverrun")
click(riverrunNode)
check(findByText("House Tully", "TextLabel") ~= nil, "province panel shows Riverrun's owner")
check(findByText("Develop (44 gold)", "TextButton") == nil, "no Develop button on a foreign province")

-- The world map: drawn land, crests and labels, then a click and a hover on the land itself.
local MapData = requirePath("ReplicatedStorage.Shared.Data.World.MapData")
local Content = requirePath("ReplicatedStorage.Shared.Data.Content")
local mapRoot = guiRoot():FindFirstChild("Map", true)
local fills = mapRoot:FindFirstChild("Fills")
local land = fills and fills:FindFirstChild("Land")
local function countWedges(model): number
	local count = 0
	for _, part in reals[model]:GetDescendants() do
		if part.ClassName == "WedgePart" then
			count += 1
		end
	end
	return count
end
local wedgeCount = countWedges(land)
check(wedgeCount > 4000 and land:FindFirstChild(MapData.subTerritories[1].id) ~= nil, `map land is drawn with flat triangles, grouped by sub-territory ({wedgeCount} wedges)`)
local crestCount = 0
local crestIds = {}
for _, house in MapData.houses do
	table.insert(crestIds, house.id)
end
table.insert(crestIds, "crownlands")
for _, id in crestIds do
	local crest = mapRoot:FindFirstChild(`Crest_{id}`, true)
	if crest and #reals[crest]:FindFirstChild("Art"):GetChildren() > 0 then
		crestCount += 1
	end
end
check(crestCount == 9, `eight great-house crests and the crown's are drawn ({crestCount})`)
check(findByText("STARK", "TextLabel") ~= nil and findByText("THE CROWN", "TextLabel") ~= nil, "great-house labels and the Crownlands title are shown")
check(findByText("TARGARYEN", "TextLabel") == nil, "no Targaryen label in 297 AC")
local subBorders = mapRoot:FindFirstChild("SubBorders", true)
local paths = 0
for _, line in reals[subBorders]:GetChildren() do
	if line.ClassName == "Path2D" then
		paths += 1
	end
end
check(paths >= #MapData.subTerritories, `sub-territory borders are drawn ({paths} paths)`)

-- The view, read exactly from the top-down camera of the map's fills (the canvas above them is
-- placed in whole pixels): the map point in the middle of the map area and the zoom (UI scale 1).
local function mapView()
	local camera = fills:FindFirstChild("Camera")
	local area = mapRoot.AbsoluteSize
	local position = camera.CFrame.Position
	local zoom = area.Y / (2 * math.tan(math.rad(camera.FieldOfView) / 2) * position.Y)
	return roblox.Vector2.new(position.X, position.Z), zoom, area
end
local function canvasZoom(): number
	local _, zoom = mapView()
	return zoom
end
-- Screen position of a map point.
local function screenAt(x: number, y: number)
	local centre, zoom, area = mapView()
	local point = area / 2 + (roblox.Vector2.new(x, y) - centre) * zoom
	return roblox.Vector3.new(point.X, point.Y, 0)
end
local MapController = requirePath("StarterPlayer.StarterPlayerScripts.Controllers.MapController")
local MapConfig = requirePath("StarterPlayer.StarterPlayerScripts.UI.MapConfig")
local winterfellAt = screenAt(Content.provinces.winterfell.position.x, Content.provinces.winterfell.position.y)
check(startSettled and renderStepped:connectedCount() == 0, "the first view glides to the seat and lets go of RenderStepped when it lands")
-- (The start zoom counts from the whole-map view: the 720 px map area's height over the frame's.)
check(math.abs(canvasZoom() - MapConfig.Camera.StartZoom * 720 / (MapConfig.View.Bounds.maxY - MapConfig.View.Bounds.minY) * MapConfig.View.FitMargin) < 1e-6
	and MapController.zoomLevel() == "political" and winterfellAt.X > 0 and winterfellAt.X < 1280 and winterfellAt.Y > 0 and winterfellAt.Y < 720,
	"the first view shows Winterfell at the start zoom, in the political look")
local UserInputService = services.UserInputService
local harrenhal = Content.provinces.harrenhal.position
local press = { UserInputType = roblox.Enum.UserInputType.MouseButton1, Position = screenAt(harrenhal.x, harrenhal.y) }
mapRoot:FindFirstChild("DragCatcher").InputBegan:Fire(press)
UserInputService.InputEnded:Fire(press)
pump()
check(findContaining("of Harrenhal ·") ~= nil, "clicking the land of Harrenhal selects it")
check(#reals[mapRoot:FindFirstChild("Selection", true)]:GetChildren() > 0, "the selected province is outlined")

mapRoot.MouseEnter:Fire()
local eyrie = Content.provinces.the_eyrie.position
UserInputService.InputChanged:Fire({ UserInputType = roblox.Enum.UserInputType.MouseMovement, Position = screenAt(eyrie.x, eyrie.y) })
check(mapRoot:FindFirstChild("Glow_vale", true).Visible == true, "hovering the Vale outlines the whole region")
check(mapRoot:FindFirstChild("Glow_north", true).Visible == false, "other regions are not outlined")
UserInputService.InputChanged:Fire({ UserInputType = roblox.Enum.UserInputType.MouseMovement, Position = screenAt(990, 20) })
check(mapRoot:FindFirstChild("Glow_vale", true).Visible == false, "moving over the sea clears the hover")
mapRoot.MouseLeave:Fire()

click(findByText("Sub-territory borders: on", "TextButton"))
check(subBorders.Visible == false, "the sub-territory border toggle hides the thin borders")
click(findByText("Sub-territory borders: off", "TextButton"))
check(subBorders.Visible == true, "and shows them again")
click(findByText("Terrain", "TextButton"))
click(findByText("Houses", "TextButton"))

-- Diplomacy: send an envoy to House Lannister.
click(findByText("Diplomacy", "TextButton"))
local lannisterRow = findByText("House Lannister", "TextLabel")
check(lannisterRow ~= nil, "diplomacy lists House Lannister")
click(lannisterRow.Parent)
local envoy = findByText("Send envoy (25 gold)", "TextButton")
check(envoy ~= nil, "envoy button is offered")
click(envoy)
local relation = store:relation("stark", "lannister")
check(relation and relation.score == 2, "relations with Lannister improved from -10 to 2")
check(findContaining("Relations: <b>2</b>") ~= nil, "diplomacy panel shows the new score")

-- Armies: raise Winterfell's levies, inspect the token and the Military tab, order a march.
local EventText = requirePath("ReplicatedStorage.Shared.Text.EventText")
local Commands = Protocol.Commands
local function countRequests(name: string): number
	local count = 0
	for _, entry in requestLog do
		if entry == name then
			count += 1
		end
	end
	return count
end
local function pressLand(position, inputType)
	local input = { UserInputType = inputType or roblox.Enum.UserInputType.MouseButton1, Position = position }
	mapRoot:FindFirstChild("DragCatcher").InputBegan:Fire(input)
	UserInputService.InputEnded:Fire(input)
	pump()
end
clock.now += 3 -- refill the request budget (8 requests, 3 per second)
click(guiRoot():FindFirstChild("Province_winterfell", true))
local winterfellLevies = store:province("winterfell").levies
check(findByText(`{EventText.troops(winterfellLevies)} / {EventText.troops(store:province("winterfell").leviesMax)}`, "TextLabel") ~= nil, "province panel shows Winterfell's levies")
local raise = findByText(`Raise levies here ({EventText.troops(winterfellLevies)} men)`, "TextButton")
check(raise ~= nil, "province panel offers 'Raise levies here' with the levy count")
check(findByText("Call all levies here", "TextButton") ~= nil, "province panel offers 'Call all levies here'")
click(raise)
local army = store:army("army_1")
check(table.find(requestLog, Commands.RaiseArmy) ~= nil and army ~= nil and army.troops == winterfellLevies, "RaiseArmy raised Winterfell's levies as army_1")
check(store:province("winterfell").levies == 0, "Winterfell's levy pool is empty")
check(findByText(`Raise levies here (0 men)`, "TextButton"):GetAttribute("Enabled") == false, "raising again is disabled with an empty pool")
check(guiRoot():FindFirstChild("ArmyLink_army_1", true) ~= nil, "province panel lists the army standing in Winterfell")
local token = mapRoot:FindFirstChild("Army_army_1", true)
check(token ~= nil, "the map shows a token for the army")
check(token:FindFirstChild("Count", true).Text == EventText.troops(winterfellLevies), "the token shows the troop count")
local winterfell = Content.provinces.winterfell.position
check(math.abs(token.Position.X.Scale - winterfell.x / MapData.width) < 1e-5 and token.Position.Y.Offset < 0, "the token stands just above Winterfell")

click(token)
local armyPanel = guiRoot():FindFirstChild("ArmyPanel", true)
check(armyPanel.Visible, "clicking the token opens the Military tab")
local commander = store:character(army.commanderId)
local function statValue(label: string)
	local row = findByText(label, "TextLabel")
	local value = row and row.Parent:FindFirstChild("Value")
	return value and value.Text
end
check(commander.id == "eddard_stark" and statValue("Commander") == "Eddard Stark", "the Military tab shows the army's commander")
check(statValue("Martial") == tostring(commander.skills.martial), "and the commander's martial")
check(findContaining("Idle at Winterfell") ~= nil, "the Military tab shows the army idle")
local function edge(armyToken)
	return armyToken:FindFirstChild("Banner"):FindFirstChild("UIStroke").Thickness
end
check(edge(token) > 2, "the selected token has a gold edge")

-- A supply tick (every 5 days) changes only morale and supply: the Military tab moves its meters
-- in place instead of rebuilding, so a button under the pointer survives it.
local function restUntilMoraleRises(): (number, number)
	local before = store:army("army_1").morale
	for _ = 1, GameConfig.Military.SupplyTickDays do
		host.sim:advanceDay()
		pump()
		if store:army("army_1").morale ~= before then
			break
		end
	end
	return before, store:army("army_1").morale
end
local moveButton = findByText("Move…", "TextButton")
local moraleBefore, moraleNow = restUntilMoraleRises()
check(moraleNow > moraleBefore, `resting at home, the army recovers morale ({moraleBefore} -> {moraleNow})`)
check(findByText("Move…", "TextButton") == moveButton, "the supply tick did not rebuild the Military tab")
check(findByText(`{moraleNow} / {GameConfig.Military.MoraleMax}`, "TextLabel") ~= nil, "the morale meter shows the new value")
-- Nor does it redraw the province panel of Winterfell, where the army stands.
click(findByText("Map", "TextButton"))
local developText = `Develop ({store:province("winterfell").developmentCost} gold)`
local developButton = findByText(developText, "TextButton")
moraleBefore, moraleNow = restUntilMoraleRises()
check(developButton ~= nil and moraleNow > moraleBefore and findByText(developText, "TextButton") == developButton, "nor the province panel (its Develop button survives)")
click(token)

click(findByText("Move…", "TextButton"))
check(findByText("Cancel move", "TextButton") ~= nil, "Move… starts move mode")
UserInputService.InputBegan:Fire({ KeyCode = roblox.Enum.KeyCode.Escape, UserInputType = roblox.Enum.UserInputType.Keyboard }, false)
pump()
check(findByText("Move…", "TextButton") ~= nil, "Esc cancels move mode")
click(findByText("Move…", "TextButton"))
services.GuiService.MenuOpened:Fire()
pump()
check(findByText("Move…", "TextButton") ~= nil, "the Roblox menu opening (Esc) cancels move mode too")
click(findByText("Move…", "TextButton"))
local whiteHarbor = Content.provinces.white_harbor.position
pressLand(screenAt(whiteHarbor.x, whiteHarbor.y), roblox.Enum.UserInputType.MouseButton2)
check(findByText("Move…", "TextButton") ~= nil and countRequests(Commands.MoveArmy) == 0, "a right-click in move mode cancels it without an order")
check(edge(token) > 2, "the army stays selected")
-- Move mode does not outlive the Military tab: after another tab or hiding the panel, a click on
-- land inspects the province instead of marching.
local moatCailin = Content.provinces.moat_cailin.position
click(findByText("Move…", "TextButton"))
click(findByText("Map", "TextButton"))
pressLand(screenAt(moatCailin.x, moatCailin.y))
check(countRequests(Commands.MoveArmy) == 0 and findContaining("of Moat Cailin ·") ~= nil, "switching tabs cancels move mode: the next click selects the province")
click(token)
click(findByText("Move…", "TextButton"))
click(findByText("Hide panel", "TextButton"))
pressLand(screenAt(moatCailin.x, moatCailin.y))
check(countRequests(Commands.MoveArmy) == 0 and findContaining("of Moat Cailin ·") ~= nil, "so does hiding the panel")
click(token)
check(armyPanel.Visible and edge(token) > 2, "a click on the token selects the army again")
click(findByText("Move…", "TextButton"))
pressLand(screenAt(moatCailin.x, moatCailin.y))
army = store:army("army_1")
check(countRequests(Commands.MoveArmy) == 1 and army.route[#army.route] == "moat_cailin" and army.legEndDay ~= nil, "a click on land in move mode sends MoveArmy to Moat Cailin")
check(armyPanel.Visible, "the click did not select the province instead")
check(findContaining("Marching to Moat Cailin — arrives in 27 days") ~= nil, "the Military tab shows the marching order")
check(findContaining("marches to Moat Cailin (27 days)") ~= nil, "the order is confirmed in a toast")
check(findByText("Move…", "TextButton") ~= nil, "move mode ended with the order")
local route = mapRoot:FindFirstChild("Route_army_1", true)
check(route ~= nil and route:FindFirstChild("Dot") ~= nil and route:FindFirstChild("Arrow") ~= nil, "a dotted route with an arrowhead leads to Moat Cailin")

-- Zooming redraws the route with the dot spacing of the new zoom, reusing its dot frames.
local function routeDots()
	local holder = mapRoot:FindFirstChild("Route_army_1", true)
	local shown, frames = 0, 0
	for _, child in (if holder then reals[holder]:GetChildren() else {}) do
		if child.ClassName == "Frame" then
			frames += 1
			if child.Name == "Dot" then
				shown += 1
			end
		end
	end
	return shown, frames, holder
end
local firstDot = route:FindFirstChild("Dot")
local dotsBefore = routeDots()
click(findByText("+", "TextButton"))
click(findByText("+", "TextButton"))
settle()
local dotsZoomed, framesZoomed, zoomedHolder = routeDots()
check(dotsZoomed > dotsBefore and zoomedHolder == route and route:FindFirstChild("Dot") == firstDot, `zooming in redraws the route in place with closer dots ({dotsBefore} -> {dotsZoomed})`)
click(findByText("-", "TextButton"))
click(findByText("-", "TextButton"))
settle()
local dotsBack, framesBack, backHolder = routeDots()
check(dotsBack == dotsBefore and framesBack == framesZoomed and backHolder == route, "zooming out again hides the extra dots without creating or destroying any")
route = backHolder

-- Time: resume, run two months at speed 3, pause. Ten days in, the army is on its first leg
-- (Winterfell to White Harbor, 13 days) and the dots it has passed are hidden.
local function hiddenDots(): number
	local holder = mapRoot:FindFirstChild("Route_army_1", true)
	local hidden = 0
	for _, child in (holder and reals[holder]:GetChildren() or {}) do
		if child.Name == "Dot" and child.Visible == false then
			hidden += 1
		end
	end
	return hidden
end
local marchStart = store.campaign.clock.dayNumber
click(findByText("Resume", "TextButton"))
click(findByText(">>>", "TextButton"))
local midMarchChecked = false
for _ = 1, 60 * 6 do
	host:update(1 / 60)
	clock.now += 1 / 60
	pump()
	if not midMarchChecked and store.campaign.clock.dayNumber >= marchStart + 10 then
		midMarchChecked = true
		local marching = store:army("army_1")
		check(marching.locationId == "winterfell" and marching.route[1] == "white_harbor" and hiddenDots() > 0, "mid-march, the dots behind the army are hidden")
		local left = 27 - (store.campaign.clock.dayNumber - marchStart)
		check(findContaining(`Marching to Moat Cailin — arrives in {left} days`) ~= nil, `and the arrival estimate counts down ({left} days left)`)
	end
end
check(midMarchChecked, "the time run passed the middle of the march")
check(#store:house("stark").ledger >= 2, "monthly ledgers reached the client")
check(findByText("1 January 297 AC", "TextLabel") == nil, "the date in the top bar advanced")
click(findByText("Pause", "TextButton"))
check(store.campaign.clock.paused == true, "the campaign is paused")

-- The march ended: the army stands at Moat Cailin and its route is gone.
army = store:army("army_1")
check(army ~= nil and army.locationId == "moat_cailin" and #army.route == 0, "the army reached Moat Cailin")
check(mapRoot:FindFirstChild("Route_army_1", true) == nil, "its route dots are gone on arrival")
token = mapRoot:FindFirstChild("Army_army_1", true)
check(math.abs(token.Position.X.Scale - moatCailin.x / MapData.width) < 1e-5, "paused, the token stands at Moat Cailin")
check(findContaining("Idle at Moat Cailin") ~= nil, "the Military tab shows the army idle at Moat Cailin")

-- The Military map mode and the top bar.
local militaryMode = guiRoot():FindFirstChild("Mode_military", true)
check(militaryMode ~= nil and militaryMode.Text == "Military", "the map modes include Military")
click(militaryMode or findByText("Military", "TextButton"))
check(findContaining("Many men (") ~= nil, "the Military map mode shows its legend")
local garrisonLabel = mapRoot:FindFirstChild("Province_winterfell", true):FindFirstChild("Garrison")
check(garrisonLabel.Visible and garrisonLabel.Text == `Garrison {EventText.troops(store:province("winterfell").garrisonTroops)}`, "holdings show their garrison in the Military mode")
click(findByText("Houses", "TextButton"))
check(garrisonLabel.Visible == false, "garrison labels hide in other modes")
local military = store:house("stark").military
check(findByText(EventText.troops(military.total), "TextLabel") ~= nil and findByText("Troops · 1 army", "TextLabel") ~= nil, "the top bar shows the house's troops")
click(findByText("Map", "TextButton"))
click(guiRoot():FindFirstChild("Troops", true))
check(armyPanel.Visible, "clicking the top bar troops opens the Military tab")

-- Split, merge, right-click march, stop, disband.
clock.now += 3
local before = army.troops
click(findByText("Split", "TextButton"))
local half = store:army("army_2")
check(half ~= nil and half.troops + store:army("army_1").troops == before, "Split divides the army in two")
local halfToken = mapRoot:FindFirstChild("Army_army_2", true)
check(halfToken ~= nil, "the map shows a token for the new army")
check(halfToken.Position.Y.Offset < mapRoot:FindFirstChild("Army_army_1", true).Position.Y.Offset, "the two tokens stack at Moat Cailin")
local merge = findByText(`Merge with Army of Winterfell ({EventText.troops(half.troops)})`, "TextButton")
check(merge ~= nil, "the Military tab offers merging the armies")
click(merge)
check(store:army("army_2") == nil and store:army("army_1").troops == before, "Merge joins them again")
check(mapRoot:FindFirstChild("Army_army_2", true) == nil, "the merged army's token is gone")

local moves = countRequests(Commands.MoveArmy)
pressLand(screenAt(winterfell.x, winterfell.y), roblox.Enum.UserInputType.MouseButton2)
army = store:army("army_1")
check(countRequests(Commands.MoveArmy) == moves + 1 and army.route[#army.route] == "winterfell" and #army.route == 2, "a right-click on land marches the selected army there")
check(mapRoot:FindFirstChild("Route_army_1", true) ~= nil, "the new route is drawn")
click(findByText("Stop", "TextButton"))
army = store:army("army_1")
check(#army.route == 1, "Stop halts the army at the end of its current leg")

clock.now += 3
local leviesBefore = store:house("stark").military.levies
click(findByText("Disband…", "TextButton"))
local confirmDisband = findByText("Confirm disband", "TextButton")
check(confirmDisband ~= nil and store:army("army_1") ~= nil, "Disband asks for confirmation first")
click(confirmDisband)
check(store:army("army_1") == nil, "the army is disbanded")
check(mapRoot:FindFirstChild("Army_army_1", true) == nil and mapRoot:FindFirstChild("Route_army_1", true) == nil, "its token and route are gone")
check(store:house("stark").military.levies > leviesBefore and store:house("stark").military.raised == 0, "its men refilled the levy pools")
check(findContaining("No armies in the field") ~= nil, "the Military tab shows no armies")

-- An army on the march when the campaign is saved (its token must come back on load).
clock.now += 3
click(guiRoot():FindFirstChild("Province_white_harbor", true))
local whiteHarborLevies = store:province("white_harbor").levies
click(findByText(`Raise levies here ({EventText.troops(whiteHarborLevies)} men)`, "TextButton"))
check(store:army("army_3") ~= nil, "a second army is raised at White Harbor")
click(mapRoot:FindFirstChild("Army_army_3", true))
pressLand(screenAt(winterfell.x, winterfell.y), roblox.Enum.UserInputType.MouseButton2)
check(#store:army("army_3").route > 0, "and sent towards Winterfell")
check(edge(mapRoot:FindFirstChild("Army_army_3", true)) > 2, "the clicked token is the selected one")
pressLand(screenAt(moatCailin.x, moatCailin.y))
check(edge(mapRoot:FindFirstChild("Army_army_3", true)) < 2 and findContaining("of Moat Cailin ·") ~= nil, "a left click on the map selects the province and lets go of the army")
local ordersBefore = countRequests(Commands.MoveArmy)
pressLand(screenAt(whiteHarbor.x, whiteHarbor.y), roblox.Enum.UserInputType.MouseButton2)
check(countRequests(Commands.MoveArmy) == ordersBefore, "so a right-click then gives no order")

-- Dragging the map by a token pans it; releasing over the token (which moved along) is no click.
local army3Token = mapRoot:FindFirstChild("Army_army_3", true)
local canvasAt = mapRoot:FindFirstChild("Canvas").Position
local grab = { UserInputType = roblox.Enum.UserInputType.MouseButton1, Position = roblox.Vector3.new(600, 300, 0) }
army3Token.InputBegan:Fire(grab)
UserInputService.InputChanged:Fire({ UserInputType = roblox.Enum.UserInputType.MouseMovement, Position = roblox.Vector3.new(640, 260, 0) })
UserInputService.InputEnded:Fire(grab)
army3Token.Activated:Fire()
pump()
check(mapRoot:FindFirstChild("Canvas").Position ~= canvasAt and edge(army3Token) < 2 and not armyPanel.Visible, "dragging the map by a token pans it without selecting the army")
local tap = { UserInputType = roblox.Enum.UserInputType.MouseButton1, Position = roblox.Vector3.new(640, 300, 0) }
army3Token.InputBegan:Fire(tap)
UserInputService.InputEnded:Fire(tap)
army3Token.Activated:Fire()
pump()
check(edge(army3Token) > 2 and armyPanel.Visible, "a click on the token selects the army")

-- A right-click on a token never targets the land drawn under the raised banner: on the selected
-- army's own token it gives no order; on another army's token it marches to where that army stands.
local function rightClickToken(armyToken, x: number, y: number)
	local input = { UserInputType = roblox.Enum.UserInputType.MouseButton2, Position = screenAt(x, y) }
	armyToken.InputBegan:Fire(input)
	UserInputService.InputEnded:Fire(input)
	pump()
end
clock.now += 3
local ordersNow = countRequests(Commands.MoveArmy)
rightClickToken(army3Token, moatCailin.x, moatCailin.y)
check(countRequests(Commands.MoveArmy) == ordersNow, "a right-click on the selected army's own token gives no order, whatever land lies under it")
click(guiRoot():FindFirstChild("Province_moat_cailin", true))
click(findByText(`Raise levies here ({EventText.troops(store:province("moat_cailin").levies)} men)`, "TextButton"))
local army4Token = mapRoot:FindFirstChild("Army_army_4", true)
check(store:army("army_4") ~= nil and army4Token ~= nil, "a third army is raised at Moat Cailin")
click(army3Token)
rightClickToken(army4Token, whiteHarbor.x, whiteHarbor.y)
local army3 = store:army("army_3")
check(countRequests(Commands.MoveArmy) == ordersNow + 1 and army3.route[#army3.route] == "moat_cailin", "a right-click on another army's token marches the selected army to that army's province")
clock.now += 3
click(army4Token)
click(findByText("Disband…", "TextButton"))
click(findByText("Confirm disband", "TextButton"))
check(store:army("army_4") == nil and mapRoot:FindFirstChild("Army_army_4", true) == nil, "the third army is disbanded again")

-- Realm and chronicle panels render with live data.
click(findByText("Realm", "TextButton"))
check(findContaining("Settled months") ~= nil or findContaining("SETTLED MONTHS") ~= nil, "realm panel shows the settled months")
click(findByText("Chronicle", "TextButton"))
check(findContaining("Your envoy was received") ~= nil, "chronicle records the envoy")

-- Save and load through the campaign menu.
clock.now += 30
click(findByText("Campaign", "TextButton"))
click(findByText("Save campaign", "TextButton"))
check(table.find(requestLog, Protocol.Commands.SaveCampaign) ~= nil, "save request reached the server")
local savedDate = table.clone(store.campaign.clock.date)
host.sim:advanceToNextMonth()
pump()
clock.now += 30
-- The campaign menu is still open after saving.
local loadButton = findByText("Load last save", "TextButton")
check(loadButton ~= nil, "campaign menu offers loading")
click(loadButton)
pump()
check(store.campaign.clock.date.month == savedDate.month and store.campaign.clock.date.day == savedDate.day, "loading restored the saved date on the client")
local loadedArmy = store:army("army_3")
local tokenCount = 0
for _, node in reals[mapRoot]:GetDescendants() do
	if string.sub(node.Name, 1, 5) == "Army_" then
		tokenCount += 1
	end
end
check(loadedArmy ~= nil and #loadedArmy.route > 0 and mapRoot:FindFirstChild("Army_army_3", true) ~= nil and tokenCount == 1, "after loading, the marching army's token is back (and only it)")

-- A loaded campaign restores its own army id counter, so an id can come back as another house's
-- army. Stand-in for loading such a save: a full snapshot in which army_3 is House Lannister's,
-- arriving while army_3 (still Stark's) is selected and in move mode.
local function sameColor(a, rgb): boolean
	return math.abs(a.R * 255 - rgb[1]) < 0.5 and math.abs(a.G * 255 - rgb[2]) < 0.5 and math.abs(a.B * 255 - rgb[3]) < 0.5
end
clock.now += 30
local closeMenu = findByText("Close", "TextButton")
if closeMenu then
	click(closeMenu)
end
click(mapRoot:FindFirstChild("Army_army_3", true))
click(findByText("Move…", "TextButton"))
check(findByText("Cancel move", "TextButton") ~= nil, "army_3 is selected and in move mode")
local starkToken = mapRoot:FindFirstChild("Army_army_3", true)
check(sameColor(starkToken:FindFirstChild("Banner").BackgroundColor3, Content.houses.stark.mapColor), "army_3's banner has Stark's colour")
local reused = networkCopy(host:syncPayload(1))
reused.campaign.armies.army_3.houseId = "lannister"
store:applyFull(reused)
local lannisterToken = mapRoot:FindFirstChild("Army_army_3", true)
check(lannisterToken ~= nil and lannisterToken ~= starkToken and sameColor(lannisterToken:FindFirstChild("Banner").BackgroundColor3, Content.houses.lannister.mapColor), "after the snapshot the token is rebuilt with Lannister's colour")
check(edge(lannisterToken) < 2, "and the army id's old selection is let go")
local movesBeforeClick = countRequests(Commands.MoveArmy)
pressLand(screenAt(moatCailin.x, moatCailin.y))
check(countRequests(Commands.MoveArmy) == movesBeforeClick, "so is the pending move order: the next click on land gives no order")

-- Returning from the lobby: snapshots that arrive in the lobby never reach the map, so the session
-- change on re-entry reconciles the tokens. Stand-in: in the lobby a load removes every army.
local session = networkCopy(host:syncPayload(1)).session
local inLobby = networkCopy(host:syncPayload(1))
inLobby.session.houseId = nil
inLobby.campaign.armies = {}
store:applyFull(inLobby)
check(lobby.Visible and mapRoot:FindFirstChild("Army_army_3", true) ~= nil, "in the lobby the map keeps its old tokens")
store:applyDelta({ seq = store.seq + 1, session = session })
check(guiRoot().Root.Game.Visible and mapRoot:FindFirstChild("Army_army_3", true) == nil, "back in the game, tokens of armies that no longer exist are gone")
store:applyFull(networkCopy(host:syncPayload(1)))
check(mapRoot:FindFirstChild("Army_army_3", true) ~= nil, "and the real state is restored")

-- The map's framing, camera and zoom levels (UI/MapConfig) ------------------------------------------
-- (In a function of its own: the main chunk is close to Luau's limit of 200 locals.)
local function mapCameraChecks()
	-- The map area is 1280 x 720 here (the shim's AbsoluteSize) at a UI scale of 1.
	local AREA = roblox.Vector2.new(1280, 720)
	local bounds = MapConfig.View.Bounds
	local canvasNode = mapRoot:FindFirstChild("Canvas")
	local dragCatcher = mapRoot:FindFirstChild("DragCatcher")
	local atlasFills = mapRoot:FindFirstChild("AtlasFills")
	local MouseButton1 = roblox.Enum.UserInputType.MouseButton1
	local MouseMovement = roblox.Enum.UserInputType.MouseMovement
	local function near(a: number, b: number, tolerance: number): boolean
		return math.abs(a - b) <= tolerance
	end
	-- The map point under a point of the map area.
	local function mapPointUnder(x: number, y: number)
		local centre, zoom, area = mapView()
		return centre + (roblox.Vector2.new(x, y) - area / 2) / zoom
	end
	-- The map point is drawn within a pixel of (x, y) (the canvas is placed in whole pixels).
	local function stillUnder(point, x: number, y: number): boolean
		local drawn = screenAt(point.X, point.Y)
		return math.abs(drawn.X - x) <= 1 and math.abs(drawn.Y - y) <= 1
	end
	local function frameEdges()
		local topLeft, bottomRight = screenAt(bounds.minX, bounds.minY), screenAt(bounds.maxX, bounds.maxY)
		return topLeft.X, topLeft.Y, bottomRight.X, bottomRight.Y
	end
	-- The canvas (borders, labels, tokens) sits on the fills: the same origin, and the same size
	-- to within a pixel (it is placed in whole pixels).
	local function canvasOnFills(): boolean
		local _, zoom = mapView()
		local origin = screenAt(0, 0)
		return math.abs(canvasNode.Position.X.Offset - origin.X) <= 0.01 and math.abs(canvasNode.Position.Y.Offset - origin.Y) <= 0.01
			and math.abs(canvasNode.Size.X.Offset - MapData.width * zoom) <= 1 and math.abs(canvasNode.Size.Y.Offset - MapData.height * zoom) <= 1
	end
	-- A press and release on a button without moving, then its activation (a click).
	local function tap(button)
		local input = { UserInputType = MouseButton1, Position = roblox.Vector3.new(640, 360, 0) }
		button.InputBegan:Fire(input)
		UserInputService.InputEnded:Fire(input)
		button.Activated:Fire()
		pump()
	end
	local function flyToProvince(provinceId: string, zoom: number): boolean
		MapController.focusProvince(provinceId, zoom)
		return settle() and near(canvasZoom(), zoom, 1e-6)
	end
	local function dragMap(dx: number, dy: number)
		local press = { UserInputType = MouseButton1, Position = roblox.Vector3.new(640, 360, 0) }
		dragCatcher.InputBegan:Fire(press)
		UserInputService.InputChanged:Fire({ UserInputType = MouseMovement, Position = roblox.Vector3.new(640 + dx, 360 + dy, 0) })
		UserInputService.InputEnded:Fire(press)
		pump()
	end
	local function wheel(x: number, y: number, z: number)
		UserInputService.InputChanged:Fire({ UserInputType = roblox.Enum.UserInputType.MouseWheel, Position = roblox.Vector3.new(x, y, z) })
	end
	mapRoot.MouseEnter:Fire()

	-- The whole-map view: Westeros from Beyond the Wall to Dorne fills the map area's height.
	-- The [ ] button glides there: an eased flight on RenderStepped.
	local fitZoom = AREA.Y / (bounds.maxY - bounds.minY) * MapConfig.View.FitMargin
	-- A zoom in each level (the levels count from the whole-map view).
	local levels = MapConfig.Zoom
	local blendZoom = fitZoom * (levels.BlendStart + (levels.BlendEnd - levels.BlendStart) * 0.35)
	local atlasZoom = fitZoom * (levels.Atlas + levels.Notable) / 2
	local closeZoom = fitZoom * levels.Close * 1.01
	check(flyToProvince("harrenhal", 1.0), "a flight to Harrenhal at zoom 1.0 ends there")
	click(findByText("[ ]", "TextButton"))
	local flying = renderStepped:connectedCount() == 1
	renderStepped:Fire(1 / 60)
	local firstFrame = canvasZoom()
	check(flying and firstFrame < 1 - 1e-3 and firstFrame > fitZoom + 1e-3, `[ ] starts a glide: one frame in, the zoom is on its way ({string.format("%.3f", firstFrame)})`)
	-- Ease-out: the first frame covers more than twice an even pace's share of the way.
	check(math.log(1 / firstFrame) / math.log(1 / fitZoom) > 2 * (1 / 60) / MapConfig.Camera.FlyTime, "the glide starts quickly and slows down (eased)")
	check(settle(), "the [ ] flight to the whole map ends and lets go of RenderStepped")
	local left, top, right, bottom = frameEdges()
	check(near(canvasZoom(), fitZoom, 1e-6) and near(top, 0, 1) and near(bottom, AREA.Y, 1), `the whole-map view fits the frame to the map area's height (zoom {string.format("%.3f", canvasZoom())})`)
	check(near((left + right) / 2, AREA.X / 2, 1), "and centres the frame horizontally")
	check(MapController.zoomLevel() == "political" and MapController.blend() == 0 and fills.Visible and not atlasFills.Visible, "the whole-map view is the political map")
	check(canvasOnFills(), "the canvas of borders and labels sits on the fills")
	local fitPosition, fitSize = canvasNode.Position, canvasNode.Size
	wheel(400, 300, -1)
	settle()
	check(canvasNode.Size == fitSize and canvasNode.Position == fitPosition, "the wheel does not zoom out past the whole-map view")
	-- The frame is narrower than the map area here: it slides sideways, never up or down, and
	-- never off the screen.
	local fitLeft = left
	dragMap(200, 80)
	left, top, right, bottom = frameEdges()
	check(near(left, fitLeft + 200, 1) and near(top, 0, 1) and near(bottom, AREA.Y, 1), "dragging the whole-map view slides Westeros sideways only")
	dragMap(5000, -300)
	left, top, right, bottom = frameEdges()
	check(near(right, AREA.X, 1) and near(top, 0, 1), "a huge drag stops with the frame at the right edge (no panning into empty sea)")
	dragMap(-5000, 300)
	left, top = frameEdges()
	check(near(left, 0, 1) and near(top, 0, 1), "and the other way at the left edge")
	click(findByText("[ ]", "TextButton"))
	settle()
	left, top, right = frameEdges()
	check(near((left + right) / 2, AREA.X / 2, 1) and near(canvasZoom(), fitZoom, 1e-6), "[ ] centres the whole map again")

	-- Zoomed in, the view stops at the frame's edges.
	check(flyToProvince("harrenhal", 2), "a flight to Harrenhal at zoom 2 ends there")
	dragMap(5000, 5000)
	left, top = frameEdges()
	check(near(left, 0, 1) and near(top, 0, 1), "a huge drag stops at the frame's north-west corner")
	dragMap(-20000, -20000)
	_, _, right, bottom = frameEdges()
	check(near(right, AREA.X, 1) and near(bottom, AREA.Y, 1), "and the other way at its south-east corner")

	-- Smooth wheel zoom towards the pointer, the + / - buttons, a pinch.
	check(flyToProvince("harrenhal", 1.5), "a flight to Harrenhal at zoom 1.5 ends there")
	local pointBefore = mapPointUnder(520, 300)
	wheel(520, 300, 1)
	check(renderStepped:connectedCount() == 1 and canvasZoom() < 1.5 * MapConfig.Camera.WheelStep, "a wheel notch starts a glide on RenderStepped")
	check(settle(), "the glide ends and lets go of RenderStepped")
	check(near(canvasZoom(), 1.5 * MapConfig.Camera.WheelStep, 1e-6) and stillUnder(pointBefore, 520, 300),
		"it zoomed by one WheelStep, keeping the map point under the pointer")
	local beforeButtons = canvasZoom()
	local buttonStep = MapConfig.Camera.ButtonStep
	click(findByText("+", "TextButton"))
	renderStepped:Fire(1 / 60)
	local stepped = canvasZoom()
	check(renderStepped:connectedCount() == 1 and stepped > beforeButtons + 1e-4 and stepped < beforeButtons * buttonStep - 1e-4, "+ glides")
	check(settle() and near(canvasZoom(), beforeButtons * buttonStep, 1e-6), "+ zooms in by ButtonStep")
	click(findByText("-", "TextButton"))
	check(settle() and near(canvasZoom(), beforeButtons, 1e-6), "- zooms back out")
	click(findByText("+", "TextButton"))
	click(findByText("+", "TextButton"))
	check(settle() and near(canvasZoom(), beforeButtons * buttonStep ^ 2, 1e-6), "two quick clicks on + add up")
	local Pinch = roblox.Enum.UserInputState
	local fingerA, fingerB = roblox.Vector2.new(500, 300), roblox.Vector2.new(700, 300)

	-- A press on the map or a pinch stops a flight where it is.
	MapController.focusProvince("harrenhal", 1.5)
	renderStepped:Fire(1 / 60)
	local hold = { UserInputType = MouseButton1, Position = roblox.Vector3.new(640, 360, 0) }
	dragCatcher.InputBegan:Fire(hold)
	local frozen = canvasZoom()
	check(renderStepped:connectedCount() == 0 and frozen < beforeButtons * buttonStep ^ 2 - 1e-3 and frozen > 1.5 + 1e-3, "a press on the map stops a flight where it is")
	UserInputService.InputChanged:Fire({ UserInputType = MouseMovement, Position = roblox.Vector3.new(660, 360, 0) })
	UserInputService.InputEnded:Fire(hold)
	pump()
	MapController.focusProvince("harrenhal", 1.5)
	renderStepped:Fire(1 / 60)
	UserInputService.TouchPinch:Fire({ fingerA, fingerB }, 1, 0, Pinch.Begin)
	check(renderStepped:connectedCount() == 0, "and so does a pinch")
	UserInputService.TouchPinch:Fire({ fingerA, fingerB }, 1, 0, Pinch.End)

	check(flyToProvince("harrenhal", 1.5), "back at zoom 1.5")
	local pinchPoint = mapPointUnder(600, 300)
	UserInputService.TouchPinch:Fire({ fingerA, fingerB }, 1, 0, Pinch.Begin)
	UserInputService.TouchPinch:Fire({ roblox.Vector2.new(510, 330), roblox.Vector2.new(750, 330) }, 1.2, 0, Pinch.Change)
	UserInputService.TouchPinch:Fire({ roblox.Vector2.new(510, 330), roblox.Vector2.new(750, 330) }, 1.2, 0, Pinch.End)
	check(near(canvasZoom(), 1.8, 1e-6) and stillUnder(pinchPoint, 630, 330), "a pinch zooms about the fingers' midpoint and the map follows the midpoint")

	-- Dragging during a wheel glide carries the glide along with the pointer.
	check(flyToProvince("harrenhal", 2), "zoom 2")
	local grabbed = mapPointUnder(640, 360)
	dragCatcher.InputBegan:Fire(hold)
	wheel(640, 360, 1)
	renderStepped:Fire(1 / 60)
	UserInputService.InputChanged:Fire({ UserInputType = MouseMovement, Position = roblox.Vector3.new(740, 360, 0) })
	settle()
	check(near(canvasZoom(), 2 * MapConfig.Camera.WheelStep, 1e-6) and stillUnder(grabbed, 740, 360), "a wheel notch while dragging zooms and keeps the grabbed point under the pointer")
	UserInputService.InputEnded:Fire(hold)
	pump()

	-- A glide arrives even when the map area changes size under it.
	check(flyToProvince("harrenhal", fitZoom * 1.2), "close to the whole-map view")
	wheel(640, 360, -1)
	renderStepped:Fire(1 / 60)
	sizeOverrides[mapRoot] = roblox.Vector2.new(1280, 900)
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	check(settle() and near(canvasZoom(), 900 / (bounds.maxY - bounds.minY) * MapConfig.View.FitMargin, 1e-6), "a wheel glide still ends when the map area grows taller under it")
	sizeOverrides[mapRoot] = nil
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()

	-- Touch: after a pinch the finger still down pans on, whichever finger lifts first, and the
	-- highlight of the touched region goes away; the gesture selects nothing.
	local Touch = roblox.Enum.UserInputType.Touch
	local selectionLayer = mapRoot:FindFirstChild("Selection", true)
	local function clearSelection(): boolean
		local seaTap = { UserInputType = MouseButton1, Position = screenAt(990, 20) }
		dragCatcher.InputBegan:Fire(seaTap)
		UserInputService.InputEnded:Fire(seaTap)
		pump()
		return #reals[selectionLayer]:GetChildren() == 0
	end
	check(flyToProvince("harrenhal", atlasZoom) and clearSelection(), "a click on the sea clears the selection")
	local tapAt = { UserInputType = Touch, Position = screenAt(harrenhal.x, harrenhal.y) }
	mapRoot.InputBegan:Fire(tapAt)
	dragCatcher.InputBegan:Fire(tapAt)
	local litWhileDown = mapRoot:FindFirstChild("KingdomHover_riverlands", true).Visible
	UserInputService.InputEnded:Fire(tapAt)
	pump()
	check(litWhileDown and not mapRoot:FindFirstChild("KingdomHover_riverlands", true).Visible and #reals[selectionLayer]:GetChildren() > 0,
		"a tap highlights the region only while the finger is down, and selects the province")
	check(clearSelection(), "the sea clears it again")
	local function pinchThenPan(firstLifts: boolean): boolean
		local atHarrenhal = screenAt(harrenhal.x, harrenhal.y)
		local first = { UserInputType = Touch, Position = atHarrenhal }
		local second = { UserInputType = Touch, Position = atHarrenhal + roblox.Vector3.new(150, 0, 0) }
		mapRoot.InputBegan:Fire(first)
		dragCatcher.InputBegan:Fire(first)
		local highlighted = mapRoot:FindFirstChild("KingdomHover_riverlands", true).Visible
		dragCatcher.InputBegan:Fire(second)
		local function at(input): Vector2
			return roblox.Vector2.new(input.Position.X, input.Position.Y)
		end
		UserInputService.TouchPinch:Fire({ at(first), at(second) }, 1, 0, Pinch.Begin)
		second.Position += roblox.Vector3.new(30, 0, 0)
		UserInputService.TouchPinch:Fire({ at(first), at(second) }, 1.1, 0, Pinch.Change)
		local lifted, staying = if firstLifts then first else second, if firstLifts then second else first
		if firstLifts then
			UserInputService.InputEnded:Fire(lifted)
			UserInputService.TouchPinch:Fire({ at(staying) }, 1.1, 0, Pinch.End)
		else
			UserInputService.TouchPinch:Fire({ at(staying) }, 1.1, 0, Pinch.End)
			UserInputService.InputEnded:Fire(lifted)
		end
		local from = canvasNode.Position
		staying.Position += roblox.Vector3.new(5, 0, 0)
		UserInputService.InputChanged:Fire(staying)
		staying.Position += roblox.Vector3.new(60, 40, 0)
		UserInputService.InputChanged:Fire(staying)
		local moved = canvasNode.Position.X.Offset - from.X.Offset == 60 and canvasNode.Position.Y.Offset - from.Y.Offset == 40
		UserInputService.InputEnded:Fire(staying)
		pump()
		return highlighted and moved and not mapRoot:FindFirstChild("KingdomHover_riverlands", true).Visible
			and not mapRoot:FindFirstChild("Glow_riverlands", true).Visible and #reals[selectionLayer]:GetChildren() == 0
	end
	check(flyToProvince("harrenhal", atlasZoom) and pinchThenPan(false), "after a pinch the first finger, still down, pans the map; lifting it clears the highlight and selects nothing")
	check(flyToProvince("harrenhal", atlasZoom) and pinchThenPan(true), "and when the first finger lifts first, the second one pans on")
	-- Two fingers that lift without moving afterwards are no tap either, pinched or not, also when
	-- the second finger lands off the map's land (on the map mode box, say).
	local function twoFingersInPlace(pinched: boolean, secondOnMap: boolean): boolean
		local atHarrenhal = screenAt(harrenhal.x, harrenhal.y)
		local first = { UserInputType = Touch, Position = atHarrenhal }
		local second = { UserInputType = Touch, Position = atHarrenhal + roblox.Vector3.new(150, 0, 0) }
		dragCatcher.InputBegan:Fire(first)
		if secondOnMap then
			dragCatcher.InputBegan:Fire(second)
		end
		if pinched then
			local positions = { roblox.Vector2.new(first.Position.X, first.Position.Y), roblox.Vector2.new(second.Position.X, second.Position.Y) }
			UserInputService.TouchPinch:Fire(positions, 1, 0, Pinch.Begin)
			UserInputService.TouchPinch:Fire(positions, 1.1, 0, Pinch.Change)
			UserInputService.TouchPinch:Fire(positions, 1.1, 0, Pinch.End)
		end
		UserInputService.InputEnded:Fire(second)
		UserInputService.InputEnded:Fire(first)
		pump()
		return #reals[selectionLayer]:GetChildren() == 0
	end
	check(twoFingersInPlace(true, true) and twoFingersInPlace(false, true) and twoFingersInPlace(true, false),
		"a pinch, or a two-finger tap, then lifting the fingers without moving them selects nothing")

	-- The map area changes size (the side panel hidden or shown).
	check(flyToProvince("harrenhal", 2), "zoom 2 again")
	local middle = mapPointUnder(640, 360)
	sizeOverrides[mapRoot] = roblox.Vector2.new(1000, 720)
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	check(near(canvasZoom(), 2, 1e-6) and stillUnder(middle, 500, 360), "when the map area narrows, the map point in the middle stays there at the same zoom")
	click(findByText("[ ]", "TextButton"))
	settle()
	sizeOverrides[mapRoot] = roblox.Vector2.new(1000, 900)
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	check(near(canvasZoom(), 900 / (bounds.maxY - bounds.minY) * MapConfig.View.FitMargin, 1e-6), "when it grows taller than the whole-map view, the view refits")

	-- On the real layout (a map area of 816 x 662) the wheel and a pinch zoom towards the pointer
	-- from the whole-map view on, in the political look; at Westeros's edges the view shifts just
	-- enough to keep the frame on screen.
	local REAL = roblox.Vector2.new(816, 662)
	sizeOverrides[mapRoot] = REAL
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	local realFit = REAL.Y / (bounds.maxY - bounds.minY) * MapConfig.View.FitMargin
	local function fromWholeMap(provinceId: string)
		click(findByText("[ ]", "TextButton"))
		settle()
		local position = Content.provinces[provinceId].position
		return roblox.Vector2.new(position.x, position.y), screenAt(position.x, position.y)
	end
	local kingsLanding, pointer = fromWholeMap("kings_landing")
	for _ = 1, 4 do
		wheel(pointer.X, pointer.Y, 1)
	end
	settle()
	check(near(canvasZoom(), realFit * MapConfig.Camera.WheelStep ^ 4, 1e-6) and MapController.zoomLevel() == "political" and stillUnder(kingsLanding, pointer.X, pointer.Y),
		"on the real layout, four wheel notches from the whole map zoom in on King's Landing, kept under the pointer")
	kingsLanding, pointer = fromWholeMap("kings_landing")
	local around = { roblox.Vector2.new(pointer.X - 60, pointer.Y), roblox.Vector2.new(pointer.X + 60, pointer.Y) }
	UserInputService.TouchPinch:Fire(around, 1, 0, Pinch.Begin)
	UserInputService.TouchPinch:Fire(around, 1.8, 0, Pinch.Change)
	UserInputService.TouchPinch:Fire(around, 1.8, 0, Pinch.End)
	check(near(canvasZoom(), realFit * 1.8, 1e-6) and stillUnder(kingsLanding, pointer.X, pointer.Y), "and a pinch from the whole map keeps King's Landing between the fingers")
	local pyke, pykePointer = fromWholeMap("pyke")
	for _ = 1, 5 do
		wheel(pykePointer.X, pykePointer.Y, 1)
	end
	settle()
	left, _, right = frameEdges()
	local pykeNow = screenAt(pyke.X, pyke.Y)
	check(left >= -1 and right <= REAL.X + 1 and math.abs(pykeNow.X - pykePointer.X) < 60 and near(pykeNow.Y, pykePointer.Y, 1),
		`zooming in at Pyke, on Westeros's west coast, keeps the whole frame on screen and Pyke near the pointer ({string.format("%.0f", pykeNow.X - pykePointer.X)} px off)`)

	-- FitMode "fill": the frame covers the map area; the whole-map view is still political, and
	-- the Close level can still be reached.
	MapConfig.View.FitMode = "fill"
	sizeOverrides[mapRoot] = roblox.Vector2.new(1188, 662)
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()
	click(findByText("[ ]", "TextButton"))
	settle()
	left, top, right, bottom = frameEdges()
	check(near(canvasZoom(), 1188 / (bounds.maxX - bounds.minX) * MapConfig.View.FitMargin, 1e-6) and near(left, 0, 1) and near(right, 1188, 1) and top < 0 and bottom > 662
		and MapController.zoomLevel() == "political" and MapController.blend() == 0 and fills.Visible and not atlasFills.Visible,
		"with FitMode \"fill\" the whole-map view covers the map area and is still the political map")
	MapController.focusProvince("harrenhal", 1000)
	settle()
	check(MapController.zoomLevel() == "close", "and zoomed in fully it reaches the Close level")
	MapConfig.View.FitMode = "height"
	sizeOverrides[mapRoot] = nil
	mapRoot:GetPropertyChangedSignal("AbsoluteSize"):Fire()

	-- The blend zone: the political map fades out over the atlas.
	check(countWedges(atlasFills:FindFirstChild("Land")) == wedgeCount, "the atlas look is drawn with the same triangles")
	check(flyToProvince("harrenhal", blendZoom), `a flight to zoom {string.format("%.2f", blendZoom)} (the blend zone) ends there`)
	local blend = MapController.blend()
	check(MapController.zoomLevel() == "blend" and blend > 0.05 and blend < MapConfig.Zoom.BorderSwitch, `that zoom is in the blend zone (blend {string.format("%.2f", blend)})`)
	check(atlasFills.Visible and fills.Visible and near(fills.ImageTransparency, blend, 1e-3) and near(fills.BackgroundTransparency, blend, 1e-3), "the atlas shows through the fading political map")
	check(mapRoot:FindFirstChild("RegionBorders", true).Visible and not mapRoot:FindFirstChild("KingdomBorders", true).Visible, "before the border switch the black borders stay")
	local starkCrest = mapRoot:FindFirstChild("Crest_stark", true)
	local starkLabel = mapRoot:FindFirstChild("HouseLabel_stark", true)
	local starkLine = starkLabel:FindFirstChild("TextLabel")
	check(starkCrest.Visible and starkCrest.ImageTransparency > 0 and starkLine.TextTransparency > 0 and starkLine:FindFirstChild("UIStroke").Transparency > MapConfig.HaloTransparency + 0.05,
		"crests and house names (with their halos) are fading")

	-- The atlas: kingdom borders in the house colours, a faint fill on hover.
	check(flyToProvince("harrenhal", atlasZoom), `a flight to zoom {string.format("%.2f", atlasZoom)} ends there`)
	check(MapController.zoomLevel() == "atlas" and MapController.blend() == 1, "that zoom is the atlas level")
	check(atlasFills.Visible and (not fills.Visible or fills.ImageTransparency >= 0.999), "the political colours are gone")
	check(not starkCrest.Visible and not starkLabel.Visible and not mapRoot:FindFirstChild("Crest_crownlands", true).Visible, "crests and house names are hidden")
	local kingdomBorders = mapRoot:FindFirstChild("KingdomBorders", true)
	local borderColours = {}
	for _, line in reals[kingdomBorders]:GetChildren() do
		borderColours[line.Color3:ToHex()] = true
	end
	local colourCount = 0
	for _ in borderColours do
		colourCount += 1
	end
	check(kingdomBorders.Visible and colourCount >= 8, `kingdom borders are shown in the house colours ({colourCount} colours)`)
	check(not mapRoot:FindFirstChild("RegionBorders", true).Visible and not subBorders.Visible, "the black region and sub-territory borders are hidden")
	local atlasLand = atlasFills:FindFirstChild("Land")
	local function atlasColours()
		local colours = {}
		for index, part in reals[atlasLand]:GetDescendants() do
			if part.ClassName == "WedgePart" then
				colours[index] = part.Color
			end
		end
		return colours
	end
	local plain = atlasColours()
	UserInputService.InputChanged:Fire({ UserInputType = MouseMovement, Position = screenAt(harrenhal.x, harrenhal.y) })
	check(mapRoot:FindFirstChild("KingdomHover_riverlands", true).Visible and not mapRoot:FindFirstChild("Glow_riverlands", true).Visible,
		"hovering the Riverlands outlines them in their house colour (not the political glow)")
	local tully
	for _, house in MapData.houses do
		if house.id == "tully" then
			tully = roblox.Color3.fromHex(house.primaryColor)
		end
	end
	local share = 1 - MapConfig.Atlas.HoverFillTransparency
	local tinted, tintedRight = 0, true
	for index, colour in atlasColours() do
		if colour ~= plain[index] then
			tinted += 1
			local expected = plain[index]:Lerp(tully, share)
			if not (near(colour.R, expected.R, 2e-3) and near(colour.G, expected.G, 2e-3) and near(colour.B, expected.B, 2e-3)) then
				tintedRight = false
			end
		end
	end
	check(tinted > 0 and tintedRight, `and give them a faint fill in that colour ({tinted} triangles)`)
	UserInputService.InputChanged:Fire({ UserInputType = MouseMovement, Position = screenAt(990, 20) })
	local restored = true
	for index, colour in atlasColours() do
		if colour ~= plain[index] then
			restored = false
		end
	end
	check(restored and not mapRoot:FindFirstChild("KingdomHover_riverlands", true).Visible, "leaving the region restores it")

	-- Army tokens stay on their army's point at every zoom, and stay clickable.
	local ArmyLayer = requirePath("StarterPlayer.StarterPlayerScripts.UI.ArmyLayer")
	local function tokenPlaced(armyId: string): boolean
		local armyToken = mapRoot:FindFirstChild(`Army_{armyId}`, true)
		local point = ArmyLayer.pointOf(armyId)
		if not armyToken or not point then
			return false
		end
		local x = canvasNode.Position.X.Offset + armyToken.Position.X.Scale * canvasNode.Size.X.Offset + armyToken.Position.X.Offset
		local y = canvasNode.Position.Y.Offset + armyToken.Position.Y.Scale * canvasNode.Size.Y.Offset + armyToken.Position.Y.Offset
		local expected = screenAt(point.X, point.Y)
		return armyToken.Visible and armyToken.Parent.Visible and near(x, expected.X, 1.5) and y < expected.Y and y > expected.Y - 40
	end
	local armyAt = store:army("army_3").locationId
	local placed = {}
	for _, zoom in { fitZoom, blendZoom, atlasZoom, closeZoom } do
		local ok = flyToProvince(armyAt, zoom) and tokenPlaced("army_3")
		table.insert(placed, `{MapController.zoomLevel()} {if ok then "ok" else "WRONG"}`)
	end
	check(table.concat(placed, ", ") == "political ok, blend ok, atlas ok, close ok", `army tokens stand on their army's point at every zoom level ({table.concat(placed, ", ")})`)
	check(canvasOnFills(), "the canvas still sits on the fills, close in")
	tap(mapRoot:FindFirstChild("Army_army_3", true))
	check(armyPanel.Visible and edge(mapRoot:FindFirstChild("Army_army_3", true)) > 2, "and a click on a token selects its army in the atlas too")
	MapController.focusArmy("army_3")
	local armyPoint = ArmyLayer.pointOf("army_3")
	local armyScreen = screenAt(armyPoint.X, armyPoint.Y)
	check(settle() and near(armyScreen.X, 640, 1) and near(armyScreen.Y, 360, 1), "focusArmy flies to the army")

	-- The data modes stay political when zoomed in; the terrain mode shares the atlas palette.
	check(flyToProvince("harrenhal", atlasZoom), "the atlas zoom again")
	click(guiRoot():FindFirstChild("Mode_realm", true))
	check(MapController.blend() == 0 and fills.Visible and fills.ImageTransparency == 0 and not atlasFills.Visible, "the Realm mode keeps its data colours when zoomed in (no atlas)")
	check(mapRoot:FindFirstChild("RegionBorders", true).Visible and not kingdomBorders.Visible and starkCrest.Visible, "with its black borders and crests")
	click(guiRoot():FindFirstChild("Mode_terrain", true))
	check(MapController.blend() == 1 and atlasFills.Visible, "the Terrain mode turns into the atlas when zoomed in")
	click(findByText("[ ]", "TextButton"))
	settle()
	local function isSandy(c): boolean
		return c.R > c.G and c.G > c.B and c.R - c.B > 0.15 and c.R > 0.6
	end
	local function partColours(model, id: string)
		local colours = {}
		for _, part in reals[model:FindFirstChild(id)]:GetDescendants() do
			if part.ClassName == "WedgePart" then
				table.insert(colours, part.Color)
			end
		end
		return colours
	end
	local function provinceColours(model, provinceId: string)
		local colours = {}
		for _, sub in MapData.subTerritories do
			if sub.provinceId == provinceId then
				for _, colour in partColours(model, sub.id) do
					table.insert(colours, colour)
				end
			end
		end
		return colours
	end
	local function all(colours, test): boolean
		for _, colour in colours do
			if not test(colour) then
				return false
			end
		end
		return #colours > 0
	end
	check(all(provinceColours(land, "sunspear"), isSandy) and all(provinceColours(land, "the_greenblood"), isSandy), "the Terrain mode paints Dorne's desert sandy")
	check(all(provinceColours(atlasLand, "sunspear"), isSandy) and all(provinceColours(atlasLand, "the_greenblood"), isSandy), "and so does the atlas")
	check(all(provinceColours(land, "kingsgrave"), function(c)
		return c.R > c.G + 0.08 and c.R > c.B + 0.1
	end), "Dorne's mountains lean reddish brown (the Red Mountains)")
	check(all(partColours(land, "beyond_the_wall"), function(c)
		return c.R > 0.85 and c.G > 0.85 and c.B > 0.85
	end), "Beyond the Wall is near-white")
	check(findByText("The Red Mountains", "TextLabel") ~= nil and findByText("Desert", "TextLabel") ~= nil, "the Terrain legend shows the terrain types and the regional looks")
	click(guiRoot():FindFirstChild("Mode_houses", true))
	local ownColour
	for _, feature in MapData.specialFeatures do
		if feature.id == "beyond_the_wall" then
			ownColour = roblox.Color3.fromHex(feature.color)
		end
	end
	check(all(partColours(land, "beyond_the_wall"), function(c)
		return c == ownColour
	end), "back in the Houses mode the features have their own colours again")

	-- MapConfig itself: zoom levels in order (the whole-map view and the start and focus views
	-- political), colours for all the land, a frame around it.
	local camera = MapConfig.Camera
	check(1 < levels.BlendStart and levels.BlendStart < levels.BlendEnd and levels.BlendEnd <= levels.Atlas and levels.Atlas < levels.Notable
		and levels.Notable < levels.Close and levels.BlendSteps >= 1 and levels.BorderSwitch >= 0 and levels.BorderSwitch <= 1
		and camera.StartZoom <= levels.BlendStart and camera.FocusZoom <= levels.BlendStart, "the zoom thresholds are in order")
	local rank = { political = 1, blend = 2, atlas = 3, close = 4 }
	local previousBlend, previousRank, ordered = -1, 0, true
	for step = 0, 1000 do
		local zoom = step / 100
		local value, levelRank = MapConfig.blend(zoom), rank[MapConfig.level(zoom)]
		if value < previousBlend or value < 0 or value > 1 or levelRank == nil or levelRank < previousRank then
			ordered = false
		end
		previousBlend, previousRank = value, levelRank
	end
	check(ordered and MapConfig.blend(levels.BlendStart) == 0 and MapConfig.blend(levels.BlendEnd) == 1 and MapConfig.level(levels.BlendStart) == "political"
		and MapConfig.level((levels.BlendStart + levels.BlendEnd) / 2) == "blend" and MapConfig.level(levels.Atlas) == "atlas" and MapConfig.level(levels.Close) == "close",
		"the blend rises from 0 to 1 across the blend zone and the levels follow the zoom in order")
	local uncoloured = {}
	for _, provinceId in Content.provinceIds do
		local province = Content.provinces[provinceId]
		if MapConfig.ProvinceLook[provinceId] == nil and MapConfig.RegionLook[province.regionId] == nil then
			table.insert(uncoloured, provinceId)
		end
	end
	for _, feature in MapData.specialFeatures do
		if MapConfig.FeatureLook[feature.id] == nil then
			table.insert(uncoloured, feature.id)
		end
	end
	check(#uncoloured == 0, `every province and special feature has a lore colour ({table.concat(uncoloured, ", ")})`)
	local loud = {}
	for name, colour in MapConfig.Palette do
		local _, saturation = colour:ToHSV()
		if saturation > 0.5 then
			table.insert(loud, name)
		end
	end
	check(#loud == 0, `the palette is muted: no colour above half saturation ({table.concat(loud, ", ")})`)
	local landBox = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
	local function enclose(paths)
		for _, path in paths do
			for i = 1, #path - 1, 2 do
				landBox.minX = math.min(landBox.minX, path[i])
				landBox.maxX = math.max(landBox.maxX, path[i])
				landBox.minY = math.min(landBox.minY, path[i + 1])
				landBox.maxY = math.max(landBox.maxY, path[i + 1])
			end
		end
	end
	for _, region in MapData.regions do
		enclose(region.paths)
	end
	for _, feature in MapData.specialFeatures do
		enclose(feature.paths)
	end
	-- At least 20 units of sea on every side, except where the frame reaches the end of the map.
	local function sea(gap: number, atMapEdge: boolean): boolean
		return gap >= (if atMapEdge then 0 else 20)
	end
	check(bounds.minX >= 0 and bounds.minY >= 0 and bounds.maxX <= MapData.width and bounds.maxY <= MapData.height
		and sea(landBox.minX - bounds.minX, bounds.minX <= 0) and sea(bounds.maxX - landBox.maxX, bounds.maxX >= MapData.width)
		and sea(landBox.minY - bounds.minY, bounds.minY <= 0) and sea(bounds.maxY - landBox.maxY, bounds.maxY >= MapData.height),
		`the frame holds all the land with a margin of sea (land x {landBox.minX}..{landBox.maxX}, y {landBox.minY}..{landBox.maxY})`)
	check(renderStepped:connectedCount() == 0, "the camera is at rest: nothing is connected to RenderStepped")
end
mapCameraChecks()

-- Every region reads as its look in the lore palette: the average of its provinces' lore colours
-- weighted by their area on the map (a large province decides much of a region's look).
local function regionLookChecks()
	local function area(path): number
		local sum, count = 0, #path // 2
		for i = 1, count do
			local j = i % count + 1
			sum += path[2 * i - 1] * path[2 * j] - path[2 * j - 1] * path[2 * i]
		end
		return math.abs(sum) / 2
	end
	local sums = {}
	for _, sub in MapData.subTerritories do
		local size = 0
		for _, path in sub.paths do
			size += area(path)
		end
		local colour = MapConfig.terrainColor(sub.provinceId)
		local sum = sums[sub.regionId] or { r = 0, g = 0, b = 0, area = 0 }
		sums[sub.regionId] = sum
		sum.r += colour.R * size
		sum.g += colour.G * size
		sum.b += colour.B * size
		sum.area += size
	end
	local function greenest(c): boolean
		return c.G > c.R and c.G > c.B
	end
	-- Each look as a test of the average colour c, its hue h (degrees), saturation s and value v.
	local looks: { { regionId: string, look: string, test: (any, number, number, number) -> boolean } } = {
		{ regionId = "north", look = "cold grey-green", test = function(c, _h, s)
			return greenest(c) and s <= 0.25
		end },
		{ regionId = "iron_islands", look = "grey rock", test = function(_c, _h, s)
			return s <= 0.08
		end },
		{ regionId = "riverlands", look = "lush green", test = function(c, _h, s)
			return greenest(c) and s >= 0.25
		end },
		{ regionId = "vale", look = "green valleys", test = function(c, _h, s)
			return greenest(c) and s >= 0.12
		end },
		{ regionId = "westerlands", look = "green-brown hills", test = function(_c, h, s)
			return h >= 45 and h <= 75 and s >= 0.15
		end },
		{ regionId = "reach", look = "rich green with gold", test = function(c, h, s)
			return greenest(c) and h <= 85 and s >= 0.3
		end },
		{ regionId = "crownlands", look = "soft green", test = function(c, _h, _s, v)
			return greenest(c) and v >= 0.65
		end },
		{ regionId = "stormlands", look = "dark green", test = function(c, _h, _s, v)
			return greenest(c) and v <= 0.6
		end },
		{ regionId = "dorne", look = "sand and ochre", test = function(c, h, _s, v)
			return c.R > c.G and c.G > c.B and h >= 30 and h <= 50 and v >= 0.65
		end },
	}
	local wrong = {}
	for _, entry in looks do
		local sum = sums[entry.regionId]
		local average = roblox.Color3.new(sum.r / sum.area, sum.g / sum.area, sum.b / sum.area)
		local h, s, v = average:ToHSV()
		if not entry.test(average, h * 360, s, v) then
			table.insert(wrong, `{entry.regionId} #{average:ToHex()} is not {entry.look}`)
		end
	end
	check(#wrong == 0, `every region reads as its look, weighted by area ({if #wrong > 0 then table.concat(wrong, "; ") else "nine regions"})`)
	local neck = MapConfig.terrainColor("moat_cailin")
	local neckHue, _, neckValue = neck:ToHSV()
	check(neckValue <= 0.5 and neckHue * 360 >= 50 and neckHue * 360 <= 90, "the Neck (Moat Cailin) is a dark green-brown marsh")
end
regionLookChecks()

-- Wrap up -----------------------------------------------------------------------------------------
task.wait(0) -- let spawned threads settle
for _, line in serverLog do
	if string.find(line, "error:", 1, true) then
		table.insert(handlerErrors, `server {line}`)
	end
end
check(#handlerErrors == 0, `no errors in client handlers or the server ({#handlerErrors})`)
for _, message in handlerErrors do
	print(`    {message}`)
end
print(if failures == 0 then "UI smoke test passed" else `UI smoke test: {failures} failure(s)`)
process.exit(if failures == 0 then 0 else 1)
