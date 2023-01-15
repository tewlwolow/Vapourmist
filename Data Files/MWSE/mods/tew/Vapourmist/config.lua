return mwse.loadConfig (
    "Vapourmist",
    {
        speedCoefficient = 45,
        debugLogOn = false,
        clouds = false,
        mistShader = false,
        mistNIF = true,
        interior = true,
        cloudyWeathers = {
            ["Cloudy"] = true,
            ["Foggy"] = true,
            ["Rain"] = true,
            ["Thunderstorm"] = true
        },
        mistyWeathers = {
            ["Foggy"] = true,
        },
        blockedCloud = {
            ["Ash"] = true,
            ["Blight"] = true
        },
        blockedMist = {
            ["Ash"] = true,
            ["Blight"] = true,
            ["Snow"] = true,
            ["Blizzard"] = true,
            ["Rain"] = true,
            ["Thunderstorm"] = true
        }
    }
)
