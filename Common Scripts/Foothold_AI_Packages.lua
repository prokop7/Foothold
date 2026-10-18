---------------------------------------------------------------------------
-- Foothold AI - packages (phase 4)
-- Claude groups flights into a package with a push time. Each air flight of the
-- package, once it is on its way, holds in an orbit at the package's IP. At the
-- push time (or earlier, once every flight is holding) the flights are released
-- and continue their own Foothold mission, so they reach the target together
-- whatever their start-up and taxi times were.
--
-- Players join a package from the F10 "AI Packages" menu (phase 5): they get
-- the IP and target on their F10 map, the AI waits at the IP for them, they
-- hear the push call, and a player in the package can call the push himself.
-- Players can also ask their side's Claude commander for support.
--
-- How a flight holds: an Orbit is pushed on top of the flight's mission
-- (Controller.pushTask) as a ControlledTask that ends by itself at the release
-- time, or earlier when the flight's user flag is set. When it ends, DCS resumes
-- the flight's original route. The hold starts only once the flight is past its
-- first waypoint (holdStartNm from its base), so the route resumes forward, not
-- back toward the airfield.
---------------------------------------------------------------------------

local FAI = FootholdAI
local X = FAI and FAI.command
if not (X and X.executors and X.util) then return end
local cfg = FAI.config.command.packages
local U = X.util
local round, zonePoint, zoneUsable = U.round, U.zonePoint, U.zoneUsable
local SIDE_NAME, SIDE_ID = U.SIDE_NAME, U.SIDE_ID
local NM = 1852

local P = {
	bySide = { red = {}, blue = {} },   -- [sideName][packageId] = package
	holding = {},                        -- [live group name] = member
	flagCounter = 0,
	markCounter = 0,
	menus = {},                          -- [player group name] = true
}
X.packages = P

local function now() return timer.getAbsTime() end
local function pack(...) return { n = select('#', ...), ... } end

-- Package names are ASCII, so they survive the round trip through the snapshot.
local function packageId(s)
	if type(s) ~= 'string' then return nil end
	local id = s:gsub('[^%w%-_]', '_'):sub(1, 30)
	return id ~= '' and id or nil
end

local function dist2(a, b)
	local dx, dz = a.x - b.x, (a.z or a.y) - (b.z or b.y)
	return math.sqrt(dx * dx + dz * dz)
end

-- Point `fromTarget` metres from target toward origin.
local function toward(target, origin, fromTarget)
	local d = dist2(target, origin)
	if d < 1 then return { x = target.x, z = target.z } end
	local f = math.min(1, fromTarget / d)
	return { x = target.x + (origin.x - target.x) * f, z = target.z + (origin.z - target.z) * f }
end

local function liveGroup(gc)
	local name = gc and (gc.spawnedName or gc.name)
	local g = name and Group.getByName(name)
	if g and g:isExist() and g:getSize() > 0 then return g, name end
	return nil, name
end

local function leadOf(g)
	for _, u in ipairs(g:getUnits() or {}) do
		if u and u:isExist() then return u end
	end
	return nil
end

local function allAirborne(g)
	for _, u in ipairs(g:getUnits() or {}) do
		if u:isExist() and not u:inAir() then return false end
	end
	return true
end

local function releaseAt(pkg, m)
	return pkg.pushAt + (m.offsetSec or 0)
end

---------------------------------------------------------------------------
-- Holding
---------------------------------------------------------------------------

local function holdTask(pkg, m, g)
	local lead = leadOf(g)
	local p = lead:getPoint()
	local helo = g:getCategory() == Group.Category.HELICOPTER
	local alt = math.max(p.y, helo and 150 or 1500)
	local releaseModel = timer.getTime() + math.max(0, releaseAt(pkg, m) - now())
	return {
		id = 'ControlledTask',
		params = {
			task = { id = 'Orbit', params = {
				pattern = AI.Task.OrbitPattern.CIRCLE,
				point = { x = pkg.ip.x, y = pkg.ip.z },
				altitude = alt,
				speed = helo and cfg.heloOrbitSpeedMps or cfg.orbitSpeedMps,
			} },
			-- ends by itself at the release time, or when the mission sets the flag
			stopCondition = { time = releaseModel, userFlag = tostring(m.flag) },
		},
	}
