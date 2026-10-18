---------------------------------------------------------------------------
-- Foothold AI - command
-- Claude commands the configured sides. This file:
--   1. takes decisions away from Foothold's Director, the RED reactive
--      system and the random event roller for those sides (no fallback);
--   2. executes Claude's orders with Foothold's own launch, purchase and
--      supply machinery (capabilities, free-form missions, purchases,
--      supply priorities and runs, BLUE player tasking, RED events);
--   3. runs Claude's standing orders instantly (scrambles, counterattacks);
--   4. sends a snapshot every cycle and after events, with the results of
--      previous orders, so Claude can plan the next cycle.
-- Player shop purchases, CTLD, AIEN and other player-facing systems are untouched.
---------------------------------------------------------------------------

local FAI = FootholdAI
if not (FAI and FAI.config and FAI.config.enabled) then return end
local cfg = FAI.config.command
if not cfg.enabled then
	FAI.log('command', 'disabled by config')
	return
end
if not (Director and Director.getForSide and BattleCommander and FAI.bridge) then
	FAI.warn('command', 'Foothold Director/BattleCommander or bridge missing - command mode disabled')
	return
end

local RED, BLUE = coalition.side.RED, coalition.side.BLUE
local SIDE_ID = { red = RED, blue = BLUE }
local SIDE_NAME = { [RED] = 'red', [BLUE] = 'blue', [0] = 'neutral' }
local NM = 1852

local X = {
	sides = {},
	authorized = {},      -- [groupName] = { at, orderId, side }
	missions = {},        -- [orderId] = mission record
	results = { red = {}, blue = {} },
	events = { red = {}, blue = {} },
	supplyPriority = { red = {}, blue = {} },
	playerTasks = {},     -- [role] = { zone, ... } (BLUE)
	taskCandidates = {},  -- [role] = { zone, ... } last offered by Foothold's generators
	standing = { red = {}, blue = {} },
	freeformSpecs = {},   -- [id] = spec, persisted
	lastRequestAt = {},
	awaiting = {},
	eventPending = {},
	readySince = {},
	building = {},
	orderCounter = 0,
}
FAI.command = X

for _, name in ipairs(cfg.sides) do
	if SIDE_ID[name] then X.sides[SIDE_ID[name]] = true end
end

function X.controls(side) return X.sides[side] == true end

-- The bridge must read orders for every commanded side.
do
	local polled = {}
	for _, name in ipairs(FAI.config.bridge.sides) do polled[name] = true end
	for side in pairs(X.sides) do
		if not polled[SIDE_NAME[side]] then table.insert(FAI.config.bridge.sides, SIDE_NAME[side]) end
	end
end

local function bcObj()
	local d = Director:getForSide(RED) or Director:getForSide(BLUE)
	return d and d.battleCommander or bc
end

local function round(x, step)
	step = step or 1
	return math.floor((tonumber(x) or 0) / step + 0.5) * step
end

local function zonePoint(z)
	if z._cz and z._cz.point then return z._cz.point end
	local ok, cz = pcall(CustomZone.getByName, CustomZone, z.zone)
	return ok and cz and cz.point or nil
end

local function zoneUsable(z)
	return z and z.active and not z.isHidden and (not z.suspended or z._idleSuspended)
end

local function pushLimited(list, item, limit)
	table.insert(list, 1, item)
	while #list > limit do table.remove(list) end
end

function X.event(sideName, kind, data)
	data = data or {}
	data.kind = kind
	data.minute = round(timer.getAbsTime() / 60)
	pushLimited(X.events[sideName], data, cfg.maxEvents)
end

function X.result(sideName, orderId, status, detail)
	pushLimited(X.results[sideName], {
		order = orderId, status = status, detail = detail, minute = round(timer.getAbsTime() / 60),
	}, cfg.maxResults)
	FAI.log('command', '%s order %s %s %s', sideName, tostring(orderId), status, tostring(detail or ''))
end

---------------------------------------------------------------------------
-- Method wrapping
---------------------------------------------------------------------------

local hooked = {}
local function pack(...) return { n = select('#', ...), ... } end

