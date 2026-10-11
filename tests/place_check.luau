--[[
	Place check (Lune): inspects a place file built by Rojo and loads every ModuleScript inside it
	with Roblox datatypes (Color3, UDim2, Font, Enum, ...) provided by @lune/roblox.

	This verifies what the pure-Luau specs cannot:
	  * the Rojo project produces the expected instance tree and service properties
	  * every ModuleScript, including client UI and engine adapters, resolves its requires and runs
	    its top-level code against real Roblox datatypes (catching e.g. invalid Enum items or
	    datatype constructors at require time)
	Instances that need the live engine (signals, Players.LocalPlayer, DataStores) are only touched
	inside functions, which this check does not call.

	Usage:
	  rojo build default.project.json -o build/IronThrone.rbxl
	  lune run tests/place_check.luau build/IronThrone.rbxl
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local placePath = process.args[1] or "build/IronThrone.rbxl"
local game = roblox.deserializePlace(fs.readFile(placePath))

local failures = 0
local function check(condition: boolean, message: string)
	if condition then
		print(`  ok    {message}`)
	else
		failures += 1
		print(`  FAIL  {message}`)
	end
end

print(`Place: {placePath}`)
local players = game:GetService("Players")
check(players.CharacterAutoLoads == false, "Players.CharacterAutoLoads is false (no avatars in a strategy game)")
local replicated = game:GetService("ReplicatedStorage")
local server = game:GetService("ServerScriptService")
local starterPlayer = game:GetService("StarterPlayer")
check(replicated:FindFirstChild("Shared") ~= nil, "ReplicatedStorage.Shared exists")
check(server:FindFirstChild("Bootstrap") ~= nil and server.Bootstrap.ClassName == "Script", "ServerScriptService.Bootstrap is a Script")
local playerScripts = starterPlayer:FindFirstChild("StarterPlayerScripts")
check(playerScripts ~= nil and playerScripts:FindFirstChild("ClientBootstrap") ~= nil
	and playerScripts.ClientBootstrap.ClassName == "LocalScript", "StarterPlayerScripts.ClientBootstrap is a LocalScript")

-- Load every ModuleScript with a Roblox-like environment.
local datatypes = {
	"Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Enum", "Faces", "Font",
	"NumberRange", "NumberSequence", "NumberSequenceKeypoint", "PhysicalProperties", "Ray", "Rect", "Region3",
	"Region3int16", "UDim", "UDim2", "Vector2", "Vector2int16", "Vector3", "Vector3int16", "Instance",
}

local cache = {}
local loading = {}
local function requireModule(module)
	if cache[module] ~= nil then
		return cache[module].value
	end
	assert(module.ClassName == "ModuleScript", `require target {module:GetFullName()} is a {module.ClassName}`)
	assert(not loading[module], `cyclic require of {module:GetFullName()}`)
	loading[module] = true
	local env = { script = module, game = game, workspace = game:GetService("Workspace"), require = requireModule }
	for _, name in datatypes do
		env[name] = (roblox :: any)[name]
	end
	local chunk = luau.load(module.Source, { debugName = module:GetFullName(), environment = env })
	local value = chunk()
	loading[module] = nil
	cache[module] = { value = value }
	return value
end

local modules = {}
for _, descendant in game:GetDescendants() do
	if descendant.ClassName == "ModuleScript" then
		table.insert(modules, descendant)
	end
end
table.sort(modules, function(a, b)
	return a:GetFullName() < b:GetFullName()
end)

-- Modules whose top-level code needs live engine services would be listed here with the reason.
-- Every module currently keeps engine access inside functions, so nothing is skipped.
local SKIP: { [string]: string } = {}

print(`Loading {#modules} ModuleScripts`)
for _, module in modules do
	local name = module:GetFullName()
	if SKIP[name] then
		print(`  skip  {name} ({SKIP[name]})`)
	else
		local ok, err = pcall(requireModule, module)
		check(ok, if ok then name else `{name}: {tostring(err)}`)
	end
end

print(if failures == 0 then "place check passed" else `place check: {failures} failure(s)`)
process.exit(if failures == 0 then 0 else 1)
