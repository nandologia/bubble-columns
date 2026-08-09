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
MODS_LOADED = {}

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
-- Mineclonia's shape. VoxeLibre's is different in one way that mattered a
-- great deal; see USE_VOXELIBRE_WATER below.
NODE_GROUPS = {
	["mcl_core:water_source"]  = {water = 3, liquid = 3, liquid_source = 1},
	["mcl_core:water_flowing"] = {water = 3, liquid = 3, liquid_flowing = 1},
	-- River water copies the water source definition, so it counts too.
	["mclx_core:river_water_source"] = {water = 3, liquid = 3, liquid_source = 1},
	["mcl_nether:soul_sand"]   = {soul_block = 1},
	-- Soul soil really does live in a different mod to soul sand, and really
	-- does share the soul_block group with it. Both matter to this mod.
	["mcl_blackstone:soul_soil"] = {soul_block = 1},
	["mcl_nether:magma"]       = {fire = 1},
}

-- Source vs flowing is a node-definition field, not a group. It is what the
-- mod reads, because the liquid_source group exists in Mineclonia and not in
-- VoxeLibre.
local NODE_LIQUIDTYPE = {
	["mcl_core:water_source"]  = "source",
	["mcl_core:water_flowing"] = "flowing",
	["mclx_core:river_water_source"] = "source",
}

-- VoxeLibre's water source carries no liquid_source group at all. Testing for
-- that group is exactly what stopped the mod working there, so a test has to
-- be able to build a world shaped its way.
function USE_VOXELIBRE_WATER()
	NODE_GROUPS["mcl_core:water_source"] =
		{water = 3, liquid = 3, water_palette = 1}
	NODE_GROUPS["mcl_core:water_flowing"] = {water = 3, liquid = 3}
	NODE_GROUPS["mclx_core:river_water_source"] = {water = 3, liquid = 3}
end

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

-- The mod only registers columns on source blocks that actually exist, so the
-- stub has to have definitions for every node it names, not just the liquids.
core.registered_nodes = {}
for name in pairs(NODE_GROUPS) do
	core.registered_nodes[name] = {liquidtype = NODE_LIQUIDTYPE[name]}
end
function core.add_particlespawner(def)
	table.insert(PARTICLES, def)
	return #PARTICLES
end
function core.register_abm(def) table.insert(ABMS, def) end
function core.register_globalstep(f) table.insert(GLOBALSTEPS, f) end
function core.register_on_mods_loaded(f) table.insert(MODS_LOADED, f) end
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
function object_mt:get_properties()
	return {
		breath_max = self._breath_max or 10,
		collisionbox = self._collisionbox,
	}
end
function object_mt:get_breath() return self._breath end
function object_mt:set_breath(b) self._breath = b end
function object_mt:get_player_name() return self._name or "stub" end
function object_mt:get_luaentity() return self._luaentity end
function object_mt:get_pos() return self._pos end
function object_mt:set_pos(p) self._pos = vector.new(p.x, p.y, p.z) end
function object_mt:set_velocity(v) self._vel = vector.new(v.x, v.y, v.z) end
function object_mt:set_rotation(r) self._rot = vector.new(r.x, r.y, r.z) end
function object_mt:get_rotation() return self._rot or vector.new(0, 0, 0) end
function object_mt:get_yaw() return self:get_rotation().y end
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

-- boats -------------------------------------------------------------------
-- A stand-in for mcl_boats, faithful in the two respects the mod has to work
-- around: it rewrites the boat's velocity every step, and while the boat is
-- floating it snaps the position back to the top of its water node -- which
-- is what silently ate the whirlpool's push before.
core.registered_entities = {}
core.luaentities = {}
BOATS_LIVE = {}
local BOAT_Y_OFFSET = 0.35

