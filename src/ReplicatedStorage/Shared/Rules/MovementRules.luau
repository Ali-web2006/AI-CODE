--!strict
--[[
	MovementRules — routes over the province graph (GameConfig.Military, docs/GAME_DESIGN.md
	§Military). Used by the server to validate and execute march orders and by the client to
	preview a route and its arrival time, so both always agree.

	findPath is Dijkstra over Content.provinces adjacency with MilitaryRules.legDays as the edge
	cost; sea edges are used only when the army can sail. It is deterministic:
	  * neighbours are visited in sorted id order;
	  * among routes with the same total days, the lexicographically smallest list of stops wins
	    (compared stop by stop, a shorter prefix first), so equal-length detours never depend on
	    table iteration order.
	A route never includes its starting province and ends at the destination.

	The sorted neighbour lists are static and cached in a module-level table on first use;
	nothing is ever stored on Content, which is frozen.
]]

local Content = require(script.Parent.Parent.Data.Content)
local MilitaryRules = require(script.Parent.MilitaryRules)

local MovementRules = {}

-- provinceId -> neighbour ids in sorted order (content is static, so this never goes stale).
local neighbourCache: { [string]: { string } } = {}

local function sortedNeighbours(provinceId: string): { string }
	local cached = neighbourCache[provinceId]
	if cached then
		return cached
	end
	local neighbours: { string } = {}
	local definition = Content.provinces[provinceId]
	if definition then
		for neighbourId in definition.adjacent do
			if Content.provinces[neighbourId] then
				table.insert(neighbours, neighbourId)
			end
		end
		table.sort(neighbours)
	end
	neighbourCache[provinceId] = neighbours
	return neighbours
end

-- True when route `a` sorts before route `b`: compared stop by stop, a shorter prefix first.
local function routeLess(a: { string }, b: { string }): boolean
	for index = 1, math.min(#a, #b) do
		if a[index] ~= b[index] then
			return a[index] < b[index]
		end
	end
	return #a < #b
end

--[[
	Fastest route from `fromId` to `toId` for an army made of `units`.
	Returns (stops, totalDays): stops excludes fromId and ends with toId ({} and 0 when the two are
	the same province). Returns (nil, 0) when there is no route, or when either id is unknown.
	Sea edges are considered only when `canSail` is true.
]]
function MovementRules.findPath(
	fromId: string,
	toId: string,
	units: MilitaryRules.Units,
	canSail: boolean,
	config: MilitaryRules.MilitaryConfig
): ({ string }?, number)
	if not Content.provinces[fromId] or not Content.provinces[toId] then
		return nil, 0
	end
	if fromId == toId then
		return {}, 0
	end

	local days: { [string]: number } = { [fromId] = 0 }
	local routes: { [string]: { string } } = { [fromId] = {} }
	local settled: { [string]: boolean } = {}
	while true do
		-- The reached, unsettled province with the fewest days (then the smallest route).
		local current: string? = nil
		for _, provinceId in Content.provinceIds do
			if days[provinceId] ~= nil and not settled[provinceId] then
				if current == nil
					or days[provinceId] < days[current]
					or (days[provinceId] == days[current] and routeLess(routes[provinceId], routes[current]))
				then
					current = provinceId
				end
			end
		end
		if current == nil then
			return nil, 0
		end
		if current == toId then
			return table.clone(routes[current]), days[current]
		end
		settled[current] = true

		local adjacent = Content.provinces[current].adjacent
		for _, neighbourId in sortedNeighbours(current) do
			if not settled[neighbourId] and (canSail or adjacent[neighbourId] ~= "sea") then
				local leg = MilitaryRules.legDays(current, neighbourId, units, config)
				if leg then
					local candidateDays = days[current] + leg
					local candidate = table.clone(routes[current])
					table.insert(candidate, neighbourId)
					local known = days[neighbourId]
					if known == nil
						or candidateDays < known
						or (candidateDays == known and routeLess(candidate, routes[neighbourId]))
					then
						days[neighbourId] = candidateDays
						routes[neighbourId] = candidate
					end
				end
			end
		end
	end
end

--[[
	Total days to follow `path` (stops after `fromId`, as findPath returns them) with `units`.
	0 for an empty path. A path with a step between provinces that are not adjacent cannot be
	travelled and yields math.huge.
]]
function MovementRules.routeDays(
	fromId: string,
	path: { string },
	units: MilitaryRules.Units,
	config: MilitaryRules.MilitaryConfig
): number
	local total = 0
	local previous = fromId
	for _, stop in path do
		local leg = MilitaryRules.legDays(previous, stop, units, config)
		if leg == nil then
			return math.huge
		end
		total += leg
		previous = stop
	end
	return total
end

return MovementRules
