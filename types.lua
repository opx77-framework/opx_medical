---@meta

-- opx_medical server exports and events. Not loaded by the manifest (LuaLS annotations only).
-- This is the contract of opx_core's provider slot `medical`: a replacement keeps these names and shapes.
-- Every export is SYNCHRONOUS (answers from memory, never waits). Never name the resource: ask opx_core.
--
--   local medical = exports.opx_core:GetProvider('medical')
--   if medical then
--       local ok, down = pcall(Open77.exports.callSync, medical, 'IsDown', source)
--   end

---@alias OpxMedicalUpReason
---| 'revived' Revive export (a medic, the staff command)
---| 'respawned' hospital respawn (menu, command, Respawn export, bleedout)
---| 'external' got up by another path (opx_admin revive, another resource calling the platform)
---| 'unloaded' the character left while down (unload, switch, disconnect); he stays flagged `isDown`

---@class OpxMedicalState
---@field down true
---@field at integer unix seconds when he went down
---@field cause string platform death cause: unknown, firearm, melee, explosion, fall, vehicle, environment, script
---@field position {x: number, y: number, z: number}|nil where he fell
---@field respawnIn integer seconds before the hospital respawn is allowed (0 = now)
---@field called boolean a call for help is open
---@field responder integer|nil source of the responder who took the call

---@class OpxMedicalReviveOptions
---@field health? number fraction 0.05..1 (default Config.revive.health)
---@field graceMs? integer invulnerable window after the revive, 0..60000 (default Config.revive.graceMs)
---@field by? integer source of the reviver (passed on with opx:medical:up)

---@class OpxMedicalRespawnOptions
---@field force? boolean skip the countdown and Config.respawn.enabled
---@field free? boolean no hospital bill
---@field hospital? integer index in Config.hospitals (default: nearest to where he fell)

---@class OpxMedicalCoverage
---@field respawnFee number 0..1, share of the hospital bill covered
---@field label? string up to 32 bytes, shown in the emergency menu (e.g. 'Trauma Team Gold')

---@class OpxMedicalCall
---@field id integer
---@field source integer the downed player
---@field position {x: number, y: number, z: number}
---@field bucket integer
---@field at integer unix seconds
---@field responder integer|nil

---@class OpxMedicalExports
local opx_medical = {}

--- SYNC. Whether the player is down (tracked by opx_medical).
---@param source integer
---@return boolean
function opx_medical.IsDown(source) end

--- SYNC. The downed state, or nil when the player is not down.
---@param source integer
---@return OpxMedicalState|nil
function opx_medical.GetState(source) end

--- SYNC. Revives any dead player where he fell (tracked or not). The platform gets him up a moment later;
--- opx:medical:up (reason 'revived') follows.
---@param source integer
---@param options? OpxMedicalReviveOptions
---@return boolean ok
---@return 'invalid_player'|'not_down'|string|nil reason `refused:<platform reason>` when the platform refused
function opx_medical.Revive(source, options) end

--- SYNC. Respawns a downed player at a hospital: bill (bank first, then cash, coverage applied; never blocks),
--- society credit, respawn. A refused respawn gives the money back.
---@param source integer
---@param options? OpxMedicalRespawnOptions
---@return boolean ok
---@return 'invalid_player'|'not_down'|'busy'|'respawn_disabled'|'too_early'|'no_hospital'|string|nil reason
function opx_medical.Respawn(source, options) end

--- SYNC. Sets (or clears with nil) the coverage of a loaded player. Owned by the calling resource and VM
--- generation, one per player; cleared on unload, disconnect and when the owner stops.
---@param source integer
---@param coverage OpxMedicalCoverage|nil
---@return boolean ok
---@return 'invalid_player'|'invalid_coverage'|'not_loaded'|'owned_by_other_resource'|nil reason
function opx_medical.SetCoverage(source, coverage) end

--- SYNC. A copy of the player's coverage, or nil.
---@param source integer
---@return OpxMedicalCoverage|nil
function opx_medical.GetCoverage(source) end

--- SYNC. Every open call for help, oldest first.
---@return OpxMedicalCall[]
function opx_medical.GetCalls() end

--- SYNC. A responder takes a patient's call: the patient is told a unit is on its way.
---@param patientSource integer
---@param responderSource integer
---@return boolean ok
---@return 'invalid_player'|'no_call'|'already_taken'|nil reason
function opx_medical.AckCall(patientSource, responderSource) end

--- SYNC. The responder gives a taken call back (another one may take it). Addition to the plan's contract.
---@param patientSource integer
---@param responderSource integer
---@return boolean ok
---@return 'invalid_player'|'no_call'|'not_responder'|nil reason
function opx_medical.ReleaseCall(patientSource, responderSource) end

--- SYNC. On-duty players of a job of type Config.responderJobType, downed ones left out.
---@return integer
function opx_medical.GetResponderCount() end

-- Server host events (AddEventHandler, never RegisterNetEvent):
---@alias OpxMedicalDownEvent fun(source: integer, info: {cause: string, killer: integer|nil, position: table|nil, bucket: integer, at: integer}) opx:medical:down
---@alias OpxMedicalUpEvent fun(source: integer, reason: OpxMedicalUpReason, by: integer|nil) opx:medical:up
---@alias OpxMedicalCallEvent fun(source: integer, call: OpxMedicalCall) opx:medical:call
---@alias OpxMedicalCallAckEvent fun(source: integer, responderSource: integer) opx:medical:callAck
---@alias OpxMedicalCallClosedEvent fun(source: integer, callId: integer, reason: string) opx:medical:callClosed
-- callClosed reason: an OpxMedicalUpReason, 'unloaded', or 'renewed' (the player sent a new call).
-- Hospital bill = floor(Config.respawn.fee * (1 - coverage.respawnFee)); money reason `medical:respawn`.
-- opx_core metadata key `isDown`: true while down when Config.persistDown (the character goes back down on reconnect).
-- Internal net events (not a contract): client -> server opx_medical:call / :respawn / :sync;
-- server -> client opx_medical:state / :notify.

-- Client net events (any client resource may RegisterNetEvent them):
-- opx:medical:down (state) / opx:medical:up (reason)
---@class OpxMedicalClientState
---@field respawnIn integer seconds
---@field canRespawn boolean Config.respawn.enabled
---@field responders integer
---@field called boolean
---@field acked boolean
---@field fee integer hospital bill now, coverage applied
---@field coverageLabel string|nil
---@field bleedoutIn integer|nil seconds before the automatic respawn (Config.bleedoutSeconds > 0)

-- Client export: Open77.exports.callSync('opx_medical', 'IsDown') -> boolean (local player).

-- Items owned by opx_medical (server/items.lua), registered in the inventory provider (GetProvider('inventory'))
-- at our start and on every onResourceStart of that provider, when Config.items.<id>.enabled:
--   RegisterItem('bandage', { label = {en,fr}, description = {en,fr}, weightG = 100, usable = true })
--   RegisterItem('medkit',  { label = {en,fr}, description = {en,fr}, weightG = 400, usable = true })
--   RegisterUsable(<id>, 'medicalUseItem')
-- Not part of the `medical` slot contract (a replacement may own other items or none).

--- ASYNC-safe usable handler called by the inventory: heals Config.items[item].heal points
--- (Open77.players.heal). Refused (false, nothing consumed) while down, at full health, or for a disabled item.
---@param source integer
---@param item 'bandage'|'medkit'
---@return boolean consume true: the inventory removes one
function opx_medical.medicalUseItem(source, item) end