end

local function applyHold(pkg, m, g, name)
	if not m.flag then
		P.flagCounter = P.flagCounter + 1
		m.flag = cfg.flagBase + P.flagCounter
		trigger.action.setUserFlag(m.flag, false)
	end
	g:getController():pushTask(holdTask(pkg, m, g))
	m.state, m.group, m.holdingSince = 'holding', name, m.holdingSince or now()
	P.holding[name] = m
end

local function release(m, state)
	if m.flag then trigger.action.setUserFlag(m.flag, true) end
	if m.group then P.holding[m.group] = nil end
	m.state = state or 'released'
end

---------------------------------------------------------------------------
-- Package tick
---------------------------------------------------------------------------

local TERMINAL = { released = true, direct = true, aborted = true, lost = true }

local function updateMember(pkg, m)
	local t = now()
	local mission = X.missions[m.key]
	if m.state == 'waiting' then
		if mission and mission.endedAt then m.state = 'aborted' return end
		local gc = m.gc
		if not gc or gc.state ~= 'inair' then return end
		local g, name = liveGroup(gc)
		local lead = g and leadOf(g)
		if not lead then return end
		local p = lead:getPoint()
		if t >= releaseAt(pkg, m) or dist2(p, pkg.targetPoint) <= pkg.ipDist + 3 * NM then
			m.state = 'direct'   -- too late or already past the IP: fly straight on
			return
		end
		if dist2(p, m.originPoint) < cfg.holdStartNm * NM then return end
		if not allAirborne(g) and t - (m.firstAirborneAt or t) < 120 then
			m.firstAirborneAt = m.firstAirborneAt or t
			return
		end
		applyHold(pkg, m, g, name)
	elseif m.state == 'holding' then
		local g = liveGroup(m.gc)
		if not g then
			release(m, 'lost')
		elseif t >= releaseAt(pkg, m) then
			release(m, 'released')
		end
	end
end

local function updatePackage(sideName, pkg)
	local t = now()
	for _, m in ipairs(pkg.members) do
		local ok, err = pcall(updateMember, pkg, m)
		if not ok then FAI.warn('packages', '%s member %s: %s', pkg.id, tostring(m.order), tostring(err)) end
	end
	P.updatePlayers(sideName, pkg)
	if pkg.pushed then return end
	-- Push early once every flight still flying (players included) is holding at the IP.
	if pkg.pushWhenReady and t < pkg.pushAt then
		local holding, waiting = 0, 0
		for _, m in ipairs(pkg.members) do
			if m.state == 'holding' then holding = holding + 1 elseif m.state == 'waiting' then waiting = waiting + 1 end
		end
		for _, pl in pairs(pkg.players) do
			if pl.state == 'at_ip' then holding = holding + 1 elseif pl.state == 'joined' then waiting = waiting + 1 end
		end
		if holding > 0 and waiting == 0 then
			local early = t + cfg.pushWhenReadyDelaySec
			if early < pkg.pushAt then pkg.pushAt, pkg.pushedEarly = early, true end
		end
	end
	if t >= pkg.pushAt then
		pkg.pushed = true
		local counts = {}
		for _, m in ipairs(pkg.members) do counts[m.state] = (counts[m.state] or 0) + 1 end
		X.event(sideName, 'package_pushed', { package = pkg.id, target = pkg.target, early = pkg.pushedEarly or nil,
			holding = counts.holding or 0, notArrived = counts.waiting or 0, direct = counts.direct or 0,
			lost = (counts.lost or 0) + (counts.aborted or 0) })
		X.eventPending[sideName] = true
		FAI.log('packages', '%s package %s pushed on %s', sideName, pkg.id, tostring(pkg.target))
		P.announcePush(pkg)
	end
end

local function tick()
	local t = now()
	for sideName, list in pairs(P.bySide) do
		for id, pkg in pairs(list) do
			updatePackage(sideName, pkg)
			local done = pkg.pushed
			for _, m in ipairs(pkg.members) do
				if not TERMINAL[m.state] and m.state ~= 'waiting' then done = false end
			end
			if done and t - pkg.pushAt > cfg.keepMin * 60 then
				for _, pl in pairs(pkg.players) do P.removeMarks(pl) end
				list[id] = nil
			end
		end
	end
