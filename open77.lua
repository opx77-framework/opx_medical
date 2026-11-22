resource "opx_medical"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- OPX//77 medical: a character who dies stays down where he fell (the platform's `dead` phase; nothing in OPX
-- respawns anybody by itself). An opx_menu emergency menu offers: wait, call for help, or respawn at a
-- hospital once a countdown ended. Other resources revive through the exports (provider slot `medical` of
-- opx_core). No database: the downed flag that survives a reconnect is opx_core metadata `isDown`.
-- opx_menu is a dependency because require('@opx_menu') only loads a declared, running one.
dependencies {
    "opx_core",
    "opx_menu",
}

permissions {
    "network.events",        -- both: requests to the server, state to the client
    "players.life.read",     -- server: getLifeState / isDead (who went down, how)
    "players.stats.read",    -- server: Open77.stats.getHealth (a bandage is not used at full health)
    "players.life.revive",   -- server: Revive export, staff command
    "players.life.respawn",  -- server: hospital respawn
    "players.life.kill",     -- server: puts a character back down after a reconnect (Config.persistDown)
    "players.stats.apply",   -- server: setDownedDamageable, Open77.players.heal (bandage, medkit)
    "players.damage.apply",  -- server: same natives (older spelling, still accepted)
    "players.screen",        -- server: fade around the hospital respawn (Config.respawn.fade)
    "input.actions",         -- client: RegisterKeyMapping / Open77.input.keyFor (the emergency menu key)
    "ui.vanilla.map",        -- client: hospital pins (Config.blips)
}

shared_script "config.lua"

-- No `require` on the server: the files share globals, loaded in this order.
server_scripts {
    "server/state.lua",
    "server/calls.lua",
    "server/main.lua",
    "server/items.lua",
}

client_script "client/main.lua"

files {
    "client/modules/*.lua",
    "locales/*.json",
}
