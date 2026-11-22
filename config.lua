Config = {}

-- Default key that reopens the emergency menu while down (players can rebind it: Settings > Key bindings).
Config.key = 'E'

-- false: a downed body cannot be finished (platform setDownedDamageable). true: it can still take damage.
Config.downedDamageable = false

-- true: disconnecting (or switching character) while down does not get you up: the character comes back down
-- when he is played again (opx_core metadata key `isDown`).
Config.persistDown = true

-- Jobs of this opx_core job `type`, on duty, are the responders: counted in the menu, and a call needs one.
Config.responderJobType = 'ems'

-- Respawn at the hospital from the emergency menu (or /respawn).
Config.respawn = {
	enabled = true,               -- false: no hospital respawn, only a revive gets you up
	delaySeconds = 300,           -- wait before respawning while a responder is on duty (chosen when going down)
	delayNoResponderSeconds = 60, -- wait when nobody is on duty
	fee = 500,                    -- hospital bill; bank first, then cash; never blocks the respawn (no debt)
	feeSociety = 'traumateam',    -- registered job whose society account receives the bill; false = nobody
	health = 1.0,                 -- health fraction after the respawn (0.05..1)
	fade = true,                  -- black screen around the move (players.screen)
}

-- > 0: automatic hospital respawn (bill included) after that many seconds down; 0 = never.
Config.bleedoutSeconds = 0

-- Defaults of the Revive export (callers may pass their own): health fraction, invulnerable window in ms.
Config.revive = { health = 0.5, graceMs = 3000 }

-- Hospitals: the respawn goes to the one nearest to where the player fell. heading in degrees,
-- bucket = routing bucket the player respawns in. Vik's clinic point from the official rp pack (check it).
Config.hospitals = {
	{ label = "Vik's Clinic", x = -1546.0, y = 1231.0, z = 11.6, heading = 180.0, bucket = 0 },
}

-- Seconds between two calls for help of one player.
Config.callCooldownSeconds = 60

-- Minimum milliseconds between two requests of one player (anything faster is ignored).
Config.rateLimitMs = 500

-- Command names (false = not registered). `respawn` and `call` are for every player (same as the menu rows);
-- `revive [playerId|me]` is restricted: ACL right `command.<name>` (command.revive by default).
Config.commands = { revive = 'revive', respawn = 'respawn', call = 'sos' }

-- true: hospitals are pinned on the world map (sprite 'meds') while a character is loaded.
Config.blips = true

-- Items this resource registers in the inventory provider (RegisterItem + RegisterUsable). heal = health points
-- given on use (refused while down, not consumed at full health). enabled = false: not registered (an item
-- already in the catalogue stays until the inventory restarts, but using it is refused).
Config.items = {
	bandage = { enabled = true, heal = 25 },
	medkit = { enabled = true, heal = 60 },
}

-- Update check at start: compares this version with the one published on GitHub and prints a line in the
-- server console when an update is out. Needs outbound HTTP in server.jsonc ("http": "enabled": true, with
-- "raw.githubusercontent.com" in "allowedHosts"). false = no request.
Config.versionCheck = true
