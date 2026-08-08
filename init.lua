-- bubble_columns — Minecraft-style bubble columns for Mineclonia.
--
-- A soul sand block with water above it turns that water column into an
-- updraft; a magma block turns it into a whirlpool that drags everything
-- down.  Players, mobs, boats and dropped items are all carried.
--
-- Nothing here registers a node, so the mod can be added to or removed from
-- an existing world freely -- there is no orphaned-node problem to migrate.
--
-- Columns are found by an ABM on the source blocks, which confines the search
-- to map blocks the engine already treats as active.  Each ABM hit refreshes
-- an entry in `columns` and re-arms the particle spawner; a globalstep then
-- does the per-object physics and lets stale entries expire.  Keeping the
-- registry means the expensive call (get_objects_in_area) scales with the
-- number of live columns rather than with the number of objects in the world.

local modname = core.get_current_modname()

local function setting_number(key, default)
	return tonumber(core.settings:get(modname .. "_" .. key)) or default
end

local function setting_bool(key, default)
	local v = core.settings:get_bool(modname .. "_" .. key)
	if v == nil then return default end
	return v
end

-- How far up from the source block a column may reach.  Only consulted from
-- the ABM, so a generous cap costs almost nothing.
local MAX_HEIGHT = setting_number("max_height", 24)
-- Terminal vertical speed, m/s.  Both are magnitudes.
local UP_SPEED = setting_number("up_speed", 8)
local DOWN_SPEED = setting_number("down_speed", 6)
-- How hard an object is pulled towards that speed, m/s^2.
local ACCEL = setting_number("accel", 30)
-- Minecraft's updraft keeps you breathing; its whirlpool does not.
local RESTORE_AIR = setting_bool("restore_air", true)
-- Traces the whole pipeline to debug.txt: column found -> object in area ->
-- velocity driven.  Off by default; noisy by design when on.
local DEBUG = setting_bool("debug", false)

local function dbg(fmt, ...)
	if DEBUG then
		core.log("action", "[bubble_columns] " .. string.format(fmt, ...))
	end
end

-- Soul *soil* deliberately absent: in Minecraft it has no bubble column, and
-- mcl_nether puts both it and soul sand in the `soul_block` group, so the
-- group is the wrong thing to test against here.
local SOURCES = {
	["mcl_nether:soul_sand"] = "up",
	["mcl_nether:magma"] = "down",
}

local ABM_INTERVAL = 2
-- Must exceed ABM_INTERVAL, or a column blinks out between refreshes.
local COLUMN_TTL = ABM_INTERVAL + 1.5
-- Re-running the object pass every server step buys nothing: we drive towards
-- a target velocity rather than applying impulses, so a coarser tick is just
-- as smooth and far cheaper.
local OBJECT_INTERVAL = 0.1

-- Monotonic seconds since load, accumulated from globalstep dtime.  Used
-- instead of os.time() so expiry follows server time, not wall clock.
local now = 0
local columns = {}

local function is_water(name)
	return core.get_item_group(name, "water") > 0
end

-- Height of the unbroken water column sitting directly on `pos`.
local function measure_column(pos)
	local height = 0
	while height < MAX_HEIGHT do
		local node = core.get_node({x = pos.x, y = pos.y + 1 + height, z = pos.z})
		-- "ignore" means unloaded map; stop rather than guess.
		if node.name == "ignore" or not is_water(node.name) then
			break
		end
		height = height + 1
	end
	return height
end

local function spawn_particles(pos, kind, height)
	local rising = kind == "up"
	local vel = rising and 4 or -4
	core.add_particlespawner({
		-- Enough to read as a column without flooding the client on a
		-- reef full of magma blocks.
		amount = math.min(4 * height, 60),
		-- Overlaps the next ABM pass so the column does not visibly pulse.
		time = ABM_INTERVAL + 0.5,
		minpos = {x = pos.x - 0.45, y = pos.y + 0.5, z = pos.z - 0.45},
		maxpos = {x = pos.x + 0.45, y = pos.y + 0.5 + height, z = pos.z + 0.45},
		minvel = {x = -0.2, y = vel, z = -0.2},
		maxvel = {x = 0.2, y = vel * 1.6, z = 0.2},
		minacc = {x = -0.4, y = 0, z = -0.4},
		maxacc = {x = 0.4, y = 0, z = 0.4},
		minexptime = 0.6,
		maxexptime = 1.4,
		minsize = 0.7,
		maxsize = 2.4,
		collisiondetection = false,
		-- Shipped by mcl_player for the underwater breath trail.  Luanti's
		-- media namespace is flat, so no dependency is needed to use it.
		texture = "mcl_particles_bubble.png",
		glow = 2,
	})
end

