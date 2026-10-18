---------------------------------------------------------------------------
-- Foothold AI - wingman
-- F10 "AI Wingman" menu for players. A wingman is a copy of the player's
-- own slot template (same type, default loadout, livery), air-started behind
-- the player and driven with native DCS tasks. Players can also give orders in
-- plain words (F10 map mark or chat "wm <order>"); Claude turns them into the
-- same actions through the sidecar.
---------------------------------------------------------------------------

local FAI = FootholdAI
if not (FAI and FAI.config and FAI.config.enabled) then return end
if not FAI.config.wingman.enabled then
	FAI.log('wingman', 'disabled by config')
	return
end

local W = {
	flights = {},      -- [playerGroupName] = flight
	byWingmanGroup = {}, -- [wingmanGroupName] = playerGroupName
	menus = {},        -- [playerGroupName] = true
	marks = {},        -- [coalition] = { [markId] = { pos = vec3, t = time } }
	spawnCounter = 0,
}
FAI.wingman = W
local cfg = FAI.config.wingman
local NM = 1852

local function msg(groupId, text, seconds)
	trigger.action.outTextForGroup(groupId, text, seconds or 10)
end

local function categoryKey(dcsGroup)
	return dcsGroup:getCategory() == Group.Category.HELICOPTER and 'helicopter' or 'plane'
end

local function playerUnitOf(dcsGroup)
	for _, unit in ipairs(dcsGroup:getUnits() or {}) do
		if unit and unit:isExist() and unit:getPlayerName() then return unit end
	end
	return nil
end

local function headingOf(unit)
	local p = unit:getPosition()
	return math.atan2(p.x.z, p.x.x)
end

local function speedOf(unit)
	local v = unit:getVelocity()
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function distance2D(a, b)
	local dx, dz = a.x - b.x, a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

local function wingmanGroup(flight)
	local g = flight and Group.getByName(flight.groupName)
	if g and g:isExist() and g:getSize() > 0 then return g end
	return nil
end

---------------------------------------------------------------------------
-- Template building
---------------------------------------------------------------------------

local function sourceTemplate(playerUnit)
	local playerType = playerUnit:getTypeName()
	local override = cfg.typeOverride[playerType]
	if override == false then return nil, 'wingmen are disabled for ' .. playerType end
	local db = _DATABASE and _DATABASE.Templates
	if not db then return nil, 'MOOSE database not available' end
	if type(override) == 'table' and override.template then
		local entry = db.Groups[override.template]
		if not entry then return nil, 'override template not found: ' .. override.template end
		return {
			unit = entry.Template.units[1],
			group = entry.Template,
			countryId = entry.CountryID,
			categoryId = entry.CategoryID,
			task = override.task or entry.Template.task,
		}
	end
	local unitEntry = db.Units[playerUnit:getName()]
	if not unitEntry then return nil, 'no ME template for slot ' .. playerUnit:getName() end
	local groupTask = unitEntry.GroupTemplate and unitEntry.GroupTemplate.task
	if type(override) == 'table' and override.task then groupTask = override.task end
	return {
		unit = unitEntry.Template,
		group = unitEntry.GroupTemplate,
		countryId = unitEntry.CountryID,
		categoryId = unitEntry.CategoryID,
		task = groupTask,
	}
end

local function nextCallsign(callsign, index)
	if type(callsign) == 'number' then return callsign + index end
	if type(callsign) ~= 'table' then return callsign end
	local cs = FAI.deepCopy(callsign)
	local element = (tonumber(cs[3]) or 1) + index
	cs[3] = element
	local prefix = type(cs.name) == 'string' and cs.name:match('^(%a+)') or nil
	if prefix then cs.name = prefix .. tostring(cs[2]) .. tostring(element) end
	return cs
end

