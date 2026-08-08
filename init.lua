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

-- The client's own liquid model, retuned per-player while in an updraft
-- (physics_overrides_v2, Luanti 5.8+).  This is what makes the climb smooth:
-- the client moves the player continuously at its own frame rate, instead of
-- the server re-kicking their velocity 20 times a second, which is what made
-- it hiccup.
--
-- THE PLAYER LIFT IS ENTIRELY CLIENT-SIDE.  The server never touches a
-- player's velocity in an updraft, and that is deliberate.
--
-- `add_velocity` arbitrates against `get_velocity()`, which lags the client by
-- however far behind the last position update is.  Rewriting velocity every
-- step against a stale reading overshoots whenever the reading is low, so the
-- client is pushed past target, and the next step pushes again.  That is both
-- the jitter and the energy pump behind the bounce that grew at the surface --
-- it needs no help from any other override to happen.
--
-- `liquid_sink` is a multiplier on the liquid sink *speed*, so a negative
-- value rises at a constant rate with no acceleration runway to compound, and
-- the client applies it continuously at its own frame rate.  One controller,
-- no stale feedback, smooth by construction.  This is the speed control for
-- players; UP_SPEED applies only to entities.
-- Not `local ... =` only: /bubblespeed rewrites this at runtime so the climb
-- can be dialled in without a restart.
local LIQUID_SINK = setting_number("liquid_sink", -1.4)
-- Only removes resistance, so it cannot drive anything on its own.  Kept
-- modest: high fluidity also makes the player retain momentum like air, which
-- is what let them carry speed up out of the water.
local LIQUID_FLUIDITY = setting_number("liquid_fluidity", 1.5)
-- The whirlpool equivalent: a positive multiplier on normal sink speed.  Was
-- originally a server-side velocity drive, which dragged the player to the
-- bottom almost instantly and brought back the same growing bounce the
-- updraft used to have -- unsurprisingly, since it was the same mechanism.
local DOWN_SINK = setting_number("down_sink", 2.0)
-- Fraction of the climb speed kept over the last SURFACE_TAPER nodes, so the
-- player eases up to the surface and floats instead of being carried clear of
-- it.  Applied as a second lift state rather than a per-step recalculation --
-- playerphysics serialises to player meta on every write.
local SURFACE_SINK_SCALE = setting_number("surface_sink_scale", 0.6)

-- Below 1 is unsupported by the engine and silently misbehaves.
if LIQUID_FLUIDITY < 1 then
	LIQUID_FLUIDITY = 1
end

-- How far below the surface the updraft starts easing off, in nodes.  Without
-- it the lift runs at full speed right up to the surface and fires the player
-- clear; they fall back in, get lifted again, and it reads as bouncing.
--
-- Measured from the player's HEAD, not their feet, which sit 1.4 nodes lower.
-- Measuring from the feet made the setting mean something else entirely and
-- started the slowdown far too early.
local SURFACE_TAPER = setting_number("surface_taper", 1.0)
-- Both directions replenish air, as in Minecraft -- the wiki describes it for
-- bubble columns generally, not just rising ones.  A whirlpool is still
-- dangerous because it pins you against a magma block, which burns.
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

-- Columns propagate through water *source* blocks only, stopping at flowing
-- water, exactly as they do in Minecraft.  Tested by group rather than by
-- name so river water (mclx_core:river_water_source, which copies the water
-- source definition) counts too.
local function is_column_water(name)
	return core.get_item_group(name, "water") > 0
		and core.get_item_group(name, "liquid_source") > 0
end

-- Height of the unbroken water column sitting directly on `pos`.
local function measure_column(pos)
	local height = 0
	while height < MAX_HEIGHT do
		local node = core.get_node({x = pos.x, y = pos.y + 1 + height, z = pos.z})
		-- "ignore" means unloaded map; stop rather than guess.
		if node.name == "ignore" or not is_column_water(node.name) then
			break
		end
		height = height + 1
	end
	return height
