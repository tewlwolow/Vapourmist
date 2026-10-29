local interior = {}

-- Imports
local util = require("tew.Vapourmist.components.util")
local config = require("tew.Vapourmist.config")
local debugLog = util.debugLog
local shader = require("tew.Vapourmist.components.shader")

-- Constants
local SHADER_NAME = "tew_dust"
local FOG_ID = "tew_interior"
local MIN_STAT_COUNT = 5
local HEIGHTS = { -900, -850, -800, -750 }
local MAX_DISTANCE = 8192 * 3
local BASE_DEPTH = 8192 / 25
local DENSITY = 8
local BASE_COLOUR = {
	r = 0.3,
	g = 0.2,
	b = 0.08,
}

-- Structures

local interiorStatics = {
	"in_bm_cave",
	"in_moldcave",
	"in_mudcave",
	"in_lavacave",
	"in_pycave",
	"in_bonecave",
	"in_bc_cave",
	"in_m_sewer",
	"in_sewer",
	"ab_in_cave",
	"ab_in_kwama",
	"ab_in_lava",
	"ab_in_mvcave",
	"t_cyr_cavegc",
	"t_cyr_cavech",
	"t_cyr_caveww",
	"t_glb_cave",
	"t_mw_cave",
	"t_sky_cave",
	"bm_ic_",
	"bm_ka",
	"in_dae",
	"t_dae_dngruin",
	"in_dwrv_",
	"in_dwe_",
	"t_dwe_dngruin",
	"in_stronghold",
	"in_strong",
	"in_strongruin",
	"dngruin",
	"t_de_dngrtrongh",
	"t_imp_dngsewers",
	"in_om_",
	"dngdirenni",
}

local interiorNames = {
	"barrow",
	"burial",
	"catacomb",
	"cave",
	"cavern",
	"crypt",
	"tomb",
}

-- Functions

local function isAvailable(cell)
	if cell.name then
		if config.blockedInteriors[cell.name] then
			return false
		end
	end

	for _, namePattern in ipairs(interiorNames) do
		if string.find(cell.name:lower(), namePattern) then
			debugLog("Found valid interior by name: " .. cell.name)
			return true
		end
	end

	local count = 0
	for stat in cell:iterateReferences(tes3.objectType.static) do
		local id = stat.object.id:lower()

		for _, statName in ipairs(interiorStatics) do
			if string.startswith(id, statName) then
				count = count + 1
				if count >= MIN_STAT_COUNT then
					debugLog("Found valid interior by static count")
					return true
				end
			end
		end
	end

	debugLog("Not a valid interior")
	return false
end

function interior.hideAll()
	shader.disableFog(SHADER_NAME)
end

function interior.unhideAll()
	shader.enableFog(SHADER_NAME)
end

function interior.removeAllFog()
	shader.deleteFog(SHADER_NAME, FOG_ID)
end

-- Determine fog position for interiors --
local function getFogLocation(cell)
	local pos = { x = 0, y = 0, z = 0 }
	local denom = 0
	local zs = {}

	for stat in cell:iterateReferences() do
		pos.x = pos.x + stat.position.x
		pos.y = pos.y + stat.position.y
		pos.z = pos.z + stat.position.z
		table.insert(zs, stat.position.z)
		denom = denom + 1
	end

	local calcZPos
	if cell.hasWater then
		calcZPos = cell.waterLevel - (table.choice(HEIGHTS) * math.random(1, 3))
	else
		calcZPos = math.lerp((pos.z / denom), math.min(table.unpack(zs)), 0.05)
	end

	return { x = pos.x / denom, y = pos.y / denom, z = calcZPos }
end

---@param val number
---@param coeff string
local function amplifyColour(val, coeff)
	return math.clamp(math.lerp(BASE_COLOUR[coeff], val, 0.8), 0.2, 0.8)
end

---@param cell tes3cell
local function getAverageColour(cell)
	local colour = { r = 0, g = 0, b = 0 }
	local denom = 0

	local ambient = {
		r = math.lerp(cell.ambientColor.r > 0 and cell.ambientColor.r / 100 or BASE_COLOUR.r,
			cell.fogColor.r > 0 and cell.fogColor.r / 100 or BASE_COLOUR.r, 0.5),
		g = math.lerp(cell.ambientColor.g > 0 and cell.ambientColor.g / 100 or BASE_COLOUR.g,
			cell.fogColor.g > 0 and cell.fogColor.g / 100 or BASE_COLOUR.g, 0.5),
		b = math.lerp(cell.ambientColor.b > 0 and cell.ambientColor.b / 100 or BASE_COLOUR.b,
			cell.fogColor.b > 0 and cell.fogColor.b / 100 or BASE_COLOUR.b, 0.5),
	}

	for light in cell:iterateReferences(tes3.objectType.light) do
		local object = light.object
		if (
				object.color[1] < 0 or
				object.color[2] < 0 or
				object.color[3] < 0
			) then
			return
		end
		colour.r = (colour.r + (object.color[1] > 0 and object.color[1] or 55) / 255)
		colour.g = (colour.g + (object.color[2] > 0 and object.color[2] or 55) / 255)
		colour.b = (colour.b + (object.color[3] > 0 and object.color[3] or 55) / 255)
		denom = denom + 1
	end

	colour.r = math.lerp(colour.r / denom, ambient.r, 0.9)
	colour.g = math.lerp(colour.g / denom, ambient.g, 0.9)
	colour.b = math.lerp(colour.b / denom, ambient.b, 0.9)

	if denom == 0 then
		return BASE_COLOUR
	else
		return { r = amplifyColour(colour.r, "r"), g = amplifyColour(colour.g, "g"), b = amplifyColour(colour.b, "b") }
	end
end


---@param cell tes3cell
local function addFog(cell)
	debugLog("Adding interior fog.")

	local interiorFogColor = getAverageColour(cell) or BASE_COLOUR
	local pos = getFogLocation(cell)

	local calcZPos, calcZRad
	local depth = math.random(BASE_DEPTH / 1.2, BASE_DEPTH * 2)
	calcZPos = pos.z + table.choice(HEIGHTS)
	if cell.hasWater then
		calcZRad = depth * 1.5
		calcZPos = cell.waterLevel + calcZRad / 3
	else
		calcZPos = pos.z + (table.choice(HEIGHTS) / math.random(6, 10))
		calcZRad = depth
	end

	local fogParams = {
		color = tes3vector3.new(
			interiorFogColor.r,
			interiorFogColor.g,
			interiorFogColor.b
		),
		center = tes3vector3.new(
			pos.x,
			pos.y,
			calcZPos
		),
		radius = tes3vector3.new(MAX_DISTANCE, MAX_DISTANCE, calcZRad),
		density = math.random(DENSITY / 3, DENSITY * 1.3),
	}

	shader.createOrUpdateFog(
		SHADER_NAME,
		FOG_ID,
		fogParams
	)

	shader.setValue {
		shaderName = SHADER_NAME,
		param = "waterlevel",
		value = calcZPos,
	}
end

function interior.onCellChanged()
	local player = tes3.player
	if not player then return end
	local cell = player.cell
	interior.removeAllFog()
	if not (cell.isOrBehavesAsExterior) then
		debugLog("Starting interior check.")
		if (isAvailable(cell)) then
			addFog(cell)
		end
	end
end

return interior