local function buildGroupData(src, playerUnit, count, groupName, cat)
	local p = playerUnit:getPoint()
	local hdg = headingOf(playerUnit)
	local fx, fz = math.cos(hdg), math.sin(hdg)
	local rx, rz = -fz, fx
	local behind = cfg.spawnBehindMeters[cat]
	local right = cfg.spawnRightMeters[cat]
	local speed = speedOf(playerUnit)
	if cat == 'plane' then
		speed = math.min(math.max(speed, 100), 250)
	else
		speed = math.min(math.max(speed, 20), 70)
	end

	local units = {}
	for i = 1, count do
		local u = FAI.deepCopy(src.unit)
		u.name = groupName .. '-' .. i
		u.unitId = nil
		u.skill = cfg.skill
		u.parking, u.parking_id, u.parking_landing, u.parking_landing_id = nil, nil, nil, nil
		local back = behind * i
		local side = right * i
		u.x = p.x - fx * back + rx * side
		u.y = p.z - fz * back + rz * side
		u.alt = p.y
		u.alt_type = 'BARO'
		u.heading = hdg
		u.psi = -hdg
		u.speed = speed
		u.callsign = nextCallsign(src.unit.callsign, i)
		if type(u.AddPropAircraft) == 'table' and tonumber(u.AddPropAircraft.STN_L16) ~= nil then
			local octal = _DATABASE:GetNextSTN(u.AddPropAircraft.STN_L16, u.name)
			u.AddPropAircraft.STN_L16 = string.format('%05d', octal)
		end
		units[i] = u
	end

	local lead = units[1]
	local ahead = cat == 'plane' and 10000 or 3000
	local function wp(x, y)
		return {
			x = x, y = y, alt = p.y, alt_type = 'BARO',
			type = 'Turning Point', action = 'Turning Point',
			speed = speed, speed_locked = true, ETA = 0, ETA_locked = false,
			task = { id = 'ComboTask', params = { tasks = {} } },
		}
	end

	local task = src.task
	if task == nil or task == 'Nothing' then task = 'CAS' end
	return {
		name = groupName,
		task = task,
		units = units,
		route = { points = { wp(lead.x, lead.y), wp(lead.x + fx * ahead, lead.y + fz * ahead) } },
		uncontrolled = false,
		lateActivation = false,
		hidden = false,
		communication = true,
		frequency = src.group and src.group.frequency or nil,
		modulation = src.group and src.group.modulation or nil,
	}
end

---------------------------------------------------------------------------
-- Tasks
---------------------------------------------------------------------------

local ROE = AI.Option.Air.val.ROE

local function setROE(dcsGroup, value)
	dcsGroup:getController():setOption(AI.Option.Air.id.ROE, value)
end

local function followTask(playerGroup, cat, escort)
	local o = cfg.followOffset[cat]
	if escort then
		return {
			id = 'Escort',
			params = {
				groupId = playerGroup:getID(),
				pos = { x = o.x, y = o.y, z = o.z },
				lastWptIndexFlag = false,
				engagementDistMax = cfg.escortEngageNm * NM,
				targetTypes = { 'Air' },
			},
		}
	end
	return {
		id = 'Follow',
		params = {
			groupId = playerGroup:getID(),
			pos = { x = o.x, y = o.y, z = o.z },
			lastWptIndexFlag = false,
		},
	}
end

local function orbitTask(point, altitude, speed)
	return {
		id = 'Orbit',
		params = {
			pattern = AI.Task.OrbitPattern.CIRCLE,
			point = { x = point.x, y = point.z },
			altitude = altitude,
			speed = speed,
		},
	}
end

local function orbitAltitude(cat, point, referenceAlt)
	if cat == 'helicopter' then
		return land.getHeight({ x = point.x, y = point.z }) + 150
	end
	return math.max(referenceAlt or 0, land.getHeight({ x = point.x, y = point.z }) + 1500)
end

local function orbitSpeed(cat)
	return cat == 'plane' and 180 or 40
end

---------------------------------------------------------------------------
-- Flight state
---------------------------------------------------------------------------

local function playerGroupOf(flight)
	local g = Group.getByName(flight.playerGroupName)
	if g and g:isExist() then return g end
	return nil
end

local function setMode(flight, mode)
	flight.mode = mode
	flight.modeToken = (flight.modeToken or 0) + 1
	return flight.modeToken
end

local function joinUp(flight, escort)
	local wg, pg = wingmanGroup(flight), playerGroupOf(flight)
	if not (wg and pg) then return false end
	wg:getController():setTask(followTask(pg, flight.cat, escort))
	setROE(wg, escort and ROE.WEAPON_FREE or ROE.OPEN_FIRE)
	setMode(flight, escort and 'escort' or 'follow')
	return true
end

local function removeFlight(playerGroupName)
	local flight = W.flights[playerGroupName]
	if not flight then return end
	W.byWingmanGroup[flight.groupName] = nil
	W.flights[playerGroupName] = nil
end

local function nearestFriendlyAirbase(side, point, cat)
	local best, bestDist
	for _, ab in ipairs(coalition.getAirbases(side) or {}) do
		local desc = ab:getDesc()
		local usable = cat == 'helicopter' or (desc and desc.category == Airbase.Category.AIRDROME)
		if usable then
			local d = distance2D(ab:getPoint(), point)
			if not bestDist or d < bestDist then best, bestDist = ab, d end
		end
	end
	return best
end

