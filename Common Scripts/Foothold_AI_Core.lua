---------------------------------------------------------------------------
-- Foothold AI - core
-- Config, logging, JSON encoder and the file mailbox shared with
-- tools/foothold_ai/sidecar.py. Loaded after zoneCommanderv2.lua, the setup
-- file, Foothold CTLD and AIEN (see tools/foothold_ai/patch_miz.py).
-- Uses only io and lfs, which Foothold already requires.
---------------------------------------------------------------------------

FootholdAI = FootholdAI or {}
local FAI = FootholdAI
FAI.version = '0.1.0'

---------------------------------------------------------------------------
-- Config
-- Defaults below. Override by defining FootholdAIConfig (same shape) before
-- this file runs, or with <exchange folder>\FootholdAI_Config.lua returning
-- a table with the same shape.
---------------------------------------------------------------------------

FAI.defaults = {
	enabled = true,
	debug = false,
	bridge = {
		enabled = true,
		pollSec = 5,
		pingIntervalSec = 60,
		sides = { 'red', 'blue' },
	},
	wingman = {
		enabled = true,
		maxWingmen = 3,
		requireAirborne = true,
		spawnBehindMeters = { plane = 600, helicopter = 150 },
		spawnRightMeters = { plane = 150, helicopter = 60 },
		followOffset = {
			plane = { x = -120, y = 0, z = 120 },
			helicopter = { x = -40, y = 0, z = 40 },
		},
		skill = 'Excellent',
		unlimitedFuel = false,
		attackRadiusNm = { ground = 5, airDefence = 8, ships = 10, mark = 2 },
		escortEngageNm = 20,
		attackAutoRejoinSec = 600,
		markPrefix = 'wm',
		markMaxDistanceNm = 60,
		removeAfterLandingSec = 60,
		-- [playerType] = false disables wingmen for that type.
		-- [playerType] = { template = 'ME group name' } uses an existing AI
		-- template instead of the player's slot (for types AI cannot fly).
		-- Add task = 'CAS' (or another DCS main task) to change the group task.
		typeOverride = {},
	},
	-- Claude commands these sides. Foothold's Director stops deciding for them:
	-- nothing launches, is bought or reacts unless Claude ordered it (directly
	-- or through a standing order). Player shop purchases are unaffected.
	command = {
		enabled = true,
		sides = { 'red', 'blue' },
		firstRequestSec = 60,     -- after the Director reports ready
		cycleSec = 300,           -- regular planning cycle
		eventMinGapSec = 90,      -- earliest extra cycle after an event
		requestTimeoutSec = 900,  -- ask again if a cycle never answered
		evalPerTick = 15,         -- capability eligibility checks per 0.2 s while building a snapshot
		maxContacts = 30,
		maxEvents = 30,
		maxResults = 40,
		authorizationTimeoutSec = 1200, -- an authorized group that never launched is released
		standingTickSec = 10,
		maxStandingOrders = 12,
		priceScale = 1,           -- every price = Foothold shop price x priceScale
		-- Used when the mission's ShopPrices lacks an item (keys are Foothold shop ids).
		fallbackPrices = { dynamiccap = 500, dynamiccas = 1000, dynamicsead = 500, dynamicbomb = 500,
			groundattack = 1000, zinf = 500, zarm = 1000, zvulcan = 500, zgepard = 750, zavenger = 1000,
			zhawk = 2000, zpat = 5000, zhimars = 2500, cruisemsl = 800, jam = 500, zsup3 = 750,
			capture = 500, intel = 150 },
		supplyBonus = { high = 400, normal = 0, low = -300 },
		-- Credits. Every order below draws on the side's Foothold account (bc.accounts).
		economy = {
			-- Fee for launching Foothold's pre-built capabilities, as a fraction of the role's
			-- shop price. 0 = free, as under Foothold's own commander (they still use aircraft/warehouse stock).
			capabilityFee = { red = 0, blue = 0 },
			-- AI kills earn the same credits a player earns for that kill (RewardContribution).
			-- BLUE players already earn through Foothold, so this is off for BLUE by default.
			killRewards = { red = true, blue = false },
			rewardScale = 1,
			-- Like a player's: an aircraft's kills are paid when it lands; if it is lost first,
			-- only this fraction is paid (a player who ejects keeps 25 %).
			airKillsPaidOnLanding = true,
			lostAircraftKeeps = 0.25,
			captureReward = { red = true, blue = false },  -- RewardContribution['Zone capture']
			bonusIncomePerMin = { red = 0, blue = 0 },     -- flat extra income on top of zone income
			ledgerSize = 25,
		},
		-- Prices of the RED operations (Foothold shop id = that item's price, or a number).
		prices = {
			deploy = { ground = 'zinf', armor = 'zarm', aaa = 'zvulcan', shorad = 'zavenger',
				sam = 'zhawk', sam_long = 'zpat', arty = 'zhimars', other = 'zarm' },
			airlift = 'zsup3',          -- per 3 supply units
			heli_raid = 'groundattack',
			air_assault = 'capture',
			ambush = 'zvulcan',
			jam = 'jam',
			awacs = 0,
			event = 1000,               -- trigger_event (scripted RED events); per event: events = { scuds = 1500 }
			events = {},
		},
		eventCooldownSec = 3600,        -- per scripted event
		massAttackCooldownSec = 3600,
		ops = {
			deployMaxPerZone = 2,       -- extra groups placed by deploy_forces, per zone
			deployMaxTotal = 12,
			-- Long-range fire: a battery is set up inside a RED zone, fires, and stays there
			-- (a real target) for lifetimeSec. range in km; eras = Foothold Era values (nil = all).
			fireSystems = {
				scud = { templates = { 'Scuds' }, rangeKm = 280, minKm = 50, salvo = 1, price = 'cruisemsl', cooldownSec = 1800, lifetimeSec = 1200 },
				iskander = { templates = { 'Khasab-Forces-attack' }, rangeKm = 450, minKm = 50, salvo = 4, price = 'cruisemsl',
					cooldownSec = 1800, lifetimeSec = 1200, eras = { Modern = true } },
				smerch = { templates = { 'qeshm-arty-Attack-Group' }, rangeKm = 65, minKm = 20, salvo = 12, price = 'zhimars',
					cooldownSec = 1200, lifetimeSec = 1200, eras = { Modern = true, Coldwar = true } },
			},
			fireSetupSec = 60,          -- from setting up to firing
			transportTemplates = { 'RED_MI8_SUPPLY_KORD', 'Bandar-force-1' },
			raidGuns = { nona = { template = 'CTLD_CARGO_RED_ARTY_Nona', rangeKm = 8 },
				akatsia = { template = 'CTLD_CARGO_RED_ARTY_Akatsia', rangeKm = 17 } },
			raidRounds = 12,
			raidGunLifetimeSec = 1800,
			ambushTeams = { manpads = 'Igla', manpads_s = 'Igla-S', zu23 = 'Red SAM AAA 9' },
			ambushLifetimeSec = 3600,
			ambushMaxActive = 4,
			helo = { altitudeM = 150, speedKmh = 220, cruiseMaxKm = 150, timeoutSec = 2400 },
			airliftUnits = 3,
			-- Jamming, both sides: only SAM radars within range of a live jammer are jammed
			-- (rangeNm, or more for long-range SAM radars, matched on the unit type, so the
			-- jammer works from outside their reach). Claude's jammer orbits standoffNm from
			-- the target; BLUE's shop jammer keeps its Mission Editor route and lifetime.
			-- RED jammer: the first template found. Add a late-activated RED group named
			-- ewAircraftRed in the Mission Editor for a dedicated jammer; AN-30M stands in until then.
			jamming = { rangeNm = 40, standoffNm = 25, durationSec = 1800, altitudeFt = 22000,
				routeJammers = true, templates = { red = { 'ewAircraftRed', 'AN-30M' } },
				rangeNmByRadar = { { 'patriot', 60 }, { 's%-300', 65 }, { '40b6', 65 }, { '64h6', 65 },
					{ '5n62', 140 }, { '19j6', 140 }, { 's%-200', 140 } } },
			maxActiveFlights = 6,       -- RED helicopter/jammer operations at once
		},
	},
}

local function deepMerge(base, override)
	if type(override) ~= 'table' then return base end
	for k, v in pairs(override) do
		if type(v) == 'table' and type(base[k]) == 'table' and #v == 0 and next(v) ~= nil then
			deepMerge(base[k], v)
		else
			base[k] = v
		end
	end
	return base
end

local function deepCopy(value)
	if type(value) ~= 'table' then return value end
	local copy = {}
	for k, v in pairs(value) do copy[k] = deepCopy(v) end
	return copy
end
FAI.deepCopy = deepCopy

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

function FAI.log(module, fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	if not ok then text = tostring(fmt) end
	env.info('[FootholdAI][' .. tostring(module) .. '] ' .. text)
end

function FAI.warn(module, fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	if not ok then text = tostring(fmt) end
	env.warning('[FootholdAI][' .. tostring(module) .. '] ' .. text)
end

function FAI.debug(module, fmt, ...)
	if FAI.config and FAI.config.debug then FAI.log(module, fmt, ...) end
end

---------------------------------------------------------------------------
-- Exchange folder
---------------------------------------------------------------------------

local function exchangeFolder()
	if not (lfs and lfs.writedir and io) then return nil end
	local dir = lfs.writedir() .. 'Missions\\Saves\\FootholdAI\\'
	pcall(lfs.mkdir, lfs.writedir() .. 'Missions\\Saves')
	pcall(lfs.mkdir, dir)
	return dir
end

local function loadDataFile(path)
	if not (lfs and lfs.attributes(path)) then return nil end
	local size = lfs.attributes(path, 'size') or 0
	if size <= 0 or size > 1024 * 1024 then return nil, 'bad size ' .. tostring(size) end
	local f, ferr = io.open(path, 'rb')
	if not f then return nil, ferr end
	local text = f:read('*a')
	f:close()
	-- Precompiled chunks can escape the empty environment; data files are text only.
	if not text or text:sub(1, 1) == '\27' then return nil, 'not a text data file' end
	local chunk, err = loadstring(text, '=' .. path)
	if not chunk then return nil, err end
	setfenv(chunk, {})
	local ok, result = pcall(chunk)
	if not ok then return nil, result end
	if type(result) ~= 'table' then return nil, 'file did not return a table' end
	return result
end
FAI.loadDataFile = loadDataFile

---------------------------------------------------------------------------
-- JSON encoder (state files). Object keys are sorted so identical states
-- produce identical text.
---------------------------------------------------------------------------

FAI.json = {}
local arrayMeta = { __jsonArray = true }

function FAI.json.array(t)
	return setmetatable(t or {}, arrayMeta)
end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
	['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format('\\u%04x', c:byte())
	end) .. '"'
end

local function isArray(t)
	if getmetatable(t) == arrayMeta then return true end
	local n = #t
	if n == 0 then return false end
	local count = 0
	for _ in pairs(t) do count = count + 1 end
	return count == n
end

local function encode(value, out, depth)
	if depth > 32 then error('json: nesting too deep') end
	local kind = type(value)
	if kind == 'nil' then
		out[#out + 1] = 'null'
	elseif kind == 'boolean' then
		out[#out + 1] = value and 'true' or 'false'
	elseif kind == 'number' then
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = 'null'
		elseif value == math.floor(value) and math.abs(value) < 1e15 then
			out[#out + 1] = string.format('%d', value)
		else
			out[#out + 1] = string.format('%.6g', value)
		end
	elseif kind == 'string' then
		out[#out + 1] = encodeString(value)
	elseif kind == 'table' then
		if isArray(value) then
			out[#out + 1] = '['
			for i = 1, #value do
				if i > 1 then out[#out + 1] = ',' end
				encode(value[i], out, depth + 1)
			end
			out[#out + 1] = ']'
		else
			local keys = {}
			for k, v in pairs(value) do
				if type(v) ~= 'function' then keys[#keys + 1] = tostring(k) end
			end
			table.sort(keys)
			out[#out + 1] = '{'
			for i, k in ipairs(keys) do
				if i > 1 then out[#out + 1] = ',' end
				out[#out + 1] = encodeString(k)
				out[#out + 1] = ':'
				local v = value[k]
				if v == nil then v = value[tonumber(k)] end
				encode(v, out, depth + 1)
			end
			out[#out + 1] = '}'
		end
	else
		out[#out + 1] = 'null'
	end
end

function FAI.json.encode(value)
	local out = {}
	encode(value, out, 0)
	return table.concat(out)
end

-- Data-only Lua literal ("return { ... }") readable with FAI.loadDataFile.
local function serialize(value, out, depth)
	local kind = type(value)
	if kind == 'string' then
		out[#out + 1] = string.format('%q', value)
	elseif kind == 'number' or kind == 'boolean' then
		out[#out + 1] = tostring(value)
	elseif kind == 'table' and depth < 16 then
		out[#out + 1] = '{'
		for k, v in pairs(value) do
			if type(k) == 'string' or type(k) == 'number' then
				local vk = type(v)
				if vk == 'string' or vk == 'number' or vk == 'boolean' or vk == 'table' then
					out[#out + 1] = '['
					serialize(k, out, depth + 1)
					out[#out + 1] = ']='
					serialize(v, out, depth + 1)
					out[#out + 1] = ','
				end
			end
		end
		out[#out + 1] = '}'
	else
		out[#out + 1] = 'nil'
	end
end

function FAI.writeDataFile(path, value)
	local out = { 'return ' }
	serialize(value, out, 0)
	local f, err = io.open(path, 'w')
	if not f then return false, err end
	f:write(table.concat(out))
	f:close()
	return true
end

---------------------------------------------------------------------------
-- Mailbox
-- Lua writes state_<side>_<kind>.json; the sidecar answers with
-- orders_<side>_<kind>.lua, a data-only file ("return { ... }") written
-- atomically. One file per kind, so a ping never overwrites a pending
-- commander request. Orders are loaded with an empty environment and passed
-- to the handler registered for their kind.
---------------------------------------------------------------------------

FAI.bridge = {
	seq = { red = 0, blue = 0 },
	lastOrderSeq = {},   -- [side:kind] = seq
	badOrderStamp = {},  -- [side:kind] = mtime:size of a file that was rejected
	handlers = {},
	pendingPings = {},
	linkOk = { red = false, blue = false },
}
local bridge = FAI.bridge

function bridge.onOrders(kind, handler)
	bridge.handlers[kind] = handler
end

function bridge.writeState(side, kind, payload)
	if not (FAI.dir and FAI.config.bridge.enabled) then return nil end
	bridge.seq[side] = (bridge.seq[side] or 0) + 1
	local state = {
		schema = 'footholdai.state.v1',
		version = FAI.version,
		side = side,
		kind = kind,
		session = bridge.session,
		seq = bridge.seq[side],
		missionTime = timer.getAbsTime(),
		modelTime = timer.getTime(),
		theatre = env.mission and env.mission.theatre or nil,
		payload = payload or {},
	}
	local ok, text = pcall(FAI.json.encode, state)
	if not ok then
		FAI.warn('bridge', 'state encode failed for %s/%s: %s', side, kind, tostring(text))
		return nil
	end
	local path = FAI.dir .. 'state_' .. side .. '_' .. kind .. '.json'
	local f, err = io.open(path, 'w')
	if not f then
		FAI.warn('bridge', 'cannot write %s: %s', path, tostring(err))
		return nil
	end
	f:write(text)
	f:close()
	FAI.debug('bridge', 'wrote %s seq=%d kind=%s bytes=%d', path, state.seq, kind, #text)
	return state.seq
end

local function readOrders(side, kind)
	local key = side .. ':' .. kind
	local path = FAI.dir .. 'orders_' .. side .. '_' .. kind .. '.lua'
	local attr = lfs.attributes(path)
	if not attr then return end
	-- Read every poll and decide by seq: file times have 1 s resolution, so two
	-- answers written within a second could look identical. Only a rejected
	-- file is skipped until it changes, so it is not reported every poll.
	local stamp = tostring(attr.modification) .. ':' .. tostring(attr.size)
	if stamp == bridge.badOrderStamp[key] then return end
	local orders, err = loadDataFile(path)
	if not orders then
		bridge.badOrderStamp[key] = stamp
		FAI.warn('bridge', 'rejected %s: %s', path, tostring(err))
		return
	end
	if orders.schema ~= 'footholdai.orders.v1' or orders.side ~= side or orders.kind ~= kind
		or type(orders.seq) ~= 'number' then
		bridge.badOrderStamp[key] = stamp
		FAI.warn('bridge', 'rejected %s: bad header', path)
		return
	end
	if orders.session ~= bridge.session then
		FAI.debug('bridge', 'ignored %s from another mission session', path)
		return
	end
	if orders.seq <= (bridge.lastOrderSeq[key] or 0) then return end
	bridge.lastOrderSeq[key] = orders.seq
	local ok, herr = pcall(bridge.handlers[kind], side, orders)
	if not ok then FAI.warn('bridge', 'handler %s failed: %s', kind, tostring(herr)) end
end

function bridge.poll()
	for _, side in ipairs(FAI.config.bridge.sides) do
		for kind in pairs(bridge.handlers) do
			local ok, err = pcall(readOrders, side, kind)
			if not ok then FAI.warn('bridge', 'poll %s/%s failed: %s', side, kind, tostring(err)) end
		end
	end
end

-- Link test: the first ping per side asks the sidecar to call Claude once.
function bridge.ping()
	local now = timer.getTime()
	for key, sentAt in pairs(bridge.pendingPings) do
		if now - sentAt > 600 then bridge.pendingPings[key] = nil end
	end
	for _, side in ipairs(FAI.config.bridge.sides) do
		local wantsClaude = not bridge.linkOk[side]
		local seq = bridge.writeState(side, 'ping', { wantsClaude = wantsClaude })
		if seq then bridge.pendingPings[side .. ':' .. seq] = timer.getTime() end
	end
end

bridge.onOrders('pong', function(side, orders)
	local sentAt = bridge.pendingPings[side .. ':' .. tostring(orders.ackSeq)]
	bridge.pendingPings[side .. ':' .. tostring(orders.ackSeq)] = nil
	local rtt = sentAt and string.format('%.1fs', timer.getTime() - sentAt) or 'n/a'
	local claude = type(orders.claude) == 'table' and orders.claude or {}
	if claude.called then
		if claude.ok then
			bridge.linkOk[side] = true
			FAI.log('bridge', 'link ok side=%s roundtrip=%s claudeLatencyMs=%s ack=%s',
				side, rtt, tostring(claude.latencyMs), tostring(claude.ack))
		else
			FAI.warn('bridge', 'sidecar reached but Claude call failed side=%s error=%s', side, tostring(claude.error))
		end
	else
		FAI.debug('bridge', 'pong side=%s roundtrip=%s', side, rtt)
	end
end)

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function FAI.init()
	FAI.config = deepMerge(deepCopy(FAI.defaults), FootholdAIConfig)
	-- Orders from a previous mission run carry another session id and are ignored.
	bridge.session = string.format('%d-%d', math.random(100000000, 999999999), math.floor(timer.getAbsTime()))
	FAI.dir = exchangeFolder()
	if FAI.dir then
		local external, err = loadDataFile(FAI.dir .. 'FootholdAI_Config.lua')
		if external then
			deepMerge(FAI.config, external)
			FAI.log('core', 'loaded FootholdAI_Config.lua')
		elseif err then
			FAI.warn('core', 'FootholdAI_Config.lua ignored: %s', tostring(err))
		end
	else
		FAI.warn('core', 'io/lfs not available (MissionScripting.lua sanitized?) - bridge disabled')
	end
	if not FAI.config.enabled then
		FAI.log('core', 'disabled by config')
		return
	end
	FAI.log('core', 'version %s exchange=%s', FAI.version, tostring(FAI.dir))
	if FAI.dir and FAI.config.bridge.enabled then
		timer.scheduleFunction(function(_, t)
			bridge.poll()
			return t + FAI.config.bridge.pollSec
		end, nil, timer.getTime() + FAI.config.bridge.pollSec)
		timer.scheduleFunction(function(_, t)
			bridge.ping()
			return t + FAI.config.bridge.pingIntervalSec
		end, nil, timer.getTime() + 10)
	end
end

FAI.init()
