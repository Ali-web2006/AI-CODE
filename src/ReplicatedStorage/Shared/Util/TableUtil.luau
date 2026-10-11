--!strict
--[[
	TableUtil — small, dependency-free helpers for plain data tables.
	All campaign state is plain data (no Instances, no metatables), so these helpers are safe for
	both simulation code and serialization.
]]

local TableUtil = {}

function TableUtil.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return (value :: any) :: T
	end
	local copy = {}
	for key, child in value :: any do
		copy[TableUtil.deepCopy(key)] = TableUtil.deepCopy(child)
	end
	return (copy :: any) :: T
end

function TableUtil.deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, child in value :: any do
			TableUtil.deepFreeze(child)
		end
		table.freeze(value :: any)
	end
	return value
end

-- Structural equality for plain data (used by tests and save round-trip verification).
function TableUtil.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not TableUtil.deepEqual(value, b[key]) then
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

-- Returns the keys of a dictionary sorted ascending. Used wherever iteration order affects the
-- simulation, because `pairs` order is unspecified and would break determinism.
function TableUtil.sortedKeys<K>(dict: { [K]: any }): { K }
	local keys = {}
	for key in dict do
		table.insert(keys, key)
	end
	table.sort(keys :: any)
	return keys
end

function TableUtil.count(dict: { [any]: any }): number
	local n = 0
	for _ in dict do
		n += 1
	end
	return n
end

function TableUtil.contains<T>(list: { T }, value: T): boolean
	return table.find(list, value) ~= nil
end

return TableUtil