local function rtb(flight)
	local wg = wingmanGroup(flight)
	if not wg then removeFlight(flight.playerGroupName) return false end
	local lead = wg:getUnit(1)
	local ab = lead and nearestFriendlyAirbase(wg:getCoalition(), lead:getPoint(), flight.cat)
	local mg = GROUP:FindByName(flight.groupName)
	local mab = ab and AIRBASE:FindByName(ab:getName())
	setMode(flight, 'rtb')
	if mab and mg then
		local speedKmh = flight.cat == 'plane' and 700 or 200
		mg:Route({
			mg:GetCoordinate():WaypointAirTurningPoint('BARO', speedKmh, {}, 'Wingman RTB'),
			mab:GetCoordinate():WaypointAirLanding(speedKmh, mab, {}, 'Wingman RTB Land'),
		}, 1)
		FAI.log('wingman', '%s RTB to %s', flight.groupName, ab:getName())
		return true, ab:getName()
	end
	wg:getController():resetTask()
	FAI.warn('wingman', '%s RTB: no friendly airbase found, task reset', flight.groupName)
	return true, nil
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function withFlight(playerGroupName, fn)
	local pg = Group.getByName(playerGroupName)
	if not (pg and pg:isExist()) then return end
	local flight = W.flights[playerGroupName]
	if not (flight and wingmanGroup(flight)) then
		removeFlight(playerGroupName)
		msg(pg:getID(), 'No wingman with you. Use AI Wingman > Request.')
		return
	end
	fn(flight, pg)
end

local function requestWingmen(playerGroupName, count)
	local pg = Group.getByName(playerGroupName)
	if not (pg and pg:isExist()) then return end
	local gid = pg:getID()
	local existing = W.flights[playerGroupName]
	if existing and wingmanGroup(existing) then
		msg(gid, 'You already have a wingman flight. Dismiss or RTB it first.')
		return
	end
	removeFlight(playerGroupName)
	local playerUnit = playerUnitOf(pg)
	if not playerUnit then return end
	if cfg.requireAirborne and not playerUnit:inAir() then
		msg(gid, 'Wingmen can join once you are airborne.')
		return
	end
	count = math.max(1, math.min(count, cfg.maxWingmen))
	local src, err = sourceTemplate(playerUnit)
	if not src then
		msg(gid, 'Wingman unavailable: ' .. tostring(err))
		FAI.warn('wingman', 'request from %s failed: %s', playerGroupName, tostring(err))
		return
	end
	local cat = categoryKey(pg)
	W.spawnCounter = W.spawnCounter + 1
	local groupName = string.format('FHAI_WM_%s_%03d', playerGroupName:gsub('[^%w]', '_'), W.spawnCounter)
	local data = buildGroupData(src, playerUnit, count, groupName, cat)
	local ok, spawned = pcall(coalition.addGroup, src.countryId, src.categoryId, data)
	if not ok or not spawned then
		msg(gid, 'Wingman spawn failed. See dcs.log.')
		FAI.warn('wingman', 'addGroup failed type=%s template=%s err=%s',
			tostring(data.units[1].type), tostring(src.unit.name), tostring(spawned))
		return
	end
	local flight = {
		playerGroupName = playerGroupName,
		playerUnitName = playerUnit:getName(),
		groupName = groupName,
		cat = cat,
		count = count,
		side = pg:getCoalition(),
	}
	W.flights[playerGroupName] = flight
	W.byWingmanGroup[groupName] = playerGroupName
	FAI.log('wingman', 'spawned %s x%d type=%s task=%s for %s', groupName, count,
		tostring(data.units[1].type), tostring(data.task), playerGroupName)
	timer.scheduleFunction(function()
		local g = wingmanGroup(flight)
		if not g then
			FAI.warn('wingman', '%s did not survive spawn (type may not be AI-flyable)', groupName)
			msg(gid, 'Wingman failed to spawn for this aircraft type. See dcs.log.')
			removeFlight(playerGroupName)
			return
		end
		if cfg.unlimitedFuel then
			g:getController():setCommand({ id = 'SetUnlimitedFuel', params = { value = true } })
		end
		joinUp(flight, false)
		msg(gid, count == 1 and 'Two, joining on your wing.' or 'Flight joining on your wing.')
	end, nil, timer.getTime() + 1)
end

local TYPES_BY_KIND = {
	ground = { 'Ground Units' },
	airDefence = { 'Air Defence' },
	ships = { 'Ships' },
	mark = { 'Ground Units', 'Ships' },
	any = { 'Ground Units', 'Ships' },
}

