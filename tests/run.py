#!/usr/bin/env python3
"""Offline test for the bubble_columns mod.

Runs init.lua against a stubbed Luanti engine (via the lupa module), builds
water columns over various blocks, drives the ABM and globalstep by hand and
asserts what the physics does to objects sitting in them -- including the
several things the mod must deliberately not do.  No Luanti install needed:

    python3 tests/run.py
"""
import os
import sys

import lupa

MODPATH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------
# Stubbed engine
# --------------------------------------------------------------------------
STUBS = r"""
SETTINGS = ...

WORLD = {}          -- "x,y,z" -> node name
OBJECTS = {}        -- list of stub objects
PARTICLES = {}      -- every core.add_particlespawner def, in order
ABMS = {}
GLOBALSTEPS = {}
JOIN_CALLBACKS = {}
LEAVE_CALLBACKS = {}
LOGS = {}
CHATCOMMANDS = {}
PLAYERS_BY_NAME = {}
PHYSICS_CALLS = 0

-- vector ------------------------------------------------------------------
vector = {}
function vector.new(x, y, z) return {x = x or 0, y = y or 0, z = z or 0} end
function vector.round(a)
	return vector.new(math.floor(a.x + 0.5), math.floor(a.y + 0.5), math.floor(a.z + 0.5))
end

-- world -------------------------------------------------------------------
local function key(p)
	return math.floor(p.x + 0.5) .. "," .. math.floor(p.y + 0.5) .. "," .. math.floor(p.z + 0.5)
end
function WORLD_SET(x, y, z, name) WORLD[x .. "," .. y .. "," .. z] = name end
function WORLD_CLEAR() WORLD = {} end

-- Only the groups the mod actually consults.
local NODE_GROUPS = {
	["mcl_core:water_source"]  = {water = 3, liquid = 3},
	["mcl_core:water_flowing"] = {water = 3, liquid = 3},
	["mcl_nether:soul_sand"]   = {soul_block = 1},
	-- Soul soil really does live in a different mod to soul sand, and really
	-- does share the soul_block group with it. Both matter to this mod.
	["mcl_blackstone:soul_soil"] = {soul_block = 1},
	["mcl_nether:magma"]       = {fire = 1},
}

-- core --------------------------------------------------------------------
core = {}
minetest = core

core.settings = {
	get = function(_, k)
		local v = SETTINGS[k]
		if v == nil then return nil end
		return tostring(v)
	end,
	get_bool = function(_, k)
		local v = SETTINGS[k]
		if v == nil then return nil end
		return v ~= false and v ~= "false"
	end,
}

function core.get_current_modname() return "bubble_columns" end
function core.get_node(p) return {name = WORLD[key(p)] or "air", param2 = 0} end
function core.get_item_group(name, group)
	local g = NODE_GROUPS[name]
	return g and g[group] or 0
end
function core.hash_node_position(p)
	return key(p)
end
function core.add_particlespawner(def)
	table.insert(PARTICLES, def)
	return #PARTICLES
end
function core.register_abm(def) table.insert(ABMS, def) end
function core.register_globalstep(f) table.insert(GLOBALSTEPS, f) end
function core.register_on_joinplayer(f) table.insert(JOIN_CALLBACKS, f) end
function core.register_on_leaveplayer(f) table.insert(LEAVE_CALLBACKS, f) end
function core.log(_, msg) table.insert(LOGS, msg) end
function core.register_chatcommand(name, def) CHATCOMMANDS[name] = def end
function core.get_player_by_name(n) return PLAYERS_BY_NAME[n] end
function core.get_connected_players()
	local players = {}
	for _, obj in ipairs(OBJECTS) do
		if obj._player and obj._valid ~= false then
			table.insert(players, obj)
		end
	end
	return players
end
function core.pos_to_string(p)
	return "(" .. p.x .. "," .. p.y .. "," .. p.z .. ")"
end

-- playerphysics ------------------------------------------------------------
-- Real one serialises into player meta; here we just record the factors so a
-- test can assert they are set on entry and cleared on exit.
playerphysics = {}
function playerphysics.add_physics_factor(player, attribute, id, value)
	player._factors[attribute .. "/" .. id] = value
	PHYSICS_CALLS = PHYSICS_CALLS + 1
end
function playerphysics.remove_physics_factor(player, attribute, id)
	player._factors[attribute .. "/" .. id] = nil
	PHYSICS_CALLS = PHYSICS_CALLS + 1
end

function core.get_objects_in_area(minp, maxp)
	local found = {}
	for _, obj in ipairs(OBJECTS) do
		local p = obj._pos
		if p.x >= minp.x and p.x <= maxp.x
			and p.y >= minp.y and p.y <= maxp.y
			and p.z >= minp.z and p.z <= maxp.z then
			table.insert(found, obj)
		end
	end
	return found
end

-- objects -----------------------------------------------------------------
local object_mt = {}
object_mt.__index = object_mt

function object_mt:is_valid() return self._valid ~= false end
function object_mt:is_player() return self._player == true end
function object_mt:get_attach() return self._attach end
function object_mt:get_velocity() return self._vel end
function object_mt:add_velocity(v)
	self._vel = vector.new(self._vel.x + v.x, self._vel.y + v.y, self._vel.z + v.z)
end
function object_mt:get_properties() return {breath_max = self._breath_max or 10} end
function object_mt:get_breath() return self._breath end
function object_mt:set_breath(b) self._breath = b end
function object_mt:get_player_name() return self._name or "stub" end
function object_mt:get_luaentity() return self._luaentity end
function object_mt:get_pos() return self._pos end
function object_mt:get_physics_override()
	-- Mirrors playerphysics: each attribute is the product of its factors.
	local function product(attribute)
		local p = 1
		local prefix = attribute .. "/"
		for k, v in pairs(self._factors) do
			if k:sub(1, #prefix) == prefix then p = p * v end
		end
		return p
	end
	return {
		gravity = product("gravity"),
		liquid_sink = product("liquid_sink"),
		liquid_fluidity = product("liquid_fluidity"),
	}
end

function MAKE_OBJECT(x, y, z, opts)
	opts = opts or {}
	local obj = setmetatable({
		_pos = vector.new(x, y, z),
		_vel = vector.new(0, opts.vy or 0, 0),
		_player = opts.player,
		_attach = opts.attach,
		_valid = opts.valid,
		_breath = opts.breath or 10,
		_breath_max = opts.breath_max,
		_name = opts.name,
		_factors = {},
	}, object_mt)
	if opts.player and opts.name then
		PLAYERS_BY_NAME[opts.name] = obj
	end
	if opts.mob then
		-- Mobs take physics factors through the entity, not playerphysics.
		obj._luaentity = {
			is_mob = true,
			factors = {},
			add_physics_factor = function(self, field, id, value)
				self.factors[field .. "/" .. id] = value
			end,
			remove_physics_factor = function(self, field, id)
				self.factors[field .. "/" .. id] = nil
			end,
		}
	end
	table.insert(OBJECTS, obj)
	return obj
end

function FACTOR(obj, key) return obj._factors[key] end
function MOB_FACTOR(obj, key) return obj._luaentity.factors[key] end
function PHYSICS_CALL_COUNT() return PHYSICS_CALLS end
function RUN_JOIN(obj)
	for _, f in ipairs(JOIN_CALLBACKS) do f(obj) end
end

function OBJECTS_CLEAR() OBJECTS = {} end
function PARTICLES_CLEAR() PARTICLES = {} end

-- driving the registered callbacks ---------------------------------------
function RUN_ABM(x, y, z)
	local pos = vector.new(x, y, z)
	local node = core.get_node(pos)
	for _, abm in ipairs(ABMS) do
		for _, name in ipairs(abm.nodenames) do
			if name == node.name then
				abm.action(pos, node)
			end
		end
	end
end

function RUN_STEPS(total, dtime)
	local left = total
	while left > 1e-9 do
		local step = math.min(dtime, left)
		for _, f in ipairs(GLOBALSTEPS) do f(step) end
		left = left - step
	end
end
"""