end

-- A straight fizz along the whole shaft, rising or falling with the column.
local function spawn_particles(pos, kind, height)
	local rising = kind == "up"
	-- Bubbles keep travelling on their own velocity after they spawn, so
	-- filling the column right to the surface threw them well clear of the
	-- water.  Stop the spawn volume a node short and keep speed x lifetime
	-- under that node, so they die at the surface rather than above it.
	local top = math.max(0.5, height - 1)
	core.add_particlespawner({
		-- Enough to read as a column without flooding the client on a
		-- reef full of magma blocks.
		amount = math.min(4 * height, 60),
		-- Overlaps the next re-arm so the column does not visibly pulse.
		time = PARTICLE_PERIOD + 0.5,
		minpos = {x = pos.x - 0.45, y = pos.y + 0.5, z = pos.z - 0.45},
		maxpos = {x = pos.x + 0.45, y = pos.y + 0.5 + top, z = pos.z + 0.45},
		minvel = {x = -0.2, y = rising and 1.5 or -1.5, z = -0.2},
		maxvel = {x = 0.2, y = rising and 2.4 or -2.4, z = 0.2},
		minacc = {x = -0.4, y = 0, z = -0.4},
		maxacc = {x = 0.4, y = 0, z = 0.4},
		minexptime = 0.25,
		maxexptime = 0.4,
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
		elseif name == "ignore" or not is_column_water(name) then
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

-- `want` is "up", "up_near" (easing off below the surface) or "down".
local function begin_lift(obj, want)
	local rising = want ~= "down"
	local state = lifted[obj]
	if state then
		state.last_seen = now
		if state.kind == want then return end
		state.kind = want
	else
		-- is_player cached: end_lift may run after the object is gone, and
		-- the release sweep must still know which path to take.
		lifted[obj] = {kind = want, last_seen = now, is_player = obj:is_player()}
	end
	if obj:is_player() then
		-- Both directions are client-side, and for the same reason: the
		-- whirlpool was the last path still driven from the server, and it
		-- reproduced both server-drive symptoms exactly -- dragged the
		-- player to the bottom almost instantly, and brought back the
		-- bounce that grew every cycle.
		local sink
		if rising then
			sink = LIQUID_SINK
			if want == "up_near" then
				sink = sink * SURFACE_SINK_SCALE
			end
			-- Only the updraft neutralises gravity, to stop it clawing back
			-- the climb.  A whirlpool wants gravity exactly as it is.
			playerphysics.add_physics_factor(obj, "gravity", LIFT_ID, UP_GRAVITY)
		else
			sink = DOWN_SINK
		end
		playerphysics.add_physics_factor(obj, "liquid_sink", LIFT_ID, sink)
		playerphysics.add_physics_factor(obj, "liquid_fluidity", LIFT_ID,
			LIQUID_FLUIDITY)
		dbg("overrides on for %s (%s): sink=%.2f fluidity=%.2f",
			obj:get_player_name(), want, sink, LIQUID_FLUIDITY)
	elseif rising then
		local entity = obj:get_luaentity()
		if entity and entity.is_mob and entity.add_physics_factor then
			entity:add_physics_factor("fall_speed", LIFT_ID, 0)
		end
	end
end

local function end_lift(obj)
	lifted[obj] = nil
	if not obj:is_valid() then return end
	if obj:is_player() then
		playerphysics.remove_physics_factor(obj, "gravity", LIFT_ID)
		playerphysics.remove_physics_factor(obj, "liquid_sink", LIFT_ID)
		playerphysics.remove_physics_factor(obj, "liquid_fluidity", LIFT_ID)
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

-- (There is deliberately no player velocity helper here any more.  Every
-- server-side velocity rewrite this mod applied to a player caused jitter and
-- a growing bounce; both directions are now client-side physics overrides.
-- Entities still use drive_towards above, which is fine -- they are simulated
-- server-side with no client predicting them.)

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
local function scan_players(in_column)
	for _, player in ipairs(core.get_connected_players()) do
		local pos = player:get_pos()
		local feet_wet = is_water(core.get_node(pos).name)
		local submerged = is_water(core.get_node({
			x = pos.x, y = pos.y + 1.4, z = pos.z,
		}).name)
		-- Any part in the water keeps the lift, rather than requiring the
		-- head under.  The head sits 1.4 nodes above the feet, so gating on
		-- it cut the lift out well over a node early and left the player
		-- short of the surface.
		--
		-- This is safe to widen only because the lift is a client-side
		-- physics override rather than a server-side velocity rewrite: the
		-- engine applies it solely while the player is actually in liquid, so
		-- it ends by itself as they clear the water, and there is no
		-- server/client arbitration left to pump energy into a bounce.  The
		-- same widening with a velocity drive is what made them bob
		-- indefinitely before.
		local in_water = feet_wet or submerged
		if in_water then
			local source_pos, kind = find_source_below(pos)
			if source_pos then
				local height = measure_column(source_pos)
				if height > 0 then
					stats.scan_hits = stats.scan_hits + 1
					-- Registered even at the surface, so the column keeps
					-- drawing its bubbles for anyone standing in the top of it.
					register_column(source_pos, kind, height)
					local rising = kind == "up"
					if in_water then
						in_column[player] = true
						-- Ease off approaching the surface so the player
						-- arrives and floats instead of being carried clear.
						-- Measured head-to-surface, so the setting means the
						-- distance the player actually sees above them.
						local surface_y = source_pos.y + 0.5 + height
						local near = (surface_y - (pos.y + 1.4)) < SURFACE_TAPER
						begin_lift(player,
							rising and (near and "up_near" or "up") or "down")
						-- Deadbanded on the way up because the liquid
						-- overrides should already be holding the speed; the
						-- correction is a floor for when they cannot (a slow
						-- client, or a Luanti build without
						-- physics_overrides_v2).  A whirlpool has no override
						-- helping it, so it is driven outright.
						-- Deliberately nothing here, in either direction: the
						-- liquid_sink override set by begin_lift is the whole
						-- of the player physics.  Every server-side velocity
						-- rewrite this mod has ever done to a player produced
						-- jitter and a bounce that grew each cycle, because
						-- add_velocity arbitrates against a get_velocity()
						-- reading that lags the client.
						if RESTORE_AIR then
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
			begin_lift(obj, rising and "up" or "down")
			drive_towards(obj, target, dtime)
		end
	end
end

local object_timer = 0
local in_column = {}

core.register_globalstep(function(dtime)
	now = now + dtime

	-- Every step, deliberately.  This is the whole reason the mod works:
	-- liquid drag bleeds an injected velocity away between ticks, so the
	-- top-up has to be as frequent as the client's own simulation -- the
	-- same cadence mcl_potions gives levitation, and so shulker bullets.
	for player in pairs(in_column) do
		in_column[player] = nil
	end
	scan_players(in_column)

	-- Players are released the instant they leave, with no grace period.
	--
	-- They are scanned every step, so a grace buys nothing -- and it costs a
	-- great deal: holding gravity = 0 for 0.3s after someone shoots out of
	-- the top of a column turns their exit arc into a coast, so they reach a
	-- higher apex, fall back in faster, get driven to full speed again and
	-- launch higher still.  That resonance grew with every bounce.
	for obj, state in pairs(lifted) do
		if state.is_player and not in_column[obj] then
			end_lift(obj)
		end
	end

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

	-- Entities only; players were released above, immediately.  Timestamps
	-- rather than a per-tick set because the entity pass runs at a coarser
	-- rate than this callback, so a shared set would release them on the
	-- steps that had no entity pass.  Clearing a key during pairs() is well
	-- defined.
	for obj, state in pairs(lifted) do
		if not state.is_player and now - state.last_seen > LIFT_GRACE then
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
			elseif not is_column_water(n) then
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

		local hold = lifted[player]
		say("stage 5: gravity hold = %s", hold and hold.kind or "nil")
		local override = player:get_physics_override()
		say("        gravity=%.2f liquid_sink=%.2f liquid_fluidity=%.2f",
			override.gravity or 1, override.liquid_sink or 1,
			override.liquid_fluidity or 1)
		local vel = player:get_velocity()
		-- No target to compare against: the lift is the liquid_sink override
		-- above, applied by the client. This v.y is the client's own result.
		say("        your v.y = %.2f (client-driven; sink is the control)",
			vel and vel.y or 0)
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

-- Climb speed is the one number that can only be judged by riding a column,
-- so make it adjustable without a restart.  Runtime only: the command prints
-- the line to put in minetest.conf once a value feels right.
core.register_chatcommand("bubblespeed", {
	params = "[<sink>]",
	description = "Show or set the bubble column climb speed (negative rises)",
	privs = {server = true},
	func = function(name, param)
		if param == "" then
			return true, string.format(
				"updraft climb = %.2f (negative rises, more is faster)\n"
				.. "whirlpool sink = %.2f (positive sinks, more is faster)",
				LIQUID_SINK, DOWN_SINK)
		end
		local value = tonumber(param)
		if not value then
			return false, "expected a number, e.g. /bubblespeed -1.8"
		end
		if value < -6 or value > 6 then
			return false, "keep it between -6 and 6"
		end
		-- Routed by sign: the two are the same engine setting in opposite
		-- directions, so one command covers both without a mode word.
		local which
		if value < 0 then
			LIQUID_SINK = value
			which = "liquid_sink"
		elseif value > 0 then
			DOWN_SINK = value
			which = "down_sink"
		else
			return false, "0 would do nothing; negative rises, positive sinks"
		end

		-- Drop every current hold so the new value is applied on the next
		-- step; begin_lift is a no-op while the state is unchanged.
		for obj in pairs(lifted) do
			end_lift(obj)
		end

		return true, string.format(
			"%s = %.2f (this session only)\n"
			.. "to keep it, add to minetest.conf:  bubble_columns_%s = %s",
			which, value, which, param)
	end,
})

-- Same reasoning as /bubblespeed: how the column feels at the surface can
-- only be judged by riding one, so it should not cost a restart per guess.
core.register_chatcommand("bubbletaper", {
	params = "[<nodes> [<scale>]]",
	description = "Show or set how early and how much the climb eases off "
		.. "below the surface",
	privs = {server = true},
	func = function(name, param)
		if param == "" then
			return true, string.format(
				"taper: starts %.2f nodes above your head, keeping %.0f%% "
				.. "of climb speed", SURFACE_TAPER, SURFACE_SINK_SCALE * 100)
		end
		local nodes, scale = param:match("^(%S+)%s*(%S*)$")
		nodes = tonumber(nodes)
		if not nodes or nodes < 0 or nodes > 12 then
			return false, "nodes must be between 0 and 12, e.g. /bubbletaper 0.5 0.7"
		end
		if scale ~= "" then
			scale = tonumber(scale)
			if not scale or scale < 0 or scale > 1 then
				return false, "scale must be between 0 and 1 (fraction of climb speed)"
			end
			SURFACE_SINK_SCALE = scale
		end
		SURFACE_TAPER = nodes

		for obj in pairs(lifted) do
			end_lift(obj)
		end

		return true, string.format(
			"taper = %.2f nodes, keeping %.0f%% of speed (this session only)\n"
			.. "to keep it:  bubble_columns_surface_taper = %s\n"
			.. "             bubble_columns_surface_sink_scale = %s",
			SURFACE_TAPER, SURFACE_SINK_SCALE * 100,
			SURFACE_TAPER, SURFACE_SINK_SCALE)
	end,
})

-- Exposed for tests/run.py, which drives the ABM and globalstep directly.
bubble_columns = {
	columns = columns,
	measure_column = measure_column,
	lifted = lifted,
}
