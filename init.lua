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
-- How hard an entity is pulled towards that speed, m/s^2.  Entities only;
-- players are moved by the gravity factors below instead.
local ACCEL = setting_number("accel", 30)
-- Gravity multiplier applied to a player in an updraft.
--
-- KEY ENGINE FACT: physics_override.gravity does NOT lift a player who is in
-- a liquid.  Luanti's client uses its liquid movement model there
-- (movement_liquid_sink / movement_liquid_fluidity), not gravity
-- acceleration.  Measured in game: gravity forced to -1.0 while standing in a
-- 16-deep column still gave v.y = -0.30, i.e. still sinking.
--
-- So this is 0, not negative: it stops gravity fighting the velocity drive
-- between steps and keeps the player from being yanked back down the instant
-- they breach the surface.  The actual lifting is done by topping velocity up
-- every server step, which is what mcl_potions' levitation does and why that
-- effect works underwater.
local UP_GRAVITY = setting_number("up_gravity", 0)
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

-- Soul *soil* is deliberately absent by default: in Minecraft it makes no
-- bubble column, only soul sand does.  They are separate nodes from separate
-- mods (mcl_nether:soul_sand vs mcl_blackstone:soul_soil) that merely share
-- the `soul_block` group -- which is exactly why the group is the wrong thing
-- to test against, and why they are so easy to confuse in the inventory.
local SOURCES = {
	["mcl_nether:soul_sand"] = "up",
	["mcl_nether:magma"] = "down",
}

if setting_bool("soul_soil_too", false) then
	SOURCES["mcl_blackstone:soul_soil"] = "up"
end

-- Derived so the ABM and the scan can never disagree about what counts.
local SOURCE_NAMES = {}
for name in pairs(SOURCES) do
	table.insert(SOURCE_NAMES, name)
end

local ABM_INTERVAL = 2
-- Must exceed ABM_INTERVAL, or a column blinks out between refreshes.
local COLUMN_TTL = ABM_INTERVAL + 1.5
-- Re-running the object pass every server step buys nothing: we drive towards
-- a target velocity rather than applying impulses, so a coarser tick is just
-- as smooth and far cheaper.
local OBJECT_INTERVAL = 0.1
-- How often a live column re-arms its particle spawner.
local PARTICLE_PERIOD = 2.0

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
		-- Overlaps the next re-arm so the column does not visibly pulse.
		time = PARTICLE_PERIOD + 0.5,
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

-- Counters, reported by /bubblecheck.  They are the difference between "the
-- ABM never fired" and "the ABM fired and the action bailed out", which is
-- not something you can otherwise tell from outside.
local stats = {abm_hits = 0, scan_hits = 0, registered = 0}

-- Both discovery paths funnel through here.
local function register_column(pos, kind, height)
	local hash = core.hash_node_position(pos)
	local column = columns[hash]
	if column then
		column.kind = kind
		column.height = height
		column.expires = now + COLUMN_TTL
	else
		column = {
			pos = vector.new(pos.x, pos.y, pos.z),
			kind = kind,
			height = height,
			expires = now + COLUMN_TTL,
			next_particles = 0,
		}
		columns[hash] = column
		stats.registered = stats.registered + 1
	end
	-- Rate-limited here rather than tied to the ABM, since the player scan
	-- now discovers the same column many times a second.
	if now >= column.next_particles then
		spawn_particles(pos, kind, height)
		column.next_particles = now + PARTICLE_PERIOD
	end
	return column
end

-- Walk down from `pos` through unbroken water looking for a source block.
-- Returns the source position and its kind, or nil.
local function find_source_below(pos)
	local y = math.floor(pos.y + 0.5)
	for i = 0, MAX_HEIGHT do
		local p = {x = pos.x, y = y - i, z = pos.z}
		local name = core.get_node(p).name
		local kind = SOURCES[name]
		if kind then
			return vector.round(p), kind
		elseif name == "ignore" or not is_water(name) then
			return nil
		end
	end
	return nil
end

-- The vertical span a column acts on, as a pair of corner positions.
--
-- The bottom is the *bottom* of the source block, not the top.  A player
-- standing on the soul sand has their position at the block's top face, and
-- floating point puts them a hair either side of it -- with the box starting
-- exactly there, they tested as outside it and nothing happened.  Anything
-- resting on the block should be carried, so the block's own cell is in.
local function column_bounds(column)
	local pos = column.pos
	return {x = pos.x - 0.5, y = pos.y - 0.5, z = pos.z - 0.5},
		{x = pos.x + 0.5, y = pos.y + 0.5 + column.height, z = pos.z + 0.5}
end