def load_mod(settings=None):
    """Fresh Lua state with the stubbed engine and init.lua loaded into it."""
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    settings_tbl = lua.eval("{}")
    for k, v in (settings or {}).items():
        settings_tbl[k] = v
    run = lua.eval("function(src, ...) return load(src)(...) end")
    run(STUBS, settings_tbl)
    with open(os.path.join(MODPATH, "init.lua")) as fh:
        run(fh.read())
    return lua


# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------
FAILURES = []
CHECKS = [0]


def check(label, condition, detail=""):
    CHECKS[0] += 1
    if condition:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}{('  -- ' + str(detail)) if detail != '' else ''}")
        FAILURES.append(label)


def close(a, b, tol=1e-6):
    return abs(a - b) < tol


def build_column(lua, x, z, source, depth, base_y=0):
    """Put `source` at base_y and `depth` water nodes above it."""
    g = lua.globals()
    g.WORLD_SET(x, base_y, z, source)
    for i in range(1, depth + 1):
        g.WORLD_SET(x, base_y + i, z, "mcl_core:water_source")


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------
def test_column_detection():
    print("column detection")
    lua = load_mod()
    g = lua.globals()

    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM(0, 0, 0)
    cols = g.bubble_columns.columns
    entry = cols["0,0,0"]
    check("soul sand under water registers a column", entry is not None)
    check("kind is up", entry and entry.kind == "up", entry and entry.kind)
    check("height matches the water depth", entry and entry.height == 4,
          entry and entry.height)

    build_column(lua, 5, 0, "mcl_nether:magma", 3)
    g.RUN_ABM(5, 0, 0)
    entry = g.bubble_columns.columns["5,0,0"]
    check("magma registers a column", entry is not None)
    check("kind is down", entry and entry.kind == "down", entry and entry.kind)

    # Soul soil shares the soul_block group but has no column in Minecraft.
    # This is the real-world mix-up that made the mod look broken in game.
    build_column(lua, 10, 0, "mcl_blackstone:soul_soil", 4)
    g.RUN_ABM(10, 0, 0)
    check("soul soil does NOT make a column by default",
          g.bubble_columns.columns["10,0,0"] is None)

    lua_soil = load_mod({"bubble_columns_soul_soil_too": True})
    gs = lua_soil.globals()
    build_column(lua_soil, 10, 0, "mcl_blackstone:soul_soil", 4)
    gs.RUN_ABM(10, 0, 0)
    entry = gs.bubble_columns.columns["10,0,0"]
    check("soul_soil_too=true opts soul soil in", entry is not None)
    check("opted-in soul soil lifts rather than sinks",
          entry and entry.kind == "up", entry and entry.kind)

    # Source with no water above it.
    g.WORLD_SET(15, 0, 0, "mcl_nether:soul_sand")
    g.RUN_ABM(15, 0, 0)
    check("dry soul sand does NOT make a column",
          g.bubble_columns.columns["15,0,0"] is None)

    # An air gap truncates the column.
    build_column(lua, 20, 0, "mcl_nether:soul_sand", 6)
    g.WORLD_SET(20, 4, 0, "air")
    g.RUN_ABM(20, 0, 0)
    entry = g.bubble_columns.columns["20,0,0"]
    check("column stops at an air gap", entry and entry.height == 3,
          entry and entry.height)


