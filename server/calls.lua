-- Calls for help: one open call per downed player, taken by one responder. opx_medical only keeps the list
-- and raises the events; a job resource (opx_traumateam) dispatches them to its medics.

Calls = {}

local open = {}   -- [patient source] = { id, source, citizenId, position, bucket, at, responder }
local lastAt = {} -- [patient source] = GetGameTimer() of his last accepted call
local counter = 0

-- A plain copy for other resources (the citizen id stays here: no patient identity in the dispatch).
function Calls.public(call)
	return {
		id = call.id, source = call.source, bucket = call.bucket, at = call.at, responder = call.responder,
		position = { x = call.position.x, y = call.position.y, z = call.position.z },
	}
end

function Calls.get(source) return open[source] end

-- Every open call, oldest first.
function Calls.list()
	local list = {}
	for _, call in pairs(open) do list[#list + 1] = Calls.public(call) end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- A downed player asks for help. true | false, reason, params.
function Calls.request(source)
	local d = Medical.down[source]
	if not d then return false, 'not_down' end
	local now = Medical.now()
	local cooldown = math.max(0, tonumber(Config.callCooldownSeconds) or 0) * 1000
	local last = lastAt[source]
	if last and now - last < cooldown then
		return false, 'call_cooldown', { seconds = Medical.secondsLeft(last + cooldown, now) }
	end
	if Medical.responderCount() < 1 then return false, 'no_responder' end
	local character = Medical.character(source)
	if not character then return false, 'not_loaded' end
	local position = Medical.toPosition(Open77.players.position(source)) or d.position
	if not position then return false, 'failed' end

	if open[source] then Calls.close(source, 'renewed') end
	counter = counter + 1
	local call = {
		id = counter, source = source, citizenId = character.citizenId, position = position,
		bucket = d.bucket, at = Medical.unix(), responder = nil,
	}
	open[source] = call
	lastAt[source] = now
	TriggerEvent('opx:medical:call', source, Calls.public(call))
	return true
end

-- A responder takes the call of a patient. true | false, reason.
function Calls.ack(patientSource, responderSource)
	local patient = Medical.toSource(patientSource)
	local responder = Medical.toSource(responderSource)
	if not patient or not responder then return false, 'invalid_player' end
	local call = open[patient]
	if not call then return false, 'no_call' end
	if call.responder and call.responder ~= responder then return false, 'already_taken' end
	if call.responder == responder then return true end
	call.responder = responder
	Medical.notify(patient, 'unit_on_way', 'success')
	Medical.sendState(patient)
	TriggerEvent('opx:medical:callAck', patient, responder)
	return true
end

-- The responder gives the call back (another one may take it). true | false, reason.
function Calls.release(patientSource, responderSource)
	local patient = Medical.toSource(patientSource)
	local responder = Medical.toSource(responderSource)
	if not patient or not responder then return false, 'invalid_player' end
	local call = open[patient]
	if not call then return false, 'no_call' end
	if call.responder ~= responder then return false, 'not_responder' end
	call.responder = nil
	Medical.sendState(patient)
	return true
end

-- Closes the open call of a patient (up, unloaded, renewed...).
function Calls.close(source, reason)
	local call = open[source]
	if not call then return end
	open[source] = nil
	TriggerEvent('opx:medical:callClosed', source, call.id, reason or 'closed')
end

-- A responder left: his taken calls are open again.
function Calls.dropResponder(responder)
	for patient, call in pairs(open) do
		if call.responder == responder then
			call.responder = nil
			Medical.sendState(patient)
		end
	end
end

function Calls.forget(source)
	Calls.close(source, 'unloaded')
	lastAt[source] = nil
	Calls.dropResponder(source)
end
