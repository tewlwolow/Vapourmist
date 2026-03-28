-- Imports
local shader = require("tew.Vapourmist.components.shader")
local util = require("tew.Vapourmist.components.util")
local debugLog = util.debugLog
local config = require("tew.Vapourmist.config")

-- Constants
local FOG_ID = "tew_mist"
local MAX_DISTANCE = 8192 * 3
local BASE_DEPTH = 8192 / 8
local TIMER_DURATION = 0.3

local FADE_SECONDS = 4 -- Fade duration in seconds for visual smoothness
local SIM_FPS = 60     -- Approximate simulate frames per second

local WtC = tes3.worldController.weatherController
local WorldC = tes3.worldController
local mistDensity = 0
local mistDeployed = false

local toWeather, postRainMist, lastRegion

local wetWeathers = {
    ["Rain"] = true,
    ["Thunderstorm"] = true,
}

local radiusFactors = {
    ["Clear"] = 1.4,
    ["Cloudy"] = 1.3,
    ["Foggy"] = 1,
    ["Overcast"] = 1.2,
    ["Rain"] = 1,
    ["Thunderstorm"] = 1,
    ["Ashstorm"] = 1,
    ["Blight"] = 1,
    ["Snow"] = 1,
    ["Blizzard"] = 1,
}

local densities = {
    ["Clear"] = 11,
    ["Cloudy"] = 12,
    ["Foggy"] = 13,
    ["Overcast"] = 12,
    ["Rain"] = 10,
    ["Thunderstorm"] = 10,
    ["Ashstorm"] = 10,
    ["Blight"] = 10,
    ["Snow"] = 10,
    ["Blizzard"] = 10,
}

local mistShader = {}

local fogParams = {
    color = tes3vector3.new(),
    center = tes3vector3.new(),
    radius = tes3vector3.new(MAX_DISTANCE, MAX_DISTANCE, BASE_DEPTH),
    density = mistDensity,
}

-- Fade parameters
local fadeTarget = 0
local fadeStep = 0

-- Stop any running timer
local function stopTimer(timerVal)
    if timerVal and timerVal.state ~= timer.expired then
        timerVal:pause()
        timerVal:cancel()
        debugLog("Timer paused and cancelled.")
    end
end

-- Check if mist should appear
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

local function getMistColourMix(fogComp, skyComp)
    return math.lerp(fogComp, skyComp, 0.2)
end

local function getModifiedColour(comp)
    return math.clamp(math.lerp(comp, 1.0, 0.013), 0.03, 0.9)
end

local function getOutputValues()
    local currentFogColor = WtC.currentFogColor:copy()
    local currentSkyColor = WtC.currentSkyColor:copy()
    local weatherColour = {
        r = getMistColourMix(currentFogColor.r, currentSkyColor.r),
        g = getMistColourMix(currentFogColor.g, currentSkyColor.g),
        b = getMistColourMix(currentFogColor.b, currentSkyColor.b),
    }

    return tes3vector3.new(
        getModifiedColour(weatherColour.r),
        getModifiedColour(weatherColour.g),
        getModifiedColour(weatherColour.b)
    )
end

-- Start fade to target density over FADE_SECONDS
local function startFade(target)
    fadeTarget = target
    local steps = FADE_SECONDS * SIM_FPS
    fadeStep = (target - mistDensity) / steps
end