function REGISTER_STUB_BOATS()
	for _, name in ipairs({"mcl_boats:boat", "mcl_boats:chest_boat"}) do
		core.registered_entities[name] = {
			name = name,
			on_step = function(self, dtime)
				local obj = self.object
				local pos = obj:get_pos()
				local base = {x = pos.x, y = pos.y - BOAT_Y_OFFSET, z = pos.z}
				local above = {x = pos.x, y = base.y + 1, z = pos.z}
				if core.get_item_group(core.get_node(base).name, "water") > 0
					and core.get_item_group(core.get_node(above).name, "water") == 0 then
					-- Floating: back to the top of the water node it sits on.
					obj:set_pos(vector.new(pos.x,
						math.floor(pos.y) + BOAT_Y_OFFSET, pos.z))
					obj:set_velocity(vector.new(0, 0, 0))
				end
				-- Level, as an undamaged boat always is.
				obj:set_rotation(vector.new(0, obj:get_yaw(), 0))
			end,
		}
	end
end

function MAKE_BOAT(x, y, z, name, hull)
	local obj = MAKE_OBJECT(x, y, z)
	-- Mineclonia's boat box starts at 0, VoxeLibre's at -0.15.
	obj._collisionbox = {-0.5, hull or 0, -0.5, 0.5, 0.55, 0.5}
	local def = core.registered_entities[name or "mcl_boats:boat"]
	-- The definition IS the metatable of every live boat, which is exactly
	-- what lets the mod's wrap of on_step reach instances made before it.
	local entity = setmetatable({object = obj}, {__index = def})
	obj._luaentity = entity
	table.insert(BOATS_LIVE, entity)
	table.insert(core.luaentities, entity)
	return obj, entity
end

function RUN_MODS_LOADED()
	for _, f in ipairs(MODS_LOADED) do f() end
end

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

-- Keeps firing the ABM at a position for as long as the test runs, the way
-- the real one does. Without it a column with no player in it expires after
-- COLUMN_TTL, which quietly ends any test that runs longer than that.
ABM_AUTO = {}
ABM_AUTO_TIMER = 0
function RUN_ABM_EVERY(x, y, z)
	table.insert(ABM_AUTO, {x = x, y = y, z = z})
	RUN_ABM(x, y, z)
end

function RUN_STEPS(total, dtime)
	local left = total
	while left > 1e-9 do
		local step = math.min(dtime, left)
		ABM_AUTO_TIMER = ABM_AUTO_TIMER + step
		if ABM_AUTO_TIMER >= 2 then
			ABM_AUTO_TIMER = 0
			for _, p in ipairs(ABM_AUTO) do RUN_ABM(p.x, p.y, p.z) end
		end
		for _, f in ipairs(GLOBALSTEPS) do f(step) end
		for _, entity in ipairs(BOATS_LIVE) do
			-- The engine integrates velocity and only then calls on_step,
			-- so anything set at the end of one step lands on the next.
			local obj = entity.object
			local vel = obj:get_velocity()
			obj:set_pos(vector.new(obj._pos.x + vel.x * step,
				obj._pos.y + vel.y * step,
				obj._pos.z + vel.z * step))
			entity:on_step(step)
		end
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


def test_source_water_only():
    """Minecraft columns propagate through water SOURCE blocks only and stop
    dead at flowing water."""
    print("source water only")
    lua = load_mod()
    g = lua.globals()

    # Flowing water directly above the block: no column at all.
    g.WORLD_SET(0, 0, 0, "mcl_nether:soul_sand")
    for i in range(1, 5):
        g.WORLD_SET(0, i, 0, "mcl_core:water_flowing")
    g.RUN_ABM(0, 0, 0)
    check("flowing water makes no column",
          g.bubble_columns.columns["0,0,0"] is None)

    # Source water that turns to flowing partway up: column stops there.
    build_column(lua, 6, 0, "mcl_nether:soul_sand", 6)
    g.WORLD_SET(6, 4, 0, "mcl_core:water_flowing")
    g.RUN_ABM(6, 0, 0)
    entry = g.bubble_columns.columns["6,0,0"]
    check("column stops at flowing water", entry and entry.height == 3,
          entry and entry.height)

    # River water is a source too, so it must work.
    g.WORLD_SET(12, 0, 0, "mcl_nether:soul_sand")
    for i in range(1, 5):
        g.WORLD_SET(12, i, 0, "mclx_core:river_water_source")
    g.RUN_ABM(12, 0, 0)
    entry = g.bubble_columns.columns["12,0,0"]
    check("river water counts as a source", entry and entry.height == 4,
          entry and entry.height)

    # A player standing in flowing water above a column is outside it.
    build_column(lua, 20, 0, "mcl_nether:soul_sand", 4)
    g.WORLD_SET(20, 3, 0, "mcl_core:water_flowing")
    swimmer = g.MAKE_OBJECT(20, 3, 0, lua.table(player=True, name="pat"))
    g.RUN_STEPS(0.2, 0.05)
    check("player in flowing water above the break is not lifted",
          g.FACTOR(swimmer, "liquid_sink/bubble_columns:column") is None,
          g.FACTOR(swimmer, "liquid_sink/bubble_columns:column"))