def test_max_height():
    print("max height cap")
    lua = load_mod({"bubble_columns_max_height": 5})
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 40)
    g.RUN_ABM(0, 0, 0)
    entry = g.bubble_columns.columns["0,0,0"]
    check("deep water is capped at max_height", entry and entry.height == 5,
          entry and entry.height)


def test_updraft_physics():
    print("updraft physics")
    lua = load_mod({"bubble_columns_up_speed": 8, "bubble_columns_accel": 30})
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM(0, 0, 0)

    obj = g.MAKE_OBJECT(0, 2, 0, lua.table(player=False))
    g.RUN_STEPS(0.1, 0.05)
    check("one tick accelerates upward but not to terminal speed",
          0 < obj._vel.y < 8, obj._vel.y)
    check("one tick respects the acceleration cap",
          close(obj._vel.y, 30 * 0.1), obj._vel.y)

    g.RUN_STEPS(2.0, 0.05)
    check("sustained ride reaches terminal speed exactly",
          close(obj._vel.y, 8), obj._vel.y)
    check("terminal speed is never overshot", obj._vel.y <= 8 + 1e-9, obj._vel.y)
    check("horizontal velocity is untouched",
          close(obj._vel.x, 0) and close(obj._vel.z, 0))


def test_whirlpool_physics():
    print("whirlpool physics")
    lua = load_mod({"bubble_columns_down_speed": 6, "bubble_columns_accel": 30})
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:magma", 4)
    g.RUN_ABM(0, 0, 0)

    obj = g.MAKE_OBJECT(0, 2, 0)
    g.RUN_STEPS(2.0, 0.05)
    check("magma column drives objects down to terminal speed",
          close(obj._vel.y, -6), obj._vel.y)

    # An object already falling faster than the whirlpool gets slowed to it,
    # not accelerated further.
    fast = g.MAKE_OBJECT(0, 2, 0, lua.table(vy=-20))
    g.RUN_STEPS(2.0, 0.05)
    check("a faster faller is braked to terminal speed, not sped up",
          close(fast._vel.y, -6), fast._vel.y)


