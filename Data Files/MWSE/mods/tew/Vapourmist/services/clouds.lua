-- Clouds module
-->>>---------------------------------------------------------------------------------------------<<<--

-- Imports
local clouds = {}
local util = require("tew.Vapourmist.components.util")
local debugLog = util.debugLog
local config = require("tew.Vapourmist.config")

local safeAddToTable = util.safeAddToTable
local safeGetFromTable = util.safeGetFromTable

-->>>---------------------------------------------------------------------------------------------<<<--
-- Constants

local TIMER_DURATION = 0.25

local CELL_SIZE = 8192

local MIN_LIFESPAN = 12
local MAX_LIFESPAN = 23

local MIN_DEPTH = 2000
local MAX_DEPTH = 4000

local MIN_BIRTHRATE = 1.3
local MAX_BIRTHRATE = 1.8

local MIN_SPEED = 15

local CUTOFF_COEFF = 4

local HEIGHTS = { 3800, 4200, 4800, 5200, 5760, 5900, 6000, 6100, 6200, 6800, 7500, 7900 }
local SIZES = {
	["small"] = { 400, 520, 600, 850, 923, 1200, 1350 },
	["medium"] = { 1740, 1917, 2000, 2250, 2800 },
	["big"] = { 2915, 3156, 3400, 3700, 4002 },
}

local MESH = tes3.loadMesh("tew\\Vapourmist\\vapourcloud.nif")
local NAME_MAIN = "tew_Clouds"
local NAME_EMITTER = "tew_Clouds_Emitter"
local NAME_PARTICLE_SYSTEMS = {
	"tew_Clouds_ParticleSystem_1",
	"tew_Clouds_ParticleSystem_2",
	"tew_Clouds_ParticleSystem_3",
}

-->>>---------------------------------------------------------------------------------------------<<<--
-- Structures

local tracker, removeQueue, appCulledTracker = {}, {}, {}

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

	if average == 0 or denom == 0 then
		return height
	else
		return (average / denom) + height
	end
end

local function isAvailable(weather)
	local cell = tes3.player.cell
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

local function isPlayerClouded(cloudMesh)
	debugLog("Checking if player is clouded.")
	local mp = tes3.mobilePlayer
	local playerPos = mp.position:copy()
	local drawDistance = mge.distantLandRenderConfig.drawDistance
	return playerPos:distance(cloudMesh.translation:copy()) < (getCutoffDistance(drawDistance))
end


-- Table logic

local function addToTracker(cloud)
	safeAddToTable(cloud, tracker)
	debugLog("Clouds added to tracker.")
end

local function removeFromTracker(cloud)
	local m = safeGetFromTable(cloud, tracker)
	if m then
		tracker[cloud] = nil
		debugLog("Clouds removed from tracker.")
	end
end

local function addToRemoveQueue(cloud)
	safeAddToTable(cloud, removeQueue)
	debugLog("Clouds added to removal queue.")
end

local function removeFromRemoveQueue(cloud)
	local m = safeGetFromTable(cloud, removeQueue)
	if m then
		removeQueue[cloud] = nil
		debugLog("Clouds removed removal queue.")
	end
end

local function addToAppCulledTracker(cloud)
	safeAddToTable(cloud, appCulledTracker)
	debugLog("Clouds added to appCulled tracker.")
end

local function removeFromAppCulledTracker(cloud)
	local m = safeGetFromTable(cloud, appCulledTracker)
	if m then
		appCulledTracker[cloud] = nil
		debugLog("Clouds removed from appCulled tracker.")
	end
end

-- Hide/show logic

local function detach(vfxRoot, node)
	removeFromAppCulledTracker(node)
	vfxRoot:detachChild(node)
	debugLog("Cloud detached.")
	removeFromRemoveQueue(node)
	removeFromTracker(node)
end

function clouds.detachAll()
	debugLog("Detaching all clouds.")
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			detach(vfxRoot, node)
		end
	end
	tracker = {}
end

local function switchAppCull(node, bool)
	local emitter = node:getObjectByName(NAME_EMITTER)
	if (emitter.appCulled ~= bool) then
		emitter.appCulled = bool
		emitter:update()
	end
end

local function appCull(node)
	local emitter = node:getObjectByName(NAME_EMITTER)
	if not (emitter.appCulled) then
		switchAppCull(node, true)
		timer.start {
			type = timer.simulate,
			duration = MAX_LIFESPAN,
			iterations = 1,
			persistent = false,
			callback = function() addToRemoveQueue(node) end,
		}
		debugLog("Clouds appculled.")
		addToAppCulledTracker(node)
		removeFromTracker(node)
	else
		debugLog("Clouds already appculled. Skipping.")
	end
end

local function appCullAll()
	debugLog("Appculling all clouds.")
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	for _, node in pairs(vfxRoot.children) do
		if node and node.name == NAME_MAIN then
			appCull(node)
		end
	end
end

-- Colour logic

-- Calculate output colours from current fog colour --
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