def test_voxelibre_water():
    """The mod did nothing at all in VoxeLibre. Its water source carries no
    liquid_source group -- Mineclonia's does -- and that group was what told
    still water from flowing, so every node failed the test and no column was
    ever found. Source has to be read from the node definition instead."""
    print("VoxeLibre water (no liquid_source group)")
    lua = load_mod()
    g = lua.globals()
    g.USE_VOXELIBRE_WATER()

    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM(0, 0, 0)
    entry = g.bubble_columns.columns["0,0,0"]
    check("a column forms over water with no liquid_source group",
          entry is not None)
    check("and reaches the full depth", entry and entry.height == 4,
          entry and entry.height)

    # The distinction it was drawing still has to hold.
    build_column(lua, 6, 0, "mcl_nether:soul_sand", 6)
    g.WORLD_SET(6, 4, 0, "mcl_core:water_flowing")
    g.RUN_ABM(6, 0, 0)
    entry = g.bubble_columns.columns["6,0,0"]
    check("flowing water still stops the column", entry and entry.height == 3,
          entry and entry.height)

    # River water is a copy of the water source definition in both games.
    g.WORLD_SET(12, 0, 0, "mcl_nether:soul_sand")
    for i in range(1, 5):
        g.WORLD_SET(12, i, 0, "mclx_core:river_water_source")
    g.RUN_ABM(12, 0, 0)
    entry = g.bubble_columns.columns["12,0,0"]
    check("river water still counts", entry and entry.height == 4,
          entry and entry.height)

    # And a player in one is actually lifted.
    player = g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, name="vera"))
    g.RUN_STEPS(0.2, 0.05)
    check("a player in a VoxeLibre column is lifted",
          g.FACTOR(player, "liquid_sink/bubble_columns:column") == -1.4,
          g.FACTOR(player, "liquid_sink/bubble_columns:column"))


def test_voxelibre_boat():
    """VoxeLibre's boat sits 0.15 lower in its own collision box, so the hull
    floor is not the boat's origin the way it is in Mineclonia."""
    print("VoxeLibre boats")
    lua = load_mod()
    g = lua.globals()
    g.USE_VOXELIBRE_WATER()
    g.REGISTER_STUB_BOATS()
    g.RUN_MODS_LOADED()
    build_column(lua, 0, 0, "mcl_nether:magma", 4)
    g.RUN_ABM_EVERY(0, 0, 0)
    obj, _ = g.MAKE_BOAT(0, 4.35, 0, "mcl_boats:boat", -0.15)

    g.RUN_STEPS(2.0, 0.05)
    check("boat rocks in VoxeLibre too",
          abs(obj._rot.x) > 0.05 or abs(obj._rot.z) > 0.05,
          (obj._rot.x, obj._rot.z))
    check("and has not sunk yet", close(obj._pos.y, 4.35, 0.01), obj._pos.y)

    g.RUN_STEPS(8.0, 0.05)
    # Hull floor is origin - 0.15, and the magma block's top face is y=0.5.
    check("boat rests on the magma block, not through it",
          0.65 <= obj._pos.y < 1.15, obj._pos.y)