-- Engage targets of `kind` within radiusNm of center, then rejoin after a while.
local function attackAt(flight, pg, center, kind, radiusNm, label)
	local wg = wingmanGroup(flight)
	local lead = wg:getUnit(1)
	local task = {
		id = 'ComboTask',
		params = { tasks = {
			{
				id = 'EngageTargetsInZone',
				params = {
					point = { x = center.x, y = center.z },
					zoneRadius = radiusNm * NM,
					targetTypes = TYPES_BY_KIND[kind] or TYPES_BY_KIND.ground,
					priority = 0,
				},
			},
			orbitTask(center, orbitAltitude(flight.cat, center, lead:getPoint().y), orbitSpeed(flight.cat)),
		} },
	}
	wg:getController():setTask(task)
	setROE(wg, ROE.WEAPON_FREE)
	local token = setMode(flight, 'attack')
	msg(pg:getID(), string.format('Engaging %s targets within %d nm of %s.',
		kind == 'airDefence' and 'air defence' or ((kind == 'mark' or kind == 'any') and 'ground' or kind), radiusNm, label))
	FAI.log('wingman', '%s attack kind=%s radiusNm=%d', flight.groupName, kind, radiusNm)
	timer.scheduleFunction(function()
		if W.flights[flight.playerGroupName] == flight and flight.modeToken == token and joinUp(flight, false) then
			local g = playerGroupOf(flight)
			if g then msg(g:getID(), 'Attack time is up, rejoining.') end
		end
	end, nil, timer.getTime() + cfg.attackAutoRejoinSec)
end

local function holdAt(flight, pg, point, label)
	local wg = wingmanGroup(flight)
	local lead = wg:getUnit(1)
	wg:getController():setTask(orbitTask(point, orbitAltitude(flight.cat, point, lead:getPoint().y), orbitSpeed(flight.cat)))
	setMode(flight, 'hold')
	msg(pg:getID(), 'Holding at ' .. label .. '.')
end

local function attackNear(playerGroupName, kind)
	withFlight(playerGroupName, function(flight, pg)
		local wg = wingmanGroup(flight)
		local center, label
		if kind == 'mark' then
			local lead = wg:getUnit(1)
			local best, bestDist
			-- Marks visible to everyone may carry a non-side coalition value.
			for _, sideKey in ipairs({ flight.side, -1 }) do
				for _, mark in pairs(W.marks[sideKey] or {}) do
					local d = distance2D(mark.pos, lead:getPoint())
					if d <= cfg.markMaxDistanceNm * NM and (not bestDist or d < bestDist) then best, bestDist = mark, d end
				end
			end
			if not best then
				msg(pg:getID(), string.format('No "%s" map mark within %d nm.', cfg.markPrefix, cfg.markMaxDistanceNm))
				return
			end
			center, label = best.pos, 'your mark'
		else
			local pu = playerUnitOf(pg)
			if not pu then return end
			center, label = pu:getPoint(), 'your position'
		end
		attackAt(flight, pg, center, kind, cfg.attackRadiusNm[kind], label)
	end)
end

local function holdHere(playerGroupName)
	withFlight(playerGroupName, function(flight, pg)
		holdAt(flight, pg, wingmanGroup(flight):getUnit(1):getPoint(), 'present position')
	end)
end

local function weapons(playerGroupName, free)
	withFlight(playerGroupName, function(flight, pg)
		setROE(wingmanGroup(flight), free and ROE.WEAPON_FREE or ROE.WEAPON_HOLD)
		msg(pg:getID(), free and 'Weapons free.' or 'Weapons hold.')
	end)
end