local function wrap(class, className, name, wrapper)
	local original = class[name]
	if type(original) ~= 'function' then
		FAI.warn('command', '%s.%s not found - hook skipped', className, name)
		return
	end
	hooked[#hooked + 1] = className .. '.' .. name
	class[name] = function(self, ...)
		return wrapper(original, self, ...)
	end
end

---------------------------------------------------------------------------
-- 1. Takeover: Director decisions for controlled sides return "nothing to do"
---------------------------------------------------------------------------

local NEUTRAL = {
	-- planning/launching loops (RED and BLUE)
	{ '_reconcileRoutineCaps', nil }, { '_updateRestoredCapStartup', nil },
	{ '_reconcileRoutineCapRevector', nil }, { '_updateGroundRelease', nil },
	{ '_startOperation', false }, { '_processPendingReaction', false },
	{ '_considerNormandyBomberLaunch', nil }, { '_adoptMassAttack', nil },
	{ '_reconcileBlueRoutinePatrolPosition', nil }, { '_blueAdoptActiveAttackMission', nil },
	{ '_blueReassessSupportFocus', nil }, { '_blueReconcileAssignments', nil },
	-- reactions requested by other Foothold systems
	{ 'requestReaction', 0 }, { 'requestReactiveCap', 0 },   -- callers compare these with numbers
	{ '_reconcileOperationCapacity', nil },
	{ 'requestEnemyPositionResponse', false }, { 'considerAIENAirSupport', false },
	{ 'considerCapturedZoneCasDiversion', false }, { 'requestZoneUpgrade', false },
	{ 'requestPlayerCapResponse', false },
}
for _, entry in ipairs(NEUTRAL) do
	local value = entry[2]
	wrap(Director, 'Director', entry[1], function(original, self, ...)
		if X.controls(self.side) then return value end
		return original(self, ...)
	end)
end

-- An operation restored from a save would keep launching; end it through
-- Foothold's own path the first time the Director updates it.
wrap(Director, 'Director', '_updateOperation', function(original, self, now, ...)
	if X.controls(self.side) then
		if self.operation then
			FAI.log('command', '%s: ending Foothold operation on %s restored from the save', SIDE_NAME[self.side],
				tostring(self.operation.targetZone))
			local ok, err = pcall(self._finishOperation, self, 'aborted', now)
			if not ok then
				FAI.warn('command', 'could not end restored operation: %s', tostring(err))
				self.operation = nil
			end
		end
		return
	end
	return original(self, now, ...)
end)

-- Purchases only when Claude ordered them.
wrap(Director, 'Director', '_executeStrategicBudgetCandidate', function(original, self, ...)
	if X.controls(self.side) and not X.allowPurchase then return false end
	return original(self, ...)
end)

-- Spawn gate: Director-gated groups of a controlled side fly only when Claude
-- authorized them. Supply, player/shop launches and save restores pass.
wrap(Director, 'Director', 'allowsGroupSpawn', function(original, self, gc)
	if not (gc and X.controls(self.side) and gc.side == self.side) then return original(self, gc) end
	if gc.mission == 'supply' or gc.playerGroundAttack == true or gc.ShopLaunchOnly == true
		or gc.forceSpawn == true or gc._pendingShopPurchase or gc._shopLaunchRequested == true
		or gc._pendingInAirRestore or gc._pendingSurfaceRestore
		or gc._pendingRestoreHeloRoutePlan or gc._pendingRestorePlaneRoutePlan then
		return true
	end
	if Director.LIVE_STATES and Director.LIVE_STATES[gc.state] then return true end
	return X.authorized[gc.name] ~= nil
end)

if BattleCommander._redReactiveTick then
	wrap(BattleCommander, 'BattleCommander', '_redReactiveTick', function(original, self, arg, time)
		if X.controls(RED) then
			local r = self.redReactive
			return time + ((r and r.config and r.config.tickSec) or 30)
		end
		return original(self, arg, time)
	end)
end

if EventCommander and EventCommander.chooseAndStart then
	wrap(EventCommander, 'EventCommander', 'chooseAndStart', function(original, self, ...)
		if X.controls(RED) then return nil end
		return original(self, ...)
	end)
end

---------------------------------------------------------------------------
-- 2. Executor
---------------------------------------------------------------------------

X.ROLES = {
	CAP = { template = 'CapPlaneTemplate', mission = 'patrol', missionType = 'CAP', type = 'air', alt = 'CapAltitude', price = 'dynamiccap' },
	SWEEP = { template = 'CapPlaneTemplate', mission = 'attack', missionType = 'CAP', type = 'air', alt = 'CapAltitude', price = 'dynamiccap' },
	CAS = { template = 'CasPlaneTemplate', mission = 'attack', missionType = 'CAS', type = 'air', alt = 'CasAltitude', price = 'dynamiccas' },
	CAS_HELO = { template = 'CasHeloTemplate', mission = 'attack', missionType = 'CAS', type = 'air', alt = 'CasAltitude', price = 'dynamiccas' },
	SEAD = { template = 'SeadPlaneTemplate', mission = 'attack', missionType = 'SEAD', type = 'air', alt = 'SeadAltitude', price = 'dynamicsead' },
	RUNWAY_STRIKE = { template = 'RunwayStrikePlaneTemplate', mission = 'attack', missionType = 'RUNWAYSTRIKE', type = 'air', alt = 'RunwayStrikeAltitude', price = 'dynamicbomb' },
	CONVOY = { template = 'AttackConvoy', mission = 'attack', type = 'surface', price = 'groundattack' },
	ARTY = { template = 'ArtilleryConvoyLong', mission = 'attack', missionType = 'ARTY', type = 'surface', price = 'groundattack' },
}

-- A price is a Foothold shop id (that item's ShopPrices price) or a number; x priceScale.
function X.shopPrice(key)
	local base = tonumber(key)
	if not base then
		base = type(ShopPrices) == 'table' and tonumber(ShopPrices[key]) or nil
		base = base or tonumber(cfg.fallbackPrices[key]) or 1000
	end
	return math.max(0, math.floor(base * (cfg.priceScale or 1)))
end

function X.priceFor(roleName)
	local role = X.ROLES[roleName]
	return X.shopPrice(role and role.price or 'groundattack')
end

local function availableCredits(side)
	local b = bcObj()
	local reserved = b._getPendingShopReservedCredits and b:_getPendingShopReservedCredits(side) or 0
	return (tonumber(b.accounts[side]) or 0) - reserved
end

---------------------------------------------------------------------------
-- Economy: each side has one Foothold account (bc.accounts). Claude's orders
-- are paid from it; RED earns like a player team (zone income, kills, captures).
---------------------------------------------------------------------------

local econ = cfg.economy or {}
X.ledger = { red = {}, blue = {} }
X.flow = { red = { spent = 0, earned = 0, refunded = 0 }, blue = { spent = 0, earned = 0, refunded = 0 } }
X.lastCredits = {}
X.unpaidKills = {}   -- [unitName] = { side, amount, kills }: air kills, paid on landing

function X.book(side, amount, what, refund)
	local sideName = SIDE_NAME[side]
	if not X.ledger[sideName] or amount == 0 then return end
	pushLimited(X.ledger[sideName], { minute = round(timer.getAbsTime() / 60), amount = round(amount), what = what },
		econ.ledgerSize or 25)
	local f = X.flow[sideName]
	if refund then f.refunded = f.refunded + amount
	elseif amount < 0 then f.spent = f.spent - amount
	else f.earned = f.earned + amount end
end

-- nil when the side can pay, else the reason it cannot.
function X.needCredits(side, price)
	if availableCredits(side) < price then
		return string.format('not enough credits (need %d, have %d)', price, round(availableCredits(side)))
	end
	return nil
end

function X.charge(side, amount, what)
	amount = math.max(0, math.floor(tonumber(amount) or 0))
	if amount == 0 then return end
	bcObj():addFunds(side, -amount)
	X.book(side, -amount, what)
end

function X.credit(side, amount, what)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return end
	bcObj():addFunds(side, amount)
	X.book(side, amount, what)
end

-- Gives back what an order cost when it never happened (spawn denied, never launched).
function X.refund(side, amount, what)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return end
	bcObj():addFunds(side, amount)
	X.book(side, amount, 'refund: ' .. what, true)
end

local function refundMission(m, why)
	if not m or m.refunded or not m.cost then return end
	m.refunded = true
	X.refund(m.side, m.cost, why .. ' (' .. tostring(m.group) .. ')')
end

local function econOn(list, side)
	return X.controls(side) and type(list) == 'table' and list[SIDE_NAME[side]] == true
end

-- Same amounts a player gets for the kill (RewardContribution in the setup file).
local function killReward(target)
	local r = bcObj().rewards or {}
	local okCat, cat = pcall(target.getCategory, target)
	if okCat and Object and Object.Category and cat == Object.Category.STATIC then
		return tonumber(r.structure) or 100, 'structure'
	end
	local okD, desc = pcall(target.getDesc, target)
	if not okD or type(desc) ~= 'table' then return nil end
	local c = desc.category
	if c == 0 then return tonumber(r.airplane) or 50, 'aircraft' end
	if c == 1 then return tonumber(r.helicopter) or 50, 'helicopter' end
	if c == 3 then return tonumber(r.ship) or 200, 'ship' end
	if c == 2 then
		local function has(a) local ok, v = pcall(target.hasAttribute, target, a) return ok and v end
		if has('Infantry') then return tonumber(r.infantry) or 10, 'infantry' end
		if has('SAM elements') or has('SAM SR') or has('SAM TR') then return tonumber(r.sam) or 30, 'SAM' end
		return tonumber(r.ground) or 10, 'ground unit'
	end
	return nil
end

local function onKill(e)
	local killer, target = e.initiator, e.target
	if not (killer and target) then return end
	local okS, side = pcall(killer.getCoalition, killer)
	local okT, targetSide = pcall(target.getCoalition, target)
	if not (okS and okT) or side == targetSide or (targetSide ~= RED and targetSide ~= BLUE) then return end
	if not econOn(econ.killRewards, side) then return end
	local okP, player = pcall(killer.getPlayerName, killer)
	if okP and player then return end   -- players are paid by Foothold
	local amount, label = killReward(target)
	if not amount or amount <= 0 then return end
	amount = math.floor(amount * (econ.rewardScale or 1))
	local okN, killerName = pcall(killer.getName, killer)
	local okA, airborne = pcall(killer.inAir, killer)
	if econ.airKillsPaidOnLanding ~= false and okA and airborne and okN then
		local u = X.unpaidKills[killerName] or { side = side, amount = 0, kills = 0 }
		u.amount, u.kills = u.amount + amount, u.kills + 1
		X.unpaidKills[killerName] = u
	else
		X.credit(side, amount, label .. ' destroyed')
	end
end

local function settleKills(unitName, landed)
	local u = X.unpaidKills[unitName]
	if not u then return end
	X.unpaidKills[unitName] = nil
	if landed then
		X.credit(u.side, u.amount, string.format('%d kills paid on landing (%s)', u.kills, unitName))
	else
		X.credit(u.side, math.floor(u.amount * (econ.lostAircraftKeeps or 0)),
			string.format('%d kills, aircraft lost (%s)', u.kills, unitName))
	end
end

-- An aircraft removed without a landing or loss event (e.g. despawned) counts as lost.
local function pruneUnpaidKills()
	for name in pairs(X.unpaidKills) do
		local unit = Unit and Unit.getByName and Unit.getByName(name)
		if not (unit and unit:isExist()) then settleKills(name, false) end
	end
end

local LOST_EVENTS = {}
for _, k in ipairs({ 'S_EVENT_DEAD', 'S_EVENT_CRASH', 'S_EVENT_PILOT_DEAD', 'S_EVENT_EJECTION', 'S_EVENT_UNIT_LOST' }) do
	if world.event[k] then LOST_EVENTS[world.event[k]] = true end
end

world.addEventHandler({ onEvent = function(_, e)
	if not e or not e.id then return end
	local ok, err = true, nil
	if e.id == world.event.S_EVENT_KILL then
		ok, err = pcall(onKill, e)
	elseif e.initiator and (e.id == world.event.S_EVENT_LAND or LOST_EVENTS[e.id]) then
		local okN, name = pcall(e.initiator.getName, e.initiator)
		if okN and name and X.unpaidKills[name] then
			ok, err = pcall(settleKills, name, e.id == world.event.S_EVENT_LAND)
		end
	end
	if not ok then FAI.warn('command', 'economy event failed: %s', tostring(err)) end
end })

local function economyRow(side, b)
	local sideName = SIDE_NAME[side]
	local zoneIncome = 0
	for _, z in ipairs(b.zones) do
		if z.side == side and z.active and not (z.redIncomeOnly and side ~= RED) then
			zoneIncome = zoneIncome + (tonumber(z.income) or 0)
		end
	end
	local updateFrequency = math.max(1, tonumber(b.updateFrequency) or 10)
	local unpaid = 0
	for _, u in pairs(X.unpaidKills) do if u.side == side then unpaid = unpaid + u.amount end end
	local credits = round(availableCredits(side))
	local f = X.flow[sideName]
	local fee = tonumber((econ.capabilityFee or {})[sideName]) or 0
	local row = {
		credits = credits,
		creditsCap = tonumber(b.creditsCap),
		incomePerMinute = round(zoneIncome * 60 / updateFrequency + (tonumber((econ.bonusIncomePerMin or {})[sideName]) or 0)),
		sinceLastSnapshot = {
			spentOnOrders = round(f.spent), earnedFromCombat = round(f.earned),
			refunded = f.refunded > 0 and round(f.refunded) or nil,
			netChange = X.lastCredits[sideName] and (credits - X.lastCredits[sideName]) or nil,
		},
		unpaidAirKills = unpaid > 0 and round(unpaid) or nil,
		killRewards = econOn(econ.killRewards, side) or nil,
		capabilityFee = fee > 0 and fee or nil,
		ledger = FAI.json.array(X.ledger[sideName]),
	}
	X.flow[sideName] = { spent = 0, earned = 0, refunded = 0 }
	X.lastCredits[sideName] = credits
	return row
end

local function bonusIncomeTick(dt)
	for side in pairs(X.sides) do
		local perMin = tonumber((econ.bonusIncomePerMin or {})[SIDE_NAME[side]]) or 0
		if perMin > 0 then bcObj():addFunds(side, perMin * dt / 60) end
	end
end

local CAP_FEE_KEYS = { CAP = 'dynamiccap', CAS = 'dynamiccas', SEAD = 'dynamicsead', RUNWAYSTRIKE = 'dynamicbomb' }

local function capabilityFee(side, role)
	local frac = tonumber((econ.capabilityFee or {})[SIDE_NAME[side]]) or 0
	if frac <= 0 then return 0 end
	return math.floor(X.shopPrice(CAP_FEE_KEYS[role] or 'groundattack') * frac)
end

-- Template sets (Foothold globals such as CapPlaneTemplate, or dc.SETS) and their sides.
local function templateSet(key)
	local g = _G[key]
	if type(g) == 'table' and type(g[1]) == 'string' then return g end
	local s = dc and dc.SETS and dc.SETS[key]
	if type(s) == 'table' and type(s[1]) == 'string' then return s end
	return nil
end

function X.templateSide(name)
	if type(ResolveTemplateSide) == 'function' then
		local ok, s = pcall(ResolveTemplateSide, name)
		if ok and (s == RED or s == BLUE) then return s end
	end
	local entry = _DATABASE and _DATABASE.Templates and _DATABASE.Templates.Groups[name]
	return entry and entry.CoalitionID or nil
end

-- Foothold resolves a capability's side from a template set; a single ME group
-- chosen by Claude is published as a one-element set.
function X.templateKey(template)
	if templateSet(template) then return template end
	local key = 'FootholdAI_TPL_' .. tostring(template):gsub('[^%w]+', '_')
	_G[key] = { template }
	return key
end

function X.roleTemplates(roleName, side)
	local role = X.ROLES[roleName]
	local out = {}
	for _, name in ipairs(role and templateSet(role.template) or {}) do
		if X.templateSide(name) == side then out[#out + 1] = name end
	end
	return out
end

local function findLaunchable(ref)
	local b = bcObj()
	local cap = b.directorCapabilitiesById and b.directorCapabilitiesById[ref]
	if cap then return cap, b.directorInstanceByCapabilityId and b.directorInstanceByCapabilityId[cap.id] end
	for _, z in ipairs(b.zones or {}) do
		for _, gc in ipairs(z.groups or {}) do
			if gc.name == ref then return nil, gc end
		end
	end
	return nil, nil
end

function X.missionKey(side, orderId) return SIDE_NAME[side] .. '/' .. tostring(orderId) end

local function trackMission(side, order, gc, extra)
	local m = {
		order = order.id, side = side, group = gc.name, gc = gc,
		capability = order.capability, origin = gc.zoneCommander and gc.zoneCommander.zone,
		target = gc.targetzone, role = gc.MissionType or gc.mission, launchedAt = timer.getAbsTime(),
		status = gc.state, source = order.source,
	}
	for k, v in pairs(extra or {}) do m[k] = v end
	local key = X.missionKey(side, order.id)
	X.missions[key] = m
	X.authorized[gc.name] = { at = timer.getAbsTime(), orderId = key, side = side }
	return m
end

function X.supplyRun(side, order)
	local b = bcObj()
	local cap, gc = findLaunchable(order.capability)
	local candidate = gc or (cap and b:_directorCapabilityCandidateView(cap))
	if not candidate then return false, 'unknown supply capability' end
	if (cap and cap.mission or candidate.mission) ~= 'supply' then return false, 'not a supply capability' end
	local origin = (cap and cap.zoneCommander) or candidate.zoneCommander
	if not origin or origin.side ~= side then return false, 'origin not held' end
	local ok, dispatched = pcall(b._dispatchRegularSupplyCommander, b, candidate, timer.getAbsTime(), {},
		b:_buildRegularSupplyCommitmentSnapshot())
	if not ok then return false, 'dispatch error: ' .. tostring(dispatched) end
	if not dispatched then return false, 'no supply stock ready at origin or target does not need supply' end
	return true, 'supply run dispatched from ' .. origin.zone
end

function X.launchCapability(side, order)
	local b = bcObj()
	local d = Director:getForSide(side)
	local cap, gc = findLaunchable(order.capability)
	if not cap and not gc then return false, 'unknown capability' end
	local origin = cap and cap.zoneCommander or gc.zoneCommander
	if not origin or origin.side ~= side or not zoneUsable(origin) then return false, 'origin zone not held' end
	if (cap and cap.mission or gc.mission) == 'supply' then return X.supplyRun(side, order) end
	if gc and (Director.LIVE_STATES[gc.state] or gc.state == 'preparing') then
		return false, 'already active (' .. tostring(gc.state) .. ')'
	end
	local targetZone = order.targetZone or (cap and cap.targetzone or gc.targetzone)
	local tz = b:getZoneByName(targetZone)
	if not tz or not tz.active or tz.isHidden then return false, 'unknown target zone' end
	-- A free-form mission launched again costs its full price again.
	local spec = cap and cap.footholdAI and X.freeformSpecs[cap.id]
	local fee
	if order.freeform then fee = 0
	elseif spec then fee = X.priceFor(spec.role)
	else fee = capabilityFee(side, cap and cap.MissionType or gc.MissionType) end
	if targetZone ~= (cap and cap.targetzone or gc.targetzone) then
		local okR, role = pcall(d._groupRole, d, gc or cap)
		if not (okR and d:_canRetaskAirRole(role)) then
			return false, 'role ' .. tostring(role) .. ' cannot be sent to another target'
		end
	end
	if fee > 0 then
		local short = X.needCredits(side, fee)
		if short then return false, short end
	end
	local now = timer.getAbsTime()
	if cap then
		local request = { targetZone = targetZone }
		local eligible, reason = b:evaluateDirectorSpawnEligibility(cap, request)
		if eligible ~= true then return false, 'not eligible: ' .. tostring(reason or 'no aircraft/stock or blocked') end
		local candidate = gc or b:_directorCapabilityCandidateView(cap)
		request._directorEligibilityApproved = true
		gc = b:resolveDirectorCandidate(candidate, request)
		if not gc then return false, 'activation denied' end
	end
	if targetZone ~= gc.targetzone then d:_retaskGroupForAssignment(gc, targetZone, nil) end
	X.authorized[gc.name] = { at = now, orderId = X.missionKey(side, order.id), side = side }
	local ok
	if gc._directorOnDemand == true then
		ok = b:_authorizeDirectorOnDemandGroup(gc, now, d)
	else
		ok = b:_redReactiveFastForwardGroup(gc, now)
	end
	if not ok then
		X.authorized[gc.name] = nil
		if gc._directorRetaskOriginalTargetZone or gc._directorRetaskOriginalMission then
			pcall(d._restoreRetaskedGroup, d, gc)
		end
		if cap and gc._directorOnDemand == true then pcall(b.requestDirectorInstanceDisposal, b, gc) end
		return false, 'group not ready (state ' .. tostring(gc.state) .. ')'
	end
	local m = trackMission(side, order, gc)
	if fee > 0 then
		X.charge(side, fee, (spec and 'relaunch ' or 'sortie ') .. gc.name)
		m.cost = fee
	end
	return true, string.format('%s from %s to %s%s', gc.name, origin.zone, targetZone,
		fee > 0 and string.format(' (fee %d)', fee) or '')
end

local function sanitizeId(s) return (tostring(s):gsub('[^%w]+', '_')) end

local function registerFreeform(spec)
	local b = bcObj()
	if b.directorCapabilitiesById[spec.id] then return b.directorCapabilitiesById[spec.id] end
	local origin = b:getZoneByName(spec.origin)
	if not origin then return nil, 'unknown origin' end
	local cap = DirectorCapability:new({
		id = spec.id, name = spec.id, mission = spec.mission, MissionType = spec.missionType,
		template = spec.template and X.templateKey(spec.template), targetzone = spec.target, type = spec.type,
		Altitude = spec.altitude,
		footholdAI = true,
	})
	local ok, err = pcall(b.registerDirectorCapability, b, origin, cap)
	if not ok then return nil, tostring(err) end
	return cap
end

local function saveFreeformSpecs()
	if not FAI.dir then return end
	local b = bcObj()
	local key = sanitizeId((env.mission and env.mission.theatre or 'x') .. '_' .. tostring(b.saveFile))
	FAI.writeDataFile(FAI.dir .. 'freeform_' .. key .. '.lua', X.freeformSpecs)
end

local function loadFreeformSpecs()
	if not FAI.dir then return end
	local b = bcObj()
	if not b then return end
	local key = sanitizeId((env.mission and env.mission.theatre or 'x') .. '_' .. tostring(b.saveFile))
	local specs = FAI.loadDataFile(FAI.dir .. 'freeform_' .. key .. '.lua')
	local count = 0
	for id, spec in pairs(specs or {}) do
		if registerFreeform(spec) then
			X.freeformSpecs[id] = spec
			count = count + 1
		end
	end
	if count > 0 then FAI.log('command', 're-registered %d free-form capabilities', count) end
end

function X.launchMission(side, order)
	local b = bcObj()
	local role = X.ROLES[order.role]
	if not role then return false, 'unknown role ' .. tostring(order.role) end
	local origin = b:getZoneByName(order.origin)
	if not origin or origin.side ~= side or not zoneUsable(origin) then return false, 'origin zone not held' end
	local target = b:getZoneByName(order.targetZone)
	if not target or not target.active or target.isHidden then return false, 'unknown target zone' end
	if role.type == 'air' then
		if order.role == 'CAS_HELO' then
			local helos = (origin.facility == 'airbase' or origin.facility == 'farp' or origin.facility == 'carrier')
				and origin.isHeloSpawn
			if not helos then return false, origin.zone .. ' cannot launch helicopters' end
		elseif not b:_zoneSupportsPlaneSpawn(origin) then
			return false, origin.zone .. ' cannot launch aircraft'
		end
	end
	if not b:_templateSetSupportsSide(role.template, side) then
		return false, 'no ' .. order.role .. ' aircraft/vehicles configured for this side'
	end
	local template = role.template
	if order.template ~= nil then
		local allowed = false
		for _, name in ipairs(X.roleTemplates(order.role, side)) do
			if name == order.template then allowed = true break end
		end
		if not allowed then return false, 'template ' .. tostring(order.template) .. ' is not a ' .. order.role .. ' template of this side' end
		template = order.template
	end
	local price = X.priceFor(order.role)
	local short = X.needCredits(side, price)
	if short then return false, short end
	local id = string.format('FAI-%s-%s-%s-%s', SIDE_NAME[side], sanitizeId(origin.zone), sanitizeId(target.zone), order.role)
	if template ~= role.template then id = id .. '-' .. sanitizeId(template) end
	local spec = X.freeformSpecs[id]
	if not spec then
		local altFn = role.alt and _G[role.alt]
		spec = { id = id, origin = origin.zone, target = target.zone, mission = role.mission,
			missionType = role.missionType, template = template, type = role.type,
			altitude = type(altFn) == 'function' and altFn() or nil, role = order.role }
	end
	local cap, err = registerFreeform(spec)
	if not cap then return false, 'cannot create mission: ' .. tostring(err) end
	if not X.freeformSpecs[id] then
		X.freeformSpecs[id] = spec
		saveFreeformSpecs()
	end
	local launched, detail = X.launchCapability(side, { id = order.id, capability = id, source = order.source, freeform = true })
	if not launched then return false, detail end
	X.charge(side, price, string.format('%s %s -> %s', order.role, origin.zone, target.zone))
	local m = X.missions[X.missionKey(side, order.id)]
	if m then m.cost = price end
	return true, detail .. string.format(' (cost %d)', price)
end

-- RED purchases go through the Director's own purchase code.
wrap(Director, 'Director', 'selectZoneUpgradeTarget', function(original, self, zoneChoices, context, now)
	local req = X.upgradeRequest
	if not req or not X.controls(self.side) then return original(self, zoneChoices, context, now) end
	for _, choice in ipairs(zoneChoices or {}) do
		if choice.zone and choice.zone.zone == req.zone then
			if not req.category then return choice end
			local pool = choice.upgradePools and choice.upgradePools[req.category]
			if type(pool) == 'table' and #pool > 0 then
				return { zone = choice.zone, slot = pool[math.random(1, #pool)],
					upgradeCounts = choice.upgradeCounts, upgradePools = choice.upgradePools }
			end
			req.failure = 'no ' .. req.category .. ' upgrade available for ' .. req.zone
			return nil
		end
	end
	req.failure = req.zone .. ' cannot take another upgrade (slot limit, cooldown or occupied)'
	return nil
end)

X.UPGRADE_CATEGORIES = { sam = true, shorad = true, aaa = true, armor = true, ground = true, arty = true }

function X.purchase(side, order)
	if side ~= RED then return false, 'purchases are RED only (BLUE credits belong to the players)' end
	local d = Director:getForSide(side)
	local b = bcObj()
	local now = timer.getAbsTime()
	local action = order.item
	local shopItem, itemId = d:_strategicShopEntry(action)
	if not shopItem then return false, 'shop item ' .. tostring(action) .. ' not available in this mission' end
	if now < (d.strategicSpendCooldownUntil or 0) then
		return false, string.format('purchase cooldown %d s', round(d.strategicSpendCooldownUntil - now))
	end
	local candidate = { action = action, itemId = itemId, cost = shopItem.cost, urgency = 1, score = 0 }
	if action == 'upgrade' then
		local z = b:getZoneByName(order.zone)
		if not z or z.side ~= side then return false, 'upgrade zone must be a RED zone' end
		if order.category and not X.UPGRADE_CATEGORIES[order.category] then return false, 'unknown category' end
		if not d:zoneUpgradePurchaseAllowed(now) then return false, 'zone upgrade cooldown' end
		candidate.category = order.category
		candidate.context = { reason = 'footholdai' }
		X.upgradeRequest = { zone = order.zone, category = order.category }
	elseif action == 'warehouse' or action == 'warehouse_repair' then
		local z = b:getZoneByName(order.zone)
		if not z or z.side ~= side then return false, 'depot zone must be a RED zone' end
		candidate.zoneRef = z
	elseif action == 'mass_attack' or action == 'bomber' then
		if action == 'mass_attack' and now < (X.massAttackReadyAt or 0) then
			return false, string.format('mass attack possible again in %d min', math.ceil((X.massAttackReadyAt - now) / 60))
		end
		local targets = {}
		for _, name in ipairs(order.targets or {}) do
			local z = b:getZoneByName(name)
			if z and z.side ~= side and z.active then targets[#targets + 1] = name end
		end
		if #targets == 0 then return false, 'needs at least one valid enemy target zone' end
		candidate.preferredTargetNames = targets
		candidate.playerCount = getBluePlayersCount and getBluePlayersCount() or 0
		candidate.strategicTarget = d:_strategicObjectiveCandidate(targets[1])
	else
		return false, 'unknown item'
	end
	X.allowPurchase = true
	local ok, purchased, where, cost = pcall(d._executeStrategicBudgetCandidate, d, candidate, now)
	X.allowPurchase = false
	local failure = X.upgradeRequest and X.upgradeRequest.failure
	X.upgradeRequest = nil
	if not ok then return false, 'purchase error: ' .. tostring(purchased) end
	if not purchased then return false, failure or 'purchase refused (credits, cooldown or no valid placement)' end
	X.book(side, -(tonumber(cost) or tonumber(shopItem.cost) or 0), 'purchase ' .. action .. ' ' .. tostring(where or ''))
	if action == 'mass_attack' then X.massAttackReadyAt = now + (cfg.massAttackCooldownSec or 3600) end
	return true, string.format('%s at %s for %s', action, tostring(where or order.zone or ''), tostring(cost or shopItem.cost))
end

-- Supply priorities feed Foothold's own dispatcher.
wrap(BattleCommander, 'BattleCommander', '_regularSupplyTargetPriority', function(original, self, side, targetZone, ...)
	local facts = original(self, side, targetZone, ...)
	if X.controls(side) and type(facts) == 'table' and targetZone then
		local p = X.supplyPriority[SIDE_NAME[side]][targetZone.zone]
		if p == 'none' then
			facts.unfilled = 0
		elseif p and cfg.supplyBonus[p] then
			facts.priority = (facts.priority or 0) + cfg.supplyBonus[p]
		end
	end
	return facts
end)

-- BLUE player tasking: Claude's designated zones per role.
wrap(Director, 'Director', 'selectMissionTarget', function(original, self, role, candidates, context)
	if self.side ~= BLUE or not X.controls(BLUE) or role == 'ATTACK' then
		if X.controls(self.side) and role == 'ATTACK' then return nil end
		return original(self, role, candidates, context)
	end
	local seen = {}
	for _, c in ipairs(candidates or {}) do
		local ok, z = pcall(self._blueCandidateZone, self, c)
		if ok and z then seen[#seen + 1] = z.zone end
	end
	X.taskCandidates[role] = seen
	for _, zoneName in ipairs(X.playerTasks[role] or {}) do
		for _, c in ipairs(candidates or {}) do
			local ok, z = pcall(self._blueCandidateZone, self, c)
			if ok and z and z.zone == zoneName then return c end
		end
	end
	return nil
end)

X.eventReadyAt = {}

function X.eventPrice(id)
	local p = cfg.prices or {}
	return X.shopPrice((p.events or {})[id] or p.event or 1000)
end

local function triggerEvent(side, order)
	if side ~= RED then return false, 'scripted events are RED only' end
	if not (evc and evc.events) then return false, 'no event commander in this mission' end
	for _, ev in ipairs(evc.events) do
		if ev.id == order.event and ev.StrikeMission ~= true then
			local now = timer.getAbsTime()
			local readyAt = X.eventReadyAt[ev.id] or 0
			if now < readyAt then
				return false, string.format('%s possible again in %d min', ev.id, math.ceil((readyAt - now) / 60))
			end
			local price = X.eventPrice(ev.id)
			local short = X.needCredits(side, price)
			if short then return false, short end
			local okCan, can = pcall(ev.canExecute, ev)
			if not okCan or not can then return false, 'event cannot run now' end
			local okRun, err = pcall(ev.action, ev)
			if not okRun then return false, 'event error: ' .. tostring(err) end
			X.eventReadyAt[ev.id] = now + (cfg.eventCooldownSec or 3600)
			X.charge(side, price, 'event ' .. ev.id)
			return true, string.format('event %s started (cost %d)', order.event, price)
		end
	end
	return false, 'unknown event'
end

local executors = {
	launch_capability = X.launchCapability,
	launch_mission = X.launchMission,
	supply_run = X.supplyRun,
	purchase = X.purchase,
	trigger_event = triggerEvent,
	supply_priority = function(side, order)
		local z = bcObj():getZoneByName(order.zone)
		if not z then return false, 'unknown zone' end
		local p = order.priority
		if p ~= 'high' and p ~= 'normal' and p ~= 'low' and p ~= 'none' then return false, 'bad priority' end
		X.supplyPriority[SIDE_NAME[side]][order.zone] = p ~= 'normal' and p or nil
		return true, order.zone .. ' supply ' .. p
	end,
	player_tasks = function(side, order)
		if side ~= BLUE then return false, 'player tasking is BLUE only' end
		if type(order.role) ~= 'string' then return false, 'role required' end
		local zones = {}
		for _, name in ipairs(order.zones or {}) do
			if type(name) == 'string' then zones[#zones + 1] = name end
		end
		X.playerTasks[order.role] = zones
		return true, order.role .. ': ' .. table.concat(zones, ', ')
	end,
	hq_message = function(side, order)
		if side ~= BLUE or type(order.text) ~= 'string' then return false, 'BLUE HQ text only' end
		trigger.action.outTextForCoalition(BLUE, 'HQ: ' .. order.text:sub(1, 400), 25)
		return true, 'sent'
	end,
	standing_orders = function(side, order)
		return X.setStandingOrders(SIDE_NAME[side], order.rules)
	end,
	cancel_orders = function(side, order)
		local done, unknown = {}, {}
		for _, id in ipairs(type(order.ids) == 'table' and order.ids or {}) do
			local key = X.missionKey(side, id)
			if X.scheduled[key] then
				X.scheduled[key] = nil
				done[#done + 1] = tostring(id)
			else
				unknown[#unknown + 1] = tostring(id)
			end
		end
		local detail = 'cancelled: ' .. (#done > 0 and table.concat(done, ', ') or 'none')
		if #unknown > 0 then detail = detail .. '; not pending: ' .. table.concat(unknown, ', ') end
		return #done > 0, detail
	end,
}
X.scheduled = {}   -- [side/orderId] = { order, dueAt } delayed orders not yet executed

X.executors = executors
X.snapshotExtensions = {}
X.util = { bcObj = bcObj, round = round, zonePoint = zonePoint, zoneUsable = zoneUsable, wrap = wrap,
	sanitizeId = sanitizeId, availableCredits = availableCredits, pushLimited = pushLimited,
	SIDE_NAME = SIDE_NAME, SIDE_ID = SIDE_ID }

function X.execute(side, order)
	local fn = executors[order.type]
	if not fn then return false, 'unknown order type ' .. tostring(order.type) end
	local ok, success, detail = pcall(fn, side, order)
	if not ok then return false, 'error: ' .. tostring(success) end
	return success, detail
end

function X.nextOrderId(prefix)
	X.orderCounter = X.orderCounter + 1
	return string.format('%s%d', prefix or 'o', X.orderCounter)
end

---------------------------------------------------------------------------
-- Mission tracking
---------------------------------------------------------------------------

wrap(Director, 'Director', 'onGroupStateChanged', function(original, self, gc, previousState, currentState, wasSpawned, isSpawned)
	local results = pack(original(self, gc, previousState, currentState, wasSpawned, isSpawned))
	local auth = gc and X.authorized[gc.name]
	if auth then
		local m = X.missions[auth.orderId]
		if m then m.status = currentState end
		local wasLive = Director.LIVE_STATES[previousState] or wasSpawned == true
		if (currentState == 'dead' or currentState == 'inhangar') and (wasLive or previousState == 'preparing') then
			X.authorized[gc.name] = nil
			if m then
				m.endedAt = timer.getAbsTime()
				m.outcome = (previousState == 'preparing' and not wasSpawned) and 'spawn-failed'
					or (currentState == 'dead' and 'lost' or 'returned')
				if m.outcome == 'spawn-failed' then refundMission(m, 'spawn failed') end
				X.event(SIDE_NAME[m.side], 'mission_ended', { order = m.order, group = m.group,
					target = m.target, outcome = m.outcome })
			end
		end
	end
	return unpack(results, 1, results.n)
end)

wrap(Director, 'Director', 'onManagedSpawnDenied', function(original, self, gc, reason, ...)
	local auth = gc and X.authorized[gc.name]
	if auth and X.controls(self.side) then
		X.authorized[gc.name] = nil
		local m = X.missions[auth.orderId]
		if m then
			m.status, m.outcome, m.endedAt = 'denied', tostring(reason), timer.getAbsTime()
			refundMission(m, 'launch denied: ' .. tostring(reason))
		end
		X.event(SIDE_NAME[self.side], 'launch_denied', { order = auth.orderId, group = gc.name, reason = tostring(reason) })
		-- Same clean-up the Director does for a denied routine CAP, so the
		-- capability can be launched again later.
		gc._spawnEvalCache, gc._spawnEvalLast = nil, nil
		if gc._directorRetaskOriginalTargetZone or gc._directorRetaskOriginalMission then
			self:_restoreRetaskedGroup(gc)
		end
		if gc._directorOnDemand == true then
			self.battleCommander:requestDirectorInstanceDisposal(gc)
		end
		return true
	end
	return original(self, gc, reason, ...)
end)

local function expireAuthorizations()
	local now = timer.getAbsTime()
	for name, auth in pairs(X.authorized) do
		local m = X.missions[auth.orderId]
		local gc = m and m.gc
		local live = gc and (Director.LIVE_STATES[gc.state] or gc.Spawned == true)
		if not live and now - auth.at > cfg.authorizationTimeoutSec then
			X.authorized[name] = nil
			if m then
				m.status, m.outcome, m.endedAt = 'expired', 'never launched', now
				refundMission(m, 'never launched')
			end
		end
	end
end

---------------------------------------------------------------------------
-- 3. Standing orders
---------------------------------------------------------------------------

X.TRIGGERS = { enemy_air_near = true, zone_attacked = true, zone_lost = true }

function X.setStandingOrders(sideName, rules)
	local side = SIDE_ID[sideName]
	local b = bcObj()
	local out, rejected = {}, {}
	for i, r in ipairs(type(rules) == 'table' and rules or {}) do
		local problem
		if #out >= cfg.maxStandingOrders then problem = 'over the limit of ' .. cfg.maxStandingOrders .. ' rules'
		elseif type(r) ~= 'table' or not X.TRIGGERS[r.trigger] then problem = 'bad trigger'
		elseif r.zone ~= '*' and not b:getZoneByName(r.zone or '') then problem = 'unknown zone'
		elseif r.trigger == 'zone_attacked' and side ~= RED then problem = 'zone_attacked is reported for RED zones only'
		elseif type(r.action) ~= 'table' or (r.action.type ~= 'launch_capability' and r.action.type ~= 'launch_mission') then
			problem = 'action must be launch_capability or launch_mission'
		end
		if problem then
			rejected[#rejected + 1] = tostring(type(r) == 'table' and r.id or i) .. ': ' .. problem
		else
			out[#out + 1] = {
				-- ASCII only, so cutting to 40 bytes never splits a character
				id = type(r.id) == 'string' and (r.id:gsub('[^%w%-_]', '_')):sub(1, 40) or ('rule' .. i),
				trigger = r.trigger, zone = r.zone,
				radiusNm = math.max(5, math.min(150, tonumber(r.radiusNm) or 40)),
				minContacts = math.max(1, math.floor(tonumber(r.minContacts) or 1)),
				cooldownSec = math.max(60, tonumber(r.cooldownSec) or 600),
				maxActive = math.max(1, math.min(4, math.floor(tonumber(r.maxActive) or 1))),
				action = r.action, lastFiredAt = 0, fired = 0,
			}
		end
	end
	X.standing[sideName] = out
	local detail = string.format('%d standing orders active', #out)
	if #rejected > 0 then detail = detail .. '; rejected: ' .. table.concat(rejected, '; ') end
	return true, detail
end

local function activeFromRule(sideName, ruleId)
	local n = 0
	for _, m in pairs(X.missions) do
		if m.source == sideName .. ':' .. ruleId and not m.endedAt then n = n + 1 end
	end
	return n
end

local function fireRule(sideName, rule, zoneName, why)
	local now = timer.getAbsTime()
	if now - rule.lastFiredAt < rule.cooldownSec then return end
	if activeFromRule(sideName, rule.id) >= rule.maxActive then return end
	rule.lastFiredAt = now
	rule.fired = rule.fired + 1
	local order = {}
	for k, v in pairs(rule.action) do order[k] = v end
	if order.targetZone == '$zone' then order.targetZone = zoneName end
	order.id = X.nextOrderId('s')
	order.source = sideName .. ':' .. rule.id
	local ok, detail = X.execute(SIDE_ID[sideName], order)
	X.result(sideName, order.id, ok and 'executed' or 'rejected',
		string.format('standing order %s (%s at %s): %s', rule.id, why, tostring(zoneName), tostring(detail)))
	X.event(sideName, 'standing_order_fired', { rule = rule.id, zone = zoneName, reason = why, ok = ok })
	X.eventPending[sideName] = true
end

local function detectedEnemyAir(sideName)
	if not (ewrs and ewrs.findDetectedTargets) then return {} end
	local ok, objects = pcall(ewrs.findDetectedTargets, sideName == 'red' and 'blue' or 'red')
	return ok and type(objects) == 'table' and objects or {}
end

local function standingTick()
	local b = bcObj()
	for sideName, rules in pairs(X.standing) do
		local airRules = {}
		for _, r in ipairs(rules) do
			if r.trigger == 'enemy_air_near' then airRules[#airRules + 1] = r end
		end
		if #airRules > 0 then
			local contacts = {}
			for _, obj in ipairs(detectedEnemyAir(sideName)) do
				local ok, p = pcall(obj.getPoint, obj)
				if ok and p then contacts[#contacts + 1] = p end
			end
			for _, r in ipairs(airRules) do
				local zones = {}
				if r.zone == '*' then
					for _, z in ipairs(b.zones) do
						if z.side == SIDE_ID[sideName] and zoneUsable(z) then zones[#zones + 1] = z end
					end
				else
					zones[1] = b:getZoneByName(r.zone)
				end
				for _, z in ipairs(zones) do
					local zp = z and zonePoint(z)
					if zp then
						local count = 0
						for _, p in ipairs(contacts) do
							local dx, dz = p.x - zp.x, p.z - zp.z
							if math.sqrt(dx * dx + dz * dz) <= r.radiusNm * NM then count = count + 1 end
						end
						if count >= r.minContacts then
							fireRule(sideName, r, z.zone, count .. ' enemy aircraft within ' .. r.radiusNm .. ' nm')
							break
						end
					end
				end
			end
		end
	end
end

local function onZoneTrigger(sideName, trigger, zoneName, why)
	for _, r in ipairs(X.standing[sideName] or {}) do
		if r.trigger == trigger and (r.zone == '*' or r.zone == zoneName) then
			fireRule(sideName, r, zoneName, why)
		end
	end
end

-- One zone_attacked event per zone per minute, so a long attack does not push
-- other events out of the snapshot.
X.lastAttackEventAt = {}
local function attackEvent(zoneName, by)
	local now = timer.getAbsTime()
	if now - (X.lastAttackEventAt[zoneName] or -1e9) < 60 then return end
	X.lastAttackEventAt[zoneName] = now
	X.event('red', 'zone_attacked', { zone = zoneName, by = by })
end

wrap(BattleCommander, 'BattleCommander', 'reportAIENAirSupportAttack', function(original, self, zoneObj, attackerCategory, attackerType, ...)
	local result = original(self, zoneObj, attackerCategory, attackerType, ...)
	if zoneObj and X.controls(RED) and zoneObj.side == RED then
		attackEvent(zoneObj.zone, tostring(attackerType or attackerCategory))
		onZoneTrigger('red', 'zone_attacked', zoneObj.zone, 'attacked from the air')
	end
	return result
end)

wrap(BattleCommander, 'BattleCommander', 'reportAIENEnemyPositionAttack', function(original, self, zoneObj, targetPoint, attackerKind, ...)
	local result = original(self, zoneObj, targetPoint, attackerKind, ...)
	if zoneObj and X.controls(RED) and zoneObj.side == RED then
		attackEvent(zoneObj.zone, tostring(attackerKind))
		onZoneTrigger('red', 'zone_attacked', zoneObj.zone, 'attacked on the ground')
	end
	return result
end)

wrap(Director, 'Director', 'recordZoneOwnershipChange', function(original, self, zoneName, fromSide, toSide, ...)
	local changed = original(self, zoneName, fromSide, toSide, ...)
	if changed then
		for side in pairs(X.sides) do
			local sideName = SIDE_NAME[side]
			X.event(sideName, 'zone_changed', { zone = zoneName, from = SIDE_NAME[fromSide], to = SIDE_NAME[toSide] })
			X.eventPending[sideName] = true
			if fromSide == side then onZoneTrigger(sideName, 'zone_lost', zoneName, 'zone lost') end
		end
		if econOn(econ.captureReward, toSide) then
			local r = bcObj().rewards or {}
			X.credit(toSide, math.floor((tonumber(r['Zone capture']) or 200) * (econ.rewardScale or 1)),
				'captured ' .. tostring(zoneName))
		end
	end
	return changed
end)

---------------------------------------------------------------------------
-- 4. Snapshot and request cycle
---------------------------------------------------------------------------

local function zoneRows(d, b)
	local rows, byName = {}, {}
	for _, z in ipairs(b.zones or {}) do
		if z.active and not z.isHidden then
			local okUp, maxUp = pcall(z._regularSupplyUpgradeCount, z)
			local okSup, needsSupply = pcall(z.canRecieveSupply, z)
			local p = zonePoint(z)
			local okN, set = pcall(d._operationalNeighbors, d, z.zone)
			local neighbors = {}
			if okN and type(set) == 'table' then for n in pairs(set) do neighbors[#neighbors + 1] = n end end
			table.sort(neighbors)
			local row = {
				name = z.zone, side = SIDE_NAME[z.side] or tostring(z.side), facility = z.facility,
				airbase = z.airbaseName, income = tonumber(z.income) or 0,
				groups = Utils.getTableSize(z.built or {}), maxGroups = okUp and tonumber(maxUp) or nil,
				needsSupply = okSup and needsSupply == true or nil,
				suspended = (z.suspended and not z._idleSuspended) or nil,
				depot = z.warehouseFacility and z.warehouseFacility.state or nil,
				xKm = p and round(p.x / 1000, 0.1) or nil, zKm = p and round(p.z / 1000, 0.1) or nil,
				neighbors = FAI.json.array(neighbors),
			}
			rows[#rows + 1] = row
			byName[z.zone] = row
		end
	end
	for _, row in ipairs(rows) do
		for _, n in ipairs(row.neighbors) do
			local o = byName[n]
			if o and o.side ~= 'neutral' and row.side ~= 'neutral' and o.side ~= row.side then row.frontline = true break end
		end
	end
	return rows
end

local function contactRows(b, sideName)
	local out = {}
	for _, obj in ipairs(detectedEnemyAir(sideName)) do
		if #out >= cfg.maxContacts then break end
		local ok, p = pcall(obj.getPoint, obj)
		if ok and p then
			local best, bestD
			for _, z in ipairs(b.zones) do
				local zp = z.active and not z.isHidden and zonePoint(z)
				if zp then
					local dx, dz = p.x - zp.x, p.z - zp.z
					local dist = math.sqrt(dx * dx + dz * dz)
					if not bestD or dist < bestD then best, bestD = z.zone, dist end
				end
			end
			local v = obj:getVelocity()
			local pos = obj:getPosition()
			out[#out + 1] = {
				type = obj:getTypeName(), nearZone = best, distNm = bestD and round(bestD / NM) or nil,
				altFt = round(p.y * 3.28084, 500), speedKt = round(math.sqrt(v.x * v.x + v.z * v.z) * 1.94384, 10),
				headingDeg = round((math.deg(math.atan2(pos.x.z, pos.x.x)) + 360) % 360, 5),
				xKm = round(p.x / 1000, 0.1), zKm = round(p.z / 1000, 0.1),
			}
		end
	end
	return out
end

local function missionRows(sideName)
	local out = {}
	for _, m in pairs(X.missions) do
		if SIDE_NAME[m.side] == sideName and (not m.endedAt or timer.getAbsTime() - m.endedAt < 1800) then
			local status = m.gc and m.gc.state or m.status
			out[#out + 1] = { order = m.order, group = m.group, role = m.role, origin = m.origin,
				target = m.target, status = m.endedAt and m.status or status, outcome = m.outcome,
				minutesAgo = round((timer.getAbsTime() - m.launchedAt) / 60), source = m.source, cost = m.cost }
		end
	end
	table.sort(out, function(a, b) return a.minutesAgo < b.minutesAgo end)
	return out
end

local function freeformOptions(b, side)
	local roles = {}
	for name, role in pairs(X.ROLES) do
		if b:_templateSetSupportsSide(role.template, side) then
			local templates = X.roleTemplates(name, side)
			while #templates > 30 do table.remove(templates) end
			roles[#roles + 1] = { role = name, price = X.priceFor(name), domain = role.type,
				templates = #templates > 0 and FAI.json.array(templates) or nil }
		end
	end
	table.sort(roles, function(a, c) return a.role < c.role end)
	local origins = {}
	for _, z in ipairs(b.zones) do
		if z.side == side and zoneUsable(z) then
			local planes = b:_zoneSupportsPlaneSpawn(z)
			local helos = (z.facility == 'airbase' or z.facility == 'farp' or z.facility == 'carrier') and z.isHeloSpawn
			if planes or helos then
				origins[#origins + 1] = { zone = z.zone, planes = planes or nil, helicopters = helos or nil }
			end
		end
	end
	return { roles = FAI.json.array(roles), airOrigins = FAI.json.array(origins),
		note = 'Surface roles (CONVOY, ARTY) need a ground connection from origin to target.' }
end

local function purchaseOptions(b, d)
	local out = {}
	for _, action in ipairs({ 'upgrade', 'warehouse', 'warehouse_repair', 'mass_attack', 'bomber' }) do
		local item = d:_strategicShopEntry(action)
		if item then out[#out + 1] = { item = action, cost = item.cost } end
	end
	local okC, choices = pcall(b._redZoneUpgradeChoices, b, true)
	local upgradeZones = {}
	if okC then for _, c in ipairs(choices or {}) do upgradeZones[#upgradeZones + 1] = c.zone.zone end end
	local now = timer.getAbsTime()
	return {
		items = FAI.json.array(out),
		upgradeZones = FAI.json.array(upgradeZones),
		upgradeCategories = FAI.json.array({ 'sam', 'shorad', 'aaa', 'armor', 'ground', 'arty' }),
		purchaseCooldownSec = math.max(0, round((d.strategicSpendCooldownUntil or 0) - now)),
		upgradeCooldownSec = math.max(0, round((d.zoneUpgradeCooldownUntil or 0) - now)),
		massAttackCooldownSec = math.max(0, round((X.massAttackReadyAt or 0) - now)),
	}
end

local function eventOptions()
	local out = {}
	for _, ev in ipairs(evc and evc.events or {}) do
		if ev.StrikeMission ~= true and type(ev.id) == 'string' then
			local ok, can = pcall(ev.canExecute, ev)
			local wait = (X.eventReadyAt[ev.id] or 0) - timer.getAbsTime()
			out[#out + 1] = { event = ev.id, available = ok and can == true and wait <= 0, price = X.eventPrice(ev.id),
				readyInMin = wait > 0 and math.ceil(wait / 60) or nil }
		end
	end
	return out
end

local function capabilityRow(b, cap, side)
	local origin = cap.zoneCommander
	local instance = b.directorInstanceByCapabilityId and b.directorInstanceByCapabilityId[cap.id]
	local row = {
		id = cap.id, origin = origin.zone, target = cap.targetzone, mission = cap.mission,
		role = cap.MissionType, domain = cap.type or 'air', freeform = cap.footholdAI or nil,
	}
	local spec = cap.footholdAI and X.freeformSpecs[cap.id]
	if spec then row.price = X.priceFor(spec.role) end
	if instance and (Director.LIVE_STATES[instance.state] or instance.state == 'preparing') then
		row.state = instance.state
		row.available = false
		return row
	end
	if cap.mission == 'supply' then
		row.available = nil
		return row
	end
	local ok, eligible, reason = pcall(b.evaluateDirectorSpawnEligibility, b, cap, { targetZone = cap.targetzone })
	row.available = ok and eligible == true
	if not row.available then row.reason = ok and tostring(reason or 'unavailable') or 'check failed' end
	return row
end

-- Zone groups that are not Director capabilities (older map scripting). The spawn
-- gate holds them for Claude, so they are offered like capabilities.
local LEGACY_MISSIONS = { attack = true, patrol = true }
local function legacyRows(b, side)
	local rows = {}
	for _, z in ipairs(b.zones or {}) do
		if z.side == side and zoneUsable(z) then
			for _, gc in ipairs(z.groups or {}) do
				if #rows >= 80 then return rows end
				if (gc.side or z.side) == side and LEGACY_MISSIONS[gc.mission] and gc._directorOnDemand ~= true
					and not gc.playerGroundAttack and not gc.ShopLaunchOnly and not gc.forceSpawn then
					local busy = Director.LIVE_STATES[gc.state] or gc.state == 'preparing'
					rows[#rows + 1] = {
						id = gc.name, origin = z.zone, target = gc.targetzone, mission = gc.mission,
						role = gc.MissionType, domain = gc.type or 'air', legacy = true,
						state = busy and gc.state or nil,
						available = not busy and (gc.state == 'inhangar' or gc.state == 'dead'),
						reason = (not busy and gc.state ~= 'inhangar' and gc.state ~= 'dead') and tostring(gc.state) or nil,
					}
				end
			end
		end
	end
	return rows
end

local function scheduledRows(side)
	local out, prefix = {}, SIDE_NAME[side] .. '/'
	local now = timer.getAbsTime()
	for key, e in pairs(X.scheduled) do
		if key:sub(1, #prefix) == prefix then
			out[#out + 1] = { order = e.order.id, type = e.order.type, inMin = math.max(0, math.ceil((e.dueAt - now) / 60)),
				capability = e.order.capability, role = e.order.role, origin = e.order.origin, target = e.order.targetZone }
		end
	end
	table.sort(out, function(a, c) return a.inMin < c.inMin end)
	return out
end

local function finishSnapshot(sideName, job)
	local side = SIDE_ID[sideName]
	local d = Director:getForSide(side)
	local b = d.battleCommander
	local standing = {}
	for _, r in ipairs(X.standing[sideName]) do
		standing[#standing + 1] = { id = r.id, trigger = r.trigger, zone = r.zone, fired = r.fired }
	end
	local payload = {
		reason = job.reason,
		campaign = { theatre = env.mission and env.mission.theatre, saveFile = b.saveFile },
		side = sideName,
		missionClockMin = round(timer.getAbsTime() / 60),
		economy = economyRow(side, b),
		zones = FAI.json.array(zoneRows(d, b)),
		capabilities = FAI.json.array(job.rows),
		freeform = freeformOptions(b, side),
		missions = FAI.json.array(missionRows(sideName)),
		detectedEnemyAir = FAI.json.array(contactRows(b, sideName)),
		events = FAI.json.array(X.events[sideName]),
		orderResults = FAI.json.array(X.results[sideName]),
		standingOrders = FAI.json.array(standing),
		standingOrdersMax = cfg.maxStandingOrders,
		scheduledOrders = FAI.json.array(scheduledRows(side)),
		supplyPriorities = X.supplyPriority[sideName],
	}
	if sideName == 'red' then
		payload.purchases = purchaseOptions(b, d)
		payload.scriptedEvents = FAI.json.array(eventOptions())
	else
		local players = {}
		for _, unit in ipairs(coalition.getPlayers(BLUE) or {}) do
			local p = unit:getPoint()
			players[#players + 1] = { type = unit:getTypeName(), xKm = round(p.x / 1000, 0.1), zKm = round(p.z / 1000, 0.1) }
		end
		payload.friendlyPlayers = FAI.json.array(players)
		payload.playerTasking = { designated = X.playerTasks, lastCandidates = X.taskCandidates,
			roles = FAI.json.array({ 'CAS', 'SEAD', 'DEAD', 'CAPTURE', 'RUNWAYSTRIKE', 'ATTACK_SUPPORT', 'RECON' }) }
	end
	for _, extend in ipairs(X.snapshotExtensions) do
		local ok, err = pcall(extend, sideName, payload, b, d)
		if not ok then FAI.warn('command', 'snapshot extension failed: %s', tostring(err)) end
	end
	local seq = FAI.bridge.writeState(sideName, 'command', payload)
	X.events[sideName], X.results[sideName] = {}, {}
	if seq then
		X.awaiting[sideName] = seq
		FAI.log('command', '%s snapshot seq=%d reason=%s capabilities=%d', sideName, seq, job.reason, #job.rows)
	end
end

function X.request(sideName, reason)
	if X.building[sideName] then return end
	local side = SIDE_ID[sideName]
	local b = bcObj()
	local caps = {}
	for _, cap in ipairs(b.directorCapabilities or {}) do
		local origin = cap.zoneCommander
		if origin and origin.side == side and zoneUsable(origin) then caps[#caps + 1] = cap end
	end
	local job = { reason = reason, caps = caps, index = 1, rows = {} }
	X.building[sideName] = job
	X.lastRequestAt[sideName] = timer.getAbsTime()
	X.eventPending[sideName] = nil
	timer.scheduleFunction(function(_, t)
		local last = math.min(#job.caps, job.index + cfg.evalPerTick - 1)
		for i = job.index, last do
			local ok, row = pcall(capabilityRow, b, job.caps[i], side)
			if ok and row then job.rows[#job.rows + 1] = row end
		end
		job.index = last + 1
		if job.index <= #job.caps then return t + 0.2 end
		X.building[sideName] = nil
		local okL, legacy = pcall(legacyRows, b, side)
		for _, row in ipairs(okL and legacy or {}) do job.rows[#job.rows + 1] = row end
		local ok, err = pcall(finishSnapshot, sideName, job)
		if not ok then FAI.warn('command', '%s snapshot failed: %s', sideName, tostring(err)) end
		return nil
	end, nil, timer.getTime() + 0.1)
end

FAI.bridge.onOrders('command', function(sideName, orders)
	local side = SIDE_ID[sideName]
	-- Only the answer to the snapshot the mission is waiting for counts. A late
	-- answer to an earlier (retried) snapshot, or a replay, would duplicate orders.
	if X.awaiting[sideName] == nil or orders.ackSeq ~= X.awaiting[sideName] then
		FAI.warn('command', '%s orders for snapshot %s ignored (waiting for %s)', sideName,
			tostring(orders.ackSeq), tostring(X.awaiting[sideName]))
		return
	end
	X.awaiting[sideName] = nil
	local list = type(orders.orders) == 'table' and orders.orders or {}
	FAI.log('command', '%s received %d orders (cycle %s): %s', sideName, #list,
		tostring(orders.cycle), tostring(orders.summary or ''):sub(1, 300))
	for _, order in ipairs(list) do
		if type(order) == 'table' then
			order.id = type(order.id) == 'string' and order.id or X.nextOrderId('c')
			local delay = math.max(0, math.min(3600, tonumber(order.delaySec) or 0))
			if delay > 0 then
				X.result(sideName, order.id, 'scheduled', string.format('%s in %d s', tostring(order.type), delay))
				local key = X.missionKey(side, order.id)
				local entry = { order = order, dueAt = timer.getAbsTime() + delay }
				X.scheduled[key] = entry
				timer.scheduleFunction(function()
					if X.scheduled[key] ~= entry then return nil end   -- cancelled
					X.scheduled[key] = nil
					local ok, detail = X.execute(side, order)
					X.result(sideName, order.id, ok and 'executed' or 'rejected', detail)
				end, nil, timer.getTime() + delay)
			else
				local ok, detail = X.execute(side, order)
				X.result(sideName, order.id, ok and 'executed' or 'rejected', detail)
			end
		end
	end
end)

local function tick()
	expireAuthorizations()
	bonusIncomeTick(15)
	pruneUnpaidKills()
	local now = timer.getAbsTime()
	for side in pairs(X.sides) do
		local sideName = SIDE_NAME[side]
		local d = Director:getForSide(side)
		if d and d.ready then
			X.readySince[sideName] = X.readySince[sideName] or now
			local last = X.lastRequestAt[sideName]
			local reason
			if not last then
				if now - X.readySince[sideName] >= cfg.firstRequestSec then reason = 'start' end
			elseif X.awaiting[sideName] then
				if now - last >= cfg.requestTimeoutSec then reason = 'retry' end
			elseif now - last >= cfg.cycleSec then
				reason = 'cycle'
			elseif X.eventPending[sideName] and now - last >= cfg.eventMinGapSec then
				reason = 'event'
			end
			if reason then
				local ok, err = pcall(X.request, sideName, reason)
				if not ok then FAI.warn('command', '%s request failed: %s', sideName, tostring(err)) end
			end
		end
	end
end

timer.scheduleFunction(function(_, t)
	local ok, err = pcall(tick)
	if not ok then FAI.warn('command', 'tick failed: %s', tostring(err)) end
	return t + 15
end, nil, timer.getTime() + 15)

timer.scheduleFunction(function(_, t)
	local ok, err = pcall(standingTick)
	if not ok then FAI.warn('command', 'standing orders tick failed: %s', tostring(err)) end
	return t + cfg.standingTickSec
end, nil, timer.getTime() + cfg.standingTickSec)

loadFreeformSpecs()

local controlled = {}
for side in pairs(X.sides) do controlled[#controlled + 1] = SIDE_NAME[side] end
table.sort(controlled)
FAI.log('command', 'Claude commands: %s (Foothold Director decisions off for these sides). hooks=%d',
	table.concat(controlled, ','), #hooked)
