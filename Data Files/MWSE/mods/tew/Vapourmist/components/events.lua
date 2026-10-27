-- Events declarations
-->>>---------------------------------------------------------------------------------------------<<<--

local config   = require("tew.Vapourmist.config")
local util     = require("tew.Vapourmist.components.util")
local debugLog = util.debugLog

local services = {
	clouds = {
		init = function()
			local clouds = require("tew.Vapourmist.services.clouds")
			event.register("VAPOURMIST:enteredInterior", clouds.detachAll)
			event.register(tes3.event.loaded, clouds.onLoaded)
			event.register(tes3.event.cellChanged, clouds.conditionCheck)
			event.register(tes3.event.weatherChangedImmediate, clouds.onWeatherChanged)
			event.register(tes3.event.weatherTransitionStarted, clouds.onWeatherChanged)
			event.register(tes3.event.weatherTransitionFinished, clouds.onWeatherChanged)
			event.register(tes3.event.uiActivated, clouds.onWaitMenu, { filter = "MenuTimePass" })
			clouds.onLoaded()
		end,
		stop = function()
			local clouds = require("tew.Vapourmist.services.clouds")
			event.unregister("VAPOURMIST:enteredInterior", clouds.detachAll)
			event.unregister(tes3.event.loaded, clouds.onLoaded)
			event.unregister(tes3.event.cellChanged, clouds.conditionCheck)
			event.unregister(tes3.event.weatherChangedImmediate, clouds.onWeatherChanged)
			event.unregister(tes3.event.weatherTransitionStarted, clouds.onWeatherChanged)
			event.unregister(tes3.event.weatherTransitionFinished, clouds.onWeatherChanged)
			event.unregister(tes3.event.uiActivated, clouds.onWaitMenu, { filter = "MenuTimePass" })
			clouds.cleanup()
		end,
	},
	mistShader = {
		init = function()
			local mistShader = require("tew.Vapourmist.services.mistShader")
			event.register("VAPOURMIST:enteredInterior", mistShader.removeMist)
			event.register(tes3.event.loaded, mistShader.onLoaded)
			event.register(tes3.event.cellChanged, mistShader.conditionCheck, { priority = -500 })
			event.register(tes3.event.weatherChangedImmediate, mistShader.onWeatherChangedImmediate)
			event.register(tes3.event.weatherTransitionStarted, mistShader.onWeatherChanged)
			event.register(tes3.event.uiActivated, mistShader.onWaitMenu, { filter = "MenuTimePass" })
			mistShader.onLoaded()
		end,
		stop = function()
			local mistShader = require("tew.Vapourmist.services.mistShader")
			event.unregister("VAPOURMIST:enteredInterior", mistShader.removeMist)
			event.unregister(tes3.event.loaded, mistShader.onLoaded)
			event.unregister(tes3.event.cellChanged, mistShader.conditionCheck, { priority = -500 })
			event.unregister(tes3.event.weatherChangedImmediate, mistShader.onWeatherChangedImmediate)
			event.unregister(tes3.event.weatherTransitionStarted, mistShader.onWeatherChanged)
			event.unregister(tes3.event.uiActivated, mistShader.onWaitMenu, { filter = "MenuTimePass" })
			mistShader.cleanup()
		end,
	},
	mistNIF = {
		init = function()
			local mistNIF = require("tew.Vapourmist.services.mistNIF")
			event.register("VAPOURMIST:enteredInterior", mistNIF.detachAll)
			event.register(tes3.event.loaded, mistNIF.onLoaded)
			event.register(tes3.event.cellChanged, mistNIF.conditionCheck)
			event.register(tes3.event.weatherChangedImmediate, mistNIF.conditionCheck)
			event.register(tes3.event.weatherTransitionStarted, mistNIF.onWeatherChanged)
			event.register(tes3.event.weatherTransitionFinished, mistNIF.conditionCheck)
			event.register(tes3.event.uiActivated, mistNIF.onWaitMenu, { filter = "MenuTimePass" })
			mistNIF.onLoaded()
		end,
		stop = function()
			local mistNIF = require("tew.Vapourmist.services.mistNIF")
			event.unregister("VAPOURMIST:enteredInterior", mistNIF.detachAll)
			event.unregister(tes3.event.loaded, mistNIF.onLoaded)
			event.unregister(tes3.event.cellChanged, mistNIF.conditionCheck)
			event.unregister(tes3.event.weatherChangedImmediate, mistNIF.conditionCheck)
			event.unregister(tes3.event.weatherTransitionStarted, mistNIF.onWeatherChanged)
			event.unregister(tes3.event.weatherTransitionFinished, mistNIF.conditionCheck)
			event.unregister(tes3.event.uiActivated, mistNIF.onWaitMenu, { filter = "MenuTimePass" })
			mistNIF.cleanup()
		end,
	},

	-- TODO: Redo - decouple, combine vtastek's underwater dust with fogbox; interior NIF out
	interior = {
		init = function()
			local interior = require("tew.Vapourmist.services.interior")
			event.register(tes3.event.cellChanged, interior.onCellChanged, { priority = 500 })
			interior.onCellChanged()
		end,
		stop = function()
			local interior = require("tew.Vapourmist.services.interior")
			event.unregister(tes3.event.cellChanged, interior.onCellChanged, { priority = 500 })
			interior.removeAllFog()
		end,
	},
}

for serviceName, service in pairs(services) do
	if config.modEnabled then
		if config[serviceName] then
			debugLog("Initialising service: [" .. serviceName .. "]")
			service.stop()
			service.init()
		else
			debugLog("Stopping service: [" .. serviceName .. "]")
			service.stop()
		end
	else
		debugLog("Mod disabled - stopping services.")
		service.stop()
	end
end