def test_standing_on_the_source_block():
    """The in-game failure: standing ON the soul sand put the player at the
    box's lower edge, so get_objects_in_area never returned them and nothing
    happened. Players must not depend on that box at all."""
    print("standing on the source block")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 16)

    # Source block at y=0 spans -0.5..0.5, so feet land at y=0.5 -- and float
    # error can put them a hair either side of it. Both must work.
    for label, feet_y in (("exactly on the top face", 0.5),
                          ("a hair below it", 0.4999),
                          ("a hair above it", 0.5001)):
        lua_t = load_mod()
        gt = lua_t.globals()
        build_column(lua_t, 0, 0, "mcl_nether:soul_sand", 16)
        player = gt.MAKE_OBJECT(0, feet_y, 0,
                                lua_t.table(player=True, name="frank"))
        gt.RUN_STEPS(0.5, 0.05)
        check(f"player standing {label} is lifted",
              gt.FACTOR(player, "gravity/bubble_columns:column") == 0,
              gt.FACTOR(player, "gravity/bubble_columns:column"))

    # An item resting on the block is inside the box now that it reaches down
    # to the block's own cell. No player here, so the ABM has to register it.
    g.RUN_ABM(0, 0, 0)
    item = g.MAKE_OBJECT(0, 0.5, 0)
    g.RUN_STEPS(0.5, 0.05)
    check("an entity resting on the source block is carried", item._vel.y > 0,
          item._vel.y)


def test_selectivity():
    print("what must NOT be moved")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM(0, 0, 0)

    outside_x = g.MAKE_OBJECT(3, 2, 0)
    above = g.MAKE_OBJECT(0, 9, 0)
    below = g.MAKE_OBJECT(0, -2, 0)
    attached = g.MAKE_OBJECT(0, 2, 0, lua.table(attach="boat"))
    invalid = g.MAKE_OBJECT(0, 2, 0, lua.table(valid=False))
    inside = g.MAKE_OBJECT(0, 2, 0)

    g.RUN_STEPS(1.0, 0.05)
    check("object in a neighbouring column is untouched", close(outside_x._vel.y, 0))
    check("object above the column top is untouched", close(above._vel.y, 0))
    check("object below the source block is untouched", close(below._vel.y, 0))
    check("attached object (rider) is untouched", close(attached._vel.y, 0))
    check("invalid object is untouched", close(invalid._vel.y, 0))
    check("object inside the column IS moved", inside._vel.y > 0, inside._vel.y)


def test_breath():
    print("air supply")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    build_column(lua, 8, 0, "mcl_nether:magma", 4)
    g.RUN_ABM(0, 0, 0)
    g.RUN_ABM(8, 0, 0)

    rising = g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, breath=3))
    sinking = g.MAKE_OBJECT(8, 2, 0, lua.table(player=True, breath=3))
    mob = g.MAKE_OBJECT(0, 2, 0, lua.table(player=False, breath=3))

    g.RUN_STEPS(0.5, 0.05)
    check("updraft refills a player's air", rising._breath == 10, rising._breath)
    check("whirlpool does NOT refill air", sinking._breath == 3, sinking._breath)
    check("non-player breath is left alone", mob._breath == 3, mob._breath)

    lua2 = load_mod({"bubble_columns_restore_air": False})
    g2 = lua2.globals()
    build_column(lua2, 0, 0, "mcl_nether:soul_sand", 4)
    g2.RUN_ABM(0, 0, 0)
    off = g2.MAKE_OBJECT(0, 2, 0, lua2.table(player=True, breath=3))
    g2.RUN_STEPS(0.5, 0.05)
    check("restore_air=false disables the refill", off._breath == 3, off._breath)


