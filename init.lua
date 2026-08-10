-- bubble_columns -- soul sand updrafts and magma whirlpools.
--
-- Soul sand under water makes an updraft; magma makes a whirlpool.  Players,
-- mobs, boats and dropped items are carried either way.
--
-- Registers no nodes, so the mod can be added to or removed from a world
-- freely.
--
-- Mineclonia and VoxeLibre only.  Both have soul sand and magma under the same
-- names, and both behave the way this is built around.  mod.conf depends on
-- them outright: a game without them should refuse to enable the mod, not
-- enable it and quietly do nothing.
--
-- Structure:
--   * Players are scanned every server step and drive their own column
--     lookup.  Everything about player movement happens in scan_players.
--   * Entities are handled from a registry of live columns, so the costly
--     get_objects_in_area scales with column count, not object count.
--   * Boats are the exception among entities: a whirlpool rocks one for a
--     few seconds and then sinks it, from inside the boat's own step.  See
--     the boat section for why nothing else could reach them.
--   * An ABM on the source blocks keeps unoccupied columns drawing bubbles.
--
-- Two engine constraints shape the whole design; see begin_lift.

local modname = core.get_current_modname()

local function setting_number(key, default)
	return tonumber(core.settings:get(modname .. "_" .. key)) or default
end

local function setting_bool(key, default)
	local v = core.settings:get_bool(modname .. "_" .. key)
	if v == nil then return default end
	return v
end

-- The dials, in two groups.
--
-- Only the first group is in settingtypes.txt, and so only the first group
-- appears in the game's settings menu or the README.  They are the ones that
-- change how the mod plays.  Everything in the second group was a development
-- tuning knob: those values are settled, and a menu full of them buries the
-- handful that matter.  They are all still read from minetest.conf, so a
-- server that really needs one is not stuck -- they are just not advertised.

-- Advertised ------------------------------------------------------------

-- Player climb and sink speeds, as multipliers on the client's own liquid
-- sink speed: negative rises, positive sinks.  These are the player speed
-- controls; UP_SPEED and DOWN_SPEED below apply only to entities.
-- Both are reassigned at runtime by /bubblespeed.
local LIQUID_SINK = setting_number("liquid_sink", -1.4)
local DOWN_SINK = setting_number("down_sink", 2.0)
-- How long a boat caught in a whirlpool rocks before it goes under, seconds.
-- The whole of the rocking, not just the part before the descent.
local BOAT_ROCK_TIME = setting_number("boat_rock_time", 3.0)
-- Columns of either direction replenish the player's air.
local RESTORE_AIR = setting_bool("restore_air", true)
-- Break the water surface above a column so it can be spotted from a boat or
-- the shore, rather than only by swimming down and looking.
local SURFACE_BUBBLES = setting_bool("surface_bubbles", true)
-- Traces column detection and physics to debug.txt.  Noisy by design.
local DEBUG = setting_bool("debug", false)
-- (bubble_columns_soul_soil_too is read further down, with SOURCES.)

-- Settled, and deliberately not advertised -------------------------------

-- How far up from the source block a column may reach.  Only consulted from
-- the ABM, so a generous cap costs almost nothing.
local MAX_HEIGHT = setting_number("max_height", 24)
-- Terminal vertical speed for entities, m/s.  Both are magnitudes.
local UP_SPEED = setting_number("up_speed", 8)
local DOWN_SPEED = setting_number("down_speed", 6)
-- How hard an entity is pulled towards that speed, m/s^2.  Entities only;
-- players are moved by the gravity factors below instead.
local ACCEL = setting_number("accel", 30)
-- Neutralises gravity for a player in an updraft so it does not fight the
-- lift.  It cannot do the lifting itself -- see begin_lift.  Unadvertised
-- partly because a negative value looks like it ought to lift and does not.
local UP_GRAVITY = setting_number("up_gravity", 0)
-- Removes some of the water resistance that would otherwise damp the climb to
-- ordinary swim-up speed.  Kept modest: high values also let a player retain
-- momentum like air and carry speed up out of the water.
local LIQUID_FLUIDITY = setting_number("liquid_fluidity", 1.5)
-- How far below the surface the updraft starts easing off, in nodes, measured
-- from the player's HEAD (their feet sit 1.4 nodes lower).  Without it the
-- lift fires them clear of the water and they fall back in repeatedly.
-- Reassigned at runtime by /bubbletaper, with SURFACE_SINK_SCALE below.
local SURFACE_TAPER = setting_number("surface_taper", 1.0)
-- Fraction of the climb speed kept over the last SURFACE_TAPER nodes so the
-- player eases up to the surface and floats rather than being fired clear.
local SURFACE_SINK_SCALE = setting_number("surface_sink_scale", 0.6)
-- How fast a boat sinks once its rocking time is up, m/s, and how many full
-- rocks it makes a second.  Both are reassigned by /bubbleboat.
local BOAT_SINK_SPEED = setting_number("boat_sink_speed", 3.0)
local BOAT_ROCK_RATE = setting_number("boat_rock_rate", 1.6)

