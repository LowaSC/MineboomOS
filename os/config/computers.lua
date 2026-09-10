-- Neutral defaults for the standalone MineboomOS distribution.
-- Device names, roles and service connections live under /data and are chosen
-- during setup. This file contains no world-specific computer IDs.
return {
    registry = {
        url = nil,
        autoRegister = false,
        defaultRole = "pocketos",
    },

    pocketosDefaults = {
        useMonitor = true,
        storeProtocol = "pocket_store",
        refreshSeconds = 5,
        staleSeconds = 15,
        topLimit = 20,
        scrollStep = 3,
    },

    default = {
        role = "pocketos",
        label = "MineboomOS Computer",
        channel = "dev",
        updateMode = "manual",
        apps = {},
        pocketos = {},
    },
}