def test_expiry():
    print("column expiry")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM(0, 0, 0)
    check("column present right after the ABM",
          g.bubble_columns.columns["0,0,0"] is not None)

    # ABM_INTERVAL is 2s and TTL is 3.5s, so one interval must not expire it.
    g.RUN_STEPS(2.0, 0.1)
    check("column survives one ABM interval without a refresh",
          g.bubble_columns.columns["0,0,0"] is not None)

    g.RUN_STEPS(3.0, 0.1)
    check("column expires once refreshes stop",
          g.bubble_columns.columns["0,0,0"] is None)

    obj = g.MAKE_OBJECT(0, 2, 0)
    g.RUN_STEPS(1.0, 0.05)
    check("an expired column stops pushing", close(obj._vel.y, 0), obj._vel.y)


def test_gravity_lift():
    """The bug that made the first version do nothing in game: driving
    velocity while the engine kept reapplying gravity and liquid drag."""
    print("gravity cancellation")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    build_column(lua, 8, 0, "mcl_nether:magma", 4)
    g.RUN_ABM(0, 0, 0)
    g.RUN_ABM(8, 0, 0)

    player = g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, name="alice"))
    sinker = g.MAKE_OBJECT(8, 2, 0, lua.table(player=True, name="bob"))
    mob = g.MAKE_OBJECT(0, 2, 0, lua.table(mob=True))

    g.RUN_STEPS(0.5, 0.05)
    # Gravity is neutralised, not inverted: measured in game, a negative
    # gravity override does NOT lift a player inside a liquid.
    check("updraft neutralises the player's gravity",
          g.FACTOR(player, "gravity/bubble_columns:column") == 0,
          g.FACTOR(player, "gravity/bubble_columns:column"))
    check("updraft zeroes a mob's fall_speed factor",
          g.MOB_FACTOR(mob, "fall_speed/bubble_columns:column") == 0)
    check("whirlpool leaves gravity alone (it is an ally there)",
          g.FACTOR(sinker, "gravity/bubble_columns:column") is None,
          g.FACTOR(sinker, "gravity/bubble_columns:column"))

    # The server must NOT touch a rising player's velocity. add_velocity
    # arbitrates against a get_velocity() that lags the client, so rewriting
    # it every step overshoots and pumps energy in -- the jitter and the
    # growing surface bounce. The liquid_sink override is the whole lift.
    check("server does NOT rewrite a rising player's velocity",
          close(player._vel.y, 0), player._vel.y)
    check("whirlpool player IS driven (no client-side equivalent)",
          close(sinker._vel.y, -6), sinker._vel.y)
    check("entity in the same column is driven server-side", mob._vel.y > 0,
          mob._vel.y)

    # Setting the factor writes player meta, so it must happen once on entry,
    # not on every one of the ~10 ticks that just elapsed.
    calls = g.PHYSICS_CALL_COUNT()
    g.RUN_STEPS(1.0, 0.05)
    check("gravity factor is not rewritten every tick",
          g.PHYSICS_CALL_COUNT() == calls, f"{calls} -> {g.PHYSICS_CALL_COUNT()}")

    # Leave the column: gravity must come back.
    player._pos = g.vector.new(30, 30, 30)
    g.RUN_STEPS(0.5, 0.05)
    check("leaving the column restores the player's gravity",
          g.FACTOR(player, "gravity/bubble_columns:column") is None)
    check("leaving the column restores a mob's fall speed",
          g.MOB_FACTOR(mob, "fall_speed/bubble_columns:column") == 0,
          "mob still inside, should be untouched")

    mob._pos = g.vector.new(30, 30, 30)
    g.RUN_STEPS(0.5, 0.05)
    check("mob leaving the column restores its fall speed",
          g.MOB_FACTOR(mob, "fall_speed/bubble_columns:column") is None)

    # Detection must work from the player scan alone, with the ABM never
    # invoked -- that is the whole point of the rewrite.
    lua2 = load_mod()
    g2 = lua2.globals()
    build_column(lua2, 0, 0, "mcl_nether:soul_sand", 4)
    stuck = g2.MAKE_OBJECT(0, 2, 0, lua2.table(player=True, name="carol"))
    g2.RUN_STEPS(0.5, 0.05)
    check("player scan alone discovers the column (ABM never run)",
          g2.FACTOR(stuck, "gravity/bubble_columns:column") == 0,
          g2.FACTOR(stuck, "gravity/bubble_columns:column"))

    # While someone stands in it the scan keeps refreshing it, so it must not
    # time out under them.
    g2.RUN_STEPS(10.0, 0.1)
    check("column does not expire while a player stands in it",
          g2.FACTOR(stuck, "gravity/bubble_columns:column") == 0)

    # Digging the source block out must release them.
    g2.WORLD_SET(0, 0, 0, "mcl_core:stone")
    g2.RUN_STEPS(5.0, 0.1)
    check("removing the source block releases the player",
          g2.FACTOR(stuck, "gravity/bubble_columns:column") is None)