-- Below 1 is unsupported by the engine and silently misbehaves.
if LIQUID_FLUIDITY < 1 then
	LIQUID_FLUIDITY = 1
end

local function dbg(fmt, ...)
	if DEBUG then
		core.log("action", "[bubble_columns] " .. string.format(fmt, ...))
	end
end

-- Matched by node name, not by the `soul_block` group: soul soil shares that
-- group with soul sand but must not make a column.
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
table.sort(SOURCE_NAMES)

-- Named blocks are a soft coupling: if a game renames one, every stage of the
-- mod fails at once and none of them says why.  That is exactly how the whole
-- mod came to be a silent no-op under VoxeLibre, so check it out loud at
-- startup rather than leaving it to be discovered in a world.  MISSING_SOURCES
-- is repeated by /bubblecheck, where it will actually be read.
local MISSING_SOURCES = {}
for _, name in ipairs(SOURCE_NAMES) do
	if not core.registered_nodes[name] then
		table.insert(MISSING_SOURCES, name)
	end
end

if #MISSING_SOURCES > 0 then
	core.log("error", "[bubble_columns] this game does not have "
		.. table.concat(MISSING_SOURCES, " or ")
		.. ", so those columns cannot work. It is built for Mineclonia and"
		.. " VoxeLibre, and should suit anything derived from them -- but"
		.. " this game has renamed the block, and the mod needs updating to"
		.. " match.")
end

local ABM_INTERVAL = 2
-- Must exceed ABM_INTERVAL, or a column blinks out between refreshes.
local COLUMN_TTL = ABM_INTERVAL + 1.5
-- Entities are eased towards a target velocity rather than kicked, so a
-- coarser tick than the player pass is just as smooth and much cheaper.
local OBJECT_INTERVAL = 0.1
-- How often a live column re-arms its particle spawner.
local PARTICLE_PERIOD = 2.0

-- Monotonic seconds since load, accumulated from globalstep dtime.  Used
-- instead of os.time() so expiry follows server time, not wall clock.
local now = 0
local columns = {}

-- The game's own underwater breath-trail sprite, in both Mineclonia and
-- VoxeLibre. Reused rather than shipped: Luanti's media namespace is flat, so
-- naming a game texture needs no dependency, and the bubbles then match
-- whatever texture pack the player is using.
local BUBBLE_TEXTURE = "mcl_particles_bubble.png"

local function is_water(name)
	return core.get_item_group(name, "water") > 0
end

-- Columns propagate through water *source* blocks only and stop at flowing
-- water.  Tested by definition rather than by name so river water
-- (mclx_core:river_water_source, which copies the water source definition)
-- counts too.
--
-- Source is read from `liquidtype`, which is the engine's own answer and the
-- only one both games agree on: Mineclonia puts a `liquid_source` group on
-- water, VoxeLibre does not.  Testing that group instead made every node fail
-- this check under VoxeLibre, so no column was ever found and the whole mod
-- silently did nothing there.
local function is_column_water(name)
	if core.get_item_group(name, "water") == 0 then
		return false
	end
	local def = core.registered_nodes[name]
	return def ~= nil and def.liquidtype == "source"
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
	-- Stop a node short of the surface: bubbles keep travelling after they
	-- spawn, and speed x lifetime must stay under that node or they end up
	-- visibly above the water.
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
		texture = BUBBLE_TEXTURE,
		glow = 2,
	})