local function reColourTable(tab, cloudColour, speed, angle)
	if not tab then return end
	if table.empty(tab) then return end
	for cloud, _ in pairs(tab) do
		for _, name in ipairs(NAME_PARTICLE_SYSTEMS) do
			local particleSystem = cloud:getObjectByName(name)

			local controller = particleSystem.controller
			local colorModifier = controller.particleModifiers

			controller.speed = speed
			controller.planarAngle = angle

			for _, key in pairs(colorModifier.colorData.keys) do
				key.color.r = cloudColour.r
				key.color.g = cloudColour.g
				key.color.b = cloudColour.b
			end

			local materialProperty = particleSystem.materialProperty
			materialProperty.emissive = cloudColour
			materialProperty.specular = cloudColour
			materialProperty.diffuse = cloudColour
			materialProperty.ambient = cloudColour

			particleSystem:update()
			particleSystem:updateProperties()
			particleSystem:updateEffects()
			cloud:update()
			cloud:updateProperties()
			cloud:updateEffects()
		end
	end
end

local function reColour()
	local output = getOutputValues()
	local cloudColour = output.colours
	local speed = output.speed
	local angle = output.angle

	reColourTable(tracker, cloudColour, speed, angle)
	reColourTable(appCulledTracker, cloudColour, speed, angle)
end

-- NIF values logic
local function deployEmitter(particleSystem, size)
	local drawDistance = mge.distantLandRenderConfig.drawDistance

	local controller = particleSystem.controller

	local birthRate = math.random(MIN_BIRTHRATE, MAX_BIRTHRATE) * drawDistance
	controller.birthRate = birthRate
	controller.useBirthRate = true

	local lifespan = math.random(MIN_LIFESPAN, MAX_LIFESPAN)
	controller.lifespan = lifespan
	controller.emitStopTime = lifespan * lifespan

	local effectSize = getParticleSystemSize(drawDistance)

	controller.emitterWidth = effectSize
	controller.emitterHeight = effectSize
	controller.emitterDepth = math.random(MIN_DEPTH, MAX_DEPTH)

	local initialSize = SIZES[size][math.random(#SIZES[size])]
	controller.initialSize = initialSize

	particleSystem:update()
	particleSystem:updateProperties()
	particleSystem:updateEffects()
	debugLog("Emitter deployed.")
end

local function addClouds()
	debugLog("Adding clouds.")
	local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
	local cell = tes3.getPlayerCell()

	local mp = tes3.mobilePlayer
	if not mp or not mp.position then return end

	local playerPos = mp.position:copy()

	local cloudPosition = tes3vector3.new(
		playerPos.x,
		playerPos.y,
		getCloudPosition(cell)
	)

	local cloudMesh = MESH:clone()
	cloudMesh:clearTransforms()
	cloudMesh.translation = cloudPosition

	vfxRoot:attachChild(cloudMesh)

	local cloudNode
	for _, node in pairs(vfxRoot.children) do
		if node then
			if node.name == NAME_MAIN then
				if not table.find(removeQueue, node) then
					cloudNode = node
				end
			end
		end
	end
	if not cloudNode then return end

	addToTracker(cloudNode)

	local sizes = { "small", "medium", "big" }

	for _, name in ipairs(NAME_PARTICLE_SYSTEMS) do
		local particleSystem = cloudNode:getObjectByName(name)
		if particleSystem then
			local ind = math.random(1, #sizes)
			local size = sizes[ind]
			deployEmitter(particleSystem, size)
			table.remove(sizes, ind)
		end
	end

	cloudMesh.appCulled = false
	cloudMesh:update()
	cloudMesh:updateProperties()
	cloudMesh:updateEffects()
	debugLog("Clouds added.")
end

-- Conditions logic

local function waitingCheck()
	debugLog("Starting waiting check.")
	local mp = tes3.mobilePlayer
	if (not mp) or (mp and (mp.waiting or mp.traveling)) then
		toWeather = WtC.nextWeather or WtC.currentWeather
		if not (isAvailable(toWeather)) then
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

	if not table.empty(tracker) then return end

	if WtC.nextWeather and WtC.transitionScalar < 0.6 then
		debugLog("Weather transition in progress. Adding clouds in a bit.")
		timer.start {
			type = timer.game,
			iterations = 1,
			duration = 0.2,
			callback = clouds.onWeatherChanged,
		}
	else
		addClouds()
	end
end

function clouds.conditionCheck()
	local cell = tes3.getPlayerCell()
	if not cell.isOrBehavesAsExterior then return end

	toWeather = WtC.nextWeather or WtC.currentWeather

	for node, _ in pairs(removeQueue) do
		local vfxRoot = tes3.worldController.vfxManager.worldVFXRoot
		detach(vfxRoot, node)
	end

	if not table.empty(tracker) then
		debugLog("Tracker not empty. Checking distance.")
		for node, _ in pairs(tracker) do
			if not isPlayerClouded(node) then
				debugLog("Found distant cloud.")
				appCull(node)
			end
		end
	else
		if isAvailable(toWeather) then
			debugLog("Tracker is empty. Adding clouds.")
			addClouds()
		end
	end
end

-- Time and event logic

local function startTimer()
	timer.start {
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
		event.register(tes3.event.enterFrame, reColour)
		recolourRegistered = true
	end
	startTimer()
	tracker, removeQueue = {}, {}
	clouds.detachAll()
	clouds.conditionCheck()
end

return clouds
