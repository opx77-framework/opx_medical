-- Entry: the life events, client requests (validated + rate-limited), the exports (provider slot `medical`),
-- the commands, the 15 s loop and the player lifecycle.

local RESOURCE = GetCurrentResourceName()
local WEAPON_PREFIX = 'opx_medical:'
local RESTORE_WEAPON = 'opx_medical:restore'

-- Deaths ------------------------------------------------------------------------------------------

-- A `dead` phase: the player goes down unless it is a scripted move of another resource (opx_character's
-- placement, admin teleports) or he has no character in the world.
local function onDeath(source)
	local ok, life = pcall(Open77.players.getLifeState, source)
	if not ok or type(life) ~= 'table' then return end
	local data = Medical.character(source)
	if not data or data.isNew then return end
	if life.cause == 'script' and not (type(life.weapon) == 'string'
		and life.weapon:sub(1, #WEAPON_PREFIX) == WEAPON_PREFIX) then
		return
	end
	Medical.goDown(source, life, data.citizenId)
end

AddEventHandler('onPlayerLifeStateChanged', function(playerId, _, phase)
	local src = Medical.toSource(playerId)
	if not src then return end
	if phase == 'dead' then
		onDeath(src)
	elseif phase == 'alive' or phase == 'recovering' then
		-- Up by any path: our Revive / Respawn recorded the reason, anything else (staff tool) is external.
		local d = Medical.down[src]
		if d then Medical.goUp(src, d.upReason or 'external', d.upBy) end
	end
end)

-- Back down after a reconnect (Config.persistDown): the character was down when he left.
AddEventHandler('opx:character:spawned', function(playerId, citizenId, info)
	local src = Medical.toSource(playerId)
	if not src or type(citizenId) ~= 'string' or type(info) ~= 'table' or info.creation == true then return end
	if Medical.core('GetMetadata', src, 'isDown') ~= true then return end
	if not Config.persistDown then
		Medical.core('SetMetadata', src, 'isDown', nil)
		return
	end
	CreateThread(function()
		local function same()
			local data = Medical.character(src)
			return data ~= nil and data.citizenId == citizenId
		end
		-- Wait for the landing (alive), 10 s at most, then a short settle.
		local deadline = Medical.now() + 10000
		while Medical.now() < deadline do
			if not same() then return end
			if Open77.players.isDead(src) == false then break end
			Wait(250)
		end
		Wait(1000)
		if not same() or Medical.down[src] or Open77.players.isDead(src) ~= false then return end
		local ok, killed, reason = pcall(Open77.players.kill, src, { cause = 'script', weapon = RESTORE_WEAPON })
		if not ok or killed ~= true then
			Medical.log('could not put player %d back down: %s', src, tostring(ok and reason or killed))
		end
	end)
end)

-- Client requests ---------------------------------------------------------------------------------

-- Answers a refused respawn with its locale key.
local function respawnFeedback(src, ok, reason, seconds)
	if ok then return end
	if reason == 'too_early' then
		return Medical.notify(src, 'too_early', 'error', { time = seconds or 0 })
	end
	if reason == 'not_down' or reason == 'respawn_disabled' or reason == 'busy' or reason == 'no_hospital' then
		return Medical.notify(src, reason, 'error')
	end
	Medical.notify(src, 'refused', 'error', { reason = tostring(reason) })
end

local function callFeedback(src, ok, reason, params)
	if ok then
		Medical.notify(src, 'call_sent_notify', 'success')
		return Medical.sendState(src)
	end
	if reason == 'call_cooldown' or reason == 'no_responder' or reason == 'not_down' then
		return Medical.notify(src, reason, 'error', params)
	end
	Medical.notify(src, 'failed', 'error', { reason = tostring(reason) })
end

-- Every client request: a valid source, under the rate limit. Nothing waits, the handler runs inline.
local function onRequest(name, handler)
	RegisterNetEvent(name, function(...)
		local src = Medical.toSource(source)
		if not src or not Medical.allow(src) then return end
		handler(src, ...)
	end)
end

onRequest('opx_medical:call', function(src) callFeedback(src, Calls.request(src)) end)
onRequest('opx_medical:respawn', function(src) respawnFeedback(src, Medical.respawn(src)) end)
-- The client (re)started: send the state again when he is down.
onRequest('opx_medical:sync', function(src)
	local state = Medical.clientState(src)
	if state then Medical.send(src, 'opx:medical:down', state) end
end)

-- Exports (provider slot `medical`, all synchronous) ------------------------------------------------

local api = {}

function api.IsDown(source)
	local src = Medical.toSource(source)
	return src ~= nil and Medical.down[src] ~= nil
end

function api.GetState(source)
	local src = Medical.toSource(source)
	local d = src and Medical.down[src]
	if not d then return nil end
	local call = Calls.get(src)
	return {
		down = true, at = d.at, cause = d.cause,
		position = d.position and { x = d.position.x, y = d.position.y, z = d.position.z } or nil,
		respawnIn = Medical.secondsLeft(d.respawnAt), called = call ~= nil, responder = call and call.responder or nil,
	}
end

function api.Revive(source, options)
	return Medical.revive(source, options)
end

function api.Respawn(source, options)
	local src = Medical.toSource(source)
	if not src then return false, 'invalid_player' end
	local ok, reason = Medical.respawn(src, options)
	return ok, reason
end

function api.SetCoverage(source, coverage)
	local src = Medical.toSource(source)
	if not src then return false, 'invalid_player' end
	local owner = GetInvokingResource() or RESOURCE
	local generation = type(GetInvokingResourceGeneration) == 'function' and GetInvokingResourceGeneration() or nil
	if type(generation) ~= 'number' then generation = Medical.generationOf(owner) end
	if generation == 0 then generation = nil end
	local current = Medical.coverageOf(src)
	if current and current.owner ~= owner then return false, 'owned_by_other_resource' end

	if coverage == nil or coverage == false then
		Medical.coverage[src] = nil
	else
		if type(coverage) ~= 'table' then return false, 'invalid_coverage' end
		local share = tonumber(coverage.respawnFee)
		if not Medical.finite(share) or share < 0 or share > 1 then return false, 'invalid_coverage' end
		local label = nil
		if coverage.label ~= nil then
			if type(coverage.label) ~= 'string' then return false, 'invalid_coverage' end
			label = coverage.label:gsub('%c', ' ')
			if #label > 32 then
				local cut = 32
				while cut > 0 and (label:byte(cut + 1) or 0) >= 0x80 and (label:byte(cut + 1) or 0) < 0xC0 do cut = cut - 1 end
				label = label:sub(1, cut)
			end
			if label == '' then label = nil end
		end
		if not Medical.character(src) then return false, 'not_loaded' end
		Medical.coverage[src] = { respawnFee = share, label = label, owner = owner, generation = generation }
	end
	Medical.sendState(src)
	return true
end

function api.GetCoverage(source)
	local src = Medical.toSource(source)
	local c = src and Medical.coverageOf(src)
	if not c then return nil end
	return { respawnFee = c.respawnFee, label = c.label }
end

function api.GetCalls() return Calls.list() end

function api.AckCall(patientSource, responderSource) return Calls.ack(patientSource, responderSource) end

-- Not in the plan's contract (an addition): gives a taken call back so another responder can take it.
function api.ReleaseCall(patientSource, responderSource) return Calls.release(patientSource, responderSource) end

function api.GetResponderCount() return Medical.responderCount() end

for name, fn in pairs(api) do
	local ok, reason = exports(name, fn)
	if not ok then Medical.log('export %s not registered: %s', name, tostring(reason)) end
end

-- Commands ------------------------------------------------------------------------------------------

local function command(name, handler, restricted)
	if type(name) ~= 'string' or name == '' then return end
	local ok, err = pcall(RegisterCommand, name, handler, restricted)
	if not ok then Medical.log('command /%s not registered: %s', name, tostring(err)) end
end

local cmds = type(Config.commands) == 'table' and Config.commands or {}

command(cmds.respawn, function(src)
	src = Medical.toSource(src)
	if not src then return print('[opx_medical] use this command in game') end
	if Medical.allow(src) then respawnFeedback(src, Medical.respawn(src)) end
end, false)

command(cmds.call, function(src)
	src = Medical.toSource(src)
	if not src then return print('[opx_medical] use this command in game') end
	if Medical.allow(src) then callFeedback(src, Calls.request(src)) end
end, false)

-- revive [playerId|me] (restricted): full health.
command(cmds.revive, function(src, args)
	local staff = Medical.toSource(src)
	local word = args and args[1]
	local target = (word == nil or word == 'me') and staff or Medical.toSource(word)
	local function answer(key, kind, params, text)
		if staff then Medical.notify(staff, key, kind, params) else print('[opx_medical] ' .. text) end
	end
	if not target then return answer('revive_usage', 'error', {}, 'usage: revive <playerId>') end
	local ok, reason = Medical.revive(target, { health = 1.0, by = staff })
	if ok then
		answer('revive_done', 'success', { id = target }, ('player %d revived'):format(target))
	else
		answer('revive_failed', 'error', { reason = tostring(reason) }, ('revive failed: %s'):format(tostring(reason)))
	end
end, true)

-- Command help shown in opx_chat when it runs (optional: nothing happens without it). Chat is not a
-- provider slot, so opx_chat is named here; its export only describes the commands above.
local COMMAND_HELP = {
	respawn = { help = { en = 'Respawn at the hospital while downed.', fr = "Réapparaître à l'hôpital quand vous êtes à terre." } },
	call = { help = { en = 'Call for medical help while downed.', fr = 'Appeler les secours quand vous êtes à terre.' } },
	revive = { help = { en = 'Revive a player with full health.', fr = 'Réanimer un joueur avec toute sa santé.' }, parameters = {
		{ name = { en = 'playerId|me', fr = 'idJoueur|me' }, help = { en = 'Default: yourself', fr = 'Par défaut : vous' }, optional = true },
	} },
}

local function publishCommandHelp()
	if GetResourceState('opx_chat') ~= 'running' then return end
	for key, info in pairs(COMMAND_HELP) do
		local name = cmds[key]
		if type(name) == 'string' and name ~= '' then
			pcall(Open77.exports.callSync, 'opx_chat', 'SetCommandHelp', name, info.help, info.parameters)
		end
	end
end

AddEventHandler('onResourceStart', function(name)
	if name == GetCurrentResourceName() or name == 'opx_chat' then publishCommandHelp() end
end)

-- Loop: responder count to downed clients, bleedout, stale entries ---------------------------------

CreateThread(function()
	while true do
		Wait(15000)
		local ok, err = pcall(function()
			local list = {}
			for src in pairs(Medical.down) do list[#list + 1] = src end
			if #list == 0 then return end
			local responders = Medical.responderCount()
			local now = Medical.now()
			for _, src in ipairs(list) do
				local d = Medical.down[src]
				if d then
					if Open77.players.isDead(src) == false then
						Medical.goUp(src, d.upReason or 'external', d.upBy) -- a missed life event
					elseif d.upReason and now - (d.upAt or 0) > 15000 then
						-- A revive / respawn accepted but never landed: let the player try again.
						d.upReason, d.upBy, d.upAt = nil, nil, nil
						Medical.sendState(src, responders)
					elseif d.bleedoutAt and now >= d.bleedoutAt and not d.upReason then
						local done, reason = Medical.respawn(src, { force = true })
						if not done then Medical.log('bleedout respawn of %d refused: %s', src, tostring(reason)) end
					else
						Medical.sendState(src, responders)
					end
				end
			end
		end)
		if not ok then Medical.log('loop raised: %s', tostring(err)) end
	end
end)

-- Lifecycle ------------------------------------------------------------------------------------------

local function leave(src)
	if Medical.down[src] then Medical.goUp(src, 'unloaded') end
	Calls.forget(src)
	Medical.forget(src)
end

AddEventHandler('opx:playerUnloaded', function(playerId)
	local src = Medical.toSource(playerId)
	if src then leave(src) end
end)

AddEventHandler('onPlayerDisconnected', function(playerId)
	local src = Medical.toSource(playerId)
	if src then leave(src) end
end)

-- Another resource stopped: its coverages go (by generation: a reloaded owner's fresh entries stay).
AddEventHandler('onResourceStop', function(name)
	if name == RESOURCE or type(name) ~= 'string' then return end
	local current = Medical.generationOf(name)
	for src, c in pairs(Medical.coverage) do
		if c.owner == name and (current == 0 or c.generation ~= current) then
			Medical.coverage[src] = nil
			if Medical.down[src] then Medical.sendState(src) end
		end
	end
end)

-- Our own start (or hot reload): adopt the loaded characters who are dead right now.
AddEventHandler('onResourceStart', function(name)
	if name ~= RESOURCE then return end
	local players = Medical.core('GetPlayers')
	for _, playerId in ipairs(type(players) == 'table' and players or {}) do
		local src = Medical.toSource(playerId)
		if src and Open77.players.isDead(src) == true then onDeath(src) end
	end
end)