end

-- The column breaking the surface, so it can be seen from above the water.
-- The shaft bubbles deliberately stop a node short of the top, which left a
-- column invisible from a boat or the shore.
--
-- Drawn only where the column actually reaches open air: a column under an
-- overhang, cut short by flowing water, or capped at MAX_HEIGHT stops below
-- something solid, and bubbles there would be inside that block.
local function spawn_surface_particles(pos, kind, height)
	if core.get_node({x = pos.x, y = pos.y + 1 + height, z = pos.z}).name ~= "air" then
		return
	end
	local rising = kind == "up"
	local surface_y = pos.y + 0.5 + height
	core.add_particlespawner({
		-- A fixed count, not scaled by height like the shaft: this is one
		-- node's worth of water surface however deep the column runs.
		amount = 15,
		time = PARTICLE_PERIOD + 0.5,
		-- A thin slab just under the surface, over the column's own
		-- footprint, so the bubbles rise through the waterline and pop.
		minpos = {x = pos.x - 0.5, y = surface_y - 0.2, z = pos.z - 0.5},
		maxpos = {x = pos.x + 0.5, y = surface_y, z = pos.z + 0.5},
		-- An updraft breaks the surface; a whirlpool dimples it and draws
		-- back under. Slow and short-lived either way -- speed x lifetime is
		-- how far clear of the water they end up, and this wants a quarter
		-- of a node, not the metre the shaft bubbles would manage.
		minvel = {x = -0.3, y = rising and 0.4 or -0.3, z = -0.3},
		maxvel = {x = 0.3, y = rising and 0.9 or 0.2, z = 0.3},
		-- Arcs them back down, so they read as popping rather than escaping.
		minacc = {x = 0, y = -1.5, z = 0},
		maxacc = {x = 0, y = -1.5, z = 0},
		minexptime = 0.2,
		maxexptime = 0.45,
		-- Smaller than the shaft bubbles: froth, not a plume.
		minsize = 0.5,
		maxsize = 1.4,
		collisiondetection = false,
		texture = BUBBLE_TEXTURE,
		glow = 1,
	})
end

-- Counters, reported by /bubblecheck: they distinguish "the ABM never fired"
-- from "it fired and the action bailed out".
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
	-- Rate-limited: the player scan rediscovers the same column every step.
	if now >= column.next_particles then
		spawn_particles(pos, kind, height)
		if SURFACE_BUBBLES then
			spawn_surface_particles(pos, kind, height)
		end
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

-- The vertical span a column acts on, as a pair of corner positions.  Starts
-- at the *bottom* of the source block so anything resting on top of it is
-- inside the box; an object standing on the block sits exactly on the upper
-- face, which floating point puts either side of.
local function column_bounds(column)
	local pos = column.pos
	return {x = pos.x - 0.5, y = pos.y - 0.5, z = pos.z - 0.5},
		{x = pos.x + 0.5, y = pos.y + 0.5 + column.height, z = pos.z + 0.5}
end

-- Keeps unoccupied columns drawing bubbles.  Cosmetic only: players find
-- their own columns by scanning, so this failing breaks nothing.
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

-- Players and entities are moved by completely different means, for two
-- engine reasons.  Both are easy to undo by accident, so:
--
--  1. NEVER rewrite a player's velocity to move them continuously.
--     `add_velocity` arbitrates against `get_velocity()`, which lags the
--     client; a stale-low reading makes the correction overshoot, and the
--     next step overshoots again.  The result is visible jitter and a bounce
--     that grows every time the player breaks the surface.
--
--  2. `physics_override.gravity` does NOT lift a player in a liquid.  The
--     client uses its liquid model there (movement_liquid_sink /
--     movement_liquid_fluidity), not gravity acceleration.
--
-- So a player is moved only by handing the client a different liquid model
-- and letting it do the work: `liquid_sink` is a multiplier on sink speed, so
-- negative rises at a constant rate.  One controller, no stale feedback.
--
-- Entities are simulated server-side with no client predicting them, so
-- `add_velocity` behaves normally and they keep the eased velocity drive.
local LIFT_ID = "bubble_columns:column"

