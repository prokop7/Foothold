-- Minimal DCS + MOOSE stand-ins for offline tests of the Foothold AI scripts.
-- Only what the scripts touch is modelled. Not used in the mission.

STUB = { now = 0, abs = 30000, scheduled = {}, logs = {}, texts = {}, addGroupCalls = {},
	groups = {}, units = {}, handlers = {}, menus = {}, nextGroupId = 100 }

local function log(level, text) STUB.logs[#STUB.logs + 1] = level .. ' ' .. text end
env = {
	info = function(t) log('INFO', t) end,
	warning = function(t) log('WARN', t) end,
	error = function(t) log('ERROR', t) end,
	mission = { theatre = 'PersianGulf' },
}

timer = {
	getTime = function() return STUB.now end,
	getAbsTime = function() return STUB.abs + STUB.now end,
	scheduleFunction = function(fn, arg, t)
		STUB.scheduled[#STUB.scheduled + 1] = { fn = fn, arg = arg, t = t }
	end,
}

function STUB.advance(seconds)
	local target = STUB.now + seconds
	while true do
		local nextIndex, nextItem
		for i, item in ipairs(STUB.scheduled) do
			if item.t <= target and (not nextItem or item.t < nextItem.t) then nextIndex, nextItem = i, item end
		end
		if not nextItem then break end
		table.remove(STUB.scheduled, nextIndex)
		STUB.now = math.max(STUB.now, nextItem.t)
		local again = nextItem.fn(nextItem.arg, nextItem.t)
		if type(again) == 'number' then
			STUB.scheduled[#STUB.scheduled + 1] = { fn = nextItem.fn, arg = nextItem.arg, t = again }
		end
	end
	STUB.now = target
end

trigger = { action = {
	outTextForGroup = function(gid, text) STUB.texts[#STUB.texts + 1] = { gid = gid, text = text } end,
} }

world = {
	event = { S_EVENT_BIRTH = 15, S_EVENT_DEAD = 8, S_EVENT_CRASH = 5, S_EVENT_PILOT_DEAD = 9,
		S_EVENT_EJECTION = 6, S_EVENT_LAND = 4, S_EVENT_PLAYER_LEAVE_UNIT = 21,
		S_EVENT_MARK_ADDED = 25, S_EVENT_MARK_CHANGE = 26, S_EVENT_MARK_REMOVED = 27,
		S_EVENT_KILL = 28, S_EVENT_UNIT_LOST = 30 },
	addEventHandler = function(h) STUB.handlers[#STUB.handlers + 1] = h end,
}
function STUB.fire(event)
	for _, h in ipairs(STUB.handlers) do h:onEvent(event) end
end

AI = {
	Option = { Air = { id = { ROE = 0 }, val = { ROE = { WEAPON_FREE = 0, OPEN_FIRE_WEAPON_FREE = 1,
		OPEN_FIRE = 2, RETURN_FIRE = 3, WEAPON_HOLD = 4 } } } },
	Task = { OrbitPattern = { CIRCLE = 'Circle', RACE_TRACK = 'Race-Track' } },
}
Group = { Category = { AIRPLANE = 0, HELICOPTER = 1, GROUND = 2, SHIP = 3 } }
Airbase = { Category = { AIRDROME = 0, HELIPAD = 1, SHIP = 2 } }
coalition = { side = { NEUTRAL = 0, RED = 1, BLUE = 2 } }
land = { getHeight = function() return 10 end, SurfaceType = { LAND = 1, SHALLOW_WATER = 2, WATER = 3, ROAD = 4 },
	getSurfaceType = function(p) return (STUB.water and STUB.water(p)) and 3 or 1 end }
Object = { Category = { UNIT = 1, WEAPON = 2, STATIC = 3 } }

-- Units and groups ------------------------------------------------------------
local Controller = {}
Controller.__index = Controller
function Controller:setTask(task) self.task = task; self.history[#self.history + 1] = task end
function Controller:resetTask() self.task = nil end
function Controller:setOption(id, value) self.options[id] = value end
function Controller:setCommand(cmd) self.commands[#self.commands + 1] = cmd end

local UnitMT = {}
UnitMT.__index = UnitMT
function UnitMT:isExist() return self.alive end
function UnitMT:getName() return self.name end
function UnitMT:getPlayerName() return self.player end
function UnitMT:getTypeName() return self.type end
function UnitMT:getGroup() return self.group end
function UnitMT:getPoint() return { x = self.p.x, y = self.p.y, z = self.p.z } end
function UnitMT:getPosition()
	return { p = self:getPoint(), x = { x = math.cos(self.hdg), y = 0, z = math.sin(self.hdg) } }
end
function UnitMT:getVelocity() return { x = math.cos(self.hdg) * self.spd, y = 0, z = math.sin(self.hdg) * self.spd } end
function UnitMT:inAir() return self.air end
function UnitMT:getFuel() return 0.8 end
function UnitMT:getAmmo() return { { count = 2, desc = { displayName = 'AIM-9M' } } } end
function UnitMT:getCoalition() return self.group.side end
function UnitMT:getCategory() return Object.Category.UNIT end
function UnitMT:getDesc() return { category = self.descCategory or (self.group.category == 1 and 1 or self.group.category) } end
function UnitMT:hasAttribute(a) return self.attrs ~= nil and self.attrs[a] == true end
function UnitMT:getLife() return self.alive and 1 or 0 end
function UnitMT:getController() return self.controller end

local GroupMT = {}
GroupMT.__index = GroupMT
function GroupMT:isExist() return self.alive end
function GroupMT:getName() return self.name end
function GroupMT:getID() return self.id end
function GroupMT:getCategory() return self.category end
function GroupMT:getCoalition() return self.side end
function GroupMT:getUnits() return self.units end
function GroupMT:getUnit(i) return self.units[i] end
function GroupMT:getSize() return #self.units end
function GroupMT:getController() return self.controller end
function GroupMT:destroy() self.alive = false; STUB.groups[self.name] = nil end

function STUB.makeGroup(name, category, side, unitDefs)
	STUB.nextGroupId = STUB.nextGroupId + 1
	local g = setmetatable({ name = name, id = STUB.nextGroupId, category = category, side = side,
		alive = true, units = {},
		controller = setmetatable({ history = {}, options = {}, commands = {} }, Controller) }, GroupMT)
	for i, d in ipairs(unitDefs) do
		local u = setmetatable({ name = d.name, type = d.type, player = d.player, group = g, alive = true,
			p = d.p, hdg = d.hdg or 0, spd = d.spd or 150, air = d.air ~= false, attrs = d.attrs,
			descCategory = d.descCategory,
			controller = setmetatable({ history = {}, options = {}, commands = {} }, Controller) }, UnitMT)
		g.units[i] = u
		STUB.units[u.name] = u
	end
	STUB.groups[name] = g
	return g
end

Group.getByName = function(name) return STUB.groups[name] end

coalition.getPlayers = function(side)
	local out = {}
	for _, u in pairs(STUB.units) do
		if u.player and u.group.side == side and u.alive then out[#out + 1] = u end
	end
	return out
end
coalition.addGroup = function(countryId, categoryId, data)
	STUB.addGroupCalls[#STUB.addGroupCalls + 1] = { countryId = countryId, categoryId = categoryId, data = data }
	local defs = {}
	for i, u in ipairs(data.units) do
		defs[i] = { name = u.name, type = u.type, p = { x = u.x, y = u.alt, z = u.y }, hdg = u.heading, spd = u.speed }
	end
	return STUB.makeGroup(data.name, categoryId, (STUB.countrySide or {})[countryId] or 2, defs)
end
STUB.countrySide = { [81] = 1, [0] = 1 }
local airbases = {}
function STUB.addAirbase(name, side, category, p)
	airbases[#airbases + 1] = { side = side, name = name,
		getName = function() return name end,
		getDesc = function() return { category = category } end,
		getPoint = function() return p end }
end
coalition.getAirbases = function(side)
	local out = {}
	for _, ab in ipairs(airbases) do if ab.side == side then out[#out + 1] = ab end end
	return out
end

-- MOOSE ------------------------------------------------------------------------
STUB.spawns = {}
SPAWN = {}
SPAWN.__index = SPAWN
function SPAWN:NewWithAlias(template, alias)
	return setmetatable({ template = template, alias = alias }, SPAWN)
end
function SPAWN:InitValidateAndRepositionGroundUnits() return self end
function SPAWN:SpawnFromVec2(v)
	local entry = _DATABASE.Templates.Groups[self.template]
	if not entry or STUB.failSpawn then return nil end
	local name = self.alias .. '#001'
	local side = (STUB.countrySide or {})[entry.CountryID] or 2
	local defs = {}
	for i, u in ipairs(entry.Template.units) do
		defs[i] = { name = name .. '-' .. i, type = u.type, p = { x = v.x, y = 0, z = v.y }, air = false, attrs = u.attrs }
	end
	STUB.makeGroup(name, entry.CategoryID or 2, side, defs)
	STUB.spawns[#STUB.spawns + 1] = { template = self.template, name = name, x = v.x, z = v.y }
	return { GetName = function() return name end }
end
_DATABASE = { Templates = { Groups = {}, Units = {} }, nextStn = 100 }
function _DATABASE:GetNextSTN(octal, unitName)
	self.nextStn = self.nextStn + 1
	return self.nextStn
end

GROUP = {}
function GROUP:FindByName(name)
	if not STUB.groups[name] then return nil end
	return {
		name = name,
		GetCoordinate = function() return {
			WaypointAirTurningPoint = function(_, alt, spd, tasks, d) return { kind = 'turn', speed = spd, name = d } end,
		} end,
		Route = function(_, points, delay) STUB.groups[name].route = points end,
	}
end
AIRBASE = {}
function AIRBASE:FindByName(name)
	return { GetCoordinate = function() return {
		WaypointAirLanding = function(_, spd, ab, tasks, d) return { kind = 'land', airbase = name, name = d } end,
	} end }
end

local function menuPath(parent, text) return (parent and parent.path .. '/' or '') .. text end
MENU_GROUP = {}
function MENU_GROUP:New(group, text, parent)
	local m = { path = menuPath(parent, text) }
	STUB.menus[group.name .. ':' .. m.path] = m
	return m
end
MENU_GROUP_COMMAND = {}
function MENU_GROUP_COMMAND:New(group, text, parent, fn, ...)
	local args = { ... }
	local m = { path = menuPath(parent, text), call = function() return fn(unpack(args)) end }
	STUB.menus[group.name .. ':' .. m.path] = m
	return m
end
function STUB.menu(groupName, path)
	local m = STUB.menus[groupName .. ':' .. path]
	assert(m and m.call, 'menu not found: ' .. path)
	return m.call()
end