def test_missing_source_block_is_loud():
    """The mod names its blocks, so a game that renames one breaks every stage
    at once and no stage says why -- which is exactly how it became a silent
    no-op under VoxeLibre. That has to be loud, at startup and in game."""
    print("a renamed source block")
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    run = lua.eval("function(src, ...) return load(src)(...) end")
    run(STUBS, lua.eval("{}"))
    # A game that has soul sand but has renamed magma.
    run('core.registered_nodes["mcl_nether:magma"] = nil')
    with open(os.path.join(MODPATH, "init.lua")) as fh:
        run(fh.read())
    g = lua.globals()

    logs = [str(m) for m in g.LOGS.values()]
    check("it says so at startup",
          any("mcl_nether:magma" in m for m in logs), logs[:3])
    check("and names the game it expects",
          any("Mineclonia" in m and "VoxeLibre" in m for m in logs), logs[:3])

    # A log line is no use to someone in game; /bubblecheck has to lead with it
    # rather than walking stages that all fail for the same hidden reason.
    g.MAKE_OBJECT(0, 2, 0, lua.table(player=True, name="rae"))
    ok, text = g.CHATCOMMANDS["bubblecheck"].func("rae")
    check("/bubblecheck leads with it", ok is True and "STOP:" in text, text)
    check("and does not walk the stages underneath it",
          "stage 1" not in text, text)
    check("and says the fix is not in the player's hands",
          "mod needs updating" in text, text)

    # A game with everything must say none of this.
    ok = load_mod()
    check("and none of it is said when the blocks are all present",
          not any("STOP" in str(m) or "does not have" in str(m)
                  for m in ok.globals().LOGS.values()),
          list(ok.globals().LOGS.values())[:3])


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
    # Minecraft replenishes air in bubble columns generally, not just rising
    # ones. A whirlpool stays dangerous by pinning you against burning magma.
    check("whirlpool refills air too, as in Minecraft",
          sinking._breath == 10, sinking._breath)
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
    check("server does NOT rewrite a sinking player's velocity either",
          close(sinker._vel.y, 0), sinker._vel.y)
    check("whirlpool sinks the player via a positive liquid_sink",
          g.FACTOR(sinker, "liquid_sink/bubble_columns:column") == 2.0,
          g.FACTOR(sinker, "liquid_sink/bubble_columns:column"))
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
    check("whirlpool sets a positive liquid_sink",
          g2.FACTOR(sinker, "liquid_sink/bubble_columns:column") == 2.0,
          g2.FACTOR(sinker, "liquid_sink/bubble_columns:column"))
    check("whirlpool leaves gravity alone (it is an ally going down)",
          g2.FACTOR(sinker, "gravity/bubble_columns:column") is None)
    check("whirlpool never rewrites the player's velocity",
          close(sinker._vel.y, 0), sinker._vel.y)


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

    # Surface is at 0.5 + 16 = 16.5. The taper is measured HEAD-to-surface and
    # the head sits 1.4 above the feet, so with a 1.0 taper easing starts once
    # the feet pass y = 16.5 - 1.4 - 1.0 = 14.1.
    still_full = gt.MAKE_OBJECT(0, 13.5, 0, lua_t.table(player=True, name="ned"))
    gt.RUN_STEPS(0.05, 0.05)
    check("full speed while the head is still well under",
          gt.FACTOR(still_full, "liquid_sink/bubble_columns:column") == -1.4,
          gt.FACTOR(still_full, "liquid_sink/bubble_columns:column"))

    near = gt.MAKE_OBJECT(0, 14.8, 0, lua_t.table(player=True, name="lee"))
    gt.RUN_STEPS(0.05, 0.05)
    sink_near = gt.FACTOR(near, "liquid_sink/bubble_columns:column")
    check("sink eased off approaching the surface",
          close(sink_near, -1.4 * 0.6), sink_near)
    check("still rising near the surface, not stalled", sink_near < 0, sink_near)
    check("easing is a gentle reduction, not a crawl",
          abs(sink_near) > 0.5 * 1.4, sink_near)

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
    check("reports both directions with no argument",
          ok is True and "-1.40" in text and "2.00" in text, text)

    for bad, why in ((" ", "not a number"), ("fast", "not a number"),
                     ("0", "would do nothing"), ("-99", "beyond tested"),
                     ("99", "beyond tested")):
        ok, _ = cmd.func("nando", bad)
        check(f"rejects {bad!r} ({why})", ok is False)

    # Sign routes to the direction: negative updraft, positive whirlpool.
    ok, text = cmd.func("nando", "2.5")
    check("a positive value sets the whirlpool, not the updraft",
          ok is True and "down_sink" in text, text)
    _, text = cmd.func("nando", "")
    check("updraft speed untouched by a whirlpool change",
          "-1.40" in text and "2.50" in text, text)

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