def test_liquid_overrides():
    """The client's own liquid model is what makes the climb smooth and lets
    it exceed ordinary swim-up speed; the deadband stops the server fighting
    it every step, which is what the player felt as hiccuping."""
    print("liquid model overrides")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 16)
    player = g.MAKE_OBJECT(0, 4, 0, lua.table(player=True, name="gail"))
    g.RUN_STEPS(0.2, 0.05)

    sink = g.FACTOR(player, "liquid_sink/bubble_columns:column")
    check("updraft sinks upward (negative liquid_sink is the lift)",
          sink == -1.4, sink)
    check("updraft lowers liquid resistance",
          g.FACTOR(player, "liquid_fluidity/bubble_columns:column") == 1.5,
          g.FACTOR(player, "liquid_fluidity/bubble_columns:column"))
    check("liquid_fluidity stays >= 1 (below 1 is unsupported)",
          g.FACTOR(player, "liquid_fluidity/bubble_columns:column") >= 1)

    # No matter how far off target, the server must never rewrite a rising
    # player's velocity -- that stale-read rewrite is the whole failure mode.
    for start in (0.0, 1.0, 25.0):
        player._vel = g.vector.new(0, start, 0)
        g.RUN_STEPS(0.15, 0.05)
        check(f"velocity left alone when rising at {start}",
              close(player._vel.y, start), player._vel.y)

    # Leaving must restore every override, not just gravity.
    player._pos = g.vector.new(50, 50, 50)
    g.RUN_STEPS(0.5, 0.05)
    for attr in ("gravity", "liquid_sink", "liquid_fluidity"):
        check(f"leaving restores {attr}",
              g.FACTOR(player, f"{attr}/bubble_columns:column") is None)

    # Fluidity below 1 is unsupported by the engine and misbehaves silently.
    lua_neg = load_mod({"bubble_columns_liquid_fluidity": 0.2})
    gn = lua_neg.globals()
    build_column(lua_neg, 0, 0, "mcl_nether:soul_sand", 16)
    victim = gn.MAKE_OBJECT(0, 4, 0, lua_neg.table(player=True, name="mo"))
    gn.RUN_STEPS(0.2, 0.05)
    check("a sub-1 liquid_fluidity from config is clamped to 1",
          gn.FACTOR(victim, "liquid_fluidity/bubble_columns:column") == 1,
          gn.FACTOR(victim, "liquid_fluidity/bubble_columns:column"))

    # A whirlpool must not get the lifting overrides.
    lua2 = load_mod()
    g2 = lua2.globals()
    build_column(lua2, 0, 0, "mcl_nether:magma", 16)
    sinker = g2.MAKE_OBJECT(0, 4, 0, lua2.table(player=True, name="hank"))
    g2.RUN_STEPS(0.2, 0.05)
    check("whirlpool does not touch liquid_sink",
          g2.FACTOR(sinker, "liquid_sink/bubble_columns:column") is None)
    check("whirlpool is driven outright, no deadband",
          close(sinker._vel.y, -6), sinker._vel.y)


