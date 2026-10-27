-- Clouds module
-->>>---------------------------------------------------------------------------------------------<<<--

-- Package
local clouds = {}

-- Imports
---@module 'tew.Vapourmist.components.util'
local util = require("tew.Vapourmist.components.util")
local debugLog = util.debugLog

---@module 'tew.Vapourmist.config'
local config = require("tew.Vapourmist.config")

local conditionTimer, delayTimer, appCullTimer

-->>>---------------------------------------------------------------------------------------------<<<--
-- Constants

local TIMER_DURATION = 0.25
local CELL_SIZE = 8192

local MIN_LIFESPAN = 12
local MAX_LIFESPAN = 28

local MIN_BIRTHRATE = 0.5
local MAX_BIRTHRATE = 1.5

local MIN_SPEED = 15
local CUTOFF_COEFF = 4

local HEIGHTS = { 5600, 5900, 6300, 6200, 6800, 7100, 7500, 7900, 8200, 8500, 9200, 9800 }

local CLOUD_BASE_HEIGHT_OFFSET = 2000

-- Three emitter profiles: shallow, middle, deep.
-- Height is a multiplier of the overall particle-system size.
-- Depth is the emitter's depth in game units.
local EMITTER_PROFILES = {
	shallow = {
		height = 2.0,
		depth = 1500,
	},
	middle = {
		height = 4.0,
		depth = 2750,
	},
	deep = {
		height = 7.0,
		depth = 4000,
	},
}

-- Assign the four particle systems to the three profiles.
local PARTICLE_SYSTEM_PROFILES = {
	tew_Clouds_ParticleSystem_1 = "shallow",
	tew_Clouds_ParticleSystem_2 = "middle",
	tew_Clouds_ParticleSystem_3 = "deep",
	tew_Clouds_ParticleSystem_4 = "middle",
}

---@type niNode
local MESH = tes3.loadMesh("tew\\Vapourmist\\vapourcloud.nif")

local NAME_MAIN = "tew_Clouds"
local NAME_EMITTER = "tew_Clouds_Emitter"

local NAME_PARTICLE_SYSTEMS = {
	"tew_Clouds_ParticleSystem_1",
	"tew_Clouds_ParticleSystem_2",
	"tew_Clouds_ParticleSystem_3",
	"tew_Clouds_ParticleSystem_4",
}

-->>>---------------------------------------------------------------------------------------------<<<--
-- Structures

local toWeather, recolourRegistered

local WtC = tes3.worldController.weatherController

-->>>---------------------------------------------------------------------------------------------<<<--
-- Functions

-- Helper logic