def test_bubbletaper_command():
    print("/bubbletaper live tuning")
    lua = load_mod()
    g = lua.globals()
    cmd = g.CHATCOMMANDS["bubbletaper"]
    check("command is registered", cmd is not None)

    ok, text = cmd.func("nando", "")
    check("reports the current taper with no argument",
          ok is True and "1.00 nodes" in text and "60%" in text, text)

    for bad in ("-1", "99", "0.5 2.0", "0.5 -0.1", "nope"):
        ok, _ = cmd.func("nando", bad)
        check(f"rejects {bad!r}", ok is False)

    build_column(lua, 0, 0, "mcl_nether:soul_sand", 16)
    # Head 0.3 below the surface: inside the default 1.0 taper.
    player = g.MAKE_OBJECT(0, 14.8, 0, lua.table(player=True, name="nando"))
    g.RUN_STEPS(0.2, 0.05)
    check("eased at the default taper",
          close(g.FACTOR(player, "liquid_sink/bubble_columns:column"),
                -1.4 * 0.6))

    # Turning the taper off entirely must restore full speed there.
    ok, text = cmd.func("nando", "0 1.0")
    check("accepts a new taper", ok is True)
    g.RUN_STEPS(0.2, 0.05)
    check("taper 0 means full speed right to the surface",
          g.FACTOR(player, "liquid_sink/bubble_columns:column") == -1.4,
          g.FACTOR(player, "liquid_sink/bubble_columns:column"))
    check("tells the user how to persist it",
          "bubble_columns_surface_taper = 0" in text, text)

    # Distance alone must leave the scale untouched.
    ok, _ = cmd.func("nando", "3")
    _, text = cmd.func("nando", "")
    check("setting distance alone keeps the scale",
          "100%" in text, text)


def boat_world(settings=None):
    """A magma whirlpool with an empty boat floating on top of it.

    Magma at y=0 and water at y=1..4, so the surface is 4.5 and a boat floats
    with its origin at 4.35.
    """
    lua = load_mod(settings)
    g = lua.globals()
    g.REGISTER_STUB_BOATS()
    g.RUN_MODS_LOADED()
    build_column(lua, 0, 0, "mcl_nether:magma", 4)
    g.RUN_ABM_EVERY(0, 0, 0)
    obj, boat = g.MAKE_BOAT(0, 4.35, 0)
    return lua, g, obj, boat


