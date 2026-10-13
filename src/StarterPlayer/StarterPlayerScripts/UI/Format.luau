--!strict
-- Format — number and text formatting for the interface (presentation only).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventText = require(ReplicatedStorage.Shared.Text.EventText)

local Format = {}

-- 4200 -> "4,200": head counts, written the same way as in server messages and event text.
function Format.troops(count: number): string
	return EventText.troops(count)
end

-- 1234.5 -> "1,234.5"
function Format.gold(value: number, decimals: number?): string
	local places = decimals or 1
	local negative = value < 0
	local text = string.format(`%.{places}f`, math.abs(value))
	local integer, fraction = string.match(text, "^(%d+)(.*)$")
	local grouped = (integer :: string):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return (if negative then "-" else "") .. grouped .. (fraction or "")
end

-- 3.25 -> "+3.3", -2 -> "-2.0"
function Format.signed(value: number, decimals: number?): string
	local text = Format.gold(value, decimals)
	if value >= 0 then
		return "+" .. text
	end
	return text
end

-- 0.105 -> "+10.5%"
function Format.percent(value: number): string
	return string.format("%+.1f%%", value * 100)
end

function Format.multiplier(value: number): string
	return string.format("x%.2f", value)
end

function Format.capitalize(text: string): string
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- Escapes text for RichText labels.
function Format.escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

return Format