core.register_abm({
	label = "bubble_columns: find and draw columns",
	nodenames = {"mcl_nether:soul_sand", "mcl_nether:magma"},
	-- Cheap rejection of every soul sand in the Nether, where there is no
	-- water to make a column out of.
	neighbors = {"group:water"},
	interval = ABM_INTERVAL,
	chance = 1,
	catch_up = false,
	action = function(pos, node)
		local kind = SOURCES[node.name]
		if not kind then return end
		local height = measure_column(pos)
		dbg("abm hit %s at %s -> kind=%s height=%d", node.name,
			core.pos_to_string(pos), kind, height)
		if height == 0 then return end

		columns[core.hash_node_position(pos)] = {
			pos = vector.new(pos.x, pos.y, pos.z),
			kind = kind,
			height = height,
			expires = now + COLUMN_TTL,
		}
		spawn_particles(pos, kind, height)
	end,
})

-- Cancelling gravity is not optional garnish -- it is what makes the lift
-- work at all.  Driving velocity alone leaves the engine reapplying gravity
-- and liquid drag every client step, which eats the added velocity faster
-- than a 0.1s server tick can top it back up.  mcl_potions' levitation
-- effect solves the same problem the same way: zero the gravity factor, then
-- drive the velocity.
local LIFT_ID = "bubble_columns:column"

-- Objects currently having their gravity cancelled.  Tracked because
-- playerphysics serialises to player meta on every call, so the factor must
-- be set on entry and cleared on exit -- never per tick.
local lifted = {}

local function begin_lift(obj)
	if lifted[obj] then return end
	lifted[obj] = true
	if obj:is_player() then
		playerphysics.add_physics_factor(obj, "gravity", LIFT_ID, 0)
	else
		local entity = obj:get_luaentity()
		if entity and entity.is_mob and entity.add_physics_factor then
			entity:add_physics_factor("fall_speed", LIFT_ID, 0)
		end
	end
	dbg("lift on for %s", obj:is_player() and obj:get_player_name() or "entity")
end

local function end_lift(obj)
	lifted[obj] = nil
	if not obj:is_valid() then return end
	if obj:is_player() then
		playerphysics.remove_physics_factor(obj, "gravity", LIFT_ID)
	else
		local entity = obj:get_luaentity()
		if entity and entity.is_mob and entity.remove_physics_factor then
			entity:remove_physics_factor("fall_speed", LIFT_ID)
		end
	end
	dbg("lift off for %s", obj:is_player() and obj:get_player_name() or "entity")
end

-- A physics factor lives in player meta, so a crash mid-column would
-- otherwise strand someone with permanent zero gravity.  Clear it on join.
core.register_on_joinplayer(function(player)
	playerphysics.remove_physics_factor(player, "gravity", LIFT_ID)
end)

core.register_on_leaveplayer(function(player)
	lifted[player] = nil
end)

-- Nudge `obj` towards `target` vertical speed without ever overshooting it.
local function drive_towards(obj, target, dtime)
	local vel = obj:get_velocity()
	if not vel then return end
	local diff = target - vel.y
	local limit = ACCEL * dtime
	if diff > limit then
		diff = limit
	elseif diff < -limit then
		diff = -limit
	end
	obj:add_velocity({x = 0, y = diff, z = 0})
	return vel.y
end

local function apply_column(column, dtime, present)
	local pos = column.pos
	local minp = {x = pos.x - 0.5, y = pos.y + 0.5, z = pos.z - 0.5}
	local maxp = {x = pos.x + 0.5, y = pos.y + 0.5 + column.height, z = pos.z + 0.5}
	local rising = column.kind == "up"
	local target = rising and UP_SPEED or -DOWN_SPEED

	for _, obj in ipairs(core.get_objects_in_area(minp, maxp)) do
		-- An attached object is driven by its parent; moving it here
		-- would fight the attachment rather than carry the rider.
		if obj:is_valid() and not obj:get_attach() then
			present[obj] = true
			-- Only updrafts fight gravity; a whirlpool has it as an ally.
			if rising then
				begin_lift(obj)
			end
			local before = drive_towards(obj, target, dtime)
			if before then
				dbg("%s in %s column: v.y %.2f -> target %.2f",
					obj:is_player() and obj:get_player_name() or "entity",
					column.kind, before, target)
			end
			if rising and RESTORE_AIR and obj:is_player() then
				local max_breath = obj:get_properties().breath_max or 10
				if obj:get_breath() < max_breath then
					obj:set_breath(max_breath)
				end
			end
		end
	end
end

local object_timer = 0
local present = {}

core.register_globalstep(function(dtime)
	now = now + dtime
	object_timer = object_timer + dtime
	if object_timer < OBJECT_INTERVAL then return end
	local elapsed = object_timer
	object_timer = 0

	for obj in pairs(present) do
		present[obj] = nil
	end

	for hash, column in pairs(columns) do
		if column.expires < now then
			columns[hash] = nil
		else
			apply_column(column, elapsed, present)
		end
	end

	-- Anything that was being lifted and is no longer in any column gets
	-- its gravity back.  Clearing a key during pairs() is well defined.
	for obj in pairs(lifted) do
		if not present[obj] then
			end_lift(obj)
		end
	end
end)

-- Exposed for tests/run.py, which drives the ABM and globalstep directly.
bubble_columns = {
	columns = columns,
	measure_column = measure_column,
}