def test_boat_rocks_then_sinks():
    """A boat has to be handled apart from every other entity: mcl_boats
    rewrites its velocity every step and snaps it back to the top of its water
    node while it floats, so the ordinary drive is thrown away and the boat
    used to take far too long to go under."""
    print("boats: rock, then sink")
    lua, g, obj, boat = boat_world()

    # The warning window: still afloat, but visibly rocking.
    g.RUN_STEPS(1.0, 0.05)
    check("boat is still at the surface a second in",
          close(obj._pos.y, 4.35, 0.01), obj._pos.y)
    check("boat is rocking, not sitting level",
          abs(obj._rot.x) > 0.05 or abs(obj._rot.z) > 0.05,
          (obj._rot.x, obj._rot.z))

    # Both axes must move: mcl_boats' damage tilt drives pitch and roll
    # together, which is the look this is copying.
    pitches, rolls = [], []
    for _ in range(20):
        g.RUN_STEPS(0.05, 0.05)
        pitches.append(obj._rot.x)
        rolls.append(obj._rot.z)
    check("the roll swings both ways", min(rolls) < -0.1 < 0.1 < max(rolls),
          (min(rolls), max(rolls)))
    check("the pitch swings both ways",
          min(pitches) < -0.1 < 0.1 < max(pitches), (min(pitches), max(pitches)))
    # Three quarters of the pi/4 lean mcl_boats gives a boat at zero hp:
    # a boat in trouble, not one coming apart.
    peak = max(abs(v) for v in pitches + rolls)
    check("tilt stays under the breaking-boat lean",
          peak <= 3.14159 / 4 * 0.75 + 1e-6, peak)
    check("but is still a real rock, not a wobble", peak > 0.3, peak)

    # Still up top with a moment of the window left.
    check("boat has not sunk before its time is up",
          close(obj._pos.y, 4.35, 0.01), obj._pos.y)

    # Past three seconds it must actually go, and quickly -- the whole point.
    g.RUN_STEPS(1.2, 0.05)
    check("boat is under way within a fifth of a second of the deadline",
          obj._pos.y < 4.0, obj._pos.y)
    g.RUN_STEPS(1.0, 0.05)
    check("boat is a good way down one second into the sink",
          obj._pos.y < 4.35 - 2.0, obj._pos.y)

    # And it stops on the bottom rather than falling through the world.
    g.RUN_STEPS(5.0, 0.05)
    # The magma block's top face is y=0.5 and a boat's hull floor is its own
    # origin, so resting on the block means an origin just above 0.5.
    check("boat comes to rest on the magma block, not through it",
          0.5 <= obj._pos.y < 1.0, obj._pos.y)
    check("boat is fully under the water", obj._pos.y < 3.5, obj._pos.y)
    check("boat is level again once it is under",
          close(obj._rot.x, 0, 1e-6) and close(obj._rot.z, 0, 1e-6),
          (obj._rot.x, obj._rot.z))


def test_boat_sink_timing():
    """The complaint that prompted all this: the sink came far too late."""
    print("boats: sink timing")
    lua, g, obj, boat = boat_world()

    # Sample where the boat is at each half second.
    depth_at = {}
    for i in range(1, 13):
        g.RUN_STEPS(0.5, 0.05)
        depth_at[i * 0.5] = obj._pos.y

    check("nothing at 1.0s", close(depth_at[1.0], 4.35, 0.01), depth_at[1.0])
    check("nothing at 2.5s", close(depth_at[2.5], 4.35, 0.01), depth_at[2.5])
    check("going down by 3.5s", depth_at[3.5] < 4.0, depth_at[3.5])
    # Default is 3 m/s, so half a second past the deadline is ~1.5 nodes.
    check("sinking at about the configured speed",
          close(depth_at[3.5], 4.35 - 1.5, 0.2), depth_at[3.5])

    # A longer window really does delay it, and a shorter one really does not.
    lua2, g2, obj2, _ = boat_world({"bubble_columns_boat_rock_time": 8})
    g2.RUN_STEPS(5.0, 0.05)
    check("boat_rock_time=8 still floats at 5s",
          close(obj2._pos.y, 4.35, 0.01), obj2._pos.y)

    lua3, g3, obj3, _ = boat_world({"bubble_columns_boat_rock_time": 0.5})
    g3.RUN_STEPS(1.0, 0.05)
    check("boat_rock_time=0.5 is already sinking at 1s", obj3._pos.y < 4.0,
          obj3._pos.y)