local function getCloudPosition(cell)
	local average = 0
	local denom = 0

	for stat in cell:iterateReferences() do
		average = average + stat.position.z
		denom = denom + 1
	end

	local height = HEIGHTS[math.random(#HEIGHTS)]

	if denom == 0 then
		return height
	end

	return (average / denom) + height
end

local function isAvailable(weather)
	local cell = tes3.getPlayerCell()
	if not cell then return end

	local weatherName = weather.name

	return not config.blockedCloud[weatherName]
		and config.cloudyWeathers[weatherName]
		and cell.isOrBehavesAsExterior
end

local function getParticleSystemSize(drawDistance)
	return (CELL_SIZE * drawDistance) * 1.5
end

local function getCutoffDistance(drawDistance)
	return getParticleSystemSize(drawDistance) / CUTOFF_COEFF
end

local function isPlayerClouded()
	debugLog("Checking if player is clouded.")

	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot

	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			local emitter = node:getObjectByName(NAME_EMITTER)

			if emitter and not emitter.appCulled then
				local playerPos = tes3.mobilePlayer.position:copy()
				local drawDistance = mge.distantLandRenderConfig.drawDistance

				return playerPos:distance(node.translation:copy())
					< getCutoffDistance(drawDistance)
			end
		end
	end
end

-- Hide/show logic

local function detach(node)
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	vfxRoot:detachChild(node)
	debugLog("Cloud detached.")
end

function clouds.detachAll()
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	if not vfxRoot then return end

	debugLog("Detaching all clouds...")

	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			detach(node)
		end
	end

	debugLog("All clouds detached.")
end

local function detachAppCulled(state)
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	if not vfxRoot then return end

	debugLog("Detaching clouds with appCulled state: " .. tostring(state))

	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			local emitter = node:getObjectByName(NAME_EMITTER)

			if emitter and emitter.appCulled == state then
				detach(node)
			end
		end
	end

	debugLog("Clouds with appCulled state: " .. tostring(state) .. " detached.")
end

---@param node niNode
---@param bool boolean
local function switchAppCull(node, bool)
	local emitter = node:getObjectByName(NAME_EMITTER)

	if emitter and emitter.appCulled ~= bool then
		emitter.appCulled = bool
		emitter:update()
	end
end

local function appCull(node)
	local emitter = node:getObjectByName(NAME_EMITTER)
	if not emitter then return end

	if not emitter.appCulled then
		switchAppCull(node, true)

		appCullTimer = timer.start {
			type = timer.simulate,
			duration = MAX_LIFESPAN,
			iterations = 1,
			persistent = false,
			callback = function()
				detachAppCulled(true)
			end,
		}

		debugLog("Clouds appculled.")
	else
		debugLog("Clouds already appculled. Skipping.")
	end
end

local function appCullAll()
	debugLog("Appculling all clouds.")

	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	if not vfxRoot then return end

	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			appCull(node)
		end
	end
end

-- Colour logic

local function getOutputValues()
	local currentFogColor = WtC.currentFogColor:copy()

	local weatherColour = {
		r = currentFogColor.r,
		g = currentFogColor.g,
		b = currentFogColor.b,
	}

	return {
		colours = weatherColour,
		angle = WtC.windVelocityCurrWeather:normalized():copy().y * math.pi * 0.5,
		speed = math.max(WtC.currentWeather.cloudsSpeed * config.speedCoefficient, MIN_SPEED),
	}
end

local function reColourAll(cloudColour, speed, angle)
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	if not vfxRoot then return end

	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			for _, name in ipairs(NAME_PARTICLE_SYSTEMS) do
				local particleSystem = node:getObjectByName(name)

				if particleSystem and particleSystem.controller then
					local controller = particleSystem.controller
					local colorModifier = controller.particleModifiers

					controller.speed = speed
					controller.planarAngle = angle

					if colorModifier and colorModifier.colorData then
						for _, key in pairs(colorModifier.colorData.keys) do
							key.color.r = cloudColour.r
							key.color.g = cloudColour.g
							key.color.b = cloudColour.b
						end
					end

					local materialProperty = particleSystem.materialProperty

					if materialProperty then
						materialProperty.emissive = cloudColour
						materialProperty.specular = cloudColour
						materialProperty.diffuse = cloudColour
						materialProperty.ambient = cloudColour
					end

					particleSystem:update()
					particleSystem:updateProperties()
					particleSystem:updateEffects()
					node:update()
					node:updateProperties()
					node:updateEffects()
				end
			end
		end
	end
end

local function reColour()
	local output = getOutputValues()
	reColourAll(output.colours, output.speed, output.angle)
end

-- NIF values logic

local function deployEmitter(particleSystem, name, drawDistance)
	local controller = particleSystem.controller
	if not controller then
		debugLog("No controller found for particle system: " .. name)
		return
	end

	local profileName = PARTICLE_SYSTEM_PROFILES[name]
	local profile = EMITTER_PROFILES[profileName]

	if not profile then
		debugLog("No emitter profile found for particle system: " .. name)
		return
	end

	controller.birthRate = math.random(MIN_BIRTHRATE, MAX_BIRTHRATE) * drawDistance
	controller.useBirthRate = true

	local lifespan = math.random(MIN_LIFESPAN, MAX_LIFESPAN)
	controller.lifespan = lifespan
	controller.emitStopTime = lifespan * lifespan

	local effectSize = getParticleSystemSize(drawDistance)

	controller.emitterWidth = effectSize
	controller.emitterHeight = effectSize * profile.height
	controller.emitterDepth = profile.depth

	debugLog("Emitter: " .. name)
	debugLog("Profile: " .. profileName)
	debugLog("Emitter width: " .. controller.emitterWidth)
	debugLog("Emitter height: " .. controller.emitterHeight)
	debugLog("Emitter depth: " .. controller.emitterDepth)

	particleSystem:update()
	particleSystem:updateProperties()
	particleSystem:updateEffects()
end

local function addClouds()
	debugLog("Adding clouds.")

	local cell = tes3.getPlayerCell()
	if not cell then return end

	local mp = tes3.mobilePlayer
	if not mp or not mp.position then return end

	local playerPos = mp.position:copy()
	local drawDistance = mge.distantLandRenderConfig.drawDistance

	local cloudPosition = tes3vector3.new(
		playerPos.x,
		playerPos.y,
		getCloudPosition(cell) + CLOUD_BASE_HEIGHT_OFFSET
	)

	---@type niNode
	local cloudMesh = MESH:clone()

	cloudMesh:clearTransforms()
	cloudMesh.translation = cloudPosition

	local cloudNode = cloudMesh:getObjectByName(NAME_MAIN) or cloudMesh

	for _, name in ipairs(NAME_PARTICLE_SYSTEMS) do
		local particleSystem = cloudNode:getObjectByName(name)

		if particleSystem then
			deployEmitter(particleSystem, name, drawDistance)
		else
			debugLog("Particle system not found: " .. name)
		end
	end

	cloudMesh.appCulled = false
	cloudMesh:update()
	cloudMesh:updateProperties()
	cloudMesh:updateEffects()

	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	if not vfxRoot then return end

	vfxRoot:attachChild(cloudMesh)

	debugLog("Clouds added.")
end

-- Conditions logic

local function waitingCheck()
	debugLog("Starting waiting check.")

	local mp = tes3.mobilePlayer

	if (not mp) or (mp and (mp.waiting or mp.sleeping or mp.traveling)) then
		toWeather = WtC.nextWeather or WtC.currentWeather

		if not isAvailable(toWeather) then
			debugLog("Player waiting or travelling and clouds not available.")
			clouds.detachAll()
		end
	end

	clouds.conditionCheck()
end

function clouds.onWaitMenu(e)
	local element = e.element

	element:registerAfter(tes3.uiEvent.destroy, function()
		waitingCheck()
	end)
end

function clouds.onWeatherChanged()
	debugLog("Starting weather check.")

	toWeather = WtC.nextWeather or WtC.currentWeather

	if not isAvailable(toWeather) then
		appCullAll()
		return
	end

	if WtC.nextWeather and WtC.transitionScalar < 0.6 then
		debugLog("Weather transition in progress. Adding clouds in a bit.")

		delayTimer = timer.start {
			type = timer.game,
			iterations = 1,
			duration = 0.2,
			callback = clouds.onWeatherChanged,
		}
	else
		clouds.conditionCheck()
	end
end

function clouds.conditionCheck()
	local cell = tes3.getPlayerCell()
	if not cell or not cell.isOrBehavesAsExterior then return end

	toWeather = WtC.nextWeather or WtC.currentWeather

	if isAvailable(toWeather) then
		if not isPlayerClouded() then
			debugLog("Player not clouded and conditions eligible. Adding clouds.")
			clouds.detachAll()
			addClouds()
		end
	else
		appCullAll()
	end
end

-- Time and event logic

local function startTimer()
	conditionTimer = timer.start {
		duration = TIMER_DURATION,
		callback = clouds.conditionCheck,
		iterations = -1,
		type = timer.game,
		persist = false,
	}
end

-- Register events, timers and reset values --

function clouds.onLoaded()
	if not tes3.player then return end

	debugLog("Game loaded.")

	if not recolourRegistered then
		event.register(tes3.event.simulate, reColour)
		recolourRegistered = true
	end

	startTimer()
	clouds.detachAll()
	clouds.conditionCheck()
end

function clouds.cleanup()
	clouds.detachAll()
	util.removeTimers({ conditionTimer, appCullTimer, delayTimer })

	if recolourRegistered then
		event.unregister(tes3.event.simulate, reColour)
		recolourRegistered = false
	end

	conditionTimer, delayTimer, appCullTimer = nil, nil, nil
end

return clouds