-- obj -> {kind = "up"|"down", last_seen = <time>}.  Timestamped rather than
-- rebuilt each tick because the player and entity passes run at different
-- rates, so a shared "seen this tick" set would release entities early.
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

--------------------------------------------------------------------------
-- Boats
--------------------------------------------------------------------------
-- A boat cannot be dragged down the way every other entity is.  mcl_boats'
-- own on_step rewrites the boat's velocity every step, and while it is
-- floating it also snaps its position back to the top of the water node it
-- sits on -- so the drive_towards push above is thrown away before it can
-- carry the boat past the surface, and the boat only creeps under at the
-- -0.2 m/s its own "inside water" branch allows.  That is why a whirlpool
-- took so long to swallow one.
--
-- So a boat gets its own path.  The mod wraps the boat's on_step and acts
-- after it -- the only ordering that can win against a per-step rewrite --
-- and drives the descent by position, because position is the thing the
-- float branch fights over.
--
-- For the first BOAT_ROCK_TIME seconds nothing moves the boat at all: it only
-- rolls, harder and harder, towards the tilt mcl_boats gives a boat at zero
-- hp.  So the whirlpool announces itself the way a breaking boat does, and
-- there is time to paddle out of it.

-- Peak tilt, radians.  mcl_boats leans a boat pi/4 when its hp reaches zero;
-- three quarters of that is a boat in trouble rather than a boat coming
-- apart, which is the note this wants to hit.
local BOAT_ROCK_TILT = math.pi / 4 * 0.75

local BOAT_ENTITIES = {"mcl_boats:boat", "mcl_boats:chest_boat"}
local BOATS = {}

-- Mineclonia lets a capable client steer its own boat, and while it does, the
-- boat's on_step returns early and the client's movement packets set the
-- boat's position outright -- there is no server-side drive that can win.  So
-- take the boat back first, keeping the rider aboard, exactly as the game
-- itself does when a client declines to drive one.
--
-- Best effort by design: on a build or a client without client-side steering
-- every call here is a no-op, and if those internals move, the worst outcome
-- is that a client-steered boat keeps floating instead of sinking.
local function reclaim_from_client(self)
	if not self._csm_driving then return end
	local driver = self._driver
	local states = mcl_serverplayer and mcl_serverplayer.client_states
	local state = driver and states and states[driver]
	if not state or state.vehicle ~= self.object then
		self._csm_driving = false
		return
	end
	if not self.fallback_attach then return end
	mcl_serverplayer.send_rescind_vehicle(driver, state.vehicle_id)
	state.vehicle = nil
	state.vehicle_id = nil
	state.vehicle_pos = nil
	state.vehicle_vel = nil
	state.vehicle_dtime = nil
	state.vehicle_tsc = nil
	-- Re-seats the driver server-side and clears _csm_driving.
	self:fallback_attach(driver, state)
	dbg("took a boat back from client-side steering")
end

