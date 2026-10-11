--!strict
--[[
	CalendarDate — the campaign's date representation.

	A date is a plain, serializable table { year, month, day } (all integers, month/day 1-based).
	The calendar uses twelve months with fixed lengths and NO leap years (a 365-day year). This keeps
	day arithmetic exact and deterministic; Westerosi reckoning has no canonical leap rule anyway.

	Two derived integer forms are used by the simulation:
	  * dayNumber  = days since 1 Jan of year 0. Strictly increasing, used for ordering.
	  * monthIndex = year * 12 + (month - 1). Identifies a calendar month, used to guarantee that
	                 monthly processing happens exactly once per month.
]]

export type Date = {
	year: number,
	month: number,
	day: number,
}

local CalendarDate = {}

CalendarDate.Era = "AC"
CalendarDate.DaysPerYear = 365

local MONTH_LENGTHS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local MONTH_NAMES = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}

-- Cumulative days before each month: CUMULATIVE[1] = 0, CUMULATIVE[2] = 31, ...
local CUMULATIVE = {}
do
	local running = 0
	for month, length in MONTH_LENGTHS do
		CUMULATIVE[month] = running
		running += length
	end
end

local function isInteger(value: any): boolean
	return type(value) == "number" and value == value and math.floor(value) == value
end

function CalendarDate.new(year: number, month: number, day: number): Date
	local date = { year = year, month = month, day = day }
	assert(CalendarDate.isValid(date), `CalendarDate.new: invalid date {year}-{month}-{day}`)
	return date
end

function CalendarDate.isValid(date: any): boolean
	if type(date) ~= "table" then
		return false
	end
	if not (isInteger(date.year) and isInteger(date.month) and isInteger(date.day)) then
		return false
	end
	if date.year < 0 or date.month < 1 or date.month > 12 then
		return false
	end
	return date.day >= 1 and date.day <= MONTH_LENGTHS[date.month]
end

function CalendarDate.daysInMonth(month: number): number
	return MONTH_LENGTHS[month]
end

function CalendarDate.monthName(month: number): string
	return MONTH_NAMES[month]
end

function CalendarDate.clone(date: Date): Date
	return { year = date.year, month = date.month, day = date.day }
end

function CalendarDate.toDayNumber(date: Date): number
	return date.year * CalendarDate.DaysPerYear + CUMULATIVE[date.month] + (date.day - 1)
end

function CalendarDate.fromDayNumber(dayNumber: number): Date
	assert(isInteger(dayNumber) and dayNumber >= 0, "CalendarDate.fromDayNumber: invalid day number")
	local year = dayNumber // CalendarDate.DaysPerYear
	local dayOfYear = dayNumber - year * CalendarDate.DaysPerYear
	local month = 12
	for m = 1, 12 do
		if dayOfYear < CUMULATIVE[m] + MONTH_LENGTHS[m] then
			month = m
			break
		end
	end
	return { year = year, month = month, day = dayOfYear - CUMULATIVE[month] + 1 }
end

function CalendarDate.addDays(date: Date, days: number): Date
	return CalendarDate.fromDayNumber(CalendarDate.toDayNumber(date) + days)
end

function CalendarDate.monthIndex(date: Date): number
	return date.year * 12 + (date.month - 1)
end

function CalendarDate.monthIndexToYearMonth(monthIndex: number): (number, number)
	return monthIndex // 12, (monthIndex % 12) + 1
end

-- Negative when a < b, zero when equal, positive when a > b.
function CalendarDate.compare(a: Date, b: Date): number
	return CalendarDate.toDayNumber(a) - CalendarDate.toDayNumber(b)
end

-- Whole years elapsed from `birth` to `now` (age on `now`).
function CalendarDate.yearsBetween(birth: Date, now: Date): number
	local years = now.year - birth.year
	if now.month < birth.month or (now.month == birth.month and now.day < birth.day) then
		years -= 1
	end
	return years
end

function CalendarDate.format(date: Date): string
	return `{date.day} {MONTH_NAMES[date.month]} {date.year} {CalendarDate.Era}`
end

function CalendarDate.formatMonthIndex(monthIndex: number): string
	local year, month = CalendarDate.monthIndexToYearMonth(monthIndex)
	return `{MONTH_NAMES[month]} {year} {CalendarDate.Era}`
end

return CalendarDate
