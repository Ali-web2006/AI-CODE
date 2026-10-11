--!strict
--[[
	EventText — player-facing text for simulation events. Narrative text lives here, separate from
	the simulation code that emits the structured events.

	format(event, viewerHouseId) returns (text, tone) where tone is "good", "bad", "info" or
	"quiet" so the interface can colour and prioritise the message.
]]

local CalendarDate = require(script.Parent.Parent.Util.CalendarDate)
local Content = require(script.Parent.Parent.Data.Content)

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
	end
	return `{kind}`, "quiet"
end

return EventText