def test_surface_resonance():
    """Breaching the top used to build a growing bounce: gravity stayed at 0
    for the 0.3s grace so the exit arc became a coast, the player fell back in
    faster, got re-driven to full speed and launched higher each cycle."""
    print("surface behaviour (no resonance)")
    lua = load_mod()
    g = lua.globals()
    # Water occupies y=1..4, so the surface is at y=4.5.
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)

    player = g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, name="iris"))
    g.RUN_STEPS(0.2, 0.05)
    check("submerged player is lifted",
          g.FACTOR(player, "gravity/bubble_columns:column") == 0)

    # Feet at node 4 (water), head at 5.4 -> node 5 -> air. Still lifted: the
    # lift runs while ANY part is wet, which is the extra node of push needed
    # to actually clear the surface.
    player._pos = g.vector.new(0, 4.0, 0)
    player._vel = g.vector.new(0, 6.0, 0)
    g.RUN_STEPS(0.05, 0.05)
    check("still lifted with only the feet in water (the extra node)",
          g.FACTOR(player, "liquid_sink/bubble_columns:column") is not None,
          g.FACTOR(player, "liquid_sink/bubble_columns:column"))

    # Fully clear of the water: feet at node 5, air.
    player._pos = g.vector.new(0, 5.0, 0)
    g.RUN_STEPS(0.05, 0.05)   # exactly one step
    check("released within ONE step of leaving the water, no grace",
          g.FACTOR(player, "gravity/bubble_columns:column") is None,
          g.FACTOR(player, "gravity/bubble_columns:column"))
    check("liquid_sink released too",
          g.FACTOR(player, "liquid_sink/bubble_columns:column") is None)
    check("velocity untouched on the way out",
          close(player._vel.y, 6.0), player._vel.y)
    check("not re-driven once the head is clear",
          close(player._vel.y, 6.0), player._vel.y)

    # The column must still be registered, so its bubbles keep drawing for
    # someone floating at the top.
    check("column still tracked while player is at the surface",
          g.bubble_columns.columns["0,0,0"] is not None)

    # Taper: full sink deep in the column, a fraction of it near the surface.
    lua_t = load_mod()
    gt = lua_t.globals()
    build_column(lua_t, 0, 0, "mcl_nether:soul_sand", 16)
    deep = gt.MAKE_OBJECT(0, 3, 0, lua_t.table(player=True, name="kim"))
    gt.RUN_STEPS(0.05, 0.05)
    check("full sink deep in the column",
          gt.FACTOR(deep, "liquid_sink/bubble_columns:column") == -1.4,
          gt.FACTOR(deep, "liquid_sink/bubble_columns:column"))

    # Surface is at 0.5 + 16 = 16.5, taper starts 2.5 below it. The head sits
    # 1.4 above the feet, so it leaves the water at about y=15.1 -- stay under
    # that or there is no lift to taper.
    near = gt.MAKE_OBJECT(0, 14.8, 0, lua_t.table(player=True, name="lee"))
    gt.RUN_STEPS(0.05, 0.05)
    sink_near = gt.FACTOR(near, "liquid_sink/bubble_columns:column")
    check("sink eased off approaching the surface",
          close(sink_near, -1.4 * 0.3), sink_near)
    check("still rising near the surface, not stalled", sink_near < 0, sink_near)

    # The taper is a state change, not a per-step recalculation --
    # playerphysics serialises to player meta on every write.
    calls = gt.PHYSICS_CALL_COUNT()
    gt.RUN_STEPS(1.0, 0.05)
    check("holding position does not rewrite player meta every step",
          gt.PHYSICS_CALL_COUNT() == calls,
          f"{calls} -> {gt.PHYSICS_CALL_COUNT()}")

    # Repeated surface bounces: nothing may accumulate. With the server never
    # touching a rising player's velocity there is no mechanism left to.
    peaks = []
    for _ in range(4):
        player._pos = g.vector.new(0, 2.0, 0)      # falls back in, submerged
        player._vel = g.vector.new(0, -6.0, 0)
        g.RUN_STEPS(0.1, 0.05)
        peaks.append(player._vel.y)
        player._pos = g.vector.new(0, 5.0, 0)      # fully clears the water
        g.RUN_STEPS(0.05, 0.05)
    check("re-entry velocity is never rewritten, so cannot compound",
          all(close(p, -6.0) for p in peaks), peaks)


def test_join_cleanup():
    print("crash-safety on join")
    lua = load_mod()
    g = lua.globals()
    player = g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, name="dave"))
    # Simulate a factor stranded in player meta by a crash mid-column.
    g.playerphysics.add_physics_factor(player, "gravity",
                                       "bubble_columns:column", 0)
    check("precondition: stranded zero-gravity factor",
          g.FACTOR(player, "gravity/bubble_columns:column") == 0)
    g.RUN_JOIN(player)
    check("joining clears a stranded zero-gravity factor",
          g.FACTOR(player, "gravity/bubble_columns:column") is None)