def test_boat_selectivity():
    print("boats: what must NOT happen")

    # An updraft carries a boat; it must not rock or sink it.
    lua = load_mod()
    g = lua.globals()
    g.REGISTER_STUB_BOATS()
    g.RUN_MODS_LOADED()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.RUN_ABM_EVERY(0, 0, 0)
    up_boat, _ = g.MAKE_BOAT(0, 4.35, 0)
    g.RUN_STEPS(6.0, 0.05)
    check("a boat in an updraft is never rocked",
          close(up_boat._rot.x, 0, 1e-6) and close(up_boat._rot.z, 0, 1e-6),
          (up_boat._rot.x, up_boat._rot.z))
    check("a boat in an updraft does not sink",
          close(up_boat._pos.y, 4.35, 0.01), up_boat._pos.y)

    # Paddling clear during the warning window has to save it -- that is what
    # the three seconds are for.
    lua2, g2, obj2, boat2 = boat_world()
    g2.RUN_STEPS(2.0, 0.05)
    check("rocking after two seconds",
          abs(obj2._rot.x) > 0.05 or abs(obj2._rot.z) > 0.05)
    obj2._pos = g2.vector.new(30, 4.35, 30)
    g2.WORLD_SET(30, 4, 30, "mcl_core:water_source")
    g2.RUN_STEPS(1.0, 0.05)
    check("a boat that leaves in time is levelled out again",
          close(obj2._rot.x, 0, 1e-6) and close(obj2._rot.z, 0, 1e-6),
          (obj2._rot.x, obj2._rot.z))
    g2.RUN_STEPS(5.0, 0.05)
    check("a boat that leaves in time never sinks",
          close(obj2._pos.y, 4.35, 0.01), obj2._pos.y)

    # And the clock restarts, rather than resuming where it left off.
    obj2._pos = g2.vector.new(0, 4.35, 0)
    g2.RUN_STEPS(2.0, 0.05)
    check("the clock restarts on re-entry, it does not resume",
          close(obj2._pos.y, 4.35, 0.01), obj2._pos.y)


def test_bubbleboat_command():
    print("/bubbleboat live tuning")
    lua, g, obj, boat = boat_world()
    cmd = g.CHATCOMMANDS["bubbleboat"]
    check("command is registered", cmd is not None)

    ok, text = cmd.func("nando", "")
    check("reports the current timing with no argument",
          ok is True and "3.00s" in text and "3.00 m/s" in text, text)

    for bad in ("nope", "-1", "99", "3 0", "3 99", "3 3 0", "3 3 99"):
        ok, _ = cmd.func("nando", bad)
        check(f"rejects {bad!r}", ok is False)

    ok, text = cmd.func("nando", "6")
    check("accepts a new window", ok is True)
    check("tells the user how to persist it",
          "bubble_columns_boat_rock_time = 6" in text, text)

    # The boat already rocking picks the new window up without a restart.
    g.RUN_STEPS(4.0, 0.05)
    check("already-rocking boat is held up by the longer window",
          close(obj._pos.y, 4.35, 0.01), obj._pos.y)

    ok, _ = cmd.func("nando", "0.5 6")
    g.RUN_STEPS(1.0, 0.05)
    check("a shorter window and faster sink both take effect",
          obj._pos.y < 4.35 - 2.0, obj._pos.y)

    # Sink speed alone must leave the window alone.
    cmd.func("nando", "3 4.5")
    _, text = cmd.func("nando", "")
    check("setting the sink speed keeps the window",
          "3.00s" in text and "4.50 m/s" in text, text)


def test_particles():
    print("particles")
    lua = load_mod()
    g = lua.globals()
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.PARTICLES_CLEAR()
    g.RUN_ABM(0, 0, 0)
    check("ABM spawns the shaft and the surface", len(g.PARTICLES) == 2,
          len(g.PARTICLES))
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


