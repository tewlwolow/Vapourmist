return mwse.loadConfig (
    "Vapourmist",
    {
        speedCoefficient = 45,
        debugLogOn = false,
        clouds = true,
        mistShader = true,
        mistNIF = true,
        interior = true,
        cloudyWeathers = {
            ["Cloudy"] = true,
            ["Rain"] = true,
            ["Thunderstorm"] = true
        },
        mistyWeathers = {
            ["Foggy"] = true,
            ["Overcast"] = true
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
