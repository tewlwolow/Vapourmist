local shader = require("tew.Vapourmist.components.shader")
local util = require("tew.Vapourmist.components.util")
local debugLog = util.debugLog
local config = require("tew.Vapourmist.config")

local FOG_ID = "tew_mist"

local MAX_DISTANCE = 8192 * 3
local BASE_DEPTH = 8192 / 10

local WtC = tes3.worldController.weatherController
local WorldC = tes3.worldController

local TIMER_DURATION = 0.3

local FADE_DURATION = 0.05
local STEPS = 100
local mistDensity = 0

local mistDeployed = false

local toWeather, postRainMist, lastRegion

local wetWeathers = {
    ["Rain"] = true,
    ["Thunderstorm"] = true
}

local radiusFactors = {
    ["Clear"] = 1.2,
    ["Cloudy"] = 1.3,
    ["Foggy"] = 1.6,
    ["Overcast"] = 1.5,
    ["Rain"] = 1,
    ["Thunderstorm"] = 1,
    ["Ash"] = 1,
    ["Blight"] = 1,
    ["Snow"] = 1,
    ["Blizzard"] = 1
}

local densities = {
    ["Clear"] = 11,
    ["Cloudy"] = 13,
    ["Foggy"] = 16,
    ["Overcast"] = 17,
    ["Rain"] = 10,
    ["Thunderstorm"] = 10,
    ["Ash"] = 10,
    ["Blight"] = 10,
    ["Snow"] = 10,
    ["Blizzard"] = 10
}

local mistShader = {}

local FOG_TIMER, FADE_IN_TIMER, FADE_OUT_TIMER, FADE_OUT_REMOVE_TIMER

local fogParams = {
    color = tes3vector3.new(),
    center = tes3vector3.new(),
    radius = tes3vector3.new(MAX_DISTANCE, MAX_DISTANCE, BASE_DEPTH),
    density = mistDensity,
}

local function stopTimer(timerVal)
    if timerVal and timerVal.state ~= timer.expired then
        timerVal:pause()
        timerVal:cancel()
    end
end

local function isAvailable(weather, gameHour)
    local weatherName = weather.name

    if config.blockedMist[weatherName] then return false end

    return
    ((
        (gameHour > WtC.sunriseHour - 1 and gameHour < WtC.sunriseHour + 1.5)
    or
        (gameHour >= WtC.sunsetHour - 0.4 and gameHour < WtC.sunsetHour + 2))
    and not
        wetWeathers[weatherName])
    or
    (
        config.mistyWeathers[weatherName]
    )
end

local function getCloudColourMix(fogComp, skyComp)
    return math.lerp(fogComp, skyComp, 0.1)
end

local function getBleachedColour(comp)
    return math.clamp(math.lerp(comp, 1.0, 0.07), 0.03, 0.9)
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
    getBleachedColour(weatherColour.r),
    getBleachedColour(weatherColour.g),
    getBleachedColour(weatherColour.b)
)
end

local function fadeIn()
    local density = densities[toWeather.name]
    if mistDensity >= density then
        mistDensity = density
        return
    end
    mistDensity = mistDensity + (density/STEPS)
end

local function fadeOut()
    local density = densities[toWeather.name]
    if mistDensity <= 0 then
        mistDensity = 0
        return
    end
    mistDensity = mistDensity - (density/STEPS)
end

local function updateMist()
    if tes3.player.cell.isInterior then
        return
    end

    local playerPos = tes3.mobilePlayer.position:copy()

    local mistCenter = tes3vector3.new(
        (playerPos.x),
        (playerPos.y),
        0
    )

    fogParams.radius.z = BASE_DEPTH * radiusFactors[toWeather.name]
    fogParams.density = mistDensity
    fogParams.center = mistCenter
    fogParams.color = getOutputValues()
    shader.createOrUpdateFog(FOG_ID, fogParams)
end

function mistShader.onLoaded()
    FOG_TIMER = timer.start{
        iterations = -1,
        duration = 0.01,
        callback = updateMist,
        type = timer.game,
        persist = false
    }

    timer.start{
		duration = TIMER_DURATION,
		callback = mistShader.conditionCheck,
		iterations = -1,
		type = timer.game,
		persist = false
	}
    mistShader.conditionCheck()
end

function mistShader.removeMist()
    stopTimer(FADE_OUT_TIMER)
    stopTimer(FADE_OUT_REMOVE_TIMER)
    stopTimer(FADE_IN_TIMER)
    shader.deleteFog(FOG_ID)
end

local function waitingCheck()
	debugLog("Starting waiting check.")
	local mp = tes3.mobilePlayer
    local gameHour = WorldC.hour.value
	if (not mp) or (mp and (mp.waiting or mp.traveling)) then
		toWeather = WtC.nextWeather or WtC.currentWeather
		if not isAvailable(toWeather, gameHour) then
			debugLog("Player waiting or travelling and clouds not available.")
			mistShader.removeMist()
		end
	end
	mistShader.conditionCheck()
end

function mistShader.onWaitMenu(e)
	local element = e.element
	element:registerAfter(tes3.uiEvent.destroy, function()
		waitingCheck()
	end)
end

function mistShader.onWeatherChanged(e)
    local fromWeather = e.from
    toWeather = e.to

	if wetWeathers[fromWeather.name] and config.blockedMist[toWeather.name] ~= true then
		debugLog("Adding post-rain mistShader.")

		-- Slight offset so it makes sense --
		timer.start {
			type = timer.game,
			iterations = 1,
			duration = 0.3,
			callback = function()
                postRainMist = true
                updateMist()
                FOG_TIMER:resume()
            end
		}

        timer.start {
			type = timer.game,
			iterations = 1,
			duration = 1,
			callback = function()
                postRainMist = false
            end
		}
	end
end

function mistShader.immediateCheck()
    local region = tes3.getPlayerCell().region

    if lastRegion ~= region then
        mistShader.removeMist()
        lastRegion = region
        return
    end
    lastRegion = region
end

function mistShader.conditionCheck()
    local cell = tes3.getPlayerCell()
    if not cell.isOrBehavesAsExterior then
        FOG_TIMER:pause()
        shader.deleteFog(FOG_ID)
    end

    mistShader.immediateCheck()

    toWeather = WtC.nextWeather or WtC.currentWeather
    local gameHour = WorldC.hour.value

    if isAvailable(toWeather, gameHour) or postRainMist then
        if not mistDeployed then
            debugLog("Mist available.")
            updateMist()
            FOG_TIMER:resume()
            stopTimer(FADE_OUT_TIMER)
            stopTimer(FADE_OUT_REMOVE_TIMER)
            FADE_IN_TIMER = timer.start{
                duration = FADE_DURATION,
                callback = fadeIn,
                iterations = STEPS,
                type = timer.game,
                persist = false
            }
            mistDeployed = true
        end
    else
        if mistDeployed then
            debugLog("Mist not available.")
            stopTimer(FADE_IN_TIMER)
            FADE_OUT_TIMER = timer.start{
                duration = FADE_DURATION,
                callback = fadeOut,
                iterations = STEPS,
                type = timer.game,
                persist = false
            }
            FADE_OUT_REMOVE_TIMER = timer.start{
                duration = (FADE_DURATION*STEPS) + FADE_DURATION,
                callback = mistShader.removeMist,
                iterations = 1,
                type = timer.game,
                persist = false
            }
            mistDeployed = false
        end
    end
end

return mistShader