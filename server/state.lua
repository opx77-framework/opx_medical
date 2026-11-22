-- Downed state: who is down and since when, the countdowns, the hospital respawn (with its bill) and the
-- coverage other resources set. Decides everything; the client only shows it and asks.
-- A player is "down" while the platform has him in its `dead` phase and we tracked that death.

Medical = {}

local CORE = 'opx_core'
local MAX_ID = 0xFFFFFFFF

Medical.down = {}     -- [source] = { citizenId, since, at, cause, killer, position, bucket, respawnAt, bleedoutAt, upReason, upBy }
Medical.coverage = {} -- [source] = { respawnFee, label, owner, generation }
local lastCall = {}   -- [source] = GetGameTimer() of his last accepted request
local busy = {}       -- [source] = true while his respawn runs (guards re-entry)
local fading = {}     -- [source] = true while his screen is held black by our respawn

-- Helpers ----------------------------------------------------------------------------------------

local function finite(n)
	return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end
Medical.finite = finite

-- A player id from anything (positive integer within uint32), or nil. Natives abort on anything else.
function Medical.toSource(value)
	local id = tonumber(value)
	if not id or id ~= id or id < 1 or id > MAX_ID or id % 1 ~= 0 then return nil end
	return math.tointeger(id)
end

-- A routing bucket (integer 0..2^32-1), else 0.
function Medical.toBucket(value)
	local n = tonumber(value)
	if not n or n ~= n or n < 0 or n > MAX_ID or n % 1 ~= 0 then return 0 end
	return math.tointeger(n) or 0
end

-- { x, y, z } with finite numbers, or nil.
function Medical.toPosition(pos)
	if type(pos) ~= 'table' then return nil end
	local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
	if not (finite(x) and finite(y) and finite(z)) then return nil end
	return { x = x, y = y, z = z }
end

-- A fraction in min..1, else the default.
function Medical.toFraction(value, default, min)
	local n = tonumber(value)
	if not finite(n) then n = default end
	return math.max(min or 0.05, math.min(n, 1.0))
end

-- Server clock in ms (a float on the server).
function Medical.now() return GetGameTimer() end

-- Unix seconds (0 when the platform does not answer).
function Medical.unix()
	local ok, t = pcall(Open77.time.unix)
	t = ok and tonumber(t) or nil
	if not finite(t) or t < 0 then return 0 end
	return math.tointeger(math.floor(t)) or 0
end

-- Whole seconds left until `at` (GetGameTimer ms), never negative.
function Medical.secondsLeft(at, now)
	if not finite(at) then return 0 end
	local left = math.ceil((at - (now or Medical.now())) / 1000)
	return math.tointeger(math.max(0, left)) or 0
end

-- An opx_core export (synchronous): its results, or nil, 'core_unavailable' when it raised.
function Medical.core(name, ...)
	local ok, a, b = pcall(Open77.exports.callSync, CORE, name, ...)
	if not ok then return nil, 'core_unavailable' end
	return a, b
end

-- The loaded character of a player (opx_core PlayerData), or nil.
function Medical.character(source)
	local data = Medical.core('GetPlayer', source)
	if type(data) ~= 'table' or type(data.citizenId) ~= 'string' then return nil end
	return data
end

-- Rate limit: false when the player asked again too soon.
function Medical.allow(source)
	local now = Medical.now()
	local last = lastCall[source]
	if last and now - last < Config.rateLimitMs then return false end
	lastCall[source] = now
	return true
end

function Medical.log(message, ...)
	print(('[opx_medical] ' .. message):format(...))
end

-- Client feedback ---------------------------------------------------------------------------------

-- A net event to one client. pcall: the player may have left.
function Medical.send(source, event, ...)
	pcall(TriggerClientEvent, event, source, ...)
end

-- A locale key + params for the player's client, which translates it and shows it through opx_core Notify.
function Medical.notify(source, key, kind, params)
	Medical.send(source, 'opx_medical:notify', key, kind or 'info', params or {})
end

-- Responders ----------------------------------------------------------------------------------------