-- Runs after the boat's own on_step, every step, for as long as apply_column
-- keeps stamping _bubble_seen.
local function boat_step(self, dtime)
	if not self._bubble_seen or now - self._bubble_seen > LIFT_GRACE then
		-- Out of the whirlpool.  mcl_boats sets the boat's rotation from
		-- its hp every step, so letting go is all it takes to level it.
		self._bubble_rock = nil
		self._bubble_sink_y = nil
		return
	end

	local t = (self._bubble_rock or 0) + dtime
	self._bubble_rock = t
	local obj = self.object

	-- Rocks harder the closer it gets to going under, and stops dead the
	-- moment the whirlpool takes it -- BOAT_ROCK_TIME is the whole of the
	-- rocking, not just the part before the descent.  mcl_boats sets the
	-- boat's rotation from its hp every step, so no unwinding is needed:
	-- letting go of the rotation is what levels it.
	if t < BOAT_ROCK_TIME then
		local tilt = BOAT_ROCK_TILT * (0.3 + 0.7 * (t / BOAT_ROCK_TIME))
		local phase = t * BOAT_ROCK_RATE * 2 * math.pi
		-- Pitch and roll a quarter cycle apart.  mcl_boats' damage tilt
		-- drives both by the same amount, which leans the hull along one
		-- diagonal and holds it there; offsetting them walks that lean
		-- around the boat instead, which is what reads as rocking.
		obj:set_rotation(vector.new(tilt * math.sin(phase), obj:get_yaw(),
			tilt * math.cos(phase)))
		return
	end

	reclaim_from_client(self)

	-- Driven by position, not velocity: see the note at the top.
	--
	-- The descent height is the mod's own, carried from step to step, not
	-- read back off the boat.  Reading it back cannot work: while the boat
	-- is still up at the surface mcl_boats snaps it to the top of its water
	-- node on every single step, so a drop measured from where the boat
	-- currently is would be given straight back, and the boat would sit
	-- there twitching for ever instead of going under.  Nothing renders in
	-- between -- the snap and this both happen inside one server step -- so
	-- what the client sees is a smooth descent.
	local pos = obj:get_pos()
	local sink_y = (self._bubble_sink_y or pos.y) - BOAT_SINK_SPEED * dtime
	-- Sinks through water only, so it settles on the bottom -- usually the
	-- magma block making the whirlpool -- rather than through it.  The hull
	-- floor comes from the boat's own collision box, which starts at 0 in
	-- Mineclonia and at -0.15 in VoxeLibre.
	local box = obj:get_properties().collisionbox
	local hull = box and box[2] or 0
	local under = core.get_node({
		x = pos.x, y = sink_y + hull - 0.1, z = pos.z,
	}).name
	if is_water(under) then
		self._bubble_sink_y = sink_y
	end
	obj:set_pos({x = pos.x, y = self._bubble_sink_y or pos.y, z = pos.z})

	-- Zeroed so the engine does not add a helping of its own on top of the
	-- drive, and so mcl_boats' own slow sink does not keep pressing a
	-- landed boat into the floor.
	local vel = obj:get_velocity()
	if vel then
		obj:set_velocity({x = vel.x, y = 0, z = vel.z})
	end
end

-- Wrapping post-registration rather than overriding on_step in a def of our
-- own: the entity definition IS the metatable every live boat indexes, so one
-- wrap covers every boat in the world, including ones already loaded.
core.register_on_mods_loaded(function()
	for _, name in ipairs(BOAT_ENTITIES) do
		local def = core.registered_entities[name]
		if def then
			BOATS[name] = true
			local inner = def.on_step
			def.on_step = function(self, dtime, moveresult)
				if inner then inner(self, dtime, moveresult) end
				-- mcl_boats removes the boat from inside its own step
				-- (fire, and being broken), so it may be gone by now.
				if self.object and self.object:get_pos() then
					boat_step(self, dtime)
				end
			end
		end
	end
end)

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
			local entity = obj:get_luaentity()
			if not rising and entity and BOATS[entity.name] then
				-- All this pass does for a boat is say it is still in the
				-- whirlpool; boat_step does the rest, from inside the
				-- boat's own step where it can outlast the rewrite.
				entity._bubble_seen = now
			else
				begin_lift(obj, rising and "up" or "down")
				drive_towards(obj, target, dtime)
			end
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

		-- Stage 0, before anything else: if a source block is not in this
		-- game at all, every stage below fails for that one reason and none
		-- of them says so.
		if #MISSING_SOURCES > 0 then
			say("STOP: this game does not have %s.",
				table.concat(MISSING_SOURCES, " or "))
			say("      Bubble Columns is built for Mineclonia and VoxeLibre,")
			say("      and should suit anything derived from them -- but this")
			say("      game has renamed the block, so the mod needs updating")
			say("      to match. Nothing you do in world will fix it.")
			return true, table.concat(out, "\n")
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
				-- The commonest way to get here is running the command from
				-- the bank while looking at the column.  The scan goes down
				-- from your feet, so standing anywhere dry fails on the very
				-- first node and says nothing about the column itself.
				if i == 0 and not is_water(n) then
					say("  ^ you are not in the water, so this checked the")
					say("    ground you are standing on, not the column.")
					say("    Swim in until you are inside the water above the")
					say("    block, then run this again.")
				elseif n == "air" then
					say("  ^ air below the water means the shaft is broken.")
					say("    A column needs an unbroken run of water sitting")
					say("    directly on the block.")
				elseif core.get_item_group(n, "water") > 0 then
					say("  ^ that is FLOWING water, not still. A column stops")
					say("    dead where the water starts flowing. Fill the")
					say("    shaft bucket by bucket, or plant kelp, to turn it")
					say("    still.")
				end
				if n == "mcl_blackstone:soul_soil" then
					say("  ^ that is Soul SOIL, not Soul SAND. They are")
					say("    different blocks and only soul sand makes a")
					say("    column. You want mcl_nether:soul_sand -- or set")
					say("    bubble_columns_soul_soil_too = true to allow both.")
				end
				break
			end
		end
		if found_source then
			say("stage 1 ok: %s at %s (%s column)", found_source,
				core.pos_to_string(source_pos), SOURCES[found_source])
			local height = measure_column(source_pos)
			say("stage 2: measured height = %d", height)
			-- A block placed on dry land, or at the bottom of a shaft that
			-- was never flooded, is the other half of the stage 1 confusion:
			-- the block is right, and there is simply no water on it.
			if height == 0 then
				local above = core.get_node({
					x = source_pos.x, y = source_pos.y + 1, z = source_pos.z,
				}).name
				say("  ^ nothing above the block but %s.", above)
				if core.get_item_group(above, "water") > 0 then
					say("    That is FLOWING water. A column needs STILL")
					say("    water sitting directly on the block -- fill the")
					say("    shaft bucket by bucket, or plant kelp.")
				else
					say("    A column is a shaft of still water standing ON")
					say("    the block. Flood it and the bubbles will start.")
				end
			end
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