def test_bubblecheck_command():
    """The in-game diagnostic must never itself throw -- it is what gets run
    when nothing else works."""
    print("/bubblecheck diagnostic")
    lua = load_mod()
    g = lua.globals()
    cmd = g.CHATCOMMANDS["bubblecheck"]
    check("command is registered", cmd is not None)

    # No column anywhere, player in open air: must still report, not error.
    player = g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, name="erin"))
    ok, text = cmd.func("erin")
    check("runs with no column present", ok is True and text is not None)
    check("reports the failing stage", "stage 1 FAIL" in text, text)

    # Full working column.
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM(0, 0, 0)
    g.RUN_STEPS(0.5, 0.05)
    ok, text = cmd.func("erin")
    check("runs with a live column", ok is True)
    for stage in ("stage 1 ok", "stage 3 ok"):
        check(f"reports {stage}", stage in text, text)
    check("reports the physics overrides", "gravity=0.00" in text, text)
    check("reports the achieved climb speed", "your v.y" in text, text)

    # Unknown player must be handled, not crash.
    ok, text = cmd.func("nobody")
    check("unknown player is handled", ok is False)


def test_bubblespeed_command():
    """Climb speed can only be judged by riding a column, so it must be
    tunable without a restart."""
    print("/bubblespeed live tuning")
    lua = load_mod()
    g = lua.globals()
    cmd = g.CHATCOMMANDS["bubblespeed"]
    check("command is registered", cmd is not None)

    ok, text = cmd.func("nando", "")
    check("reports the current speed with no argument",
          ok is True and "-1.40" in text, text)

    for bad, why in ((" ", "not a number"), ("fast", "not a number"),
                     ("2", "positive would sink"), ("-99", "beyond tested")):
        ok, _ = cmd.func("nando", bad)
        check(f"rejects {bad!r} ({why})", ok is False)

    build_column(lua, 0, 0, "mcl_nether:soul_sand", 16)
    player = g.MAKE_OBJECT(0, 4, 0, lua.table(player=True, name="nando"))
    g.RUN_STEPS(0.2, 0.05)
    check("player lifted at the old speed",
          g.FACTOR(player, "liquid_sink/bubble_columns:column") == -1.4)

    ok, text = cmd.func("nando", "-2.2")
    check("accepts a new speed", ok is True)
    check("tells the user how to persist it",
          "bubble_columns_liquid_sink = -2.2" in text, text)

    g.RUN_STEPS(0.2, 0.05)
    check("already-lifted player picks up the new speed without relogging",
          g.FACTOR(player, "liquid_sink/bubble_columns:column") == -2.2,
          g.FACTOR(player, "liquid_sink/bubble_columns:column"))


def test_particles():
    print("particles")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.PARTICLES_CLEAR()
    g.RUN_ABM(0, 0, 0)
    check("ABM spawns exactly one spawner per column", len(g.PARTICLES) == 1)
    spawner = g.PARTICLES[1]
    check("reuses the game's own bubble texture",
          spawner.texture == "mcl_particles_bubble.png", spawner.texture)
    check("updraft bubbles move upward", spawner.minvel.y > 0, spawner.minvel.y)
    # Stops a node short of the surface: bubbles keep travelling after they
    # spawn, and filling to the top threw them clear of the water.
    check("spawn volume stops a node below the surface",
          close(spawner.minpos.y, 0.5) and close(spawner.maxpos.y, 3.5),
          f"{spawner.minpos.y}..{spawner.maxpos.y}")
    check("bubbles cannot outlive the node they have left to travel",
          spawner.maxvel.y * spawner.maxexptime < 1.0 + 1e-9,
          spawner.maxvel.y * spawner.maxexptime)
    check("spawner outlives the ABM interval (no visible pulsing)",
          spawner.time > 2, spawner.time)

    build_column(lua, 8, 0, "mcl_nether:magma", 4)
    g.PARTICLES_CLEAR()
    g.RUN_ABM(8, 0, 0)
    check("whirlpool bubbles move downward", g.PARTICLES[1].minvel.y < 0,
          g.PARTICLES[1].minvel.y)


def main():
    print(f"bubble_columns offline tests  (lua {lupa.LuaRuntime().lua_implementation})\n")
    for test in (test_column_detection, test_max_height, test_updraft_physics,
                 test_whirlpool_physics, test_standing_on_the_source_block,
                 test_selectivity, test_breath,
                 test_gravity_lift, test_liquid_overrides, test_surface_resonance,
                 test_join_cleanup,
                 test_bubblecheck_command, test_bubblespeed_command,
                 test_expiry, test_particles):
        test()
        print()

    print(f"{CHECKS[0]} checks, {len(FAILURES)} failed")
    if FAILURES:
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
