# opx_medical

A character who dies stays down where he fell. An emergency menu lets him call for help, wait, or respawn at the hospital (for a fee) once a countdown ends.

## Install
- Needs: `opx_core`, `opx_menu`. Load after both.
- No database (the "still down after a reconnect" flag is opx_core metadata).
- opx_core `config.lua`: `Config.providers.medical = 'opx_medical'`.
- ACL: grant staff `command.revive`.
- Walk the hospital point in `Config.hospitals` in game and adjust it.

## In game
- `E` (rebindable) while down: open the emergency menu again.
- `/sos`: call the responders on duty (jobs of type `ems`).
- `/respawn`: respawn at the nearest hospital once the countdown ended.
- `/revive [playerId|me]`: staff, ACL `command.revive`.
- Items `bandage` and `medkit` (Use in the inventory): heal 25 / 60 points. Refused while down (they do not revive) and at full health.

## Config
`config.lua`: `respawn` (delays, `fee`, `feeSociety`), `bleedoutSeconds`, `hospitals`, `responderJobType`, `items` (heal amounts, `enabled = false` to drop an item). Everything else is commented in the file.

## For developers
Provider of the `medical` slot: a replacement implements the exports in `types.lua`.
- `IsDown(source)` → boolean
- `GetState(source)` → downed state or nil
- `Revive(source, { health?, graceMs?, by? })` → `true` | `false, reason`
- `Respawn(source, { force?, free?, hospital? })` → `true` | `false, reason`
- `SetCoverage(source, { respawnFee, label? } | nil)` → `true` | `false, reason`
- `GetCalls()` / `AckCall(patient, responder)` → open calls for help / take one
- Events: `opx:medical:down (source, info)`, `opx:medical:up (source, reason, by)`, `opx:medical:call`, `opx:medical:callAck`, `opx:medical:callClosed`.
- Items: `bandage` and `medkit` are registered in the inventory provider (`RegisterItem` + `RegisterUsable`, export `medicalUseItem`) at start and whenever the inventory restarts.
- Full contract: `types.lua`.
