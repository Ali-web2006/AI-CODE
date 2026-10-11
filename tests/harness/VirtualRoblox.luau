--[[
	VirtualRoblox — runs the game's ModuleScripts headlessly under Lune.

	It reads default.project.json, mirrors the Rojo file mapping into a tree of virtual instances
	and implements just enough of the Roblox module environment for Roblox-agnostic code:
	  * `script`               the virtual instance of the running module
	  * `require(instance)`    loads the mapped .luau file with its own `script`, cached per module
	  * `game:GetService(n)`   returns mapped services (ReplicatedStorage, ServerScriptService, ...)
	  * instance:FindFirstChild / WaitForChild / GetChildren / IsA / GetFullName
	Indexing a missing child raises the same style of error as Roblox, so broken require paths fail
	tests instead of passing silently.

	Modules that use real engine services (Players, DataStoreService, RemoteEvents, UI) are not
	loaded here; they are thin adapters verified in Studio (docs/TEST_PLAN.md).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local VirtualRoblox = {}

local Instance = {}
local instanceMethods = {}

local function newInstance(name: string, className: string, parent: any?, path: string?): any
	local node = {
		_name = name,
		_className = className,
		_parent = parent,
		_children = {},
		_path = path,
	}
	setmetatable(node, Instance)
	if parent then
		parent._children[name] = node
	end
	return node
end

Instance.__index = function(self, key)
	if key == "Name" then
		return rawget(self, "_name")
	elseif key == "ClassName" then
		return rawget(self, "_className")
	elseif key == "Parent" then
		return rawget(self, "_parent")
	end
	local method = instanceMethods[key]
	if method then
		return method
	end
	local child = rawget(self, "_children")[key]
	if child then
		return child
	end
	error(`{key} is not a valid member of {rawget(self, "_className")} "{instanceMethods.GetFullName(self)}"`, 2)
end

Instance.__tostring = function(self)
	return rawget(self, "_name")
end

function instanceMethods.FindFirstChild(self, name)
	return rawget(self, "_children")[name]
end

function instanceMethods.WaitForChild(self, name)
	local child = rawget(self, "_children")[name]
	if not child then
		error(`WaitForChild: {name} does not exist under {instanceMethods.GetFullName(self)} (would yield forever)`, 2)
	end
	return child
end

function instanceMethods.GetChildren(self)
	local list = {}
	for _, child in rawget(self, "_children") do
		table.insert(list, child)
	end
	table.sort(list, function(a, b)
		return rawget(a, "_name") < rawget(b, "_name")
	end)
	return list
end

function instanceMethods.IsA(self, className)
	return rawget(self, "_className") == className
end

function instanceMethods.GetFullName(self)
	local parts = {}
	local node = self
	while node and rawget(node, "_className") ~= "DataModel" do
		table.insert(parts, 1, rawget(node, "_name"))
		node = rawget(node, "_parent")
	end
	return table.concat(parts, ".")
end

function instanceMethods.GetService(self, name)
	local service = rawget(self, "_children")[name]
	if not service then
		service = newInstance(name, name, self, nil)
	end
	return service
end

local function stripSuffix(fileName: string): (string?, string?)
	for _, rule in { { ".server.luau", "Script" }, { ".client.luau", "LocalScript" }, { ".luau", "ModuleScript" } } do
		local suffix, className = rule[1], rule[2]
		if string.sub(fileName, -#suffix) == suffix then
			return string.sub(fileName, 1, -#suffix - 1), className
		end
	end
	return nil, nil
end

-- Mirrors a directory into the virtual tree following Rojo's conventions.
local function mirrorDirectory(node: any, directory: string)
	for _, entry in fs.readDir(directory) do
		local fullPath = `{directory}/{entry}`
		if fs.isDir(fullPath) then
			local initPath = `{fullPath}/init.luau`
			local child
			if fs.isFile(initPath) then
				child = newInstance(entry, "ModuleScript", node, initPath)
			else
				child = newInstance(entry, "Folder", node, nil)
			end
			mirrorDirectory(child, fullPath)
		elseif entry ~= "init.luau" then
			local name, className = stripSuffix(entry)
			if name then
				newInstance(name, className :: string, node, fullPath)
			end
		end
	end
end

local function mirrorProjectNode(node: any, description: { [string]: any }, root: string)
	if description["$path"] then
		local path = `{root}/{description["$path"]}`
		if fs.isDir(path) then
			mirrorDirectory(node, path)
		else
			rawset(node, "_path", path)
		end
	end
	for key, child in description do
		if string.sub(key, 1, 1) ~= "$" then
			local className = child["$className"] or "Folder"
			local childNode = newInstance(key, className, node, nil)
			mirrorProjectNode(childNode, child, root)
		end
	end
end

function VirtualRoblox.new(projectRoot: string)
	local project = serde.decode("json", fs.readFile(`{projectRoot}/default.project.json`))
	local game = newInstance("Game", "DataModel", nil, nil)
	mirrorProjectNode(game, project.tree, projectRoot)

	local cache = {}
	local loading = {}
	local env

	local function virtualRequire(module: any)
		if type(module) ~= "table" or getmetatable(module) ~= Instance then
			error(`require expects a ModuleScript instance, got {typeof(module)}`, 2)
		end
		if rawget(module, "_className") ~= "ModuleScript" then
			error(`require: {instanceMethods.GetFullName(module)} is a {rawget(module, "_className")}, not a ModuleScript`, 2)
		end
		if cache[module] ~= nil then
			return cache[module].value
		end
		if loading[module] then
			error(`require: cyclic dependency on {instanceMethods.GetFullName(module)}`, 2)
		end
		loading[module] = true
		local path = rawget(module, "_path")
		local source = fs.readFile(path)
		local moduleEnv = { script = module, game = env.game, require = env.require }
		local chunk = luau.load(source, { debugName = path, environment = moduleEnv })
		local results = table.pack(chunk())
		loading[module] = nil
		if results.n ~= 1 then
			error(`{instanceMethods.GetFullName(module)} must return exactly one value (returned {results.n})`)
		end
		cache[module] = { value = results[1] }
		return results[1]
	end

	env = {
		game = game,
		require = virtualRequire,
	}

	local self = {}
	self.game = game

	-- Requires a module by dotted path, e.g. "ServerScriptService.Simulation.Simulation".
	function self.require(dottedPath: string)
		local node = game
		for part in string.gmatch(dottedPath, "[^%.]+") do
			node = node[part]
		end
		return virtualRequire(node)
	end

	-- Every ModuleScript in the tree (used to compile-check and load-check all modules).
	function self.allModules()
		local list = {}
		local function walk(node)
			if rawget(node, "_className") == "ModuleScript" then
				table.insert(list, node)
			end
			for _, child in instanceMethods.GetChildren(node) do
				walk(child)
			end
		end
		walk(game)
		return list
	end

	function self.allScripts()
		local list = {}
		local function walk(node)
			local className = rawget(node, "_className")
			if className == "Script" or className == "LocalScript" or className == "ModuleScript" then
				table.insert(list, node)
			end
			for _, child in instanceMethods.GetChildren(node) do
				walk(child)
			end
		end
		walk(game)
		return list
	end

	self.requireInstance = virtualRequire
	self.fullName = instanceMethods.GetFullName
	self.pathOf = function(node)
		return rawget(node, "_path")
	end
	return self
end

return VirtualRoblox
