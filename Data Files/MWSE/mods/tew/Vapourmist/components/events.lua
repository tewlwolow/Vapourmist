-- Events declarations
-->>>---------------------------------------------------------------------------------------------<<<--

local config = require("tew.Vapourmist.config")

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
			event.register(tes3.event.uiActivated, clouds.onWaitMenu, { filter = "MenuTimePass"})
		end
	},
	mist = {
		init = function()
			local mist = require("tew.Vapourmist.services.mist")
			event.register(tes3.event.loaded, mist.onLoaded)
			event.register(tes3.event.cellChanged, mist.conditionCheck)
			event.register(tes3.event.weatherTransitionStarted, mist.onWeatherChanged)
		end
	},
	interior = {
		init = function()
			local interior = require("tew.Vapourmist.services.interior")
			event.register(tes3.event.cellChanged, interior.onCellChanged)
		end
	}
}

for serviceName, service in pairs(services) do
	if config[serviceName] then
		service.init()
	end
end