-- On-duty players holding a job of type Config.responderJobType, downed ones left out.
function Medical.responders()
	local list = {}
	local jobs = Medical.core('GetJobs')
	if type(jobs) ~= 'table' then return list end
	for name, job in pairs(jobs) do
		if type(job) == 'table' and job.type == Config.responderJobType then
			local holders = Medical.core('GetPlayersByJob', name, true)
			for _, src in ipairs(type(holders) == 'table' and holders or {}) do
				if not Medical.down[src] then list[#list + 1] = src end
			end
		end
	end
	return list
end

function Medical.responderCount() return #Medical.responders() end

-- Coverage --------------------------------------------------------------------------------------------

-- The VM generation of a running resource; 0 when it is not running or the platform does not say.
function Medical.generationOf(name)
	if type(name) ~= 'string' or GetResourceState(name) ~= 'running' then return 0 end
	local ok, value = pcall(Open77.resource.generation, name)
	return ok and type(value) == 'number' and value == value and value or 0
end

-- The coverage of a player, dropped when its owner stopped or reloaded without setting it again.
function Medical.coverageOf(source)
	local c = Medical.coverage[source]
	if not c then return nil end
	local current = Medical.generationOf(c.owner)
	if current == 0 or (c.generation and c.generation ~= current) then
		Medical.coverage[source] = nil
		return nil
	end
	return c
end

-- The hospital bill of a player right now (integer >= 0), coverage applied.
function Medical.feeFor(source)
	local fee = tonumber(Config.respawn.fee) or 0
	if not finite(fee) or fee < 0 then fee = 0 end
	local c = Medical.coverageOf(source)
	if c then fee = fee * (1 - c.respawnFee) end
	return math.tointeger(math.max(0, math.floor(fee))) or 0
end

-- State sent to the client (seconds, integers; nil fields are absent).
function Medical.clientState(source, responders)
	local d = Medical.down[source]
	if not d then return nil end
	local now = Medical.now()
	local c = Medical.coverageOf(source)
	local call = Calls.get(source)
	return {
		respawnIn = Medical.secondsLeft(d.respawnAt, now),
		canRespawn = Config.respawn.enabled == true,
		responders = responders or Medical.responderCount(),
		called = call ~= nil,
		acked = call ~= nil and call.responder ~= nil,
		fee = Medical.feeFor(source),
		coverageLabel = c and c.label or nil,
		bleedoutIn = d.bleedoutAt and Medical.secondsLeft(d.bleedoutAt, now) or nil,
	}
end

function Medical.sendState(source, responders)
	local state = Medical.clientState(source, responders)
	if state then Medical.send(source, 'opx_medical:state', state) end
end

-- Screen fade ----------------------------------------------------------------------------------------

local function fadeOut(source)
	if Config.respawn.fade ~= true then return end
	local ok, done = pcall(Open77.players.fade, source, true, 0, { timeoutMs = 10000 })
	if ok and done == true then fading[source] = true end
end

function Medical.fadeIn(source)
	if not fading[source] then return end
	fading[source] = nil
	pcall(Open77.players.fade, source, false, 800)
end

-- Down / up ----------------------------------------------------------------------------------------

-- The player went down (life phase `dead`). A death while already down only refreshes the position.
function Medical.goDown(source, life, citizenId)
	local now = Medical.now()
	local position = Medical.toPosition(life.position) or Medical.toPosition(Open77.players.position(source))
	local bucket = Medical.toBucket(life.bucket)
	local d = Medical.down[source]
	if d then
		d.position, d.bucket = position or d.position, bucket
		return
	end

	local responders = Medical.responderCount()
	local delay = tonumber(responders > 0 and Config.respawn.delaySeconds or Config.respawn.delayNoResponderSeconds) or 0
	local bleed = tonumber(Config.bleedoutSeconds) or 0
	d = {
		citizenId = citizenId,
		since = now,
		at = Medical.unix(),
		cause = type(life.cause) == 'string' and life.cause or 'unknown',
		killer = Medical.toSource(life.killer), -- 0 (nobody) -> nil
		position = position,
		bucket = bucket,
		respawnAt = now + math.max(0, delay) * 1000,
		bleedoutAt = bleed > 0 and (now + bleed * 1000) or nil,
	}
	Medical.down[source] = d

	pcall(Open77.players.setDownedDamageable, source, Config.downedDamageable == true)
	if Config.persistDown then Medical.core('SetMetadata', source, 'isDown', true) end
	Medical.send(source, 'opx:medical:down', Medical.clientState(source, responders))
	TriggerEvent('opx:medical:down', source, {
		cause = d.cause, killer = d.killer, position = d.position, bucket = d.bucket, at = d.at,
	})
end

-- The player is up again (or his character left). reason: revived | respawned | external | unloaded.
function Medical.goUp(source, reason, by)
	local d = Medical.down[source]
	if not d then return end
	Medical.down[source] = nil
	-- An unloaded character keeps his flag (Config.persistDown): he comes back down next time.
	if reason ~= 'unloaded' and Medical.core('GetMetadata', source, 'isDown') ~= nil then
		Medical.core('SetMetadata', source, 'isDown', nil)
	end
	Calls.close(source, reason)
	Medical.fadeIn(source)
	Medical.send(source, 'opx:medical:up', reason)
	TriggerEvent('opx:medical:up', source, reason, by)
end

-- Forgets a player's per-session state (unload, disconnect). Call after goUp.
function Medical.forget(source)
	Medical.coverage[source], lastCall[source], busy[source], fading[source] = nil, nil, nil, nil
end

-- Revive ------------------------------------------------------------------------------------------

-- Revives any dead player where he fell (tracked or not). true | false, reason.
function Medical.revive(source, options)
	local src = Medical.toSource(source)
	if not src then return false, 'invalid_player' end
	options = type(options) == 'table' and options or {}
	if Open77.players.isDead(src) ~= true then return false, 'not_down' end
	local health = Medical.toFraction(options.health, Config.revive.health, 0.05)
	local grace = tonumber(options.graceMs)
	if not finite(grace) then grace = tonumber(Config.revive.graceMs) or 3000 end
	grace = math.tointeger(math.floor(math.max(0, math.min(grace, 60000)))) or 3000
	local by = Medical.toSource(options.by)

	local d = Medical.down[src]
	if d then d.upReason, d.upBy, d.upAt = 'revived', by, Medical.now() end
	local called, ok, why = pcall(Open77.players.revive, src, { health = health, graceMs = grace })
	if not called or ok ~= true then
		if d then d.upReason, d.upBy = nil, nil end
		return false, 'refused:' .. tostring(called and (why or 'failed') or ok)
	end
	return true
end

-- Hospital respawn ---------------------------------------------------------------------------------

-- The hospital: options.hospital (index) when valid, else the one nearest to where the player fell.
local function validHospital(h)
	return type(h) == 'table' and finite(h.x) and finite(h.y) and finite(h.z)
end

local function pickHospital(d, index)
	local list = Config.hospitals or {}
	local i = math.tointeger(tonumber(index) or -1)
	if i and validHospital(list[i]) then return list[i] end
	local best, bestDist = nil, math.huge
	for _, h in ipairs(list) do
		if validHospital(h) then
			local dist = 0
			if d.position then
				local dx, dy, dz = d.position.x - h.x, d.position.y - h.y, d.position.z - h.z
				dist = dx * dx + dy * dy + dz * dz
			end
			if dist < bestDist then best, bestDist = h, dist end
		end
	end
	return best
end

-- Takes up to `fee` from the bank, then cash for the rest. Returns { bank = n, money = n }.
local function charge(source, fee)
	local taken = { bank = 0, money = 0 }
	local rest = fee
	for _, account in ipairs({ 'bank', 'money' }) do
		if rest <= 0 then break end
		local balance = math.tointeger(Medical.core('GetMoney', source, account)) or 0
		local take = math.min(balance, rest)
		if take > 0 and Medical.core('RemoveMoney', source, account, take, 'medical:respawn') == true then
			taken[account] = take
			rest = rest - take
		end
	end
	return taken
end

local function refund(source, taken)
	for account, amount in pairs(taken) do
		if amount > 0 and Medical.core('AddMoney', source, account, amount, 'medical:respawn (refund)') ~= true then
			Medical.log('REFUND FAILED: %d to %s of player %d', amount, account, source)
		end
	end
end

-- Respawns a downed player at a hospital. options = { force (skip the countdown and the enabled switch),
-- free (no bill), hospital (index) }. Synchronous: the bill, the respawn and the society credit happen in
-- one step, the life event later gets him up (goUp 'respawned'). true | false, reason.
function Medical.respawn(source, options)
	options = type(options) == 'table' and options or {}
	local d = Medical.down[source]
	if not d then return false, 'not_down' end
	if busy[source] then return false, 'busy' end
	if d.upReason then return false, 'busy' end -- a revive or respawn is already in flight
	if options.force ~= true then
		if Config.respawn.enabled ~= true then return false, 'respawn_disabled' end
		if Medical.now() < d.respawnAt then return false, 'too_early', Medical.secondsLeft(d.respawnAt) end
	end
	local hospital = pickHospital(d, options.hospital)
	if not hospital then return false, 'no_hospital' end

	busy[source] = true
	local fee = options.free == true and 0 or Medical.feeFor(source)
	local taken = fee > 0 and charge(source, fee) or { bank = 0, money = 0 }

	fadeOut(source)
	local called, ok, why = pcall(Open77.players.respawn, source, {
		position = { x = hospital.x + 0.0, y = hospital.y + 0.0, z = hospital.z + 0.0 },
		heading = finite(tonumber(hospital.heading)) and tonumber(hospital.heading) or 0.0,
		bucket = Medical.toBucket(hospital.bucket),
		health = Medical.toFraction(Config.respawn.health, 1.0, 0.05),
		graceMs = 5000,
	})
	if not called or ok ~= true then
		refund(source, taken)
		Medical.fadeIn(source)
		busy[source] = nil
		-- Tracked down but no longer dead (a missed life event): he is up.
		if Open77.players.isDead(source) == false then Medical.goUp(source, 'external') end
		return false, 'refused:' .. tostring(called and (why or 'failed') or ok)
	end

	d.upReason, d.upBy, d.upAt = 'respawned', nil, Medical.now()
	local paid = taken.bank + taken.money
	local society = Config.respawn.feeSociety
	if paid > 0 and type(society) == 'string' and society ~= '' then
		local credited, reason = Medical.core('AddSocietyMoney', society, paid, 'medical:respawn')
		if credited ~= true then
			Medical.log('hospital bill of %d not credited to society %s: %s', paid, society, tostring(reason))
		end
	end
	if fee > 0 then
		if paid >= fee then
			Medical.notify(source, 'respawn_paid', 'info', { amount = paid })
		else
			Medical.notify(source, 'respawn_partial', 'warning', { amount = paid, fee = fee })
		end
	end
	busy[source] = nil
	-- The life event gives the image back; this is the fallback when it is late.
	SetTimeout(3000, function() Medical.fadeIn(source) end)
	return true
end
