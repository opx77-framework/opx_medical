-- The emergency menu (opx_menu) shown while down. Shows and asks; the server decides.
-- The countdowns run on a local clock from the last state the server sent: nothing is asked every second.

local OPX = assert(require('@opx_core'))
local Menu = assert(require('@opx_menu'))

local Ui = {}

local T = OPX.Locale()
local main = nil    -- the open menu, or nil
local state = nil   -- last state from the server
local stateAt = 0   -- GetGameTimer() when it arrived
local ticking = false

-- Translated text; money params formatted the player's way, `time` (seconds) as mm:ss.
local MONEY = { amount = true, fee = true }

local function clock(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	return ('%02d:%02d'):format(seconds // 60, seconds % 60)
end

function Ui.text(key, params)
	local shown = {}
	for k, v in pairs(type(params) == 'table' and params or {}) do
		if MONEY[k] and type(v) == 'number' then shown[k] = OPX.FormatMoney(v)
		elseif k == 'time' and type(v) == 'number' then shown[k] = clock(v)
		else shown[k] = v end
	end
	return T(key, shown)
end

-- A server answer: locale key + kind + params. An unknown key reads as a generic failure.
function Ui.notify(key, kind, params)
	if type(key) ~= 'string' then return end
	local text = Ui.text(key, params)
	if text == key then text = Ui.text('failed', { reason = key }) end
	OPX.Notify(text, kind, nil, Ui.text('title'))
end

-- Seconds left on a countdown of the state, the time since it arrived taken off. nil when absent.
local function left(field)
	local value = state and tonumber(state[field])
	if not value then return nil end
	return math.max(0, value - math.floor((GetGameTimer() - stateAt) / 1000))
end

local function int(v) return math.tointeger(tonumber(v) or 0) or 0 end

local function subtitle()
	local bleed = left('bleedoutIn')
	if bleed then return Ui.text('subtitle_bleed', { time = bleed }) end
	return Ui.text('subtitle', { responders = int(state.responders) })
end

local function callRow()
	local row = { label = Ui.text('call'), value = 'call', icon = 'phone', rightLabel = tostring(int(state.responders)),
		description = Ui.text('call_desc'), disabled = false }
	if state.acked then
		row.label, row.rightLabel, row.description, row.disabled = Ui.text('call_acked'), '', Ui.text('call_acked_desc'), true
	elseif state.called then
		row.rightLabel, row.description, row.disabled = Ui.text('call_sent'), Ui.text('call_sent_desc'), true
	elseif int(state.responders) < 1 then
		row.description, row.disabled = Ui.text('no_responder'), true
	end
	return row
end

local function respawnRow()
	local row = { label = Ui.text('respawn'), value = 'respawn', icon = 'medical', disabled = false }
	local wait = left('respawnIn') or 0
	local fee = int(state.fee)
	if state.canRespawn ~= true then
		row.rightLabel, row.description, row.disabled = '', Ui.text('respawn_disabled'), true
	elseif wait > 0 then
		row.rightLabel, row.description, row.disabled = clock(wait), Ui.text('respawn_wait'), true
	else
		row.rightLabel = fee > 0 and OPX.FormatMoney(fee) or Ui.text('free')
		row.description = Ui.text('respawn_desc', { fee = fee })
		if type(state.coverageLabel) == 'string' then
			row.description = row.description .. ' · ' .. Ui.text('covered', { label = state.coverageLabel })
		end
	end
	return row
end

local function waitRow()
	return { label = Ui.text('wait'), value = 'wait', icon = 'clock', description = Ui.text('wait_desc') }
end

-- Redraws the rows that change (countdowns, call state) and the subtitle.
local function refresh()
	if not main or not main:isOpen() or not state then return end
	main:setTitle(Ui.text('title'), subtitle())
	main:updateElement('call', callRow())
	main:updateElement('respawn', respawnRow())
end

local function tick()
	if ticking then return end
	ticking = true
	CreateThread(function()
		while main and main:isOpen() do
			refresh()
			Wait(1000)
		end
		ticking = false
	end)
end

local function askRespawn()
	local fee = int(state and state.fee)
	local yes = Menu.confirm({
		title = Ui.text('confirm_title'),
		message = Ui.text('confirm_message', { fee = fee }),
		confirmLabel = Ui.text('confirm_yes'), cancelLabel = Ui.text('confirm_no'),
	})
	if yes then TriggerServerEvent('opx_medical:respawn') end
end

function Ui.open()
	if not state then return end
	if main and main:isOpen() then return refresh() end
	local menu, reason = Menu.open({
		id = 'opx_medical_down', title = Ui.text('title'), subtitle = subtitle(),
		elements = { callRow(), respawnRow(), waitRow() },
		onSelect = function(element, m)
			if element.value == 'call' then TriggerServerEvent('opx_medical:call')
			elseif element.value == 'respawn' then askRespawn()
			else m:close() end
		end,
		onClose = function(m)
			if main == m then main = nil end
		end,
	})
	if not menu then
		print(('[opx_medical] emergency menu not opened: %s'):format(tostring(reason)))
		return
	end
	main = menu
	tick()
end

function Ui.isOpen() return main ~= nil and main:isOpen() end

function Ui.close()
	if main then main:close() end
	main = nil
end

-- A new state from the server (down, call sent, coverage changed, responder count).
function Ui.setState(newState)
	if type(newState) ~= 'table' then return end
	state, stateAt = newState, GetGameTimer()
	refresh()
end

function Ui.clear() state = nil end

return Ui
