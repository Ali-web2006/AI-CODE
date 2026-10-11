--!strict
-- CharacterRules — derived character facts (names, ages) computed identically on server and client.

local CalendarDate = require(script.Parent.Parent.Util.CalendarDate)
local Content = require(script.Parent.Parent.Data.Content)
local GameTypes = require(script.Parent.Parent.Types.GameTypes)

export type CharacterLike = {
	givenName: string,
	houseId: string,
	cultureId: string,
	birthDate: GameTypes.Date,
	deathDate: GameTypes.Date?,
	epithet: string?,
	bastard: boolean?,
}

local CharacterRules = {}

-- "Eddard Stark", or "Jon Snow" for an acknowledged bastard of northern culture.
function CharacterRules.displayName(character: CharacterLike): string
	if character.bastard then
		local culture = Content.cultures[character.cultureId]
		return `{character.givenName} {if culture then culture.bastardSurname else ""}`
	end
	local house = Content.houses[character.houseId]
	return `{character.givenName} {if house then house.surname else ""}`
end

-- Age on `now`; for the dead, age at death.
function CharacterRules.age(character: CharacterLike, now: GameTypes.Date): number
	local reference = character.deathDate or now
	return CalendarDate.yearsBetween(character.birthDate, reference)
end

return CharacterRules