-- Calculate mist Z using lowest third of statics
local function getMistPosition(cell)
    local zValues = {}

    for stat in cell:iterateReferences() do
        table.insert(zValues, stat.position.z)
    end

    if #zValues == 0 then
        return tes3.player.position.z
    end

    table.sort(zValues)

    local count = math.ceil(#zValues / 3)
    local sum = 0
    for i = 1, count do
        sum = sum + zValues[i]
    end

    return sum / count
end

-- Main simulate update
local function updateMist()
    local player = tes3.player
    if not player then return end
    local cell = player.cell
    if cell.isInterior then
        mistDensity = 0
        shader.deleteFog(FOG_ID)
        return
    end

    -- Smooth density update
    if fadeStep ~= 0 then
        mistDensity = mistDensity + fadeStep
        if (fadeStep > 0 and mistDensity >= fadeTarget) or (fadeStep < 0 and mistDensity <= fadeTarget) then
            mistDensity = fadeTarget
            fadeStep = 0
        end
    end

    local playerPos = tes3.mobilePlayer.position:copy()
    local mistCenter = tes3vector3.new(
        playerPos.x,
        playerPos.y,
        0
    --getMistPosition(cell)
    )

    fogParams.center = mistCenter
    fogParams.radius.z = BASE_DEPTH * radiusFactors[toWeather.name]
    fogParams.density = mistDensity
    fogParams.color = getOutputValues()

    shader.createOrUpdateFog(FOG_ID, fogParams)
end

-- Deploy mist
function mistShader.deployMist()
    if not mistDeployed then
        mistDeployed = true
        startFade(densities[toWeather.name])
        if not mistShader._simulateRegistered then
            event.register("simulate", updateMist)
            mistShader._simulateRegistered = true
        end
    end
end

-- Fade removal
function mistShader.removeMist()
    if mistDeployed then
        mistDeployed = false
        startFade(0)
    end
end

-- Immediate removal (no fade)
function mistShader.removeMistImmediate()
    mistDeployed = false
    mistDensity = 0
    shader.deleteFog(FOG_ID)
    fadeStep = 0
end

-- Condition check
function mistShader.conditionCheck()
    debugLog("Starting condition check.")

    local cell = tes3.getPlayerCell()
    if not cell then return end
    if not cell.isOrBehavesAsExterior then
        debugLog("Interior detected, removing mist.")
        mistShader.removeMist()
        return
    end

    toWeather = WtC.nextWeather or WtC.currentWeather
    local gameHour = WorldC.hour.value

    if isAvailable(toWeather, gameHour) or postRainMist then
        mistShader.deployMist()
    else
        mistShader.removeMist()
    end
end

-- Weather change events
function mistShader.onWeatherChanged(e)
    local fromWeather = e.from
    toWeather = e.to

    if wetWeathers[fromWeather.name] and not config.blockedMist[toWeather.name] then
        debugLog("Adding post-rain mistShader.")

        timer.start {
            type = timer.game,
            iterations = 1,
            duration = 0.06,
            callback = function()
                postRainMist = true
                mistDensity = 0
                updateMist()
                mistShader.conditionCheck()
            end,
        }

        timer.start {
            type = timer.game,
            iterations = 1,
            duration = 1,
            callback = function()
                postRainMist = false
            end,
        }
    end
end

function mistShader.onWeatherChangedImmediate(e)
    local gameHour = WorldC.hour.value
    if not isAvailable(e.to, gameHour) then
        debugLog("Weather changed immediate but mist not available.")
        mistShader.removeMistImmediate()
    end
end

-- Wait menu handling
local function waitingCheck()
    debugLog("Starting waiting check.")
    local mp = tes3.mobilePlayer
    local gameHour = WorldC.hour.value
    if not mp or (mp.waiting or mp.sleeping or mp.traveling) then
        toWeather = WtC.nextWeather or WtC.currentWeather
        if not isAvailable(toWeather, gameHour) then
            debugLog("Player waiting/traveling and mist not available.")
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

-- Initialization
function mistShader.onLoaded()
    if not tes3.player then return end

    -- Register simulate once
    if not mistShader._simulateRegistered then
        event.register("simulate", updateMist)
        mistShader._simulateRegistered = true
    end

    timer.start {
        duration = TIMER_DURATION,
        callback = mistShader.conditionCheck,
        iterations = -1,
        type = timer.game,
        persist = false,
    }

    mistShader.conditionCheck()
end

return mistShader
