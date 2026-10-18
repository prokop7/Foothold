---------------------------------------------------------------------------
-- Foothold AI - commander
-- Sends a fog-of-war snapshot per side to the sidecar, receives 2-3 weighted
-- plans from Claude, picks one at random, and lets it bias Foothold's own
-- Director through wrapped methods. Every wrapper falls back to the original
-- result when no plan is active or the bias code fails.
--
-- RED:  campaign strategy, target focus/avoid, doctrine weights, budget
--       weights, zone-upgrade priority, CAP zones.
-- BLUE: target focus/avoid for BLUE AI missions, CAP zones, HQ intent text.
---------------------------------------------------------------------------

local FAI = FootholdAI
if not (FAI and FAI.config and FAI.config.enabled) then return end
local cfg = FAI.config.commander
if not cfg.enabled then
	FAI.log('commander', 'disabled by config')
	return
end
if not (Director and Director.getForSide and FAI.bridge) then
	FAI.warn('commander', 'Director or bridge not available - commander disabled')
	return
end

local C = {
	plans = {},          -- [sideName] = active plan
	lastRequestAt = {},  -- [sideName] = time
	awaitingSeq = {},    -- [sideName] = state seq of an unanswered request
	eventPending = {},   -- [sideName] = true after an ownership change
	readySince = {},     -- [sideName] = time the Director became ready
	outcomes = { red = {}, blue = {} },
}
FAI.commander = C

local SIDE_ID = { red = coalition.side.RED, blue = coalition.side.BLUE }
local SIDE_NAME = { [coalition.side.RED] = 'red', [coalition.side.BLUE] = 'blue', [0] = 'neutral' }
local NM = 1852

C.STRATEGIES = { 'air_supremacy', 'economic_pressure', 'island_campaign', 'breakthrough', 'counterpunch' }
C.DOCTRINES = { 'suppression', 'isolation', 'ground_push', 'counterattack', 'air_assault', 'probe' }
C.BUDGET_ACTIONS = { 'upgrade', 'warehouse', 'warehouse_repair', 'mass_attack', 'bomber' }