def test_surface_bubbles():
    """The shaft bubbles stop a node below the top, which left a column
    invisible from a boat or the shore. A second spawner breaks the surface."""
    print("surface bubbles")
    lua = load_mod()
    g = lua.globals()
    # Water at y=1..4, so the surface is the top face of node 4: y=4.5.
    build_column(lua, 0, 0, "mcl_nether:soul_sand", 4)
    g.PARTICLES_CLEAR()
    g.RUN_ABM(0, 0, 0)
    check("a surface spawner is added", len(g.PARTICLES) == 2, len(g.PARTICLES))
    surface = g.PARTICLES[2]

    check("it sits at the waterline, not up the shaft",
          close(surface.maxpos.y, 4.5) and close(surface.minpos.y, 4.3),
          f"{surface.minpos.y}..{surface.maxpos.y}")
    check("it covers the column's own footprint",
          close(surface.minpos.x, -0.5) and close(surface.maxpos.x, 0.5),
          f"{surface.minpos.x}..{surface.maxpos.x}")
    check("updraft froth rises through the surface", surface.maxvel.y > 0,
          surface.maxvel.y)
    # The whole point of the low speeds: they must pop, not fly off.
    check("froth never gets more than a quarter node clear of the water",
          surface.maxvel.y * surface.maxexptime < 0.5,
          surface.maxvel.y * surface.maxexptime)
    check("it is pulled back down", surface.minacc.y < 0, surface.minacc.y)
    check("froth is smaller than the shaft bubbles",
          surface.maxsize < g.PARTICLES[1].maxsize,
          (surface.maxsize, g.PARTICLES[1].maxsize))
    check("it outlives the ABM interval, like the shaft", surface.time > 2,
          surface.time)

    # A whirlpool dimples the surface rather than boiling out of it.
    build_column(lua, 8, 0, "mcl_nether:magma", 4)
    g.PARTICLES_CLEAR()
    g.RUN_ABM(8, 0, 0)
    check("whirlpool surface is drawn back under, not thrown up",
          g.PARTICLES[2].minvel.y < 0 and g.PARTICLES[2].maxvel.y < 0.5,
          (g.PARTICLES[2].minvel.y, g.PARTICLES[2].maxvel.y))

    # Under a ceiling there is no surface, and bubbles there would be inside
    # the block.
    build_column(lua, 16, 0, "mcl_nether:soul_sand", 4)
    g.WORLD_SET(16, 5, 0, "mcl_core:stone")
    g.PARTICLES_CLEAR()
    g.RUN_ABM(16, 0, 0)
    check("no surface bubbles under a solid ceiling", len(g.PARTICLES) == 1,
          len(g.PARTICLES))

    # Same where flowing water cuts the column short: that is not the surface.
    build_column(lua, 24, 0, "mcl_nether:soul_sand", 6)
    g.WORLD_SET(24, 4, 0, "mcl_core:water_flowing")
    g.PARTICLES_CLEAR()
    g.RUN_ABM(24, 0, 0)
    check("no surface bubbles where flowing water cut the column short",
          len(g.PARTICLES) == 1, len(g.PARTICLES))

    # And the shaft is unaffected by the switch being off.
    lua2 = load_mod({"bubble_columns_surface_bubbles": False})
    g2 = lua2.globals()
    build_column(lua2, 0, 0, "mcl_nether:soul_sand", 4)
    g2.PARTICLES_CLEAR()
    g2.RUN_ABM(0, 0, 0)
    check("surface_bubbles=false leaves only the shaft", len(g2.PARTICLES) == 1,
          len(g2.PARTICLES))


def main():
    print(f"bubble_columns offline tests  (lua {lupa.LuaRuntime().lua_implementation})\n")
    for test in (test_column_detection, test_source_water_only,
                 test_voxelibre_water, test_voxelibre_boat,
                 test_missing_source_block_is_loud,
                 test_max_height, test_updraft_physics,
                 test_whirlpool_physics, test_standing_on_the_source_block,
                 test_selectivity, test_breath,
                 test_gravity_lift, test_liquid_overrides, test_surface_resonance,
                 test_join_cleanup,
                 test_bubblecheck_command, test_bubblespeed_command,
                 test_bubbletaper_command,
                 test_boat_rocks_then_sinks, test_boat_sink_timing,
                 test_boat_selectivity, test_bubbleboat_command,
                 test_expiry, test_particles, test_surface_bubbles):
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