end

---------------------------------------------------------------------------
-- Foothold re-tasks some flights (SEAD retargeting, CAP routing). That replaces
-- the task stack, so a holding flight gets its hold back; a flight sent home is
-- no longer part of the package.
---------------------------------------------------------------------------

local function rehold(name)
	local m = name and P.holding[name]
	if not m or m.state ~= 'holding' then return end
	local pkg = m.package
	local g = Group.getByName(name)
	if not (g and g:isExist()) or now() >= releaseAt(pkg, m) then return end
	local ok, err = pcall(function() g:getController():pushTask(holdTask(pkg, m, g)) end)
	if not ok then FAI.warn('packages', 're-hold of %s failed: %s', name, tostring(err)) end
end

U.wrap(BattleCommander, 'BattleCommander', 'EngageSeadMission', function(original, self, tgtzone, groupname, ...)
	local results = pack(original(self, tgtzone, groupname, ...))
	rehold(groupname)
	return unpack(results, 1, results.n)
end)
U.wrap(BattleCommander, 'BattleCommander', 'EngageCasMission', function(original, self, tgtzone, groupname, ...)
	local results = pack(original(self, tgtzone, groupname, ...))
	rehold(groupname)
	return unpack(results, 1, results.n)
end)
U.wrap(BattleCommander, 'BattleCommander', 'EngageRunwayBombing', function(original, self, homeBase, targetZoneName, groupName, ...)
	local results = pack(original(self, homeBase, targetZoneName, groupName, ...))
	rehold(groupName)
	return unpack(results, 1, results.n)
end)
if GroupCommander then
	U.wrap(GroupCommander, 'GroupCommander', '_assignCapTask', function(original, self, ...)
		local results = pack(original(self, ...))
		rehold(self.spawnedName or self.name)
		return unpack(results, 1, results.n)
	end)
	U.wrap(GroupCommander, 'GroupCommander', '_startCapReturnHome', function(original, self, ...)
		local name = self.spawnedName or self.name
		local m = P.holding[name]
		if m then release(m, 'aborted') end
		return original(self, ...)
	end)
end

---------------------------------------------------------------------------
-- Orders
---------------------------------------------------------------------------

local function ownZoneNearest(side, point)
	local best, bestD
	for _, z in ipairs(U.bcObj().zones or {}) do
		local zp = z.side == side and zoneUsable(z) and zonePoint(z)
		if zp then
			local d = dist2(zp, point)
			if not bestD or d < bestD then best, bestD = z, d end
		end
	end
	return best
end

local function createPackage(side, order)
	local sideName = SIDE_NAME[side]
	local b = U.bcObj()
	local id = packageId(order.package)
	if not id then return false, 'package name required' end
	local existing = P.bySide[sideName][id]
	if existing and not existing.pushed then return false, 'package ' .. id .. ' exists and has not pushed yet' end
	local target = b:getZoneByName(order.targetZone or '')
	if not target or not target.active or target.isHidden then return false, 'unknown target zone' end
	local tp = zonePoint(target)
	if not tp then return false, 'target position unknown' end
	local from = order.fromZone and b:getZoneByName(order.fromZone)
	if order.fromZone and not (from and from.side == side) then return false, 'fromZone must be one of your zones' end
	from = from or ownZoneNearest(side, tp)
	if not from then return false, 'no own zone to set the IP from' end
	local ipNm = math.max(10, math.min(80, tonumber(order.ipNm) or cfg.ipNm))
	local pushMin = math.max(cfg.minPushMin, math.min(cfg.maxPushMin, tonumber(order.pushInMin) or 20))
	local pkg = {
		id = id, side = side, target = target.zone, targetPoint = { x = tp.x, z = tp.z }, ipNm = ipNm,
		ip = toward(tp, zonePoint(from), ipNm * NM), ipFrom = from.zone,
		pushAt = now() + pushMin * 60, pushWhenReady = order.pushWhenReady ~= false,
		members = {}, players = {}, createdAt = now(),
	}
	pkg.ipDist = dist2(pkg.ip, pkg.targetPoint)   -- shorter than ipNm when the own zone is closer
	P.bySide[sideName][id] = pkg
	return true, string.format('package %s on %s: IP %d nm toward %s, push in %d min%s', id, target.zone, ipNm,
		from.zone, pushMin, pkg.pushWhenReady and ' (earlier if every flight is holding)' or '')
