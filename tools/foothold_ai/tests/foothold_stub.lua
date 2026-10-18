-- Minimal stand-ins for Foothold's BattleCommander, Director, EWRS and helpers,
-- shaped like the real call sites the commander hooks. Test-only.

Utils = { getTableSize = function(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end }

local zonePoints = {}
CustomZone = {}
function CustomZone:getByName(name) return { point = zonePoints[name] } end

trigger.action.outTextForCoalition = function(side, text)
	STUB.coalitionTexts = STUB.coalitionTexts or {}
	STUB.coalitionTexts[#STUB.coalitionTexts + 1] = { side = side, text = text }
end

local function zone(name, side, x, z, income, groups, facility)
	local built = {}
	for i = 1, groups do built[i] = name .. ' group ' .. i end
	zonePoints[name] = { x = x, y = 0, z = z }
	return { zone = name, side = side, active = true, isHidden = false, suspended = false,
		income = income, facility = facility or 'ground', built = built,
		_regularSupplyUpgradeCount = function() return 6 end }
end

FS = {}
FS.bc = {
	saveFile = 'foothold_pg_test.lua',
	accounts = { [1] = 1200, [2] = 800 },
	zones = {
		zone('Red Base', 1, 0, 0, 2, 5, 'airbase'),
		zone('Red Front', 1, 20000, 0, 1, 4),
		zone('Blue Front', 2, 40000, 0, 1, 3),
		zone('Blue Base', 2, 60000, 0, 2, 6, 'airbase'),
		zone('Neutral Hill', 0, 30000, 20000, 0, 0),
		zone('Hidden Zone', 2, 90000, 0, 0, 0),
	},
	_directorCampaignFrontMemory = { events = { { zone = 'Blue Front', fromSide = 1, toSide = 2, at = 30000 } } },
}
FS.bc.zones[6].isHidden = true
FS.byName = {}
for _, z in ipairs(FS.bc.zones) do FS.byName[z.zone] = z end
function FS.bc:getZoneByName(name) return FS.byName[name] end
bc = FS.bc

local links = {
	['Red Base'] = { 'Red Front' },
	['Red Front'] = { 'Red Base', 'Blue Front', 'Neutral Hill' },
	['Blue Front'] = { 'Red Front', 'Blue Base', 'Neutral Hill' },
	['Blue Base'] = { 'Blue Front' },
	['Neutral Hill'] = { 'Red Front', 'Blue Front' },
}

Director = { instancesBySide = {} }
Director.__index = Director
function Director:getForSide(side) return self.instancesBySide[side] end
function Director:_operationalNeighbors(name)
	local set = {}
	for _, n in ipairs(links[name] or {}) do set[n] = true end
	return set
end
function Director:_collectTargetCandidates(now)
	local out = {}
	for _, z in ipairs(FS.bc.zones) do
		if z.side ~= self.side and z.active and not z.isHidden then
			out[#out + 1] = { zone = z, score = FS.baseScores[z.zone] or 10 }
		end
	end
	table.sort(out, function(a, b) return a.score > b.score end)
	if FS.injectBroken then out[#out + 1] = { score = 5 } end -- malformed row (no zone)
	return out
end
-- Simplified: picks the best candidate of the top-ranked area.
function Director:_areaFirstCandidateOrder(candidates)
	local top = self.areaShadowRecommendation.ranked[1]
	for _, c in ipairs(candidates) do
		if self.areaByZone[c.zone.zone] and self.areaByZone[c.zone.zone].id == top.areaId then
			return c, candidates, top.areaId
		end
	end
	return candidates[1], candidates, nil
end
function Director:_doctrineSelectionWeight(doctrine, now) return doctrine == 'probe' and 1 or 3 end
function Director:_strategicBudgetCandidates(now, playerCount, facts, onlyAction)
	return {
		{ action = 'upgrade', score = 300, urgency = 1 },
		{ action = 'bomber', score = 250, urgency = 1 },
		{ action = 'warehouse', score = 100, urgency = 1 },
	}
end
function Director:_zoneUpgradeScore(zoneObj, context, now, profile) return 10 end
function Director:rankCapZones(missionType, zoneDistances)
	local prefix = self.side == 1 and 'Red' or 'Blue'
	self.capCache = self.capCache or {
		{ zone = prefix .. ' Base', distance = 1, directorPriority = 300 },
		{ zone = prefix .. ' Front', distance = 2, directorPriority = 200 },
	}
	return self.capCache
end
function Director:_blueMissionCandidateScore(candidate, role, context, now, zoneObj) return 100 end
function Director:_finishOperation(result, now) self.operation = nil end
function Director:recordZoneOwnershipChange(zoneName, fromSide, toSide, now) return fromSide ~= toSide end

FS.baseScores = { ['Blue Front'] = 50, ['Blue Base'] = 40, ['Neutral Hill'] = 30,
	['Red Front'] = 50, ['Red Base'] = 40 }

local function newDirector(side, areas)
	local d = setmetatable({ side = side, ready = true, battleCommander = FS.bc, state = 'waiting',
		areaByZone = {}, regionByZone = {} }, Director)
	for areaId, zones in pairs(areas) do
		for _, zn in ipairs(zones) do
			d.areaByZone[zn] = { id = areaId }
			d.regionByZone[zn] = { id = 'region-' .. areaId }
		end
	end
	d.areaShadowRecommendation = { ranked = {
		{ areaId = 'west', targetZone = 'Blue Front', score = 100, control = 'contested' },
		{ areaId = 'east', targetZone = 'Blue Base', score = 60, control = 'enemy' },
	} }
	d.strategicShadowObjective = { candidates = {} }
	Director.instancesBySide[side] = d
	return d
end
FS.red = newDirector(1, { west = { 'Blue Front', 'Neutral Hill' }, east = { 'Blue Base' } })
FS.blue = newDirector(2, { west = { 'Red Front' }, east = { 'Red Base' } })
FS.red.strategicShadowObjective.candidates = {
	{ zone = FS.byName['Blue Front'], score = 80, areaId = 'west', regionId = 'r1', regionIntent = 'push',
		runway = false, income = 1, effects = { 'GROUND_ASSAULT' } },
	{ zone = FS.byName['Blue Base'], score = 60, areaId = 'east', regionId = 'r2', runway = true, income = 2, effects = {} },
}
FS.red.operation = { id = 'op-1', targetZone = 'Blue Front', doctrine = 'probe', startedAt = 30000 }
FS.red.campaignStrategy = { name = 'breakthrough', goalZone = 'Blue Front', reason = 'test' }

-- RED radars see one BLUE fighter near Blue Front; BLUE radars see nothing.
local fighter = {
	getPoint = function() return { x = 41000, y = 6000, z = 1000 } end,
	getVelocity = function() return { x = 200, y = 0, z = 0 } end,
	getPosition = function() return { x = { x = 1, y = 0, z = 0 } } end,
	getTypeName = function() return 'FA-18C_hornet' end,
}
ewrs = { findDetectedTargets = function(side) if side == 'blue' then return { fighter } end return {} end }