-- Secondary: keeps unoccupied columns visible.  Cosmetic only now, so its
-- failure modes no longer break the feature.
core.register_abm({
	label = "bubble_columns: draw unoccupied columns",
	nodenames = SOURCE_NAMES,
	-- Cheap rejection of every soul sand in the Nether, where there is no
	-- water to make a column out of.
	neighbors = {"group:water"},
	interval = ABM_INTERVAL,
	chance = 1,
	catch_up = false,
	action = function(pos, node)
		local kind = SOURCES[node.name]
		if not kind then return end
		stats.abm_hits = stats.abm_hits + 1
		local height = measure_column(pos)
		dbg("abm hit %s at %s -> kind=%s height=%d", node.name,
			core.pos_to_string(pos), kind, height)
		if height == 0 then return end
		register_column(pos, kind, height)
	end,
})

-- Players and everything else need completely different treatment.
--
-- A player is moved by the *client*, which runs its own gravity and liquid
-- drag every frame.  `add_velocity` on a player is a single nudge into that
-- simulation -- the drag eats it between server ticks, and lua_api.md notes
-- it does nothing at all during `free_move` (fly), which is easy to be in
-- inside a creative world.  So players are not pushed: their gravity is
-- *inverted* via a physics override, and the client's own movement code
-- lifts them.  Working with the engine instead of against it.
--
-- Entities (mobs, boats, dropped items) are simulated server-side, where
-- add_velocity does exactly what it says, so those keep the velocity drive.
local LIFT_ID = "bubble_columns:column"

-- obj -> {kind = "up"|"down", last_seen = <time>}.
--
-- Timestamped rather than rebuilt from a per-tick set because players are now
-- refreshed every server step while entities are only swept every
-- OBJECT_INTERVAL; a single shared "seen this tick" set would release
-- entities the moment a step ran without an entity pass.
local lifted = {}
-- How long an object keeps its hold after it stops being refreshed.  Must
-- comfortably exceed OBJECT_INTERVAL.
local LIFT_GRACE = 0.3

local function begin_lift(obj, rising)
	local want = rising and "up" or "down"
	local state = lifted[obj]
	if state then
		state.last_seen = now
		if state.kind == want then return end
		state.kind = want
	else
		lifted[obj] = {kind = want, last_seen = now}
	end
	-- Only the updraft needs the hold: it keeps gravity from clawing back
	-- what the velocity drive gains between steps.  A whirlpool wants
	-- gravity exactly as it is.
	if rising then
		if obj:is_player() then
			playerphysics.add_physics_factor(obj, "gravity", LIFT_ID, UP_GRAVITY)
			dbg("gravity factor %.2f for %s", UP_GRAVITY, obj:get_player_name())
		else
			local entity = obj:get_luaentity()
			if entity and entity.is_mob and entity.add_physics_factor then
				entity:add_physics_factor("fall_speed", LIFT_ID, 0)
			end
		end
	end
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

-- Force `obj` to `target` vertical speed outright, rather than easing towards
-- it.  In a liquid the client bleeds an injected velocity away within a
-- frame or two, so anything gentler simply never accumulates -- this is the
-- shape mcl_potions' levitation uses, and why that effect works underwater.
-- Only ever speeds an object up in the intended direction; something already
-- moving faster that way is left alone.
local function force_speed(obj, target)
	local vel = obj:get_velocity()
	if not vel then return end
	if (target > 0 and vel.y < target) or (target < 0 and vel.y > target) then
		obj:add_velocity({x = 0, y = target - vel.y, z = 0})
	end
end

-- Primary detection, driven by the players themselves, and the whole of the
-- player physics.
--
-- This started out as an ABM alone, whose scheduling is not observable from
-- Lua.  Scanning down from each player is deterministic, costs one get_node
-- when they are not in water, and is tied directly to the thing that has to
-- be affected.  The ABM is kept only so columns are still drawn when nobody
-- is inside one.
--
-- Players are driven *here* rather than from the column's bounding box: the
-- scan found the column by looking down from the player, so the player is in
-- it by construction.  There is no membership test left to get wrong, which
-- is what went wrong when standing on the source block put them a hair below
-- the box.
--
-- Called every server step, not on the entity cadence.  A 0.1s top-up is not
-- enough -- liquid drag eats the injected velocity between ticks, which is
-- why the earlier version left the player sinking at -0.30 with the gravity
-- override already applied.
local function scan_players()
	for _, player in ipairs(core.get_connected_players()) do
		local pos = player:get_pos()
		if is_water(core.get_node(pos).name)
			or is_water(core.get_node({x = pos.x, y = pos.y + 1.4, z = pos.z}).name) then
			local source_pos, kind = find_source_below(pos)
			if source_pos then
				local height = measure_column(source_pos)
				if height > 0 then
					stats.scan_hits = stats.scan_hits + 1
					register_column(source_pos, kind, height)
					local rising = kind == "up"
					begin_lift(player, rising)
					force_speed(player, rising and UP_SPEED or -DOWN_SPEED)
					if rising and RESTORE_AIR then
						local max_breath = player:get_properties().breath_max or 10
						if player:get_breath() < max_breath then
							player:set_breath(max_breath)
						end
					end
				end
			end
		end
	end
end

