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
local dotsZoomed, framesZoomed, zoomedHolder = routeDots()
check(dotsZoomed > dotsBefore and zoomedHolder == route and route:FindFirstChild("Dot") == firstDot, `zooming in redraws the route in place with closer dots ({dotsBefore} -> {dotsZoomed})`)
click(findByText("-", "TextButton"))
click(findByText("-", "TextButton"))
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
local canvasX = mapRoot:FindFirstChild("Canvas").Position.X.Offset
local grab = { UserInputType = roblox.Enum.UserInputType.MouseButton1, Position = roblox.Vector3.new(600, 300, 0) }
army3Token.InputBegan:Fire(grab)
UserInputService.InputChanged:Fire({ UserInputType = roblox.Enum.UserInputType.MouseMovement, Position = roblox.Vector3.new(640, 300, 0) })
UserInputService.InputEnded:Fire(grab)
army3Token.Activated:Fire()
pump()
check(mapRoot:FindFirstChild("Canvas").Position.X.Offset ~= canvasX and edge(army3Token) < 2 and not armyPanel.Visible, "dragging the map by a token pans it without selecting the army")
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
