--[[
	Test runner (Lune).

	Usage, from the repository root:
	  lune run tests/run.luau            run every spec
	  lune run tests/run.luau clock      run specs whose file name contains "clock"

	Each spec file in tests/specs returns function(context) and registers tests through
	context.test(name, fn). The context provides:
	  vr        the VirtualRoblox instance tree (vr.require("ServerScriptService.App.CampaignHost"))
	  fx        Fixtures (deterministic sims, hosts, configs)
	  expect    assertion helpers
	Exit code is 1 if any test fails.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local VirtualRoblox = require("./harness/VirtualRoblox")
local Fixtures = require("./harness/Fixtures")
local Expect = require("./harness/Expect")

local filter = process.args[1]
local root = process.cwd

local vr = VirtualRoblox.new(root)
local fx = Fixtures.new(vr)

local specFiles = {}
for _, entry in fs.readDir(`{root}/tests/specs`) do
	if string.sub(entry, -10) == ".spec.luau" and (filter == nil or string.find(entry, filter, 1, true)) then
		table.insert(specFiles, entry)
	end
end
table.sort(specFiles)

local passed, failed = 0, 0
local failures = {}

for _, file in specFiles do
	local spec = require(`./specs/{string.sub(file, 1, -6)}`)
	local tests = {}
	spec({
		vr = vr,
		fx = fx,
		expect = Expect,
		test = function(name: string, fn: () -> ())
			table.insert(tests, { name = name, fn = fn })
		end,
	})
	print(`\n{file}`)
	for _, case in tests do
		local ok, err = xpcall(case.fn, function(message)
			return debug.traceback(tostring(message), 2)
		end)
		if ok then
			passed += 1
			print(`  PASS  {case.name}`)
		else
			failed += 1
			print(`  FAIL  {case.name}`)
			table.insert(failures, { file = file, name = case.name, err = err })
		end
	end
end

print(`\n{passed} passed, {failed} failed`)
for _, failure in failures do
	print(`\n--- {failure.file} :: {failure.name}\n{failure.err}`)
end

process.exit(if failed > 0 then 1 else 0)
