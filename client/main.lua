-- opx_medical client: the emergency menu and the help line while down, the reopen key, the hospital pins.
-- It only shows and asks; the server decides.

local OPX = assert(require('@opx_core'))
local Ui = assert(require('client.modules.ui'))

local MAPPING = 'opx_medical.menu'
local down = false
local blips = {}

-- Calls the HUD provider (opx_core Config.providers.hud) under pcall: it may be absent or lack ShowHelp.
local function hud(name, ...)
	local provider = OPX.GetProvider('hud')
	if not provider then return end
	pcall(Open77.exports.callSync, provider, name, ...)
end

local function keyLabel()
	local ok, key = pcall(Open77.input.keyFor, MAPPING)
	return ok and type(key) == 'string' and key or Config.key
end

local function setDown(value)
	down = value
	if value then
		hud('ShowHelp', Ui.text('help'), keyLabel())
	else
		Ui.close()
		Ui.clear()
		hud('HideHelp')
	end
end

RegisterNetEvent('opx:medical:down', function(state)
	Ui.setState(state)
	setDown(true)
	Ui.open()
end)

RegisterNetEvent('opx_medical:state', function(state)
	if down then Ui.setState(state) end
end)

RegisterNetEvent('opx:medical:up', function(reason)
	setDown(false)
	if reason == 'revived' then Ui.notify('up_revived', 'success')
	elseif reason == 'respawned' then Ui.notify('up_respawned', 'info') end
end)

RegisterNetEvent('opx_medical:notify', function(key, kind, params) Ui.notify(key, kind, params) end)

-- Client export: whether the local player is down.
exports('IsDown', function() return down end)

-- Hospital pins while a character is loaded ---------------------------------------------------------

local function clearBlips()
	for _, id in ipairs(blips) do pcall(Open77.blips.remove, id) end
	blips = {}
end

local function createBlips()
	clearBlips()
	if Config.blips ~= true then return end
	for _, h in ipairs(Config.hospitals or {}) do
		local ok, id = pcall(Open77.blips.create, {
			position = { x = h.x, y = h.y, z = h.z }, sprite = 'meds', title = h.label or Ui.text('hospital'),
		})
		if ok and id then blips[#blips + 1] = id end
	end
end

OPX.OnPlayerLoaded(function() createBlips() end)
OPX.OnPlayerUnloaded(function()
	clearBlips()
	if down then setDown(false) end
end)

-- Key and start ---------------------------------------------------------------------------------------

CreateThread(function()
	local ok, reason = RegisterKeyMapping(MAPPING, Ui.text('key_name'), Config.key or 'E', function()
		if down and not Ui.isOpen() then Ui.open() end
	end)
	if not ok then print(('[opx_medical] key mapping refused: %s'):format(tostring(reason))) end

	-- A (re)start while already down: ask the server for the state.
	Wait(1000)
	if OPX.IsLoaded() then TriggerServerEvent('opx_medical:sync') end
end)