local function status(playerGroupName)
	withFlight(playerGroupName, function(flight, pg)
		local wg = wingmanGroup(flight)
		local pu = playerUnitOf(pg)
		local lines = { string.format('Wingmen: %s (mode %s)', flight.groupName, tostring(flight.mode)) }
		for i, unit in ipairs(wg:getUnits() or {}) do
			local ammo = {}
			for _, a in ipairs(unit:getAmmo() or {}) do
				local d = a.desc or {}
				ammo[#ammo + 1] = string.format('%dx %s', a.count or 0, tostring(d.displayName or d.typeName))
			end
			local dist = pu and string.format('%.1f nm', distance2D(unit:getPoint(), pu:getPoint()) / NM) or '?'
			lines[#lines + 1] = string.format('#%d fuel %d%%, %s, %s', i, math.floor((unit:getFuel() or 0) * 100),
				dist, #ammo > 0 and table.concat(ammo, ', ') or 'winchester')
		end
		msg(pg:getID(), table.concat(lines, '\n'), 20)
	end)
end

local function sendHome(playerGroupName)
	withFlight(playerGroupName, function(flight, pg)
		local _, abName = rtb(flight)
		msg(pg:getID(), abName and ('RTB to ' .. abName .. '.') or 'RTB.')
	end)
end

local function dismiss(playerGroupName)
	withFlight(playerGroupName, function(flight, pg)
		local wg = wingmanGroup(flight)
		if wg then wg:destroy() end
		removeFlight(playerGroupName)
		msg(pg:getID(), 'Wingmen dismissed.')
	end)
end

---------------------------------------------------------------------------
-- Plain-language orders. The player writes "wm <order>" on an F10 map mark
-- (the mark is "here") or in chat (with the chat hook). The request goes to the
-- sidecar, Claude answers with a short radio reply and a list of the actions
-- above, and they are carried out here.
---------------------------------------------------------------------------

local nl = cfg.naturalLanguage or {}
W.nl = { pending = {}, counter = 0, chatSeq = nil, seenMarks = {} }
local SIDE_KEY = { [coalition.side.RED] = 'red', [coalition.side.BLUE] = 'blue' }

local function bearingDeg(from, to)
	return math.floor((math.deg(math.atan2(to.z - from.z, to.x - from.x)) + 360) % 360 + 0.5)
end

local function zonePointByName(name)
	local ok, cz = pcall(CustomZone.getByName, CustomZone, name)
	return ok and cz and cz.point or nil
end

local function zonesNear(point)
	local out = {}
	local b = bc
	for _, z in ipairs(b and b.zones or {}) do
		local zp = z.active and not z.isHidden and zonePointByName(z.zone)
		if zp then
			local d = distance2D(point, zp) / NM
			if d <= (nl.contextRadiusNm or 80) then
				out[#out + 1] = { name = z.zone, side = SIDE_KEY[z.side] or 'neutral', bearingDeg = bearingDeg(point, zp),
					distanceNm = math.floor(d + 0.5) }
			end
		end
	end
	table.sort(out, function(a, c) return a.distanceNm < c.distanceNm end)
	while #out > 15 do table.remove(out) end
	return out
end

local function flightSummary(flight)
	local wg = wingmanGroup(flight)
	if not wg then return nil end
	local units = {}
	for _, unit in ipairs(wg:getUnits() or {}) do
		local ammo = {}
		for _, a in ipairs(unit:getAmmo() or {}) do
			local d = a.desc or {}
			ammo[#ammo + 1] = string.format('%dx %s', a.count or 0, tostring(d.displayName or d.typeName))
		end
		units[#units + 1] = { fuelPct = math.floor((unit:getFuel() or 0) * 100), weapons = FAI.json.array(ammo) }
	end
	return { mode = flight.mode, aircraft = FAI.json.array(units) }
end

local function writeRequests(sideName)
	local list = {}
	for _, req in pairs(W.nl.pending) do
		if req.side == sideName then list[#list + 1] = req.payload end
	end
	table.sort(list, function(a, c) return a.id < c.id end)
	return FAI.bridge.writeState(sideName, 'wingman', { requests = FAI.json.array(list) })
end

function W.submitRequest(playerGroupName, text, markPos)
	local pg = Group.getByName(playerGroupName)
	if not (pg and pg:isExist()) then return false end
	local gid = pg:getID()
	local pu = playerUnitOf(pg)
	if not pu then return false end
	local sideName = SIDE_KEY[pg:getCoalition()]
	if not sideName then return false end
	local open = 0
	for _, req in pairs(W.nl.pending) do if req.side == sideName then open = open + 1 end end
	if open >= (nl.maxPending or 3) then
		msg(gid, 'Wingman: say again in a moment, still working on the last call.')
		return false
	end
	text = tostring(text):sub(1, 300)
	local p = pu:getPoint()
	local v = pu:getVelocity()
	local flight = W.flights[playerGroupName]
	W.nl.counter = W.nl.counter + 1
	local id = string.format('%s-%d', sideName, W.nl.counter)
	local packages = {}
	local P = FAI.command and FAI.command.packages
	for pid, pkg in pairs(P and P.bySide[sideName] or {}) do
		if not pkg.pushed then
			packages[#packages + 1] = { package = pid, target = pkg.target,
				pushInMin = math.max(0, math.ceil((pkg.pushAt - timer.getAbsTime()) / 60)) }
		end
	end
	local payload = {
		id = id,
		text = text,
		player = { type = pu:getTypeName(), altFt = math.floor(p.y * 3.28084), headingDeg = math.floor((math.deg(headingOf(pu)) + 360) % 360),
			speedKt = math.floor(math.sqrt(v.x * v.x + v.z * v.z) * 1.94384) },
		wingmen = flight and flightSummary(flight) or nil,
		mark = markPos and { bearingDeg = bearingDeg(p, markPos), distanceNm = math.floor(distance2D(p, markPos) / NM + 0.5) } or nil,
		zones = FAI.json.array(zonesNear(p)),
		packages = FAI.json.array(packages),
	}
	W.nl.pending[id] = { id = id, side = sideName, group = playerGroupName, markPos = markPos, at = timer.getTime(), payload = payload }
	if not writeRequests(sideName) then
		W.nl.pending[id] = nil
		msg(gid, 'Wingman: plain-language orders need the Foothold AI sidecar. Use the F10 menu.')
		return false
	end
	FAI.log('wingman', 'request %s from %s: %s', id, playerGroupName, text)
	return true
end

local KINDS = { ground = 'ground', air_defence = 'airDefence', ships = 'ships', any = 'any' }

-- Where an action points: the player, the request's map mark, or a zone.
local function placeOf(action, req, pg)
	if action.where == 'mark' and req.markPos then return req.markPos, 'your mark' end
	if action.where == 'zone' and type(action.zone) == 'string' then
		local zp = zonePointByName(action.zone)
		if zp then return { x = zp.x, y = 0, z = zp.z }, action.zone end
		return nil, 'unknown zone ' .. action.zone
	end
	local pu = playerUnitOf(pg)
	if pu then return pu:getPoint(), 'your position' end
	return nil, 'no position'
end

local function runAction(action, req)
	local name = req.group
	local pg = Group.getByName(name)
	if not (pg and pg:isExist()) or type(action) ~= 'table' then return end
	local a = action.action
	if a == 'request' then
		requestWingmen(name, tonumber(action.count) == 3 and 3 or 1)
	elseif a == 'join' or a == 'cover' then
		withFlight(name, function(f, g)
			if joinUp(f, a == 'cover') then msg(g:getID(), a == 'cover' and 'Covering you.' or 'Rejoining.') end
		end)
	elseif a == 'hold' then
		withFlight(name, function(f, g)
			local point, label = placeOf(action, req, g)
			if point then holdAt(f, g, point, label) else msg(g:getID(), 'Wingman: ' .. label) end
		end)
	elseif a == 'attack' then
		withFlight(name, function(f, g)
			local kind = KINDS[action.kind] or 'ground'
			local point, label = placeOf(action, req, g)
			if not point then msg(g:getID(), 'Wingman: ' .. label) return end
			local radius = math.max(1, math.min(20, tonumber(action.radius_nm) or cfg.attackRadiusNm[kind] or 5))
			attackAt(f, g, point, kind, radius, label)
		end)
	elseif a == 'weapons' then
		weapons(name, action.free == true)
	elseif a == 'status' then
		status(name)
	elseif a == 'rtb' then
		sendHome(name)
	elseif a == 'dismiss' then
		dismiss(name)
	end
end

FAI.bridge.onOrders('wingman', function(sideName, orders)
	for _, r in ipairs(type(orders.results) == 'table' and orders.results or {}) do
		local req = type(r) == 'table' and W.nl.pending[r.id]
		if req then
			W.nl.pending[r.id] = nil
			local pg = Group.getByName(req.group)
			if pg and pg:isExist() and type(r.reply) == 'string' and r.reply ~= '' then
				msg(pg:getID(), 'Wingman: ' .. r.reply:sub(1, 200), 12)
			end
			-- A new wingman needs a moment to spawn before it can take orders.
			local delay = 0
			for _, action in ipairs(type(r.actions) == 'table' and r.actions or {}) do
				if delay == 0 then
					local ok, err = pcall(runAction, action, req)
					if not ok then FAI.warn('wingman', 'action %s failed: %s', tostring(action.action), tostring(err)) end
				else
					timer.scheduleFunction(function()
						local ok, err = pcall(runAction, action, req)
						if not ok then FAI.warn('wingman', 'action %s failed: %s', tostring(action.action), tostring(err)) end
					end, nil, timer.getTime() + delay)
				end
				if type(action) == 'table' and action.action == 'request' then delay = delay + 3 end
			end
			FAI.log('wingman', 'request %s answered: %s', r.id, tostring(r.reply))
		end
	end
end)

-- The player who placed a mark, or else the closest player of that side.
local function playerGroupForMark(event)
	local init = event.initiator
	if init and init.getGroup then
		local ok, g = pcall(init.getGroup, init)
		if ok and g and g:isExist() and playerUnitOf(g) then return g:getName() end
	end
	local best, bestD
	for _, side in ipairs({ coalition.side.RED, coalition.side.BLUE }) do
		if event.coalition == side or event.coalition == -1 then
			for _, unit in ipairs(coalition.getPlayers(side) or {}) do
				local d = distance2D(unit:getPoint(), event.pos)
				if not bestD or d < bestD then best, bestD = unit:getGroup():getName(), d end
			end
		end
	end
	return best
end

function W.onMarkText(event, text)
	if not nl.enabled then return end
	local prefix = cfg.markPrefix:lower() .. ' '
	if text:sub(1, #prefix) ~= prefix then return end
	local order = text:sub(#prefix + 1):gsub('^%s+', '')
	if order == '' then return end
	local key = tostring(event.idx) .. ':' .. order
	if W.nl.seenMarks[key] then return end
	W.nl.seenMarks[key] = true
	local groupName = playerGroupForMark(event)
	if groupName then W.submitRequest(groupName, order, event.pos) end
end

-- Chat lines from the optional hook (Saved Games\DCS\Scripts\Hooks\FootholdAI_Chat.lua).
local function pollChat()
	if not (nl.enabled and nl.chatInbox and FAI.dir) then return end
	local path = FAI.dir .. 'chat_inbox.lua'
	local data = FAI.loadDataFile(path)
	if type(data) ~= 'table' then
		-- no inbox yet: every line that appears later is new
		if W.nl.chatSeq == nil and not lfs.attributes(path) then W.nl.chatSeq = 0 end
		return
	end
	local items = type(data.items) == 'table' and data.items or {}
	local maxSeq = 0
	for _, item in ipairs(items) do maxSeq = math.max(maxSeq, tonumber(item.seq) or 0) end
	if W.nl.chatSeq == nil then W.nl.chatSeq = maxSeq return end   -- lines from before this mission
	for _, item in ipairs(items) do
		local seq = tonumber(item.seq) or 0
		if seq > W.nl.chatSeq and type(item.text) == 'string' and type(item.name) == 'string' then
			W.nl.chatSeq = math.max(W.nl.chatSeq, seq)
			local lower = item.text:lower()
			for _, prefix in ipairs(nl.chatPrefixes or {}) do
				if lower:sub(1, #prefix) == prefix:lower() then
					for _, side in ipairs({ coalition.side.RED, coalition.side.BLUE }) do
						for _, unit in ipairs(coalition.getPlayers(side) or {}) do
							if unit:getPlayerName() == item.name then
								W.submitRequest(unit:getGroup():getName(), item.text:sub(#prefix + 1), nil)
							end
						end
					end
					break
				end
			end
		end
	end
end

local function expireRequests()
	local now = timer.getTime()
	for id, req in pairs(W.nl.pending) do
		if now - req.at > (nl.timeoutSec or 90) then
			W.nl.pending[id] = nil
			local pg = Group.getByName(req.group)
			if pg and pg:isExist() then msg(pg:getID(), 'Wingman: no answer (is the Foothold AI sidecar running?). Use the F10 menu.') end
		end
	end
end

if nl.enabled then
	timer.scheduleFunction(function(_, t)
		local ok, err = pcall(pollChat)
		if not ok then FAI.warn('wingman', 'chat poll failed: %s', tostring(err)) end
		ok, err = pcall(expireRequests)
		if not ok then FAI.warn('wingman', 'request expiry failed: %s', tostring(err)) end
		return t + 2
	end, nil, timer.getTime() + 2)
end

W.api = { requestWingmen = requestWingmen, joinUp = joinUp, attackAt = attackAt, holdAt = holdAt,
	weapons = weapons, status = status, sendHome = sendHome, dismiss = dismiss }

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

local function addMenus(playerGroupName)
	if W.menus[playerGroupName] then return end
	local mg = GROUP:FindByName(playerGroupName)
	if not mg then return end
	W.menus[playerGroupName] = true
	local root = MENU_GROUP:New(mg, 'AI Wingman')
	local req = MENU_GROUP:New(mg, 'Request', root)
	MENU_GROUP_COMMAND:New(mg, 'One wingman', req, requestWingmen, playerGroupName, 1)
	if cfg.maxWingmen >= 3 then
		MENU_GROUP_COMMAND:New(mg, 'Three wingmen (4-ship)', req, requestWingmen, playerGroupName, 3)
	end
	local form = MENU_GROUP:New(mg, 'Formation', root)
	MENU_GROUP_COMMAND:New(mg, 'Join up', form, function() withFlight(playerGroupName, function(f, pg)
		if joinUp(f, false) then msg(pg:getID(), 'Rejoining.') end end) end)
	MENU_GROUP_COMMAND:New(mg, 'Cover me (engage air)', form, function() withFlight(playerGroupName, function(f, pg)
		if joinUp(f, true) then msg(pg:getID(), 'Covering you, engaging air threats.') end end) end)
	MENU_GROUP_COMMAND:New(mg, 'Hold here', form, holdHere, playerGroupName)
	local atk = MENU_GROUP:New(mg, 'Attack', root)
	MENU_GROUP_COMMAND:New(mg, 'Ground targets near me', atk, attackNear, playerGroupName, 'ground')
	MENU_GROUP_COMMAND:New(mg, 'Air defences near me', atk, attackNear, playerGroupName, 'airDefence')
	MENU_GROUP_COMMAND:New(mg, 'Ships near me', atk, attackNear, playerGroupName, 'ships')
	MENU_GROUP_COMMAND:New(mg, 'My "' .. cfg.markPrefix .. '" map mark', atk, attackNear, playerGroupName, 'mark')
	local wpn = MENU_GROUP:New(mg, 'Weapons', root)
	MENU_GROUP_COMMAND:New(mg, 'Weapons free', wpn, weapons, playerGroupName, true)
	MENU_GROUP_COMMAND:New(mg, 'Weapons hold', wpn, weapons, playerGroupName, false)
	MENU_GROUP_COMMAND:New(mg, 'Status', root, status, playerGroupName)
	MENU_GROUP_COMMAND:New(mg, 'RTB', root, sendHome, playerGroupName)
	MENU_GROUP_COMMAND:New(mg, 'Dismiss', root, dismiss, playerGroupName)
	FAI.debug('wingman', 'menus added for %s', playerGroupName)
end

local function setupPlayerUnit(unit)
	if not (unit and unit:isExist() and unit:getPlayerName()) then return end
	local g = unit:getGroup()
	if not g then return end
	local cat = g:getCategory()
	if cat ~= Group.Category.AIRPLANE and cat ~= Group.Category.HELICOPTER then return end
	local name = g:getName()
	timer.scheduleFunction(function()
		local ok, err = pcall(addMenus, name)
		if not ok then FAI.warn('wingman', 'menu setup failed for %s: %s', name, tostring(err)) end
	end, nil, timer.getTime() + 2)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local playerLossEvents = {
	[world.event.S_EVENT_PLAYER_LEAVE_UNIT] = true,
	[world.event.S_EVENT_DEAD] = true,
	[world.event.S_EVENT_CRASH] = true,
	[world.event.S_EVENT_PILOT_DEAD] = true,
	[world.event.S_EVENT_EJECTION] = true,
}

local function flightForPlayerUnit(unitName)
	for _, flight in pairs(W.flights) do
		if flight.playerUnitName == unitName then return flight end
	end
	return nil
end

local function onEvent(event)
	local id = event.id
	if id == world.event.S_EVENT_MARK_ADDED or id == world.event.S_EVENT_MARK_CHANGE then
		local text = type(event.text) == 'string' and event.text:lower() or ''
		local side = event.coalition
		if side and event.pos then
			W.marks[side] = W.marks[side] or {}
			if text:sub(1, #cfg.markPrefix) == cfg.markPrefix:lower() then
				W.marks[side][event.idx] = { pos = event.pos, t = timer.getTime() }
			else
				W.marks[side][event.idx] = nil
			end
			W.onMarkText(event, text)
		end
		return
	end
	if id == world.event.S_EVENT_MARK_REMOVED then
		for _, marks in pairs(W.marks) do marks[event.idx] = nil end
		return
	end
	local unit = event.initiator
	if not unit or not unit.getName then return end
	local okName, unitName = pcall(unit.getName, unit)
	if not okName or not unitName then return end

	if id == world.event.S_EVENT_BIRTH then
		if unit.getPlayerName and unit:getPlayerName() then setupPlayerUnit(unit) end
		return
	end
	if playerLossEvents[id] then
		local flight = flightForPlayerUnit(unitName)
		if flight and flight.mode ~= 'rtb' then
			FAI.log('wingman', 'player %s lost (event %d), sending %s home', unitName, id, flight.groupName)
			rtb(flight)
		end
	end
	if id == world.event.S_EVENT_LAND then
		local okGroup, g = pcall(unit.getGroup, unit)
		local gName = okGroup and g and g:getName()
		local owner = gName and W.byWingmanGroup[gName]
		if owner then
			local flight = W.flights[owner]
			timer.scheduleFunction(function()
				local wg = Group.getByName(gName)
				if wg and wg:isExist() then wg:destroy() end
				if W.flights[owner] == flight then removeFlight(owner) end
				FAI.log('wingman', '%s removed after landing', gName)
			end, nil, timer.getTime() + cfg.removeAfterLandingSec)
		end
	end
end

world.addEventHandler({
	onEvent = function(_, event)
		local ok, err = pcall(onEvent, event)
		if not ok then FAI.warn('wingman', 'event %s failed: %s', tostring(event and event.id), tostring(err)) end
	end,
})

-- Players already in a slot when this file loads (single player, early joins).
for _, side in ipairs({ coalition.side.RED, coalition.side.BLUE }) do
	for _, unit in ipairs(coalition.getPlayers(side) or {}) do
		setupPlayerUnit(unit)
	end
end

FAI.log('wingman', 'ready (maxWingmen=%d, plain-language orders %s)', cfg.maxWingmen,
	(cfg.naturalLanguage or {}).enabled and 'on' or 'off')
