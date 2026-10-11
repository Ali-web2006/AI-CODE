--[[
	Compile check (Lune): compiles every .luau file under src/ and tests/ with the Luau compiler and
	reports syntax errors. This covers client and engine-adapter code that cannot execute outside
	Roblox.

	Usage, from the repository root:  lune run tests/compile_check.luau
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local root = process.cwd
local files = {}

local function walk(directory: string)
	for _, entry in fs.readDir(directory) do
		local path = `{directory}/{entry}`
		if fs.isDir(path) then
			walk(path)
		elseif string.sub(entry, -5) == ".luau" then
			table.insert(files, path)
		end
	end
end

walk(`{root}/src`)
walk(`{root}/tests`)
table.sort(files)

local failures = 0
for _, path in files do
	local ok, err = pcall(luau.compile, fs.readFile(path))
	if not ok then
		failures += 1
		print(`FAIL {path}\n  {tostring(err)}`)
	end
end

print(`compiled {#files} files, {failures} failure(s)`)
process.exit(if failures > 0 then 1 else 0)