local function setOf(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end
local STRATEGY_SET, DOCTRINE_SET, BUDGET_SET = setOf(C.STRATEGIES), setOf(C.DOCTRINES), setOf(C.BUDGET_ACTIONS)

local function round(x, step)
	step = step or 1
	return math.floor((tonumber(x) or 0) / step + 0.5) * step
end

local function clamp(x, lo, hi)
	x = tonumber(x)
	if not x or x ~= x then return nil end
	return math.max(lo, math.min(hi, x))
end

local function battleCommander()
	local d = Director:getForSide(coalition.side.RED) or Director:getForSide(coalition.side.BLUE)
	return d and d.battleCommander or nil
end

local function zoneUsable(z)
	return z and z.active and not z.isHidden and (not z.suspended or z._idleSuspended)
end

local function zonePoint(z)
	if z._cz and z._cz.point then return z._cz.point end
	local ok, cz = pcall(CustomZone.getByName, CustomZone, z.zone)
	return ok and cz and cz.point or nil
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

local function neighborsOf(director, zoneName)
	local ok, set = pcall(director._operationalNeighbors, director, zoneName)
	local out = {}
	if ok and type(set) == 'table' then
		for name in pairs(set) do out[#out + 1] = name end
		table.sort(out)
	end
	return out
end

local function zoneRows(director, bcObj, side)
	local rows, byName = {}, {}
	for _, z in ipairs(bcObj.zones or {}) do
		if z.active and not z.isHidden then
			local okUp, maxUpgrades = pcall(z._regularSupplyUpgradeCount, z)
			local p = zonePoint(z)
			local row = {
				name = z.zone,
				side = SIDE_NAME[z.side] or tostring(z.side),
				facility = z.facility,
				income = tonumber(z.income) or 0,
				groups = Utils.getTableSize(z.built or {}),
				maxGroups = okUp and tonumber(maxUpgrades) or nil,
				suspended = z.suspended and not z._idleSuspended or nil,
				xKm = p and round(p.x / 1000) or nil,
				zKm = p and round(p.z / 1000) or nil,
				neighbors = FAI.json.array(neighborsOf(director, z.zone)),
			}
			rows[#rows + 1] = row
			byName[z.zone] = row
		end
	end
	for _, row in ipairs(rows) do
		for _, n in ipairs(row.neighbors) do
			local other = byName[n]
			if other and other.side ~= 'neutral' and row.side ~= 'neutral' and other.side ~= row.side then
				row.frontline = true
				break
			end
		end
	end
	return rows
end

local function nearestZone(bcObj, point)
	local best, bestDist
	for _, z in ipairs(bcObj.zones or {}) do
		if z.active and not z.isHidden then
			local p = zonePoint(z)
			if p then
				local dx, dz = p.x - point.x, p.z - point.z
				local d = math.sqrt(dx * dx + dz * dz)
				if not bestDist or d < bestDist then best, bestDist = z.zone, d end
			end
		end
	end
	return best, bestDist
end

-- Enemy aircraft seen by this side's radars (Foothold's EWRS registry).
local function detectedContacts(bcObj, sideName)
	if not (ewrs and ewrs.findDetectedTargets) then return nil end
	local enemyName = sideName == 'red' and 'blue' or 'red'
	local ok, objects = pcall(ewrs.findDetectedTargets, enemyName)
	if not ok or type(objects) ~= 'table' then return nil end
	local out = {}
	for _, obj in ipairs(objects) do
		if #out >= cfg.maxContacts then break end
		local okP, p = pcall(obj.getPoint, obj)
		if okP and p then
			local zoneName, dist = nearestZone(bcObj, p)
			local v = obj:getVelocity()
			local pos = obj:getPosition()
			out[#out + 1] = {
				type = obj:getTypeName(),
				nearZone = zoneName,
				distNm = dist and round(dist / NM) or nil,
				altFt = round(p.y * 3.28084, 500),
				speedKt = round(math.sqrt(v.x * v.x + v.z * v.z) * 1.94384, 10),
				headingDeg = round((math.deg(math.atan2(pos.x.z, pos.x.x)) + 360) % 360, 5),
			}
		end
	end
	return out
end

local function recentEvents(bcObj, now)
	local memory = bcObj._directorCampaignFrontMemory
	local out = {}
	for _, e in ipairs(memory and memory.events or {}) do
		if #out >= cfg.maxEvents then break end
		out[#out + 1] = {
			zone = e.zone,
			from = SIDE_NAME[e.fromSide] or tostring(e.fromSide),
			to = SIDE_NAME[e.toSide] or tostring(e.toSide),
			minutesAgo = round((now - (e.at or now)) / 60),
		}
	end
	return out
end

local function candidateRows(director)
	local out = {}
	local objective = director.strategicShadowObjective
	for _, c in ipairs(objective and objective.candidates or {}) do
		if #out >= cfg.maxCandidates then break end
		if c.zone and c.zone.zone then
			out[#out + 1] = {
				zone = c.zone.zone,
				score = round(c.score),
				area = c.areaId,
				region = c.regionId,
				intent = c.regionIntent,
				runway = c.runway or nil,
				income = c.income,
				effects = c.effects and FAI.json.array(FAI.deepCopy(c.effects)) or nil,
			}
		end
	end
	return out
end

local function areaRows(director)
	local out = {}
	local rec = director.areaShadowRecommendation
	for _, a in ipairs(rec and rec.ranked or {}) do
		if #out >= cfg.maxAreas then break end
		out[#out + 1] = {
			area = a.areaId,
			bestTarget = a.targetZone,
			score = round(a.score),
			control = a.control,
			availableCombatGroups = a.availableCombat,
			availableSupplyGroups = a.availableSupply,
		}
	end
	return out
end

local function operationRow(director)
	local op = director.operation
	if not op then return nil end
	return {
		id = op.id,
		target = op.targetZone,
		doctrine = op.doctrine,
		state = director.state,
		minutesRunning = op.startedAt and round((timer.getAbsTime() - op.startedAt) / 60) or nil,
	}
end

local function planSummary(sideName)
	local plan = C.plans[sideName]
	if not plan then return nil end
	return {
		name = plan.name,
		chosenMinutesAgo = round((timer.getAbsTime() - plan.appliedAt) / 60),
		strategy = plan.strategy,
		strategyGoal = plan.strategyGoal,
		focusZones = FAI.json.array(plan.focusList),
	}
end

function C.buildState(sideName)
	local side = SIDE_ID[sideName]
	local director = Director:getForSide(side)
	local bcObj = director and director.battleCommander
	if not bcObj then return nil end
	local now = timer.getAbsTime()
	local own, enemy = {}, {}
	local zones = zoneRows(director, bcObj, side)
	local income = 0
	for _, z in ipairs(zones) do
		if z.side == sideName then
			own[#own + 1] = z.name
			income = income + (z.income or 0)
		end
	end
	local payload = {
		campaign = {
			theatre = env.mission and env.mission.theatre,
			saveFile = bcObj.saveFile,
		},
		side = sideName,
		missionClockMin = round(now / 60),
		economy = {
			credits = round(bcObj.accounts and bcObj.accounts[side] or 0),
			zoneIncomeTotal = income,
		},
		zones = FAI.json.array(zones),
		targetCandidates = FAI.json.array(candidateRows(director)),
		areas = FAI.json.array(areaRows(director)),
		currentOperation = operationRow(director),
		detectedEnemyAir = detectedContacts(bcObj, sideName),
		recentZoneChanges = FAI.json.array(recentEvents(bcObj, now)),
		recentOperations = FAI.json.array(FAI.deepCopy(C.outcomes[sideName])),
		currentPlan = planSummary(sideName),
		menu = {},
	}
	payload.detectedEnemyAir = payload.detectedEnemyAir and FAI.json.array(payload.detectedEnemyAir) or 'unavailable'
	if sideName == 'red' then
		local s = director.campaignStrategy
		payload.campaignStrategy = s and { name = s.name, goal = s.goalZone, reason = s.reason } or nil
		payload.menu.strategies = FAI.json.array(FAI.deepCopy(C.STRATEGIES))
		payload.menu.doctrines = FAI.json.array(FAI.deepCopy(C.DOCTRINES))
		payload.menu.budgetActions = FAI.json.array(FAI.deepCopy(C.BUDGET_ACTIONS))
	else
		local players = {}
		for _, unit in ipairs(coalition.getPlayers(side) or {}) do
			players[#players + 1] = unit:getTypeName()
		end
		table.sort(players)
		payload.friendlyPlayers = FAI.json.array(players)
		local commitment = director.blueAreaCommitment
		payload.areaCommitment = commitment and { area = commitment.areaId, lastTarget = commitment.lastTargetZone } or nil
	end
	return payload
end

---------------------------------------------------------------------------
-- Plans
---------------------------------------------------------------------------

local function zoneIndex()
	local bcObj = battleCommander()
	local index = {}
	for _, z in ipairs(bcObj and bcObj.zones or {}) do index[z.zone] = z end
	return index
end

local function validZoneList(list, predicate, maxCount)
	local out = {}
	if type(list) ~= 'table' then return out end
	for _, entry in ipairs(list) do
		if #out >= maxCount then break end
		local name = type(entry) == 'table' and entry.zone or entry
		if type(name) == 'string' and predicate(name) then
			out[#out + 1] = { zone = name, weight = type(entry) == 'table' and entry.weight or nil }
		end
	end
	return out
end

local function weightMap(source, allowed)
	local out = {}
	if type(source) ~= 'table' then return out end
	for key, value in pairs(source) do
		if allowed[key] then out[key] = clamp(value, cfg.bias.minWeight, cfg.bias.maxWeight) end
	end
	return out
end

-- Turns one raw plan into a validated plan, or nil. Unknown zones and values
-- are dropped, never guessed.
function C.validatePlan(sideName, raw)
	if type(raw) ~= 'table' then return nil end
	local side = SIDE_ID[sideName]
	local zones = zoneIndex()
	local function enemyTarget(name)
		local z = zones[name]
		return zoneUsable(z) and z.side ~= side
	end
	local function own(name)
		local z = zones[name]
		return zoneUsable(z) and z.side == side
	end
	local plan = {
		name = type(raw.name) == 'string' and raw.name:sub(1, 60) or 'unnamed',
		weight = clamp(raw.weight, 0.05, 10) or 1,
		rationale = type(raw.rationale) == 'string' and raw.rationale:sub(1, 400) or '',
		focus = {},
		focusList = {},
		avoid = {},
		reinforce = {},
		capZones = {},
	}
	for _, e in ipairs(validZoneList(raw.focusZones, enemyTarget, 5)) do
		plan.focus[e.zone] = clamp(e.weight, cfg.bias.minWeight, cfg.bias.maxWeight) or 2
		plan.focusList[#plan.focusList + 1] = e.zone
	end
	for _, e in ipairs(validZoneList(raw.avoidZones, enemyTarget, 5)) do
		if not plan.focus[e.zone] then plan.avoid[e.zone] = true end
	end
	for i, e in ipairs(validZoneList(raw.capZones, own, 4)) do plan.capZones[e.zone] = 5 - i end
	if sideName == 'red' then
		for i, e in ipairs(validZoneList(raw.reinforceZones, own, 5)) do plan.reinforce[e.zone] = 6 - i end
		if STRATEGY_SET[raw.strategy] and type(raw.strategyGoal) == 'string' and enemyTarget(raw.strategyGoal) then
			plan.strategy, plan.strategyGoal = raw.strategy, raw.strategyGoal
		end
		plan.doctrineWeights = weightMap(raw.doctrineWeights, DOCTRINE_SET)
		plan.budgetWeights = weightMap(raw.budgetWeights, BUDGET_SET)
	end
	return plan
end

local function pickPlan(plans)
	local total = 0
	for _, p in ipairs(plans) do total = total + p.weight end
	local roll = math.random() * total
	for _, p in ipairs(plans) do
		roll = roll - p.weight
		if roll <= 0 then return p end
	end
	return plans[#plans]
end

local function applyStrategy(director, plan, now)
	if not plan.strategy then return end
	local regionByZone = director.regionByZone or {}
	local region = regionByZone[plan.strategyGoal]
	local generation = math.max(1, math.floor(tonumber(director.campaignStrategyGeneration) or 1))
	director.campaignStrategy = {
		name = plan.strategy,
		generation = generation,
		reason = 'footholdai:' .. plan.name,
		goalZone = plan.strategyGoal,
		goalRegion = region and region.id or nil,
		selectedAt = now,
		weight = 1,
	}
	director.campaignStrategyGeneration = generation
	director.strategicShadowNextAt = 0
	FAI.log('commander', 'red strategy=%s goal=%s (plan %s)', plan.strategy, plan.strategyGoal, plan.name)
end

function C.applyOrders(sideName, orders)
	local plans = {}
	for _, raw in ipairs(type(orders.plans) == 'table' and orders.plans or {}) do
		local plan = C.validatePlan(sideName, raw)
		if plan then plans[#plans + 1] = plan end
	end
	C.awaitingSeq[sideName] = nil
	if #plans == 0 then
		FAI.warn('commander', '%s orders contained no valid plan', sideName)
		return
	end
	local now = timer.getAbsTime()
	local plan = pickPlan(plans)
	plan.appliedAt = now
	plan.expiresAt = now + cfg.planTtlSec
	C.plans[sideName] = plan
	local names = {}
	for _, p in ipairs(plans) do names[#names + 1] = string.format('%s:%.2f', p.name, p.weight) end
	FAI.log('commander', '%s picked plan "%s" from [%s] focus=%s | %s', sideName, plan.name,
		table.concat(names, ', '), table.concat(plan.focusList, ','), plan.rationale)
	local director = Director:getForSide(SIDE_ID[sideName])
	if sideName == 'red' and director then applyStrategy(director, plan, now) end
	if sideName == 'blue' and cfg.announceBlue and type(orders.summary) == 'string' and orders.summary ~= '' then
		trigger.action.outTextForCoalition(coalition.side.BLUE, 'HQ intent: ' .. orders.summary:sub(1, 300), 20)
	end
end

function C.activePlan(side)
	local plan = C.plans[SIDE_NAME[side]]
	if plan and timer.getAbsTime() < plan.expiresAt then return plan end
	return nil
end

---------------------------------------------------------------------------
-- Director hooks
---------------------------------------------------------------------------

-- Keeps trailing and embedded nils, which {...} plus unpack() would lose.
local function pack(...) return { n = select('#', ...), ... } end

local hooked = {}
local function wrap(name, wrapper)
	local original = Director[name]
	if type(original) ~= 'function' then
		FAI.warn('commander', 'Director.%s not found - hook skipped', name)
		return
	end
	hooked[#hooked + 1] = name
	Director[name] = function(self, ...)
		return wrapper(original, self, ...)
	end
end

-- Runs bias code; on error logs once per hook and keeps the original result.
local failedHooks = {}
local function safely(hookName, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not failedHooks[hookName] then
		failedHooks[hookName] = true
		FAI.warn('commander', 'hook %s failed, using Foothold default: %s', hookName, tostring(err))
	end
	return ok
end

local function focusWeight(plan, zoneName)
	if plan.focus[zoneName] then return plan.focus[zoneName] end
	if plan.avoid[zoneName] then return cfg.bias.avoidWeight end
	return 1
end

local function byScoreDesc(a, b)
	if a.score == b.score then return a.zone.zone < b.zone.zone end
	return a.score > b.score
end

-- RED target candidates: scale scores for focus/avoid zones (fresh table per call).
wrap('_collectTargetCandidates', function(original, self, ...)
	local candidates = original(self, ...)
	local plan = C.activePlan(self.side)
	if plan and self.side == coalition.side.RED and type(candidates) == 'table' then
		safely('_collectTargetCandidates', function()
			local scores = {}
			for i, c in ipairs(candidates) do
				scores[i] = (tonumber(c.score) or 0) * focusWeight(plan, c.zone.zone)
			end
			for i, c in ipairs(candidates) do c.score = scores[i] end
			table.sort(candidates, byScoreDesc)
		end)
	end
	return candidates
end)

-- RED area choice: re-rank areas containing focus zones for this call only.
wrap('_areaFirstCandidateOrder', function(original, self, candidates, ...)
	local plan = C.activePlan(self.side)
	local rec = self.areaShadowRecommendation
	if not (plan and rec and type(rec.ranked) == 'table') then return original(self, candidates, ...) end
	local savedRanked = rec.ranked
	safely('_areaFirstCandidateOrder', function()
		local areaWeight = {}
		for zoneName, w in pairs(plan.focus) do
			local area = self.areaByZone and self.areaByZone[zoneName]
			if area then areaWeight[area.id] = math.max(areaWeight[area.id] or 1, w) end
		end
		for zoneName in pairs(plan.avoid) do
			local area = self.areaByZone and self.areaByZone[zoneName]
			if area and not areaWeight[area.id] then areaWeight[area.id] = cfg.bias.avoidWeight end
		end
		local reranked = {}
		for i, row in ipairs(savedRanked) do
			local copy = {}
			for k, v in pairs(row) do copy[k] = v end
			copy.score = math.max(1, tonumber(row.score) or 0) * (areaWeight[row.areaId] or 1)
			reranked[i] = copy
		end
		table.sort(reranked, function(a, b) return a.score > b.score end)
		rec.ranked = reranked
	end)
	local results = pack(pcall(original, self, candidates, ...))
	rec.ranked = savedRanked
	if not results[1] then error(results[2], 0) end
	return unpack(results, 2, results.n)
end)

wrap('_doctrineSelectionWeight', function(original, self, doctrine, ...)
	local weight = original(self, doctrine, ...)
	local plan = C.activePlan(self.side)
	if plan and plan.doctrineWeights and plan.doctrineWeights[doctrine] and type(weight) == 'number' then
		return weight * plan.doctrineWeights[doctrine]
	end
	return weight
end)

wrap('_strategicBudgetCandidates', function(original, self, ...)
	local candidates = original(self, ...)
	local plan = C.activePlan(self.side)
	if plan and plan.budgetWeights and next(plan.budgetWeights) and type(candidates) == 'table' then
		safely('_strategicBudgetCandidates', function()
			local scores = {}
			for i, c in ipairs(candidates) do
				scores[i] = c.score * (plan.budgetWeights[c.action] or 1)
			end
			for i, c in ipairs(candidates) do c.score = scores[i] end
			table.sort(candidates, function(a, b)
				if a.score == b.score then
					if a.urgency == b.urgency then return a.action < b.action end
					return a.urgency > b.urgency
				end
				return a.score > b.score
			end)
		end)
	end
	return candidates
end)

wrap('_zoneUpgradeScore', function(original, self, zoneObj, ...)
	local score = original(self, zoneObj, ...)
	local plan = C.activePlan(self.side)
	if plan and type(score) == 'number' and zoneObj and plan.reinforce[zoneObj.zone] then
		return score + cfg.bias.reinforceBonus * plan.reinforce[zoneObj.zone] / 5
	end
	return score
end)

-- CAP ranking is cached inside the Director; re-rank a copy, never the cache.
wrap('rankCapZones', function(original, self, ...)
	local ranked = original(self, ...)
	local plan = C.activePlan(self.side)
	if not (plan and next(plan.capZones) and type(ranked) == 'table') then return ranked end
	local copy
	safely('rankCapZones', function()
		copy = {}
		for i, row in ipairs(ranked) do
			local r = {}
			for k, v in pairs(row) do r[k] = v end
			local rank = plan.capZones[row.zone]
			if rank then r.directorPriority = (tonumber(r.directorPriority) or 0) + cfg.bias.capBonus * rank / 4 end
			copy[i] = r
		end
		table.sort(copy, function(a, b)
			if a.directorPriority == b.directorPriority then
				if a.distance == b.distance then return a.zone < b.zone end
				return a.distance < b.distance
			end
			return a.directorPriority > b.directorPriority
		end)
	end)
	return copy or ranked
end)

-- BLUE AI missions (CAS, SEAD, DEAD, capture, runway strike, recon, ...).
wrap('_blueMissionCandidateScore', function(original, self, candidate, role, context, now, zoneObj, ...)
	local score = original(self, candidate, role, context, now, zoneObj, ...)
	local plan = C.activePlan(self.side)
	if plan and type(score) == 'number' and zoneObj then
		if plan.focus[zoneObj.zone] then
			return score + cfg.bias.blueFocusBonus * plan.focus[zoneObj.zone]
		elseif plan.avoid[zoneObj.zone] then
			return score * cfg.bias.avoidWeight
		end
	end
	return score
end)

wrap('_finishOperation', function(original, self, result, now, ...)
	local op = self.operation
	local results = pack(original(self, result, now, ...))
	if op then
		safely('_finishOperation', function()
			local list = C.outcomes[SIDE_NAME[self.side]]
			if list then
				table.insert(list, 1, { target = op.targetZone, doctrine = op.doctrine, result = result,
					minuteFinished = round(timer.getAbsTime() / 60) })
				while #list > 8 do table.remove(list) end
			end
		end)
	end
	return unpack(results, 1, results.n)
end)

wrap('recordZoneOwnershipChange', function(original, self, ...)
	local changed = original(self, ...)
	if changed then
		C.eventPending.red, C.eventPending.blue = true, true
	end
	return changed
end)

---------------------------------------------------------------------------
-- Request loop
---------------------------------------------------------------------------

function C.request(sideName, reason)
	local payload = C.buildState(sideName)
	if not payload then return nil end
	payload.reason = reason
	local seq = FAI.bridge.writeState(sideName, 'commander', payload)
	if seq then
		C.lastRequestAt[sideName] = timer.getAbsTime()
		C.awaitingSeq[sideName] = seq
		C.eventPending[sideName] = nil
		FAI.log('commander', '%s requested plan seq=%d reason=%s', sideName, seq, reason)
	end
	return seq
end

local function tick()
	local now = timer.getAbsTime()
	for _, sideName in ipairs(cfg.sides) do
		local director = Director:getForSide(SIDE_ID[sideName])
		if director and director.ready then
			C.readySince[sideName] = C.readySince[sideName] or now
			local last = C.lastRequestAt[sideName]
			local reason
			if not last then
				if now - C.readySince[sideName] >= cfg.firstRequestSec then reason = 'start' end
			elseif C.awaitingSeq[sideName] then
				if now - last >= cfg.retrySec then reason = 'retry' end
			elseif now - last >= cfg.intervalSec then
				reason = 'interval'
			elseif C.eventPending[sideName] and now - last >= cfg.eventMinIntervalSec then
				reason = 'zone-change'
			end
			if reason then
				local ok, err = pcall(C.request, sideName, reason)
				if not ok then FAI.warn('commander', '%s request failed: %s', sideName, tostring(err)) end
			end
		end
	end
end

FAI.bridge.onOrders('commander', function(sideName, orders)
	C.applyOrders(sideName, orders)
end)

timer.scheduleFunction(function(_, t)
	tick()
	return t + 30
end, nil, timer.getTime() + 30)

FAI.log('commander', 'ready sides=%s hooks=%s', table.concat(cfg.sides, ','), table.concat(hooked, ','))
