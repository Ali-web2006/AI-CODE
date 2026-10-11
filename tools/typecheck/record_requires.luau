--[[
	Records, for every script in a built place, which source line requires which module.

	The Luau analyzer resolves string requires, while Roblox code requires Instances
	(`require(script.Parent.X)`). Loading the real place in Lune and logging each require call
	gives the exact target of every instance-path require. tools/typecheck/typecheck.mjs then
	rewrites them to string requires (line-preserving) so cross-module types flow as in Studio.

	ModuleScripts are loaded normally. Scripts and LocalScripts are executed only far enough to
	record their requires (errors after that point are ignored).

	Usage: lune run tools/typecheck/record_requires.luau build/IronThrone.rbxl build/requires.json
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local place = roblox.deserializePlace(fs.readFile(process.args[1]))
local outputPath = process.args[2]

local DATATYPES = {
	"Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Enum", "Faces", "Font",
	"NumberRange", "NumberSequence", "NumberSequenceKeypoint", "Rect", "UDim", "UDim2", "Vector2", "Vector3", "Instance",
}

local cache = {}
local records: { [string]: { { line: number, target: string } } } = {}

local function record(chunkName: string, line: number, module)
	records[chunkName] = records[chunkName] or {}
	table.insert(records[chunkName], { line = line, target = module:GetFullName() })
end

local function environment(scriptInstance, requireFn)
	local env = { script = scriptInstance, game = place, workspace = place:GetService("Workspace"), require = requireFn }
	for _, name in DATATYPES do
		env[name] = (roblox :: any)[name]
	end
	return env
end

local function requireModule(module)
	record(debug.info(2, "s"), debug.info(2, "l"), module)
	if cache[module] then
		return cache[module].value
	end
	local chunk = luau.load(module.Source, { debugName = module:GetFullName(), environment = environment(module, requireModule) })
	local value = chunk()
	cache[module] = { value = value }
	return value
end

local scripts = {}
for _, instance in place:GetDescendants() do
	if instance.ClassName == "ModuleScript" or instance.ClassName == "Script" or instance.ClassName == "LocalScript" then
		table.insert(scripts, { name = instance:GetFullName(), className = instance.ClassName, source = instance.Source })
		if instance.ClassName == "ModuleScript" then
			requireModule(instance)
		end
	end
end

for _, instance in place:GetDescendants() do
	if instance.ClassName == "Script" or instance.ClassName == "LocalScript" then
		local chunkName = `[string "{instance:GetFullName()}"]`
		local function scriptRequire(module)
			record(chunkName, debug.info(2, "l"), module)
			return requireModule(module)
		end
		-- WaitForChild would yield in the engine; for recording, the children already exist.
		local source = string.gsub(instance.Source, ":WaitForChild%(", ":FindFirstChild(")
		pcall(luau.load(source, { debugName = instance:GetFullName(), environment = environment(instance, scriptRequire) }))
	end
end

fs.writeFile(outputPath, serde.encode("json", { modules = scripts, requires = records }))
print(`recorded requires for {#scripts} scripts -> {outputPath}`)