-- Entities only; players came through scan_players above.
local function apply_column(column, dtime)
	local minp, maxp = column_bounds(column)
	local rising = column.kind == "up"
	local target = rising and UP_SPEED or -DOWN_SPEED

	local found = core.get_objects_in_area(minp, maxp)
	dbg("%s column at %s h=%d: %d object(s) in area",
		column.kind, core.pos_to_string(column.pos), column.height, #found)

	for _, obj in ipairs(found) do
		-- An attached object is driven by its parent; moving it here
		-- would fight the attachment rather than carry the rider.
		if obj:is_valid() and not obj:get_attach() and not obj:is_player() then
			begin_lift(obj, rising)
			drive_towards(obj, target, dtime)
		end
	end
end

local object_timer = 0

core.register_globalstep(function(dtime)
	now = now + dtime

	-- Every step, deliberately.  This is the whole reason the mod works:
	-- liquid drag bleeds an injected velocity away between ticks, so the
	-- top-up has to be as frequent as the client's own simulation -- the
	-- same cadence mcl_potions gives levitation, and so shulker bullets.
	scan_players()

	object_timer = object_timer + dtime
	if object_timer < OBJECT_INTERVAL then return end
	local elapsed = object_timer
	object_timer = 0

	-- Entities are server-side and far more numerous, so they stay on the
	-- coarser cadence; get_objects_in_area is the expensive call here.
	for hash, column in pairs(columns) do
		if column.expires < now then
			columns[hash] = nil
		else
			apply_column(column, elapsed)
		end
	end

	-- Release anything that has stopped being refreshed by either pass.
	-- Timestamps rather than a per-tick set, because the two passes run at
	-- different rates and a shared set would release entities on the steps
	-- that had no entity pass.  Clearing a key during pairs() is well defined.
	for obj, state in pairs(lifted) do
		if now - state.last_seen > LIFT_GRACE then
			end_lift(obj)
		end
	end
end)

-- Walks the whole pipeline for wherever the player is standing and reports
-- which stage fails, so a column that "does nothing" can be diagnosed in
-- game rather than by reading debug.txt after the fact.
core.register_chatcommand("bubblecheck", {
	description = "Diagnose the bubble column at your feet",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false, "no such player" end

		local pos = player:get_pos()
		local out = {"--- bubblecheck ---"}
		local function say(fmt, ...)
			table.insert(out, string.format(fmt, ...))
		end

		say("you: %s", core.pos_to_string(vector.round(pos)))

		local feet = core.get_node(pos).name
		say("node at your feet: %s (water group %d)", feet,
			core.get_item_group(feet, "water"))

		-- Stage 1: is there a source block under an unbroken run of water?
		local found_source, source_pos
		local y = math.floor(pos.y + 0.5)
		for i = 0, MAX_HEIGHT do
			local p = {x = pos.x, y = y - i, z = pos.z}
			local n = core.get_node(p).name
			if SOURCES[n] then
				found_source, source_pos = n, vector.round(p)
				break
			elseif not is_water(n) then
				say("stage 1 FAIL: hit %s at %d before finding a source block",
					n, y - i)
				if n == "mcl_blackstone:soul_soil" then
					say("  ^ that is Soul SOIL, not Soul SAND. They are different")
					say("    blocks and only soul sand makes a column, as in")
					say("    Minecraft. You want mcl_nether:soul_sand -- or set")
					say("    bubble_columns_soul_soil_too = true to allow both.")
				end
				break
			end
		end
		if found_source then
			say("stage 1 ok: %s at %s (%s column)", found_source,
				core.pos_to_string(source_pos), SOURCES[found_source])
			say("stage 2: measured height = %d", measure_column(source_pos))
			local registered = columns[core.hash_node_position(source_pos)]
			say("stage 3 %s: column %s in the live registry",
				registered and "ok" or "FAIL",
				registered and "IS" or "is NOT")
			if registered then
				local minp, maxp = column_bounds(registered)
				local n = #core.get_objects_in_area(minp, maxp)
				-- Informational, not pass/fail: players no longer depend on
				-- this box, only entities do.
				say("stage 4: %d object(s) in the column box (entities use", n)
				say("         this; you do not -- the scan handles players)")
			end
		end

		say("stage 5: gravity hold = %s", tostring(lifted[player]))
		local override = player:get_physics_override()
		say("        physics_override.gravity = %.2f", override.gravity or 1)
		local vel = player:get_velocity()
		say("        your v.y = %.2f", vel and vel.y or 0)
		local live = 0
		for _ in pairs(columns) do live = live + 1 end
		say("live columns tracked: %d", live)
		say("counters: player-scan hits=%d, abm hits=%d, columns registered=%d",
			stats.scan_hits, stats.abm_hits, stats.registered)
		say("NOTE: if gravity is right but you do not move, you are flying;")
		say("      press K to leave fly mode and try again.")

		return true, table.concat(out, "\n")
	end,
})

-- Exposed for tests/run.py, which drives the ABM and globalstep directly.
bubble_columns = {
	columns = columns,
	measure_column = measure_column,
	lifted = lifted,
}
