--[[
	Expect — minimal assertion helpers for the Lune test runner. Each failure raises an error with
	a precise message; the runner records it against the current test.
]]

local Expect = {}

local function describe(value: any): string
	if type(value) == "string" then
		return `"{value}"`
	elseif type(value) == "table" then
		local ok, serde = pcall(require, "@lune/serde")
		if ok then
			local encodeOk, text = pcall(serde.encode, "json", value)
			if encodeOk then
				return if #text > 300 then string.sub(text, 1, 300) .. "..." else text
			end
		end
	end
	return tostring(value)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function Expect.equal(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "values differ"}: expected {describe(expected)}, got {describe(actual)}`, 2)
	end
end

function Expect.notEqual(actual: any, unexpected: any, label: string?)
	if actual == unexpected then
		error(`{label or "values are equal"}: did not expect {describe(unexpected)}`, 2)
	end
end

function Expect.truthy(value: any, label: string?)
	if not value then
		error(`{label or "expected a truthy value"}: got {describe(value)}`, 2)
	end
end

function Expect.falsy(value: any, label: string?)
	if value then
		error(`{label or "expected a falsy value"}: got {describe(value)}`, 2)
	end
end

function Expect.near(actual: number, expected: number, tolerance: number, label: string?)
	if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
		error(`{label or "numbers differ"}: expected {expected} ± {tolerance}, got {describe(actual)}`, 2)
	end
end

function Expect.deepEqual(actual: any, expected: any, label: string?)
	if not deepEqual(actual, expected) then
		error(`{label or "tables differ"}:\n  expected {describe(expected)}\n  got      {describe(actual)}`, 2)
	end
end

function Expect.contains(list: { any }, value: any, label: string?)
	for _, item in list do
		if item == value then
			return
		end
	end
	error(`{label or "list does not contain value"}: {describe(value)} not in {describe(list)}`, 2)
end

-- Asserts that some string in `list` contains `fragment` (plain substring match).
function Expect.anyContains(list: { string }, fragment: string, label: string?)
	for _, item in list do
		if string.find(item, fragment, 1, true) then
			return
		end
	end
	error(`{label or "no entry contains fragment"}: "{fragment}" not found in {describe(list)}`, 2)
end

function Expect.result(result: any, expectedCode: string, label: string?)
	if type(result) ~= "table" or result.code ~= expectedCode then
		error(`{label or "unexpected result"}: expected code {expectedCode}, got {describe(result)}`, 2)
	end
end

Expect.deepEqualValue = deepEqual

return Expect
