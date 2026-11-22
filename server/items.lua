-- Items owned by opx_medical: bandage and medkit. Registered in the inventory provider's catalogue
-- (RegisterItem) with a usable handler (RegisterUsable -> our export medicalUseItem), at our start and again
-- whenever the inventory provider (re)starts. Nothing happens when no inventory provider is configured.

local RESOURCE = GetCurrentResourceName()
local USE_EXPORT = 'medicalUseItem'

-- Catalogue text and weights (heal amounts and on/off come from Config.items).
local ITEMS = {
	bandage = {
		label = { en = 'Bandage', fr = 'Bandage' },
		description = { en = 'Stops the bleeding.', fr = 'Arrête le saignement.' },
		weightG = 100,
	},
	medkit = {
		label = { en = 'Medkit', fr = 'Trousse de soins' },
		description = { en = 'Trauma kit: dressings, stims, a sealant spray.',
			fr = 'Trousse de traumatologie : pansements, stimulants, spray cicatrisant.' },
		weightG = 400,
	},
}

-- The heal amount of an enabled item, else nil.
local function healOf(item)
	local all = Config.items
	local entry = type(all) == 'table' and ITEMS[item] and all[item]
	if type(entry) ~= 'table' or entry.enabled == false then return nil end
	local heal = tonumber(entry.heal)
	if not Medical.finite(heal) or heal <= 0 or heal > 100000 then return nil end
	return heal
end

-- The resource filling the `inventory` slot, or nil.
local function inventory()
	local name = Medical.core('GetProvider', 'inventory')
	return type(name) == 'string' and name ~= '' and name or nil
end

local function register()
	local inv = inventory()
	if not inv then return end
	for item, def in pairs(ITEMS) do
		if healOf(item) then
			local ok, done, reason = pcall(Open77.exports.callSync, inv, 'RegisterItem', item, {
				label = def.label, description = def.description, weightG = def.weightG, usable = true,
			})
			if not ok or done ~= true then
				Medical.log('item %s not registered in %s: %s', item, inv, tostring(ok and reason or done))
			else
				local uok, udone, ureason = pcall(Open77.exports.callSync, inv, 'RegisterUsable', item, USE_EXPORT)
				if not uok or udone ~= true then
					Medical.log('usable %s not registered in %s: %s', item, inv, tostring(uok and ureason or udone))
				end
			end
		end
	end
end

-- Called by the inventory when a player uses the item; true consumes one. A bandage does not revive:
-- refused while down. Not consumed at full health.
exports(USE_EXPORT, function(source, item)
	local src = Medical.toSource(source)
	if not src or type(item) ~= 'string' then return false end
	local heal = healOf(item)
	if not heal then
		Medical.notify(src, 'item_disabled', 'error')
		return false
	end
	if Medical.down[src] or Open77.players.isDead(src) ~= false then
		Medical.notify(src, 'item_down', 'error')
		return false
	end
	local rok, hp = pcall(Open77.stats.getHealth, src)
	if rok and type(hp) == 'table' then
		local current, maximum = tonumber(hp.current or hp.value), tonumber(hp.maximum or hp.max)
		if Medical.finite(current) and Medical.finite(maximum) and maximum > 0 and current >= maximum then
			Medical.notify(src, 'item_full', 'info')
			return false
		end
	end
	local ok, done, reason = pcall(Open77.players.heal, src, heal)
	if not ok or done == false then
		Medical.log('heal of %d with %s failed: %s', src, item, tostring(ok and reason or done))
		Medical.notify(src, 'failed', 'error', { reason = tostring(ok and reason or 'error') })
		return false
	end
	Medical.notify(src, 'item_used', 'success')
	return true
end)

-- Our start, and every (re)start of the inventory provider (its catalogue and usables start empty).
-- Wait a second: the provider's exports may still be loading.
AddEventHandler('onResourceStart', function(name)
	if name ~= RESOURCE and name ~= inventory() then return end
	CreateThread(function()
		Wait(1000)
		register()
	end)
end)
