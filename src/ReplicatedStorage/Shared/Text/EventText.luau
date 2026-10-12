--!strict
--[[
	EventText — player-facing text for simulation events. Narrative text lives here, separate from
	the simulation code that emits the structured events.

	format(event, viewerHouseId) returns (text, tone) where tone is "good", "bad", "info" or
	"quiet" so the interface can colour and prioritise the message.

	troops(count) is the shared way to write a head count ("10,800"); server command messages use
	it too, so every number of men reads the same everywhere.
]]

local CalendarDate = require(script.Parent.Parent.Util.CalendarDate)
local Content = require(script.Parent.Parent.Data.Content)
local MilitaryRules = require(script.Parent.Parent.Rules.MilitaryRules)

local EventText = {}

local function houseName(houseId: string?, viewerHouseId: string?): string
	if houseId == nil then
		return "an unknown house"
	end
	if houseId == viewerHouseId then
		return "your house"
	end
	local house = Content.houses[houseId]
	return if house then house.name else houseId
end

local function provinceName(provinceId: string?): string
	local province = provinceId and Content.provinces[provinceId]
	return if province then province.name else tostring(provinceId)
end

local function gold(value: number): string
	return string.format("%.1f", value)
end

-- 10800 -> "10,800" (rounded to whole men).
function EventText.troops(count: number): string
	local digits = string.format("%d", math.floor(math.abs(count) + 0.5))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return (if count < 0 then "-" else "") .. grouped
end

-- "Army of Winterfell": army events carry the id of the province the army was raised in.
local function armyName(data: { [string]: any }): string
	return MilitaryRules.armyName({ originId = data.originId or data.provinceId })
end

local function plural(count: number, singular: string, pluralForm: string): string
	return if count == 1 then `{count} {singular}` else `{count} {pluralForm}`
end

function EventText.format(event: { [string]: any }, viewerHouseId: string?): (string, string)
	local data = event.data or {}
	local kind = event.kind

	if kind == "MonthlyReport" then
		local net = data.net :: number
		return `{CalendarDate.formatMonthIndex(data.monthIndex)} accounts: income {gold(data.income)}, expenses {gold(data.expenses)}, net {if net >= 0 then "+" else ""}{gold(net)}. Treasury {gold(data.treasury)}.`,
			"quiet"
	elseif kind == "TreasuryCrisis" then
		return `The treasury is empty ({gold(data.treasury)} gold). Expenses exceed income: develop holdings or cut costs.`, "bad"
	elseif kind == "ProvinceDeveloped" then
		if data.houseId == viewerHouseId then
			return `You developed {provinceName(data.provinceId)} to level {data.development} for {data.cost} gold.`, "good"
		end
		return `{houseName(data.houseId, viewerHouseId)} developed {provinceName(data.provinceId)} to level {data.development}.`, "quiet"
	elseif kind == "RelationsImproved" then
		if data.targetHouseId == viewerHouseId then
			return `{houseName(data.actorHouseId, viewerHouseId)} sent an envoy to your court. Relations +{data.gain} (now {data.score}).`, "good"
		elseif data.actorHouseId == viewerHouseId then
			return `Your envoy was received by {houseName(data.targetHouseId, viewerHouseId)}. Relations +{data.gain} (now {data.score}).`, "good"
		end
		return `{houseName(data.actorHouseId, viewerHouseId)} courted {houseName(data.targetHouseId, viewerHouseId)} (relations now {data.score}).`, "quiet"
	elseif kind == "HouseClaimed" then
		return `{data.playerName} now leads {houseName(data.houseId, nil)}.`, "info"
	elseif kind == "PlayerLeft" then
		return `{data.playerName} has left. The AI governs {houseName(data.houseId, nil)} until they return.`, "info"
	elseif kind == "CampaignSaved" then
		return `Campaign saved to {data.backend} on {CalendarDate.format(data.date)}.`, "info"
	elseif kind == "CampaignLoaded" then
		return `Campaign loaded: {CalendarDate.format(data.date)}. The clock is paused.`, "info"
	elseif kind == "ArmyRaised" then
		return `The {armyName(data)} has been raised: {EventText.troops(data.troops)} men.`, "info"
	elseif kind == "LeviesCalled" then
		return `The banners are called to {provinceName(data.provinceId)}: {plural(data.armies, "army", "armies")}, {EventText.troops(data.troops)} men.`,
			"info"
	elseif kind == "ArmyArrived" then
		return `The {armyName(data)} has reached {provinceName(data.provinceId)}.`, "info"
	elseif kind == "ArmySplit" then
		return `The {armyName(data)} divided: {EventText.troops(data.troops)} men march under a new banner.`, "quiet"
	elseif kind == "ArmiesMerged" then
		return `Armies joined the {armyName(data)}: {EventText.troops(data.troops)} men now march together.`, "quiet"
	elseif kind == "ArmyDisbanded" then
		return `The {armyName(data)} was disbanded: {EventText.troops(data.returned)} of {EventText.troops(data.troops)} men returned to the levies.`,
			"quiet"
	elseif kind == "ArmyStarving" then
		return `The {armyName(data)} has run out of supplies in {provinceName(data.provinceId)}. Men are dying.`, "bad"
	elseif kind == "ArmyDesertion" then
		return `The {armyName(data)} melted away in {provinceName(data.provinceId)}: its last {EventText.troops(data.troops)} men deserted.`,
			"bad"
	end
	return `{kind}`, "quiet"
end

return EventText
