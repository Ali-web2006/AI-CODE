--[[
	UI smoke test (Lune): runs the real client code against the real server pipeline, headlessly.

	How it works:
	  * Every Instance the client creates is a real @lune/roblox Instance behind a thin proxy, so
	    every property assignment is validated against Roblox's reflection database (unknown
	    property names and wrong value types raise errors).
	  * The proxy emulates what Lune lacks: signals (Activated, MouseEnter, ...), attribute and
	    property-changed signals, AbsoluteSize, Players.LocalPlayer, UserInputService, TweenService.
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
		return VIEWPORT
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
	},
}
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
local wedgeCount = 0
for _, part in reals[land]:GetChildren() do
	if part.ClassName == "WedgePart" then
		wedgeCount += 1
	end
end
check(wedgeCount > 4000, `map land is drawn with flat triangles ({wedgeCount} wedges)`)
local crestCount = 0
for _, house in MapData.houses do
	local crest = mapRoot:FindFirstChild(`Crest_{house.id}`, true)
	if crest and #reals[crest]:FindFirstChild("Art"):GetChildren() > 0 then
		crestCount += 1
	end
end
check(crestCount == 9, `all nine great-house crests are drawn ({crestCount})`)
check(findByText("STARK", "TextLabel") ~= nil and findByText("TARGARYEN", "TextLabel") ~= nil, "great-house labels are shown")
local subBorders = mapRoot:FindFirstChild("SubBorders", true)
local paths = 0
for _, line in reals[subBorders]:GetChildren() do
	if line.ClassName == "Path2D" then
		paths += 1
	end
end
check(paths >= #MapData.subTerritories, `sub-territory borders are drawn ({paths} paths)`)

-- Screen position of a map point, from the canvas the controller placed (UI scale is 1 here).
local function screenAt(x: number, y: number)
	local canvas = mapRoot:FindFirstChild("Canvas")
	local zoom = canvas.Size.X.Offset / MapData.width
	return roblox.Vector3.new(canvas.Position.X.Offset + x * zoom, canvas.Position.Y.Offset + y * zoom, 0)
end
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

-- Time: resume, run two months at speed 3, pause.
click(findByText("Resume", "TextButton"))
click(findByText(">>>", "TextButton"))
for _ = 1, 60 * 6 do
	host:update(1 / 60)
	clock.now += 1 / 60
	pump()
end
check(#store:house("stark").ledger >= 2, "monthly ledgers reached the client")
check(findByText("1 January 297 AC", "TextLabel") == nil, "the date in the top bar advanced")
click(findByText("Pause", "TextButton"))
check(store.campaign.clock.paused == true, "the campaign is paused")

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