end

X.executors.create_package = createPackage

local function addMember(pkg, key, mission, order)
	local gc = mission.gc
	local origin = gc.zoneCommander and zonePoint(gc.zoneCommander)
	local m = {
		key = key, order = order.id, package = pkg, gc = gc, role = mission.role, state = 'waiting',
		offsetSec = math.max(-600, math.min(600, (tonumber(order.pushOffsetMin) or 0) * 60)),
		originPoint = origin and { x = origin.x, z = origin.z } or pkg.ip,
	}
	pkg.members[#pkg.members + 1] = m
	return m
end

-- launch_capability / launch_mission take an optional package and pushOffsetMin.
for _, kind in ipairs({ 'launch_capability', 'launch_mission' }) do
	local original = X.executors[kind]
	X.executors[kind] = function(side, order)
		local pkg
		if order.package ~= nil then
			pkg = P.bySide[SIDE_NAME[side]][packageId(order.package) or '']
			if not pkg then return false, 'unknown package ' .. tostring(order.package) end
			if pkg.pushed then return false, 'package ' .. pkg.id .. ' has already pushed' end
		end
		local ok, detail = original(side, order)
		if ok and pkg then
			local key = X.missionKey(side, order.id)
			local mission = X.missions[key]
			if mission and mission.gc and mission.gc.type ~= 'surface' then
				addMember(pkg, key, mission, order)
				detail = string.format('%s; package %s, holds at the IP until push%s', detail, pkg.id,
					(tonumber(order.pushOffsetMin) or 0) ~= 0 and string.format(' %+d min', tonumber(order.pushOffsetMin)) or '')
			else
				detail = detail .. '; ground units do not hold, not added to package ' .. pkg.id
			end
		end
		return ok, detail
	end
end

---------------------------------------------------------------------------
-- Players (phase 5): join a package from the F10 menu, hear the push.
---------------------------------------------------------------------------

local function groupMsg(groupName, text, seconds)
	local g = Group.getByName(groupName)
	if g and g:isExist() then trigger.action.outTextForGroup(g:getID(), text, seconds or 15) end
end

local function playerUnitOf(g)
	for _, u in ipairs(g:getUnits() or {}) do
		if u and u:isExist() and u:getPlayerName() then return u end
	end
	return nil
end

local function bearingDeg(from, to)
	return math.floor((math.deg(math.atan2(to.z - from.z, to.x - from.x)) + 360) % 360 + 0.5)
end

-- "045 for 32 nm" from the player's position to a point.
local function braa(groupName, point)
	local g = Group.getByName(groupName)
	local u = g and g:isExist() and playerUnitOf(g)
	if not u then return '?' end
	local p = u:getPoint()
	return string.format('%03d for %d nm', bearingDeg(p, point), math.floor(dist2(p, point) / NM + 0.5))
end

local function openPackages(sideName)
	local list = {}
	for _, pkg in pairs(P.bySide[sideName] or {}) do
		if not pkg.pushed then list[#list + 1] = pkg end
	end
	table.sort(list, function(a, c) return a.id < c.id end)
	return list
end

local function playerSide(groupName)
	local g = Group.getByName(groupName)
	if not (g and g:isExist()) then return nil end
	return SIDE_NAME[g:getCoalition()], g
end

local function packageOfPlayer(groupName)
	for _, list in pairs(P.bySide) do
		for _, pkg in pairs(list) do
			local pl = pkg.players[groupName]
			if pl and pl.state ~= 'left' and not pkg.pushed then return pkg, pl end
		end
	end
	return nil
end

function P.removeMarks(pl)
	for _, id in ipairs(pl.marks or {}) do pcall(trigger.action.removeMark, id) end
	pl.marks = {}
end

local function addMark(pl, g, text, point)
	P.markCounter = P.markCounter + 1
	local id = cfg.markBase + P.markCounter
	local ok = pcall(trigger.action.markToGroup, id, text, { x = point.x, y = land.getHeight({ x = point.x, y = point.z }), z = point.z },
		g:getID(), true)
	if ok then pl.marks[#pl.marks + 1] = id end
end

local function flightsLine(pkg)
	local roles = {}
	for _, m in ipairs(pkg.members) do
		if m.state ~= 'aborted' and m.state ~= 'lost' then
			roles[#roles + 1] = tostring(m.role or '?') .. (m.offsetSec ~= 0 and string.format(' %+d', m.offsetSec / 60) or '')
		end
	end
	return #roles > 0 and table.concat(roles, ', ') or 'no AI flights yet'
end

function P.listFor(groupName)
	local sideName = playerSide(groupName)
	if not sideName then return end
	local list = openPackages(sideName)
	if #list == 0 then
		groupMsg(groupName, 'No AI packages are planned right now. Use AI Packages > Request support to ask for one.')
		return
	end
	local lines = { 'AI packages (F10 > AI Packages > Join):' }
	for i, pkg in ipairs(list) do
		if i > 6 then break end
		lines[#lines + 1] = string.format('%d. %s on %s, push in %d min, IP %s from you. Flights: %s', i, pkg.id, pkg.target,
			math.max(0, math.ceil((pkg.pushAt - now()) / 60)), braa(groupName, pkg.ip), flightsLine(pkg))
	end
	groupMsg(groupName, table.concat(lines, '\n'), 25)
end

function P.join(groupName, index)
	local sideName, g = playerSide(groupName)
	if not sideName then return end
	local pkg = openPackages(sideName)[index]
	if not pkg then
		groupMsg(groupName, 'There is no package ' .. tostring(index) .. '. Use AI Packages > List packages.')
		return
	end
	local current = packageOfPlayer(groupName)
	if current and current ~= pkg then P.leave(groupName, true) end
	local u = playerUnitOf(g)
	local pl = pkg.players[groupName] or { marks = {} }
	pl.group, pl.state = groupName, 'joined'
	pl.playerName = u and u:getPlayerName() or '?'
	pl.type = u and u:getTypeName() or '?'
	pl.warned = {}
	pkg.players[groupName] = pl
	P.removeMarks(pl)
	addMark(pl, g, string.format('%s IP - hold here, push in %d min', pkg.id, math.max(0, math.ceil((pkg.pushAt - now()) / 60))), pkg.ip)
	addMark(pl, g, string.format('%s target: %s', pkg.id, pkg.target), pkg.targetPoint)
	groupMsg(groupName, string.format('Joined %s on %s. IP %s (marked on your F10 map), push in %d min. AI flights: %s.%s',
		pkg.id, pkg.target, braa(groupName, pkg.ip), math.max(0, math.ceil((pkg.pushAt - now()) / 60)), flightsLine(pkg),
		pkg.pushWhenReady and ' The package pushes early once everyone, you included, is at the IP.' or ''), 25)
	X.event(sideName, 'player_joined_package', { package = pkg.id, player = pl.playerName, aircraft = pl.type })
	FAI.log('packages', '%s joined package %s', pl.playerName, pkg.id)
end

function P.leave(groupName, quiet)
	local pkg, pl = packageOfPlayer(groupName)
	if not pkg then
		if not quiet then groupMsg(groupName, 'You are not in a package.') end
		return
	end
	pl.state = 'left'
	P.removeMarks(pl)
	if not quiet then groupMsg(groupName, 'Left package ' .. pkg.id .. '.') end
end

function P.statusFor(groupName)
	local pkg, pl = packageOfPlayer(groupName)
	if not pkg then
		groupMsg(groupName, 'You are not in a package. AI Packages > List packages shows what is planned.')
		return
	end
	local lines = { string.format('%s on %s: push in %d min, IP %s, you are %s.', pkg.id, pkg.target,
		math.max(0, math.ceil((pkg.pushAt - now()) / 60)), braa(groupName, pkg.ip), pl.state == 'at_ip' and 'at the IP' or 'en route') }
	for _, m in ipairs(pkg.members) do
		lines[#lines + 1] = string.format('  %s: %s', tostring(m.role), m.state)
	end
	for _, other in pairs(pkg.players) do
		if other ~= pl and other.state ~= 'left' then lines[#lines + 1] = string.format('  %s (%s): %s', other.playerName, other.type, other.state) end
	end
	groupMsg(groupName, table.concat(lines, '\n'), 20)
end

-- A player in the package calls the push: every holding flight leaves the IP now
-- (plus its offset).
function P.pushNow(groupName)
	local pkg, pl = packageOfPlayer(groupName)
	if not pkg then
		groupMsg(groupName, 'You are not in a package.')
		return
	end
	pkg.pushAt, pkg.pushedBy = now(), pl.playerName
	updatePackage(SIDE_NAME[pkg.side], pkg)
end

function P.announcePush(pkg)
	for groupName, pl in pairs(pkg.players) do
		local g = Group.getByName(groupName)
		if pl.state ~= 'left' and g and g:isExist() then
			groupMsg(groupName, string.format('%s, PUSH PUSH%s. Flights: %s. Target %s %s.', pkg.id,
				pkg.pushedBy and (' (called by ' .. pkg.pushedBy .. ')') or '', flightsLine(pkg), pkg.target,
				braa(groupName, pkg.targetPoint)), 20)
			pl.state = 'pushed'
			P.removeMarks(pl)
			addMark(pl, g, string.format('%s target: %s', pkg.id, pkg.target), pkg.targetPoint)
		end
	end
end

function P.updatePlayers(sideName, pkg)
	local t = now()
	for groupName, pl in pairs(pkg.players) do
		local g = Group.getByName(groupName)
		local u = g and g:isExist() and playerUnitOf(g)
		if pl.state ~= 'left' and not u then
			pl.state = 'left'   -- left the slot, died or landed out
			P.removeMarks(pl)
		elseif u and not pkg.pushed then
			if pl.state == 'joined' and dist2(u:getPoint(), pkg.ip) <= cfg.playerAtIpNm * NM then
				pl.state = 'at_ip'
				groupMsg(groupName, string.format('%s: at the IP, hold. Push in %d min.', pkg.id,
					math.max(0, math.ceil((pkg.pushAt - t) / 60))))
			end
			for _, mins in ipairs({ 5, 1 }) do
				local left = pkg.pushAt - t
				if left <= mins * 60 and left > (mins * 60 - 30) and not pl.warned[mins] then
					pl.warned[mins] = true
					groupMsg(groupName, string.format('%s: push in %d minute%s.', pkg.id, mins, mins > 1 and 's' or ''))
				end
			end
		end
	end
end

-- Players ask their side's Claude commander for support; it plans it next cycle.
local SUPPORT = { sead = 'SEAD on the air defences near me', cap = 'CAP cover over me',
	cas = 'CAS on the enemy near me', strike = 'a strike package on the nearest enemy zone' }

function P.requestSupport(groupName, kind)
	local sideName, g = playerSide(groupName)
	if not sideName then return end
	local u = playerUnitOf(g)
	if not u then return end
	if not X.controls(SIDE_ID[sideName]) then
		groupMsg(groupName, 'No AI commander for your side in this mission.')
		return
	end
	local last = P.lastRequestAt and P.lastRequestAt[groupName] or -1e9
	if now() - last < 120 then
		groupMsg(groupName, 'HQ: we have your request, stand by.')
		return
	end
	P.lastRequestAt = P.lastRequestAt or {}
	P.lastRequestAt[groupName] = now()
	local p = u:getPoint()
	local nearestEnemy, bestD
	for _, z in ipairs(U.bcObj().zones or {}) do
		local zp = z.active and not z.isHidden and z.side ~= 0 and z.side ~= g:getCoalition() and zonePoint(z)
		if zp then
			local d = dist2(zp, p)
			if not bestD or d < bestD then nearestEnemy, bestD = z.zone, d end
		end
	end
	X.event(sideName, 'player_request', { player = u:getPlayerName(), aircraft = u:getTypeName(), wants = kind,
		nearestEnemyZone = nearestEnemy, distanceNm = bestD and math.floor(bestD / NM + 0.5) or nil,
		playerXKm = round(p.x / 1000, 0.1), playerZKm = round(p.z / 1000, 0.1) })
	X.eventPending[sideName] = true
	groupMsg(groupName, string.format('HQ: copy, %s. Planning; check AI Packages > List packages in a few minutes.', SUPPORT[kind]))
end

local function addPlayerMenus(groupName)
	if P.menus[groupName] then return end
	local mg = GROUP:FindByName(groupName)
	if not mg then return end
	P.menus[groupName] = true
	local root = MENU_GROUP:New(mg, 'AI Packages')
	MENU_GROUP_COMMAND:New(mg, 'List packages', root, P.listFor, groupName)
	local join = MENU_GROUP:New(mg, 'Join', root)
	for i = 1, 6 do MENU_GROUP_COMMAND:New(mg, 'Package ' .. i, join, P.join, groupName, i) end
	MENU_GROUP_COMMAND:New(mg, 'My package status', root, P.statusFor, groupName)
	MENU_GROUP_COMMAND:New(mg, 'Push now', root, P.pushNow, groupName)
	MENU_GROUP_COMMAND:New(mg, 'Leave package', root, P.leave, groupName)
	local req = MENU_GROUP:New(mg, 'Request support', root)
	MENU_GROUP_COMMAND:New(mg, 'SEAD', req, P.requestSupport, groupName, 'sead')
	MENU_GROUP_COMMAND:New(mg, 'CAP cover', req, P.requestSupport, groupName, 'cap')
	MENU_GROUP_COMMAND:New(mg, 'CAS', req, P.requestSupport, groupName, 'cas')
	MENU_GROUP_COMMAND:New(mg, 'Strike package', req, P.requestSupport, groupName, 'strike')
end

local function setupPlayer(unit)
	if not (unit and unit:isExist() and unit:getPlayerName()) then return end
	local g = unit:getGroup()
	local cat = g and g:getCategory()
	if cat ~= Group.Category.AIRPLANE and cat ~= Group.Category.HELICOPTER then return end
	local name = g:getName()
	timer.scheduleFunction(function()
		local ok, err = pcall(addPlayerMenus, name)
		if not ok then FAI.warn('packages', 'menu setup failed for %s: %s', name, tostring(err)) end
	end, nil, timer.getTime() + 3)
end

world.addEventHandler({ onEvent = function(_, e)
	if e and e.id == world.event.S_EVENT_BIRTH and e.initiator then
		local ok, err = pcall(setupPlayer, e.initiator)
		if not ok then FAI.warn('packages', 'birth handling failed: %s', tostring(err)) end
	end
end })
for _, side in ipairs({ coalition.side.RED, coalition.side.BLUE }) do
	for _, unit in ipairs(coalition.getPlayers(side) or {}) do pcall(setupPlayer, unit) end
end

---------------------------------------------------------------------------
-- Snapshot and timer
---------------------------------------------------------------------------

X.snapshotExtensions[#X.snapshotExtensions + 1] = function(sideName, payload)
	local rows = {}
	local t = now()
	for id, pkg in pairs(P.bySide[sideName]) do
		local members = {}
		for _, m in ipairs(pkg.members) do
			members[#members + 1] = { order = m.order, role = m.role, state = m.state,
				pushOffsetMin = m.offsetSec ~= 0 and round(m.offsetSec / 60) or nil,
				holdingMin = m.state == 'holding' and round((t - m.holdingSince) / 60) or nil }
		end
		local players = {}
		for _, pl in pairs(pkg.players) do
			if pl.state ~= 'left' then players[#players + 1] = { player = pl.playerName, aircraft = pl.type, state = pl.state } end
		end
		rows[#rows + 1] = {
			package = id, target = pkg.target, ipNm = pkg.ipNm, ipToward = pkg.ipFrom,
			players = #players > 0 and FAI.json.array(players) or nil,
			pushInMin = not pkg.pushed and math.max(0, math.ceil((pkg.pushAt - t) / 60)) or nil,
			pushedMinAgo = pkg.pushed and round((t - pkg.pushAt) / 60) or nil,
			members = FAI.json.array(members),
		}
	end
	table.sort(rows, function(a, c) return a.package < c.package end)
	payload.packages = FAI.json.array(rows)
end

timer.scheduleFunction(function(_, t)
	local ok, err = pcall(tick)
	if not ok then FAI.warn('packages', 'tick failed: %s', tostring(err)) end
	return t + 5
end, nil, timer.getTime() + 5)

FAI.log('packages', 'ready (IP %d nm, hold from %d nm out, push %d-%d min)', cfg.ipNm, cfg.holdStartNm,
	cfg.minPushMin, cfg.maxPushMin)
