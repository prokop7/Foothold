---------------------------------------------------------------------------
-- Foothold AI - packages (phase 4)
-- Claude groups flights into a package with a push time. Each air flight of the
-- package, once it is on its way, holds in an orbit at the package's IP. At the
-- push time (or earlier, once every flight is holding) the flights are released
-- and continue their own Foothold mission, so they reach the target together
-- whatever their start-up and taxi times were.
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
	if pkg.pushed then return end
	-- Push early once every flight still flying is holding at the IP.
	if pkg.pushWhenReady and #pkg.members > 0 and t < pkg.pushAt then
		local holding, waiting = 0, 0
		for _, m in ipairs(pkg.members) do
			if m.state == 'holding' then holding = holding + 1 elseif m.state == 'waiting' then waiting = waiting + 1 end
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
			if done and t - pkg.pushAt > cfg.keepMin * 60 then list[id] = nil end
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
		members = {}, createdAt = now(),
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
		rows[#rows + 1] = {
			package = id, target = pkg.target, ipNm = pkg.ipNm, ipToward = pkg.ipFrom,
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
