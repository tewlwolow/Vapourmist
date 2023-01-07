local data = {}

local config = require("tew.Vapourmist.config")

data.baseTimerDuration = 0.1
data.minimumSpeed = 15
data.minStaticCount = 5

local interiorStatics = {
    "in_moldcave",
    "in_mudcave",
    "in_lavacave",
    "in_pycave",
    "in_bonecave",
    "in_bc_cave",
    "in_m_sewer",
    "in_sewer",
    "ab_in_kwama",
    "ab_in_lava",
    "ab_in_mvcave",
    "t_cyr_cavegc",
    "t_glb_cave",
    "t_mw_cave",
    "t_sky_cave",
    "bm_ic_",
    "bm_ka",
}

local interiorNames = {
    "cave",
    "cavern",
    "tomb",
    "burial",
    "crypt",
    "catacomb",
}


data.fogTypes = {
    ["cloud"] = {
        name = "cloud",
        mesh = "tew\\Vapourmist\\vapourcloud.nif",
        height = 6000,
        initialSize = {1340, 1500, 1620, 1740, 1917, 2100, 2450, 2500, 2600 },
        isAvailable = function(_, weather)
            return not config.blockedCloud[weather.name]
            and config.cloudyWeathers[weather.name]
        end
    },
    ["mist"] = {
        name = "mist",
        mesh = "tew\\Vapourmist\\vapourmist.nif",
        height = 650,
        initialSize = { 700, 800, 1100, 1243, 1450, 1520},
        wetWeathers = { ["Rain"] = true, ["Thunderstorm"] = true },
        isAvailable = function(gameHour, weather)
            if config.blockedMist[weather.name] then return false end
            local WtC = tes3.worldController.weatherController
            return (
            (gameHour > WtC.sunriseHour - 1 and gameHour < WtC.sunriseHour + 1.5)
            or (gameHour >= WtC.sunsetHour - 0.4 and gameHour < WtC.sunsetHour + 2)
        ) and not data.fogTypes["mist"].wetWeathers[weather.name]
        or config.mistyWeathers[weather.name]
    end
}
}

data.interiorFog = {
    name = "interior",
    mesh = "tew\\Vapourmist\\vapourint.nif",
    height = -1300,
    initialSize = { 300, 400, 450, 500, 510, 550 },
    isAvailable = function(cell)
        for _, namePattern in ipairs(interiorNames) do
            if string.find(cell.name:lower(), namePattern) then
                return true
            end
        end

        local count = 0
        for stat in cell:iterateReferences(tes3.objectType.static) do
            for _, statName in ipairs(interiorStatics) do
                if string.startswith(stat.object.id:lower(), statName) then
                    count = count + 1
                    if count >= data.minStaticCount then
                        return true
                    end
                end
            end
        end

        return false
    end
}


return data
