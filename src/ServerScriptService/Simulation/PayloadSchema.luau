--!strict
--[[
	PayloadSchema — strict validation of client-supplied command payloads.

	A schema maps field name -> field type. Validation rejects:
	  * non-table payloads (a nil payload is accepted only for empty schemas),
	  * tables with metatables, unknown or non-string keys, or too many keys,
	  * missing fields and wrongly typed values,
	  * ids that are too long or contain characters outside [A-Za-z0-9_].
	Field types:
	  "id"          non-empty string id, at most maxIdLength characters
	  "speed"       integer in 1..speedCount
	  "boolean"     true/false
]]

export type FieldType = "id" | "speed" | "boolean"
export type Schema = { [string]: FieldType }

export type Limits = {
	maxIdLength: number,
	maxPayloadKeys: number,
	speedCount: number,
}

local PayloadSchema = {}

local function validateField(fieldType: FieldType, value: any, limits: Limits): boolean
	if fieldType == "id" then
		return type(value) == "string"
			and #value > 0
			and #value <= limits.maxIdLength
			and string.match(value, "^[%w_]+$") ~= nil
	elseif fieldType == "speed" then
		return type(value) == "number"
			and value == value
			and math.floor(value) == value
			and value >= 1
			and value <= limits.speedCount
	elseif fieldType == "boolean" then
		return type(value) == "boolean"
	end
	return false
end

-- Returns (true, nil) when valid, otherwise (false, reason). Reasons are for server diagnostics;
-- clients receive a generic InvalidPayload message.
function PayloadSchema.validate(schema: Schema, payload: any, limits: Limits): (boolean, string?)
	if payload == nil then
		if next(schema) == nil then
			return true, nil
		end
		return false, "payload missing"
	end
	if type(payload) ~= "table" then
		return false, `payload must be a table, got {typeof(payload)}`
	end
	if getmetatable(payload) ~= nil then
		return false, "payload has a metatable"
	end

	local keyCount = 0
	for key, value in payload do
		keyCount += 1
		if keyCount > limits.maxPayloadKeys then
			return false, "payload has too many keys"
		end
		if type(key) ~= "string" then
			return false, "payload has a non-string key"
		end
		local fieldType = schema[key]
		if fieldType == nil then
			return false, `unexpected field '{string.sub(key, 1, 32)}'`
		end
		if not validateField(fieldType, value, limits) then
			return false, `field '{key}' is not a valid {fieldType}`
		end
	end
	for field in schema do
		if payload[field] == nil then
			return false, `missing field '{field}'`
		end
	end
	return true, nil
end

return PayloadSchema
