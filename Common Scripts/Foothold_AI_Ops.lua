---------------------------------------------------------------------------
-- Foothold AI - RED operations, and fair jamming for both sides
-- Orders Claude can give RED on top of Foothold_AI_Command.lua, each built on
-- Foothold's own functions and paid from RED's credits:
--   deploy_forces   extra ground group in a RED zone      (CustomZone:spawnGroup)
--   upgrade_zone    exact template into a zone's extra slot (addExtraSlot + upgrade)
--   fire_mission    a long-range battery set up in a RED zone fires at a zone (fireAtZone)
--   move_awacs      RED AWACS orbit over a chosen RED zone  (setAwacsRacetrack)
--   supply_airlift  supply stock into a RED zone            (_addExpeditedRegularSupplyStock)
--   heli_raid       Mi-8 lands a gun near an enemy zone, the gun fires (fireAtZone)
--   air_assault     Mi-8 lands troops in a neutral zone    (startPendingCaptureFromAircraft)
--   ambush          Mi-8 drops a MANPADS/AAA team on a route
--   jam             a jammer orbits near an enemy zone      (jamRadarsAtZone)
-- Jamming (both sides, including BLUE's shop jammer): only SAM radars within
-- range of a live jammer are jammed, and the jammer flies to a standoff orbit.
-- Nothing appears out of thin air: units spawn inside RED zones or where a
-- RED helicopter has landed, and every flight can be shot down.
---------------------------------------------------------------------------

local FAI = FootholdAI
local X = FAI and FAI.command
if not (X and X.executors and X.util) then return end
local cfg = FAI.config.command
local ops = cfg.ops
local prices = cfg.prices
local U = X.util
local round, zonePoint, zoneUsable = U.round, U.zonePoint, U.zoneUsable
local RED, BLUE = coalition.side.RED, coalition.side.BLUE
local NM = 1852

local O = {
	deployed = {},      -- list of { zone, template, category, group, at }
	fireReadyAt = {},   -- [system] = abs time
	batteries = {},     -- [group] = { system, origin, target, at }
	flights = {},       -- [group] = flight record (helicopters and jammers)
	teams = {},         -- [group] = { kind = 'gun'|'ambush', ... } units a flight left behind
	jams = {},          -- [jammer group] = { zone, side, own, ended, jammed = { [unitName] = true } }
	ownJammers = {},    -- [group] = true for jammers Claude launched
	counter = 0,
}
X.ops = O

local function now() return timer.getAbsTime() end

local function nextName(kind)
	O.counter = O.counter + 1
	return string.format('FAI-RED-%s-%d-%d', kind, math.floor(now()) % 100000, O.counter)
end

local function priceOf(key)
	if key == nil then return 0 end
	return X.shopPrice(key)
end

local function dist2(a, b)
	local dx, dz = a.x - b.x, (a.z or a.y) - (b.z or b.y)
	return math.sqrt(dx * dx + dz * dz)
end

local function templateExists(name)
	return _DATABASE and _DATABASE.Templates and _DATABASE.Templates.Groups[name] ~= nil
end

local function firstTemplate(list)
	for _, name in ipairs(list or {}) do
		if templateExists(name) then return name end
	end
	return nil
end

local function groupAlive(name)
	if not name then return false end
	local g = Group.getByName(name)
	return g ~= nil and g:isExist() and g:getSize() > 0
end

local function destroyGroup(name)
	local g = Group.getByName(name)
	if g and g:isExist() then g:destroy() end
end

local function eraAllowed(system)
	return system.eras == nil or Era == nil or system.eras[Era] == true
end

-- A point on land (not water) near center, tried at random within radius.
local function landPoint(center, radius)
	local surface = land.getSurfaceType
	local LAND = land.SurfaceType and land.SurfaceType.LAND or 1
	local ROAD = land.SurfaceType and land.SurfaceType.ROAD or 4
	for i = 1, 30 do
		local r = (i == 1) and 0 or radius * math.sqrt(math.random())
		local a = math.random() * 2 * math.pi
		local p = { x = center.x + r * math.cos(a), y = (center.z or center.y) + r * math.sin(a) }
		local s = surface and surface(p) or LAND
		if s == LAND or s == ROAD then return p end
	end
	return nil
end

-- Point at `fromTarget` metres from target toward origin (both {x, z}).
local function toward(target, origin, fromTarget)
	local d = dist2(target, origin)
	if d < 1 then return { x = target.x, z = target.z } end
	local f = math.min(1, fromTarget / d)
	return { x = target.x + (origin.x - target.x) * f, z = target.z + (origin.z - target.z) * f }
end

local function zoneRadius(z)
	local ok, cz = pcall(CustomZone.getByName, CustomZone, z.zone)
	return ok and cz and tonumber(cz.radius) or 2000
end

local function redZone(name)
	local z = U.bcObj():getZoneByName(name or '')
	if not z or z.side ~= RED or not zoneUsable(z) then return nil end
	return z
end

local function heloOrigin(z)
	return (z.facility == 'airbase' or z.facility == 'farp' or z.facility == 'carrier') and z.isHeloSpawn
end

-- Foothold suspends zones nobody is near ("idle"). Like the BLUE shop, wake the
-- target first: Foothold deletes launchers and jammers aimed at a suspended zone,
-- and a suspended zone has no units to hit.
local function wake(z)
	if not z then return end
	local hold = (GlobalSettings and tonumber(GlobalSettings.idleZoneWakeHoldSec)) or 120
	z._idleWakeUntil = math.max(tonumber(z._idleWakeUntil) or 0, timer.getTime() + hold)
	if z._idleSuspended and type(z.resume) == 'function' then pcall(z.resume, z) end
end

local function awake(z)
	return z ~= nil and not z.suspended and not z._idleRestorePending
end

-- Runs fn(true) once zone z is awake, or fn(false) after waiting 2 minutes.
local function whenAwake(z, fn)
	local tries = 0
	timer.scheduleFunction(function(_, t)
		wake(z)
		if awake(z) then fn(true) return nil end
		tries = tries + 1
		if tries > 24 then fn(false) return nil end
		return t + 5
	end, nil, timer.getTime() + 0.1)
end

local function spawnGround(template, alias, p2)
	local ok, g = pcall(function()
		return SPAWN:NewWithAlias(template, alias)
			:InitValidateAndRepositionGroundUnits(true)
			:SpawnFromVec2({ x = p2.x, y = p2.y })
	end)
	if ok and g then return g:GetName() end
	FAI.warn('ops', 'spawn %s as %s failed: %s', tostring(template), alias, tostring(g))
	return nil
end

---------------------------------------------------------------------------
-- Catalogue of RED ground templates (the mission's own zone upgrade templates)
---------------------------------------------------------------------------

local LONG_RANGE_SAM = { 'sa%-10', 'sa%-5', 'sa%-12', 'sa%-20', 'sa%-23', 's%-300', 's%-400' }

local function categoryOf(name)
	local c = type(classifyUpgradeName) == 'function' and classifyUpgradeName(name) or 'other'
	if c == 'sam' then
		local n = name:lower()
		for _, pat in ipairs(LONG_RANGE_SAM) do
			if n:find(pat) then return 'sam_long' end
		end
	end
	return c
end

function O.deployPrice(category)
	return priceOf(prices.deploy[category] or prices.deploy.other)
end

-- Ground groups only: no statics or ships, no fixed-position or hidden mission
-- groups, no radars, no fire-mission launchers.
local function deployable(name)
	local entry = _DATABASE.Templates.Groups[name]
	if not entry or entry.CategoryID ~= Group.Category.GROUND or X.templateSide(name) ~= RED then return false end
	local n = name:lower()
	if n:find('fixed', 1, true) or n:find('hidden', 1, true) or n:find('ewr', 1, true) then return false end
	for _, s in pairs(ops.fireSystems) do
		for _, t in ipairs(s.templates or {}) do
			if t == name then return false end
		end
	end
	return true
end

function O.catalog()
	if O._catalog then return O._catalog end
	local seen, out = {}, {}
	for _, z in ipairs(U.bcObj().zones or {}) do
		local list = z.upgrades and z.upgrades.red
		for _, name in ipairs(type(list) == 'table' and list or {}) do
			if type(name) == 'string' and not seen[name] and deployable(name) then
				seen[name] = true
				out[#out + 1] = { template = name, category = categoryOf(name) }
			end
		end
	end
	table.sort(out, function(a, b) return a.template < b.template end)
	O._catalog = out
	return out
end

local function catalogEntry(name)
	for _, e in ipairs(O.catalog()) do
		if e.template == name then return e end
	end
	return nil
end

---------------------------------------------------------------------------
-- Persistence of deployed forces (other operations are short-lived)
---------------------------------------------------------------------------

local function opsFile()
	if not FAI.dir then return nil end
	local b = U.bcObj()
	return FAI.dir .. 'ops_' .. U.sanitizeId((env.mission and env.mission.theatre or 'x') .. '_' .. tostring(b.saveFile)) .. '.lua'
end

local saveOps
local function pruneDeployed()
	local kept = {}
	for _, d in ipairs(O.deployed) do
		if groupAlive(d.group) then kept[#kept + 1] = d end
	end
	local removed = #O.deployed - #kept
	O.deployed = kept
	if removed > 0 and saveOps then saveOps() end   -- a destroyed group must not come back after a restart
end

local function pruneTeams()
	for name in pairs(O.teams) do
		if not groupAlive(name) then O.teams[name] = nil end
	end
end

function saveOps()
	local path = opsFile()
	if not path then return end
	local list = {}
	for _, d in ipairs(O.deployed) do
		list[#list + 1] = { zone = d.zone, template = d.template, category = d.category, alias = d.alias }
	end
	FAI.writeDataFile(path, { deployed = list })
end

local function deployIntoZone(z, template, alias)
	local cz = CustomZone:getByName(z.zone)
	if not cz then return nil, 'zone has no trigger zone' end
	local ok, res = pcall(cz.spawnGroup, cz, template, false, RED, nil, alias)
	if not ok then return nil, tostring(res) end
	if type(res) ~= 'table' or not res.name then return nil, 'no free ground in zone' end
	return res.name
end

local function restoreDeployed()
	local path = opsFile()
	local data = path and FAI.loadDataFile(path)
	if type(data) ~= 'table' then return end
	local restored = 0
	for _, d in ipairs(data.deployed or {}) do
		local z = redZone(d.zone)
		if z and templateExists(d.template) and d.alias then
			local name = deployIntoZone(z, d.template, d.alias)
			if name then
				O.deployed[#O.deployed + 1] = { zone = d.zone, template = d.template, category = d.category,
					alias = d.alias, group = name, at = now() }
				restored = restored + 1
			end
		end
	end
	saveOps()
	if restored > 0 then FAI.log('ops', 'restored %d deployed RED groups', restored) end
end

---------------------------------------------------------------------------
-- Wave 1
---------------------------------------------------------------------------

local function redOnly(side) if side ~= RED then return 'RED only' end end

function O.deployForces(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local z = redZone(order.zone)
	if not z then return false, 'zone must be a RED zone' end
	local entry = catalogEntry(order.template)
	if not entry then return false, 'unknown template (see operations.deployCatalog)' end
	pruneDeployed()
	local inZone = 0
	for _, d in ipairs(O.deployed) do if d.zone == z.zone then inZone = inZone + 1 end end
	if inZone >= ops.deployMaxPerZone then return false, string.format('%s already has %d deployed groups', z.zone, inZone) end
	if #O.deployed >= ops.deployMaxTotal then return false, 'deployed group limit reached' end
	local price = O.deployPrice(entry.category)
	local short = X.needCredits(side, price); if short then return false, short end
	local alias = nextName('DEP')
	local name, err = deployIntoZone(z, entry.template, alias)
	if not name then return false, 'spawn failed: ' .. tostring(err) end
	O.deployed[#O.deployed + 1] = { zone = z.zone, template = entry.template, category = entry.category,
		alias = alias, group = name, at = now() }
	saveOps()
	X.charge(side, price, string.format('deploy %s at %s', entry.template, z.zone))
	return true, string.format('%s (%s) deployed at %s as %s (cost %d)', entry.template, entry.category, z.zone, name, price)
end

local function upgradePools(z)
	local b = U.bcObj()
	if type(b.getRedZoneUpgradeDirectorInputs) ~= 'function' then return {} end
	local ok, _, pools = pcall(b.getRedZoneUpgradeDirectorInputs, b, z)
	return ok and type(pools) == 'table' and pools or {}
end

function O.upgradeZone(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local z = redZone(order.zone)
	if not z then return false, 'zone must be a RED zone' end
	local b = U.bcObj()
	local okC, choices = pcall(b._redZoneUpgradeChoices, b, false)
	local eligible = false
	for _, c in ipairs(okC and choices or {}) do
		if c.zone == z then eligible = true break end
	end
	if not eligible then return false, z.zone .. ' cannot take another upgrade (slot limit or custom SAM slots)' end
	local category
	for cat, list in pairs(upgradePools(z)) do
		for _, name in ipairs(type(list) == 'table' and list or {}) do
			if name == order.template then category = cat break end
		end
		if category then break end
	end
	if not category then return false, order.zone .. ' does not take template ' .. tostring(order.template) .. ' (see operations.upgradeSlots)' end
	if category == 'sam' then category = categoryOf(order.template) end
	local price = O.deployPrice(category)
	local short = X.needCredits(side, price); if short then return false, short end
	if not z:addExtraSlot(order.template) then return false, z.zone .. ' has no free upgrade slot' end
	if type(z.updateLabel) == 'function' then pcall(z.updateLabel, z) end
	local ok, err = pcall(z.upgrade, z, true)
	if not ok then FAI.warn('ops', 'upgrade of %s failed: %s', z.zone, tostring(err)) end
	X.charge(side, price, string.format('upgrade %s with %s', z.zone, order.template))
	local text = (L10N and L10N.Format) and L10N:Format('WAREHOUSE_RED_REINFORCED', z.zone) or (z.zone .. ' reinforced')
	trigger.action.outTextForCoalition(RED, text, 10)
	trigger.action.outTextForCoalition(BLUE, text, 10)
	return true, string.format('%s gets %s (%s, cost %d)', z.zone, order.template, category, price)
end

local function fireSystem(name)
	local s = ops.fireSystems[name]
	if not s or not eraAllowed(s) then return nil, nil end
	return s, firstTemplate(s.templates)
end

function O.fireMission(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local system, template = fireSystem(order.system)
	if not system then return false, 'unknown or unavailable system ' .. tostring(order.system) end
	if not template then return false, 'no launcher template for ' .. order.system .. ' in this mission' end
	local origin = redZone(order.origin)
	if not origin then return false, 'origin must be a RED zone' end
	local b = U.bcObj()
	local target = b:getZoneByName(order.targetZone or '')
	if not target or not target.active or target.isHidden then return false, 'unknown target zone' end
	if target.side == RED or target.side == 0 then return false, 'target must be an enemy zone' end
	if target.suspended and not target._idleSuspended then return false, 'target zone is dormant' end
	local op, tp = zonePoint(origin), zonePoint(target)
	if not (op and tp) then return false, 'zone position unknown' end
	local km = dist2(op, tp) / 1000
	if km > system.rangeKm then return false, string.format('%s is %d km away, %s reaches %d km', target.zone, round(km), order.system, system.rangeKm) end
	if km < (system.minKm or 0) then return false, string.format('%s is only %d km away, %s needs at least %d km', target.zone, round(km), order.system, system.minKm) end
	local readyAt = O.fireReadyAt[order.system] or 0
	if now() < readyAt then return false, string.format('%s reloading, ready in %d min', order.system, math.ceil((readyAt - now()) / 60)) end
	local price = priceOf(system.price)
	local short = X.needCredits(side, price); if short then return false, short end
	local p = landPoint(op, math.min(zoneRadius(origin), 3000))
	if not p then return false, 'no firing position on land in ' .. origin.zone end
	local name = spawnGround(template, nextName('FIRE'), p)
	if not name then return false, 'battery could not be set up' end
	O.fireReadyAt[order.system] = now() + (system.cooldownSec or 1800)
	O.batteries[name] = { system = order.system, origin = origin.zone, target = target.zone, at = now() }
	X.charge(side, price, string.format('%s fire mission %s -> %s', order.system, origin.zone, target.zone))
	wake(target)
	timer.scheduleFunction(function()
		local function report(result)
			X.event('red', 'fire_mission', { battery = name, system = order.system, target = target.zone, result = result })
			X.eventPending.red = true
		end
		if not groupAlive(name) then report('battery destroyed before firing') return nil end
		whenAwake(target, function(isAwake)
			if not groupAlive(name) then report('battery destroyed before firing') return end
			if not isAwake then
				X.refund(side, price, order.system .. ': target zone did not wake up')
				report('not fired: target zone did not wake up (refunded)')
				return
			end
			local ok, err = pcall(b.fireAtZone, b, target.zone, name, true, system.salvo or 1)
			if ok and not err then
				report('fired')
			else
				X.refund(side, price, order.system .. ' did not fire: ' .. tostring(err))
				report('not fired: ' .. tostring(err) .. ' (refunded)')
			end
		end)
		return nil
	end, nil, timer.getTime() + ops.fireSetupSec)
	timer.scheduleFunction(function()
		destroyGroup(name)
		O.batteries[name] = nil
	end, nil, timer.getTime() + ops.fireSetupSec + (system.lifetimeSec or 1200))
	return true, string.format('%s battery %s setting up at %s, fires at %s in %d s (cost %d)',
		order.system, name, origin.zone, target.zone, ops.fireSetupSec, price)
end

-- Claude's AWACS station wins over Foothold's automatic front-line placement.
if type(setAwacsRacetrack) == 'function' then
	local original = setAwacsRacetrack
	setAwacsRacetrack = function(side, coord, heading, leg, zoneName)
		local st = O.awacsStation
		if st then
			local z = U.bcObj():getZoneByName(st.zone)
			if not (z and z.side == RED) then O.awacsStation, st = nil, nil end   -- zone lost: Foothold places it again
		end
		if side == RED and st and X.controls(RED) and not O.settingAwacs then
			return original(side, st.coord, st.heading, st.leg, st.zone)
		end
		return original(side, coord, heading, leg, zoneName)
	end
end

function O.moveAwacs(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	if type(setAwacsRacetrack) ~= 'function' or not (_awacsFG and _awacsFG[RED]) then
		return false, 'no RED AWACS in this mission'
	end
	local fg = _awacsFG[RED]
	if not (fg.isExist and fg:isExist()) then return false, 'RED AWACS is not airborne' end
	local z = redZone(order.zone)
	if not z then return false, 'AWACS orbits over RED zones only' end
	local readyAt = O.awacsReadyAt or 0
	if now() < readyAt then return false, string.format('AWACS can move again in %d min', math.ceil((readyAt - now()) / 60)) end
	local price = priceOf(prices.awacs)
	local short = X.needCredits(side, price); if short then return false, short end
	local p = zonePoint(z)
	local coord = (COORDINATE and COORDINATE.New) and COORDINATE:New(p.x, 0, p.z) or { x = p.x, z = p.z }
	local heading = tonumber(order.headingDeg) or 0
	local leg = math.max(0, math.min(60, tonumber(order.legNm) or 20))
	O.awacsStation = { coord = coord, heading = heading, leg = leg, zone = z.zone }
	O.settingAwacs = true
	local ok, err = pcall(setAwacsRacetrack, RED, coord, heading, leg, z.zone)
	O.settingAwacs = false
	if not ok then return false, 'AWACS re-task failed: ' .. tostring(err) end
	O.awacsReadyAt = now() + 600
	X.charge(side, price, 'AWACS to ' .. z.zone)
	return true, string.format('AWACS orbit over %s, heading %d, leg %d nm', z.zone, heading, leg)
end

function O.supplyAirlift(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local z = redZone(order.zone)
	if not z then return false, 'zone must be a RED zone' end
	if type(z._addExpeditedRegularSupplyStock) ~= 'function' then return false, 'supply stock not available in this Foothold version' end
	if type(z._regularSupplyHasRouteForSide) == 'function' and not z:_regularSupplyHasRouteForSide(RED) then
		return false, z.zone .. ' has no supply route to use the stock'
	end
	local price = priceOf(prices.airlift)
	local short = X.needCredits(side, price); if short then return false, short end
	if not z:_addExpeditedRegularSupplyStock(ops.airliftUnits, now()) then return false, z.zone .. ' cannot store more supply' end
	X.charge(side, price, 'supply airlift to ' .. z.zone)
	return true, string.format('%d supply units added at %s (cost %d)', ops.airliftUnits, z.zone, price)
end

---------------------------------------------------------------------------
-- Flights: helicopters (raid, assault, ambush) and jammers
---------------------------------------------------------------------------

local function activeFlights()
	local n = 0
	for _ in pairs(O.flights) do n = n + 1 end
	return n
end

local function waypoint(p, altM, speed, tasks, altType)
	return {
		x = p.x, y = p.z or p.y, alt = altM, alt_type = altType or 'RADIO',
		type = 'Turning Point', action = 'Turning Point',
		speed = speed, speed_locked = true, ETA = 0, ETA_locked = false,
		task = { id = 'ComboTask', params = { tasks = tasks or {} } },
	}
end

local function landTask(p, durationSec)
	return { id = 'Land', params = { point = { x = p.x, y = p.z or p.y },
		durationFlag = durationSec ~= nil, duration = durationSec } }
end

-- Spawns an aircraft group from an ME template, airborne at `start` ({x, z}).
local function spawnFlight(template, name, start, altM, speed, points, maxUnits)
	local entry = _DATABASE.Templates.Groups[template]
	if not entry then return nil, 'template ' .. tostring(template) .. ' missing' end
	local tpl = FAI.deepCopy(entry.Template)
	local first = points[2] or points[1]
	local hdg = math.atan2(first.y - start.z, first.x - start.x)
	local units = {}
	for i, src in ipairs(tpl.units or {}) do
		if i > (maxUnits or 2) then break end
		local u = FAI.deepCopy(src)
		u.name = name .. '-' .. i
		u.unitId = nil
		u.parking, u.parking_id, u.parking_landing, u.parking_landing_id = nil, nil, nil, nil
		u.x = start.x - (i - 1) * 60 * math.cos(hdg)
		u.y = start.z - (i - 1) * 60 * math.sin(hdg)
		u.alt, u.alt_type = altM, 'RADIO'
		u.heading, u.psi, u.speed = hdg, -hdg, speed
		units[i] = u
	end
	if #units == 0 then return nil, 'template has no units' end
	tpl.name, tpl.groupId = name, nil
	tpl.units = units
	tpl.route = { points = points }
	tpl.lateActivation, tpl.uncontrolled, tpl.hidden = false, false, false
	local ok, g = pcall(coalition.addGroup, entry.CountryID, entry.CategoryID, tpl)
	if not ok or not g then return nil, 'spawn failed: ' .. tostring(g) end
	return name
end

local function heloRoute(origin, lz, holdSec)
	local h = ops.helo
	local speed = h.speedKmh / 3.6
	return {
		waypoint(origin, h.altitudeM, speed),
		waypoint(lz, h.altitudeM, speed, { landTask(lz, holdSec) }),
		waypoint(origin, h.altitudeM, speed, { landTask(origin, 3600) }),
	}
end

local function startHeloFlight(kind, originZone, lz, extra)
	if activeFlights() >= ops.maxActiveFlights then return nil, 'too many RED operations in progress' end
	local template = firstTemplate(ops.transportTemplates)
	if not template then return nil, 'no RED transport helicopter template in this mission' end
	local op = zonePoint(originZone)
	local km = dist2(op, lz) / 1000
	if km > ops.helo.cruiseMaxKm then
		return nil, string.format('landing site is %d km from %s, helicopters reach %d km', round(km), originZone.zone, ops.helo.cruiseMaxKm)
	end
	local name = nextName(kind:upper())
	local hold = extra.holdSec or 90
	local spawned, err = spawnFlight(template, name, op, ops.helo.altitudeM, ops.helo.speedKmh / 3.6,
		heloRoute(op, lz, hold), 1)
	if not spawned then return nil, err end
	-- Out, hold, back, plus margin for take-off, landing and detours.
	local timeout = math.floor(2 * km * 1000 / (ops.helo.speedKmh / 3.6) + hold + 900)
	local f = { kind = kind, group = name, origin = originZone.zone, lz = lz, home = { x = op.x, z = op.z },
		phase = 'outbound', at = now(), timeoutSec = math.max(timeout, ops.helo.timeoutSec) }
	for k, v in pairs(extra) do f[k] = v end
	O.flights[name] = f
	return f
end

local function leadUnit(name)
	local g = Group.getByName(name)
	if not (g and g:isExist()) then return nil end
	for _, u in ipairs(g:getUnits() or {}) do
		if u and u:isExist() then return u end
	end
	return nil
end

local function endFlight(f, outcome)
	O.flights[f.group] = nil
	f.outcome = outcome
	X.event('red', 'operation_ended', { operation = f.kind, group = f.group, target = f.target, outcome = outcome })
	X.eventPending.red = true
end

local function onLanded(f, lead)
	local p = lead:getPoint()
	local behind = { x = p.x - 40, y = p.z - 40 }
	if f.kind == 'heli_raid' then
		local gun = spawnGround(f.gunTemplate, f.group .. '-GUN', behind)
		if not gun then return 'gun could not be unloaded' end
		O.teams[gun] = { kind = 'gun', target = f.target, at = now() }
		local b = U.bcObj()
		local z = b:getZoneByName(f.target)
		timer.scheduleFunction(function()
			if not groupAlive(gun) or not z then return nil end
			whenAwake(z, function(isAwake)
				if not groupAlive(gun) then return end
				local ok, err = isAwake, 'target zone did not wake up'
				if isAwake then ok, err = pcall(b.fireAtZone, b, f.target, gun, true, 4, math.max(1, math.floor(ops.raidRounds / 4))) end
				local fired = ok and not err
				if not fired then X.refund(RED, f.price, 'heli raid gun did not fire: ' .. tostring(err)) end
				X.event('red', 'heli_raid', { gun = gun, target = f.target,
					result = fired and 'firing' or ('not firing: ' .. tostring(err) .. ' (refunded)') })
			end)
			return nil
		end, nil, timer.getTime() + 30)
		timer.scheduleFunction(function() destroyGroup(gun) O.teams[gun] = nil end, nil,
			timer.getTime() + ops.raidGunLifetimeSec)
		return 'gun unloaded'
	elseif f.kind == 'ambush' then
		local team = spawnGround(f.teamTemplate, f.group .. '-TEAM', behind)
		if not team then return 'team could not be unloaded' end
		O.teams[team] = { kind = 'ambush', team = f.team, at = now() }
		timer.scheduleFunction(function() destroyGroup(team) O.teams[team] = nil end, nil,
			timer.getTime() + ops.ambushLifetimeSec)
		return 'team in position'
	elseif f.kind == 'air_assault' then
		local z = U.bcObj():getZoneByName(f.target)
		if not z or z.side ~= 0 then return 'zone is no longer neutral' end
		local g = Group.getByName(f.group)
		local ok, accepted, status = pcall(z.startPendingCaptureFromAircraft, z, RED, g)
		if not ok then return 'capture error: ' .. tostring(accepted) end
		return accepted and ('troops capturing ' .. f.target) or ('capture refused: ' .. tostring(status))
	end
	return 'landed'
end

local function flightTick()
	for name, f in pairs(O.flights) do
		local lead = leadUnit(name)
		if not lead then
			endFlight(f, f.phase == 'outbound' and 'shot down before landing' or 'lost')
		elseif now() - f.at > (f.timeoutSec or ops.helo.timeoutSec) then
			destroyGroup(name)
			endFlight(f, 'timed out')
		elseif f.kind ~= 'jam' then
			local p = lead:getPoint()
			local airborne = lead:inAir()
			if f.phase == 'outbound' and not airborne and dist2(p, f.home) < 3000 and now() - f.at > 180 then
				-- landed back home without ever landing at the site
				destroyGroup(name)
				X.refund(RED, f.price, f.kind .. ' could not land at its landing site')
				endFlight(f, 'could not land at the landing site (refunded)')
			elseif f.phase == 'outbound' and not airborne and dist2(p, { x = f.lz.x, z = f.lz.z }) < 1500 then
				local ok, result = pcall(onLanded, f, lead)
				f.result = ok and result or ('error: ' .. tostring(result))
				f.phase = 'returning'
				X.event('red', f.kind, { group = name, target = f.target, result = f.result })
				X.eventPending.red = true
			elseif f.phase == 'returning' and not airborne and dist2(p, f.home) < 3000 then
				destroyGroup(name)
				endFlight(f, 'returned (' .. tostring(f.result) .. ')')
			end
		elseif f.phase == 'returning' and dist2(lead:getPoint(), f.home) < 8000 then
			destroyGroup(name)
			endFlight(f, 'returned')
		end
	end
end

local function enemyZone(name)
	local z = U.bcObj():getZoneByName(name or '')
	if not z or not z.active or z.isHidden or z.side == RED or z.side == 0 then return nil end
	if z.suspended and not z._idleSuspended then return nil end
	return z
end

-- Origin helper: the given RED helicopter zone.
local function heloZone(name)
	local z = redZone(name)
	if not z then return nil, 'origin must be a RED zone' end
	if not heloOrigin(z) then return nil, z.zone .. ' cannot launch helicopters' end
	return z
end

function O.heliRaid(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local origin, err = heloZone(order.origin)
	if not origin then return false, err end
	local target = enemyZone(order.targetZone)
	if not target then return false, 'target must be an active enemy zone' end
	local gunName = order.gun or 'akatsia'
	local gun = ops.raidGuns[gunName]
	if not gun or not templateExists(gun.template) then return false, 'unknown gun ' .. tostring(order.gun) end
	local price = priceOf(prices.heli_raid)
	local short = X.needCredits(side, price); if short then return false, short end
	local tp, op = zonePoint(target), zonePoint(origin)
	local site = toward(tp, op, gun.rangeKm * 1000 * 0.8)
	local lz = landPoint({ x = site.x, z = site.z }, 800)
	if not lz then return false, 'no landing site on land within range of ' .. target.zone end
	local f, ferr = startHeloFlight('heli_raid', origin, { x = lz.x, z = lz.y },
		{ target = target.zone, gunTemplate = gun.template, gun = gunName })
	if not f then return false, ferr end
	f.price = price
	X.charge(side, price, string.format('heli raid %s -> %s', origin.zone, target.zone))
	return true, string.format('%s carries a %s from %s to %d km from %s (cost %d)', f.group, gunName, origin.zone,
		round(gun.rangeKm * 0.8), target.zone, price)
end

function O.airAssault(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local origin, err = heloZone(order.origin)
	if not origin then return false, err end
	local b = U.bcObj()
	local target = b:getZoneByName(order.targetZone or '')
	if not target or not target.active or target.isHidden then return false, 'unknown target zone' end
	if target.side ~= 0 then return false, 'air assault needs a neutral zone' end
	local price = priceOf(prices.air_assault)
	local short = X.needCredits(side, price); if short then return false, short end
	local lz = landPoint(zonePoint(target), math.min(zoneRadius(target) * 0.5, 600))
	if not lz then return false, 'no landing site in ' .. target.zone end
	local f, ferr = startHeloFlight('air_assault', origin, { x = lz.x, z = lz.y }, { target = target.zone, holdSec = 60 })
	if not f then return false, ferr end
	f.price = price
	X.charge(side, price, string.format('air assault %s -> %s', origin.zone, target.zone))
	return true, string.format('%s flies troops from %s to capture %s (cost %d)', f.group, origin.zone, target.zone, price)
end

function O.ambush(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local origin, err = heloZone(order.origin)
	if not origin then return false, err end
	local teamTemplate = ops.ambushTeams[order.team or 'manpads']
	if not teamTemplate or not templateExists(teamTemplate) then return false, 'unknown team ' .. tostring(order.team) end
	local b = U.bcObj()
	local from, to = b:getZoneByName(order.fromZone or ''), b:getZoneByName(order.towardZone or '')
	if not (from and to and from.active and to.active) then return false, 'fromZone and towardZone must be known zones' end
	pruneTeams()
	local active = 0
	for _, t in pairs(O.teams) do if t.kind == 'ambush' then active = active + 1 end end
	for _, f in pairs(O.flights) do if f.kind == 'ambush' then active = active + 1 end end
	if active >= ops.ambushMaxActive then return false, 'ambush team limit reached' end
	local price = priceOf(prices.ambush)
	local short = X.needCredits(side, price); if short then return false, short end
	local frac = math.max(0.1, math.min(0.9, tonumber(order.fraction) or 0.5))
	local fp, tp = zonePoint(from), zonePoint(to)
	local site = { x = fp.x + (tp.x - fp.x) * frac, z = fp.z + (tp.z - fp.z) * frac }
	local lz = landPoint(site, 1500)
	if not lz then return false, 'no landing site on land there' end
	local f, ferr = startHeloFlight('ambush', origin, { x = lz.x, z = lz.y },
		{ target = string.format('%s-%s', from.zone, to.zone), teamTemplate = teamTemplate, team = order.team or 'manpads', holdSec = 60 })
	if not f then return false, ferr end
	f.price = price
	X.charge(side, price, string.format('ambush team between %s and %s', from.zone, to.zone))
	return true, string.format('%s drops a %s team %d%% of the way from %s to %s (cost %d)', f.group, order.team or 'manpads',
		round(frac * 100), from.zone, to.zone, price)
end

---------------------------------------------------------------------------
-- Jamming (fair for both sides)
---------------------------------------------------------------------------

local jcfg = ops.jamming

local function setJammed(unit, jammed)
	local c = unit:getController()
	if not c then return end
	if jammed then
		c:setOption(0, 4)   -- ROE weapon hold
		c:setOption(9, 1)   -- alarm state green
	else
		c:setOption(0, 2)
		c:setOption(9, 2)
	end
end

local function isRadar(unit)
	local ok1, sr = pcall(unit.hasAttribute, unit, 'SAM SR')
	local ok2, tr = pcall(unit.hasAttribute, unit, 'SAM TR')
	return (ok1 and sr) or (ok2 and tr)
end

-- Jamming range against one radar: long-range systems are jammed from beyond
-- the distance at which they could shoot the jammer down.
function O.jamRangeNm(unit)
	local okT, typeName = pcall(unit.getTypeName, unit)
	local t = okT and tostring(typeName):lower() or ''
	for _, rule in ipairs(jcfg.rangeNmByRadar or {}) do
		if t:find(rule[1]) then return rule[2] end
	end
	return jcfg.rangeNm
end

-- Sends a jammer Claude launched to orbit standoffNm from the zone, on its own side.
local function routeJammer(gr, zn)
	local lead = gr:getUnit(1)
	local zp = zonePoint(zn)
	if not (lead and zp) then return end
	local p = lead:getPoint()
	local orbit = toward(zp, p, jcfg.standoffNm * NM)
	local alt = jcfg.altitudeFt * 0.3048
	local speed = 200
	local leg = toward(orbit, p, 15 * NM)
	gr:getController():setTask({ id = 'Mission', params = { airborne = true, route = { points = {
		waypoint(p, alt, speed, nil, 'BARO'),
		waypoint(orbit, alt, speed, { { id = 'Orbit', params = { pattern = AI.Task.OrbitPattern.RACE_TRACK,
			point = { x = orbit.x, y = orbit.z }, point2 = { x = leg.x, y = leg.z }, speed = speed, altitude = alt } } }, 'BARO'),
	} } } })
end

local function jamTick(groupname, zonename, state)
	if O.jams[groupname] ~= state then
		-- a newer jamRadarsAtZone call for this group took over; release what this one jammed
		for name in pairs(state.jammed) do
			local u = Unit and Unit.getByName and Unit.getByName(name)
			if u and u:isExist() then setJammed(u, false) end
		end
		return false
	end
	local b = U.bcObj()
	local gr = Group.getByName(groupname)
	local zn = b:getZoneByName(zonename)
	local active = not state.ended and gr ~= nil and gr:isExist() and gr:getSize() > 0 and zn ~= nil and zn.side ~= state.side
	if active and Utils and Utils.isGroupActive then active = Utils.isGroupActive(gr) end
	if active and state.own then wake(zn) end   -- keep the target's radars spawned while Claude's jammer works
	local jammers = {}
	if active then
		for _, u in ipairs(gr:getUnits() or {}) do
			if u:isExist() then jammers[#jammers + 1] = u:getPoint() end
		end
	end
	local seen = {}
	for _, v in pairs(zn and zn.built or {}) do
		local g = Group.getByName(v)
		for _, u in ipairs(g and g:getUnits() or {}) do
			if u:isExist() and isRadar(u) then
				local name = u:getName()
				local range = O.jamRangeNm(u) * NM
				local inRange = false
				for _, jp in ipairs(jammers) do
					if dist2(jp, u:getPoint()) <= range then inRange = true break end
				end
				seen[name] = true
				if inRange then
					setJammed(u, true)
					state.jammed[name] = true
				elseif state.jammed[name] then
					setJammed(u, false)
					state.jammed[name] = nil
				end
			end
		end
	end
	for name in pairs(state.jammed) do
		if not seen[name] then state.jammed[name] = nil end
	end
	if not active then
		if O.jams[groupname] == state then O.jams[groupname] = nil end
		return false
	end
	return true
end

-- Replaces Foothold's jamRadarsAtZone for both sides: same checks and messages,
-- but only radars within range of a live jammer are jammed. Jammers Claude
-- launched are routed to a standoff orbit; others (BLUE's shop jammer) keep their
-- Mission Editor route and lifetime.
U.wrap(BattleCommander, 'BattleCommander', 'jamRadarsAtZone', function(original, self, groupname, zonename)
	local gr = Group.getByName(groupname)
	local zn = self:getZoneByName(zonename)
	if not zn then return 'Zone not found' end
	if zn.suspended then
		if gr and gr:isExist() then gr:destroy() end
		return
	end
	if not gr then return 'EW group dead' end
	if zn.side == gr:getCoalition() then return 'Can not jam friendly zone' end
	local own = O.ownJammers[groupname] == true
	if own and jcfg.routeJammers ~= false then pcall(routeJammer, gr, zn) end
	local state = { zone = zonename, side = gr:getCoalition(), jammed = {}, own = own }
	O.jams[groupname] = state
	timer.scheduleFunction(function(_, t)
		local ok, again = pcall(jamTick, groupname, zonename, state)
		if not ok then FAI.warn('ops', 'jamming tick failed: %s', tostring(again)) return nil end
		return again and t + 10 or nil
	end, nil, timer.getTime() + 10)
end)

function O.jammerTemplate()
	return firstTemplate(jcfg.templates and jcfg.templates.red)
end

local function stopJamming(name)
	local state = O.jams[name]
	if state then state.ended = true end   -- the next tick restores every radar it jammed
end

function O.jam(side, order)
	local bad = redOnly(side); if bad then return false, bad end
	local template = O.jammerTemplate()
	if not template then
		return false, 'no RED jammer aircraft in this mission (add a late-activated RED group named ewAircraftRed)'
	end
	for _, f in pairs(O.flights) do
		if f.kind == 'jam' then return false, 'a jammer is already flying (' .. tostring(f.target) .. ')' end
	end
	local target = enemyZone(order.targetZone)
	if not target then return false, 'target must be an active enemy zone' end
	local b = U.bcObj()
	local tp = zonePoint(target)
	local origin, best
	for _, z in ipairs(b.zones or {}) do
		if z.side == RED and zoneUsable(z) and b:_zoneSupportsPlaneSpawn(z) then
			local d = dist2(zonePoint(z), tp)
			if not best or d < best then origin, best = z, d end
		end
	end
	if not origin then return false, 'no RED airfield to launch a jammer from' end
	local price = priceOf(prices.jam)
	local short = X.needCredits(side, price); if short then return false, short end
	if activeFlights() >= ops.maxActiveFlights then return false, 'too many RED operations in progress' end
	local op = zonePoint(origin)
	local alt = jcfg.altitudeFt * 0.3048
	local name = nextName('JAM')
	local spawned, err = spawnFlight(template, name, op, alt, 200, { waypoint(op, alt, 200, nil, 'BARO'),
		waypoint(toward(tp, op, jcfg.standoffNm * NM), alt, 200, nil, 'BARO') }, 1)
	if not spawned then return false, err end
	O.ownJammers[name] = true
	local f = { kind = 'jam', group = name, origin = origin.zone, target = target.zone, price = price,
		home = { x = op.x, z = op.z }, phase = 'transit', at = now(), timeoutSec = jcfg.durationSec + 2400 }
	O.flights[name] = f
	X.charge(side, price, 'jammer over ' .. target.zone)
	local function fail(why)
		destroyGroup(name)
		X.refund(side, price, 'jammer: ' .. why)
		if O.flights[name] == f then endFlight(f, why .. ' (refunded)') end
	end
	-- The jamming starts once the target zone is awake (its radars exist).
	whenAwake(target, function(isAwake)
		if O.flights[name] ~= f then return end
		if not isAwake then fail('target zone did not wake up') return end
		local jamErr = b:jamRadarsAtZone(name, target.zone)
		if jamErr or not groupAlive(name) or not O.jams[name] then
			fail('jamming refused: ' .. tostring(jamErr or 'jammer removed'))
			return
		end
		f.phase = 'jamming'
	end)
	timer.scheduleFunction(function()
		local g = Group.getByName(name)
		if O.flights[name] ~= f or not (g and g:isExist()) then return nil end
		f.phase = 'returning'
		stopJamming(name)
		local lead = leadUnit(name)
		if lead then
			g:getController():setTask({ id = 'Mission', params = { airborne = true, route = { points = {
				waypoint(lead:getPoint(), alt, 200, nil, 'BARO'), waypoint(f.home, alt, 200, nil, 'BARO') } } } })
		end
		return nil
	end, nil, timer.getTime() + jcfg.durationSec)
	return true, string.format('%s from %s jams %s SAM radars in range for %d min (cost %d)', name, origin.zone,
		target.zone, round(jcfg.durationSec / 60), price)
end

---------------------------------------------------------------------------
-- Registration, snapshot and timers
---------------------------------------------------------------------------

local E = X.executors
E.deploy_forces = O.deployForces
E.upgrade_zone = O.upgradeZone
E.fire_mission = O.fireMission
E.move_awacs = O.moveAwacs
E.supply_airlift = O.supplyAirlift
E.heli_raid = O.heliRaid
E.air_assault = O.airAssault
E.ambush = O.ambush
E.jam = O.jam

local function operationsRow(b)
	pruneDeployed()
	pruneTeams()
	local catPrices = {}
	for cat in pairs(prices.deploy) do catPrices[cat] = O.deployPrice(cat) end
	local catalog = {}
	for _, e in ipairs(O.catalog()) do catalog[#catalog + 1] = { template = e.template, category = e.category } end
	local deployed = {}
	for _, d in ipairs(O.deployed) do
		deployed[#deployed + 1] = { zone = d.zone, template = d.template, category = d.category, group = d.group }
	end
	local slots = {}
	local okC, choices = pcall(b._redZoneUpgradeChoices, b, false)
	for _, c in ipairs(okC and choices or {}) do
		local pools = {}
		local slotPrices = {}
		for cat, list in pairs(upgradePools(c.zone)) do
			if type(list) == 'table' and #list > 0 then
				pools[cat] = FAI.json.array(list)
				for _, name in ipairs(list) do
					slotPrices[name] = O.deployPrice(cat == 'sam' and categoryOf(name) or cat)
				end
			end
		end
		if next(pools) then slots[#slots + 1] = { zone = c.zone.zone, templates = pools, prices = slotPrices } end
	end
	local systems = {}
	for name, s in pairs(ops.fireSystems) do
		if eraAllowed(s) and firstTemplate(s.templates) then
			systems[#systems + 1] = { system = name, rangeKm = s.rangeKm, salvo = s.salvo, price = priceOf(s.price),
				readyInMin = math.max(0, math.ceil(((O.fireReadyAt[name] or 0) - now()) / 60)) }
		end
	end
	table.sort(systems, function(a, c) return a.system < c.system end)
	local heloOrigins = {}
	for _, z in ipairs(b.zones or {}) do
		if z.side == RED and zoneUsable(z) and heloOrigin(z) then heloOrigins[#heloOrigins + 1] = z.zone end
	end
	local flights = {}
	for name, f in pairs(O.flights) do
		flights[#flights + 1] = { group = name, operation = f.kind, origin = f.origin, target = f.target,
			phase = f.phase, minutes = round((now() - f.at) / 60) }
	end
	local teams = {}
	for name, t in pairs(O.teams) do
		teams[#teams + 1] = { group = name, kind = t.kind, target = t.target, minutes = round((now() - t.at) / 60) }
	end
	local batteries = {}
	for name, bt in pairs(O.batteries) do
		if groupAlive(name) then
			batteries[#batteries + 1] = { group = name, system = bt.system, origin = bt.origin, target = bt.target }
		end
	end
	local guns = {}
	for name, g in pairs(ops.raidGuns) do
		if templateExists(g.template) then guns[#guns + 1] = { gun = name, rangeKm = g.rangeKm } end
	end
	local teamsAvail = {}
	for name, tpl in pairs(ops.ambushTeams) do
		if templateExists(tpl) then teamsAvail[#teamsAvail + 1] = name end
	end
	table.sort(teamsAvail)
	local jammer = O.jammerTemplate()
	local longRange = jcfg.rangeNm
	for _, r in ipairs(jcfg.rangeNmByRadar or {}) do longRange = math.max(longRange, r[2]) end
	return {
		prices = { deploy = catPrices, airlift = priceOf(prices.airlift), heli_raid = priceOf(prices.heli_raid),
			air_assault = priceOf(prices.air_assault), ambush = priceOf(prices.ambush), jam = priceOf(prices.jam),
			awacs = priceOf(prices.awacs) },
		deployCatalog = FAI.json.array(catalog),
		deployed = FAI.json.array(deployed),
		deployLimits = { perZone = ops.deployMaxPerZone, total = ops.deployMaxTotal },
		upgradeSlots = FAI.json.array(slots),
		fireSystems = FAI.json.array(systems),
		batteries = FAI.json.array(batteries),
		heloOrigins = FAI.json.array(heloOrigins),
		heloRangeKm = ops.helo.cruiseMaxKm,
		raidGuns = FAI.json.array(guns),
		ambushTeams = FAI.json.array(teamsAvail),
		flights = FAI.json.array(flights),
		groundTeams = FAI.json.array(teams),
		jammer = jammer and { template = jammer, rangeNm = jcfg.rangeNm, longRangeSamRangeNm = longRange,
			minutes = round(jcfg.durationSec / 60) }
			or { unavailable = 'no RED jammer aircraft in this mission' },
		awacs = { station = O.awacsStation and O.awacsStation.zone or nil,
			available = (_awacsFG and _awacsFG[RED] and true) or false },
		airliftUnits = ops.airliftUnits,
		limits = { activeFlights = ops.maxActiveFlights, ambushTeams = ops.ambushMaxActive },
		awacsReadyInMin = math.max(0, math.ceil(((O.awacsReadyAt or 0) - now()) / 60)),
	}
end

X.snapshotExtensions[#X.snapshotExtensions + 1] = function(sideName, payload, b)
	if sideName == 'red' then payload.operations = operationsRow(b) end
end

timer.scheduleFunction(function(_, t)
	local ok, err = pcall(flightTick)
	if not ok then FAI.warn('ops', 'flight tick failed: %s', tostring(err)) end
	return t + 5
end, nil, timer.getTime() + 5)

timer.scheduleFunction(function(_, t)
	local ok, err = pcall(function() pruneDeployed() pruneTeams() end)
	if not ok then FAI.warn('ops', 'prune failed: %s', tostring(err)) end
	return t + 60
end, nil, timer.getTime() + 60)

local okR, errR = pcall(restoreDeployed)
if not okR then FAI.warn('ops', 'restoring deployed groups failed: %s', tostring(errR)) end
FAI.log('ops', 'RED operations ready (jammer: %s)', tostring(O.jammerTemplate() or 'none'))