-- How long a boat should hang on before it goes under, and how fast it then
-- goes, are both pure feel, so they get the same treatment as the climb.
core.register_chatcommand("bubbleboat", {
	params = "[<seconds> [<sink> [<rocks>]]]",
	description = "Show or set how long a boat rocks in a whirlpool before "
		.. "it sinks, and how fast it sinks",
	privs = {server = true},
	func = function(name, param)
		if param == "" then
			return true, string.format(
				"boats rock for %.2fs at %.2f rocks/s, then sink at %.2f m/s",
				BOAT_ROCK_TIME, BOAT_ROCK_RATE, BOAT_SINK_SPEED)
		end
		local seconds, sink, rocks = param:match("^(%S+)%s*(%S*)%s*(%S*)$")
		seconds = tonumber(seconds)
		if not seconds or seconds < 0 or seconds > 30 then
			return false, "seconds must be between 0 and 30, e.g. /bubbleboat 3 3.0"
		end
		if sink ~= "" then
			sink = tonumber(sink)
			if not sink or sink <= 0 or sink > 12 then
				return false, "sink speed must be between 0 and 12 m/s"
			end
			BOAT_SINK_SPEED = sink
		end
		if rocks ~= "" then
			rocks = tonumber(rocks)
			if not rocks or rocks <= 0 or rocks > 10 then
				return false, "rocks per second must be between 0 and 10"
			end
			BOAT_ROCK_RATE = rocks
		end
		BOAT_ROCK_TIME = seconds

		-- Boats already rocking restart their clock, so the new timing is
		-- what the next run of the column actually shows.
		for _, entity in pairs(core.luaentities or {}) do
			if BOATS[entity.name] then
				entity._bubble_rock = nil
				entity._bubble_sink_y = nil
			end
		end

		return true, string.format(
			"boats rock for %.2fs at %.2f rocks/s, then sink at %.2f m/s "
			.. "(this session only)\n"
			.. "to keep it:  bubble_columns_boat_rock_time = %s\n"
			.. "             bubble_columns_boat_sink_speed = %s\n"
			.. "             bubble_columns_boat_rock_rate = %s",
			BOAT_ROCK_TIME, BOAT_ROCK_RATE, BOAT_SINK_SPEED,
			BOAT_ROCK_TIME, BOAT_SINK_SPEED, BOAT_ROCK_RATE)
	end,
})

-- Exposed for tests/run.py, which drives the ABM and globalstep directly.
bubble_columns = {
	columns = columns,
	measure_column = measure_column,
	lifted = lifted,
}
