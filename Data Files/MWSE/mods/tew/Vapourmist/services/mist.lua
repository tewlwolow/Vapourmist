local shader = require("tew.Vapourmist.components.shader")

local MIN_DISTANCE = 8192 * 1.5
local MAX_DISTANCE = 8192 * 3
local MAX_DEPTH = 8192 / 10
local DENSITY = 10
local WtC = tes3.worldController.weatherController

local fogId = "tew_mist"

local mist = {}

---@type mwseTimer
local FOG_TIMER

---@type fogParams
local fogParams = {
    color = tes3vector3.new(),
    center = tes3vector3.new(),
    radius = tes3vector3.new(MAX_DISTANCE, MAX_DISTANCE, MAX_DEPTH),
    density = DENSITY,
}

local function getCloudColourMix(fogComp, skyComp)
	return math.lerp(fogComp, skyComp, 0.2)
end

local function getDarkerColour(comp)
	return math.clamp(math.lerp(comp, 0.0, 0.15), 0.03, 0.88)
end

-- Calculate output colours from current fog colour --
local function getOutputValues()
	local currentFogColor = WtC.currentFogColor:copy()
	local currentSkyColor = WtC.currentSkyColor:copy()
	local weatherColour = {
		r = getCloudColourMix(currentFogColor.r, currentSkyColor.r),
		g = getCloudColourMix(currentFogColor.g, currentSkyColor.g),
		b = getCloudColourMix(currentFogColor.b, currentSkyColor.b)
	}

	return tes3vector3.new(
        getDarkerColour(weatherColour.r),
        getDarkerColour(weatherColour.g),
        getDarkerColour(weatherColour.b)
    )
end

local function updateDensity(dist)
    local f = math.clamp(dist, MIN_DISTANCE, MAX_DISTANCE)
    f = math.remap(f, MIN_DISTANCE, MAX_DISTANCE, 15.0, 0.0)

    local playerPos = tes3.mobilePlayer.position:copy()

    local mistCenter = tes3vector3.new(
        (playerPos.x),
        (playerPos.y),
        0
    )

    fogParams.density = f
    fogParams.center = mistCenter
    fogParams.color = getOutputValues()

    shader.createOrUpdateFog(fogId, fogParams)
end

local function update()
    if tes3.player.cell.isInterior then
        return
    end

	local currDist = 0

    if currDist <= MAX_DISTANCE then
        updateDensity(currDist)
    end

end
event.register(tes3.event.loaded, function()
    FOG_TIMER = timer.start({
        iterations = -1,
        duration = 0.01,
        callback = update,
        type = timer.game,
        data = {},
    })
end)

--- @param e cellChangedEventData
function mist.onCellChanged(e)
    local dist = 5000
    if dist > MAX_DISTANCE or e.cell.isInterior then
        shader.deleteFog(fogId)
        FOG_TIMER:pause()
    else
        update()
        shader.createOrUpdateFog(fogId, fogParams)
        FOG_TIMER:resume()
    end
end

return mist
