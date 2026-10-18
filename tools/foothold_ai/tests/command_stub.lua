-- Stand-ins for Foothold's BattleCommander, Director, capabilities, EWRS and
-- events, shaped like the real call sites Foothold_AI_Command.lua uses.
-- Methods live on the classes and instances inherit them, as in Foothold,
-- so class-level wrapping is exercised for real. Test-only.

Utils = { getTableSize = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end }
ShopPrices = { dynamiccap = 500, dynamiccas = 1000, dynamicsead = 500, dynamicbomb = 500, groundattack = 1000 }
function CapAltitude() return 25000 end
function CasAltitude() return 15000 end
function SeadAltitude() return 28000 end
function RunwayStrikeAltitude() return 26000 end
function getBluePlayersCount() return 1 end

local zonePoints = {}
CustomZone = {}
function CustomZone:getByName(name) return { point = zonePoints[name] } end

trigger.action.outTextForCoalition = function(side, text)
	STUB.coalitionTexts = STUB.coalitionTexts or {}
	STUB.coalitionTexts[#STUB.coalitionTexts + 1] = { side = side, text = text }
end

FS = { calls = {} }
local function called(name, ...) FS.calls[#FS.calls + 1] = { name = name, args = { ... } } end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------
local ZoneCommanderStub = {}
ZoneCommanderStub.__index = ZoneCommanderStub
function ZoneCommanderStub:_regularSupplyUpgradeCount() return 6 end
function ZoneCommanderStub:canRecieveSupply() return #self.built < 6 end
function ZoneCommanderStub:_activateFsmGroup(gc) called('_activateFsmGroup', gc.name) end

local function zone(name, side, x, z, opts)
	opts = opts or {}
	local built = {}
	for i = 1, (opts.groups or 3) do built[i] = name .. ' group ' .. i end
	zonePoints[name] = { x = x, y = 0, z = z }
	return setmetatable({ zone = name, side = side, active = true, isHidden = opts.hidden or false,
		suspended = false, income = opts.income or 1, facility = opts.facility or 'ground',
		airbaseName = opts.airbase, isPlaneSpawn = opts.planes or false, isHeloSpawn = opts.helos or false,
		built = built, groups = {} }, ZoneCommanderStub)
end

---------------------------------------------------------------------------
-- BattleCommander
---------------------------------------------------------------------------
BattleCommander = {}
BattleCommander.__index = BattleCommander

function BattleCommander:getZoneByName(name) return self.byName[name] end
function BattleCommander:addFunds(side, amount) self.accounts[side] = math.max(0, self.accounts[side] + amount) end
function BattleCommander:_getPendingShopReservedCredits(side) return 0 end
function BattleCommander:_zoneSupportsPlaneSpawn(z) return z.isPlaneSpawn == true end
function BattleCommander:_templateSetSupportsSide(template, side)
	return not (FS.unsupportedTemplates and FS.unsupportedTemplates[template])
end
function BattleCommander:evaluateDirectorSpawnEligibility(cap, request)
	called('evaluate', cap.id, request and request.targetZone)
	local denial = FS.ineligible[cap.id]
	if denial then return false, denial end
	return true
end
function BattleCommander:_directorCapabilityCandidateView(cap)
	return { name = cap.id, _directorPassiveCapability = cap, mission = cap.mission,
		zoneCommander = cap.zoneCommander, targetzone = cap.targetzone, MissionType = cap.MissionType }
end
function BattleCommander:resolveDirectorCandidate(candidate, request)
	called('resolve', candidate.name, request and request._directorEligibilityApproved)
	local cap = candidate._directorPassiveCapability
	if not cap then return candidate end
	local gc = { name = cap.id, side = cap.zoneCommander.side, state = 'inhangar', mission = cap.mission,
		MissionType = cap.MissionType, targetzone = cap.targetzone, zoneCommander = cap.zoneCommander,
		_directorOnDemand = true, _directorInstanceGeneration = 1, type = cap.type }
	self.directorInstanceByCapabilityId[cap.id] = gc
	return gc
end
function BattleCommander:_authorizeDirectorOnDemandGroup(gc, now, director)
	called('authorize', gc.name)
	local previous = gc.state
	gc.state = 'preparing'
	if director then director:onGroupStateChanged(gc, previous, 'preparing', false, false) end
	return true
end
function BattleCommander:_redReactiveFastForwardGroup(gc, now)
	called('fastForward', gc.name)
	return gc.state == 'inhangar' or gc.state == 'dead'
end
function BattleCommander:registerDirectorCapability(origin, cap)
	assert(self.directorCapabilitiesById[cap.id] == nil, 'duplicate DirectorCapability id: ' .. cap.id)
	cap.zoneCommander = origin
	self.directorCapabilities[#self.directorCapabilities + 1] = cap
	self.directorCapabilitiesById[cap.id] = cap
	return cap
end
function BattleCommander:_redZoneUpgradeChoices(includeSlots)
	local out = {}
	for _, z in ipairs(self.zones) do
		if z.side == 1 and z.zone ~= 'Red Full' then
			out[#out + 1] = { zone = z, slot = includeSlots and 'Red Armour Group' or nil,
				upgradePools = includeSlots and { shorad = { 'Red SAM SHORAD SA-8' }, armor = { 'Red Armour Group' } } or nil }
		end
	end
	return out
end
function BattleCommander:buyShopItem(side, itemId, params)
	called('buyShopItem', itemId)
	if itemId == 'redzoneupgrade' then
		local d = Director:getForSide(1)
		local pick = d:selectZoneUpgradeTarget(self:_redZoneUpgradeChoices(true), params, 0)
		if not pick then return 'no zone' end
		params.purchasedZone = pick.zone.zone
		FS.lastUpgradeSlot = pick.slot
		return true
	end
	if itemId == 'redwarehouse' then params.zone.warehouseFacility = { state = 'operational' } end
	return true
end
function BattleCommander:_regularSupplyTargetPriority(side, targetZone)
	return { priority = 100, unfilled = 2 }
end
function BattleCommander:_buildRegularSupplyCommitmentSnapshot() return { regularBySourceTarget = {} } end
function BattleCommander:_dispatchRegularSupplyCommander(candidate, now)
	called('dispatchSupply', candidate.name)
	return FS.supplyStock ~= false
end
function BattleCommander:requestDirectorInstanceDisposal(gc)
	called('dispose', gc.name)
	self.directorInstanceByCapabilityId[gc.name] = nil
end
function BattleCommander:_redReactiveTick(_, time)
	called('redReactiveTick')
	return time + 30
end
function BattleCommander:reportAIENAirSupportAttack(zoneObj, cat, attackerType)
	local d = Director:getForSide(1)
	return d:considerAIENAirSupport(zoneObj, cat, attackerType)
end
function BattleCommander:reportAIENEnemyPositionAttack(zoneObj, point, kind)
	local d = Director:getForSide(1)
	return d:requestEnemyPositionResponse(zoneObj, point, kind)
end

---------------------------------------------------------------------------
-- Director
---------------------------------------------------------------------------
Director = { instancesBySide = {}, LIVE_STATES = { takeoff = true, inair = true, landed = true,
	enroute = true, atdestination = true } }
Director.__index = Director
function Director:getForSide(side) return self.instancesBySide[side] end
local links = {
	['Red Base'] = { 'Red Front' }, ['Red Front'] = { 'Red Base', 'Blue Front', 'Neutral Hill' },
	['Blue Front'] = { 'Red Front', 'Blue Base', 'Neutral Hill' }, ['Blue Base'] = { 'Blue Front' },
	['Neutral Hill'] = { 'Red Front', 'Blue Front' }, ['Red Full'] = {},
}
function Director:_operationalNeighbors(name)
	local s = {}
	for _, n in ipairs(links[name] or {}) do s[n] = true end
	return s
end
function Director:_groupRole(gc) return gc.MissionType or 'SURFACE' end
function Director:_canRetaskAirRole(role)
	return role == 'CAP' or role == 'CAS' or role == 'SEAD' or role == 'RUNWAYSTRIKE'
end
function Director:_retaskGroupForAssignment(gc, target)
	gc._directorRetaskOriginalTargetZone = gc.targetzone
	gc.targetzone = target
end
function Director:_restoreRetaskedGroup(gc)
	gc.targetzone = gc._directorRetaskOriginalTargetZone or gc.targetzone
	gc._directorRetaskOriginalTargetZone = nil
end
Director.RED_STRATEGIC_SHOP_IDS = { upgrade = 'redzoneupgrade', warehouse = 'redwarehouse',
	warehouse_repair = 'redwhrepair', mass_attack = 'redmassattack', bomber = 'strategicbomberRed' }
function Director:_strategicShopEntry(action)
	local id = self.RED_STRATEGIC_SHOP_IDS[action]
	local item = id and FS.shop[id]
	return item, id
end
function Director:zoneUpgradePurchaseAllowed(now) return now >= (self.zoneUpgradeCooldownUntil or 0) end
function Director:_strategicObjectiveCandidate(name) return { zone = { zone = name } } end
function Director:selectZoneUpgradeTarget(choices, context, now)
	called('originalSelectZoneUpgradeTarget')
	return choices[1]
end
-- Simplified purchase path: same contract as Foothold's (true, zone, cost) or false.
function Director:_executeStrategicBudgetCandidate(candidate, now)
	called('executeBudget', candidate.action)
	local cost = candidate.cost
	if (self.battleCommander.accounts[self.side] or 0) < cost then return false end
	local params = { _directorExpectedCategory = candidate.category, zone = candidate.zoneRef }
	local ok = self.battleCommander:buyShopItem(self.side, candidate.itemId, params)
	if ok ~= true then return false end
	self.battleCommander:addFunds(self.side, -cost)
	return true, params.purchasedZone or (candidate.zoneRef and candidate.zoneRef.zone), cost
end
function Director:selectMissionTarget(role, candidates, context)
	called('originalSelectMissionTarget', role)
	return candidates[1]
end
function Director:_blueCandidateZone(c) return FS.bc.byName[c.zoneName] end
function Director:onGroupStateChanged(gc, previous, current) called('onGroupStateChanged', gc.name, current) end
function Director:onManagedSpawnDenied(gc, reason) called('originalDenied', gc.name) return false end
function Director:recordZoneOwnershipChange(zoneName, fromSide, toSide) return fromSide ~= toSide end
function Director:allowsGroupSpawn(gc) called('originalAllows', gc.name) return true end
-- Decision methods that command mode must neutralize.
for _, name in ipairs({ '_reconcileRoutineCaps', '_updateRestoredCapStartup', '_reconcileRoutineCapRevector',
	'_updateGroundRelease', '_startOperation', '_processPendingReaction', '_considerNormandyBomberLaunch',
	'_adoptMassAttack', '_reconcileBlueRoutinePatrolPosition', '_blueAdoptActiveAttackMission',
	'_blueReassessSupportFocus', '_blueReconcileAssignments', 'requestReaction', 'requestReactiveCap',
	'requestEnemyPositionResponse', 'considerAIENAirSupport', 'considerCapturedZoneCasDiversion',
	'requestZoneUpgrade', 'requestPlayerCapResponse' }) do
	Director[name] = function(self) called('original:' .. name) return 'original' end
end

DirectorCapability = {}
function DirectorCapability:new(obj)
	obj.id = obj.id or obj.name
	obj._isDirectorCapability = true
	return obj
end

EventCommander = {}
EventCommander.__index = EventCommander
function EventCommander:chooseAndStart() called('evcRandom') end
evc = setmetatable({ events = {
	{ id = 'scuds', canExecute = function() return true end, action = function() called('event:scuds') end },
	{ id = 'helohunt', canExecute = function() return false end, action = function() called('event:helohunt') end },
	{ id = 'StrikePort', StrikeMission = true, canExecute = function() return true end, action = function() end },
} }, EventCommander)

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
FS.shop = { redzoneupgrade = { cost = 1000 }, redwarehouse = { cost = 3000 }, redmassattack = { cost = 6000 } }
FS.ineligible = { ['red-cas-blocked'] = 'no-warehouse-stock' }
FS.bc = setmetatable({
	saveFile = 'foothold_pg_test.lua', accounts = { [1] = 5000, [2] = 2000 }, updateFrequency = 10,
	zones = {
		zone('Red Base', 1, 0, 0, { facility = 'airbase', airbase = 'Bandar', planes = true, helos = true, income = 2 }),
		zone('Red Front', 1, 20000, 0, { groups = 4 }),
		zone('Red Full', 1, -20000, 0, { groups = 6 }),
		zone('Blue Front', 2, 40000, 0, { groups = 3 }),
		zone('Blue Base', 2, 60000, 0, { facility = 'airbase', airbase = 'Dhafra', planes = true, helos = true, groups = 6 }),
		zone('Neutral Hill', 0, 30000, 20000, { groups = 0 }),
	},
	directorCapabilities = {}, directorCapabilitiesById = {}, directorInstanceByCapabilityId = {},
}, BattleCommander)
FS.bc.byName = {}
for _, z in ipairs(FS.bc.zones) do FS.bc.byName[z.zone] = z end
bc = FS.bc

local function cap(id, origin, target, mission, missionType, typ)
	local c = DirectorCapability:new({ id = id, name = id, mission = mission, MissionType = missionType,
		targetzone = target, type = typ or 'air', template = 'X' })
	FS.bc:registerDirectorCapability(FS.bc.byName[origin], c)
	return c
end
cap('red-cap-front', 'Red Base', 'Red Front', 'patrol', 'CAP')
cap('red-cas-bluefront', 'Red Base', 'Blue Front', 'attack', 'CAS')
cap('red-cas-blocked', 'Red Base', 'Blue Base', 'attack', 'CAS')
cap('red-arty-bluefront', 'Red Front', 'Blue Front', 'attack', 'ARTY', 'surface')
cap('red-supply-front', 'Red Base', 'Red Front', 'supply', nil, 'air')
cap('blue-cap-base', 'Blue Base', 'Blue Front', 'patrol', 'CAP')

local function director(side)
	local d = setmetatable({ side = side, ready = true, battleCommander = FS.bc, state = 'waiting' }, Director)
	Director.instancesBySide[side] = d
	return d
end
FS.red = director(1)
FS.blue = director(2)

-- RED radars see one BLUE fighter 5 km from Red Front; BLUE radars see nothing.
FS.contacts = { blue = {
	{ getPoint = function() return { x = 25000, y = 6000, z = 0 } end,
	  getVelocity = function() return { x = 200, y = 0, z = 0 } end,
	  getPosition = function() return { x = { x = 1, y = 0, z = 0 } } end,
	  getTypeName = function() return 'FA-18C_hornet' end },
}, red = {} }
ewrs = { findDetectedTargets = function(side) return FS.contacts[side] or {} end }
