# Bubble Columns

Minecraft-style bubble columns for **Mineclonia**. Put a soul sand block under
water and the whole column above it becomes an updraft that carries players,
mobs, boats and dropped items to the surface. Put a magma block there instead
and it becomes a whirlpool that drags them down.

Mineclonia has no bubble columns of its own — soul sand only slows walking and
magma only burns your feet, neither of them looks at the water above.

## Why this is a mod and not a game patch

It registers **no nodes**. Column state is derived on the fly from the blocks
already in the world, so the mod can be added to or removed from an existing
world at any time with nothing left behind — no orphaned nodes, no migration,
and nothing for `mineclonia-patches/restore.sh` to re-apply after a Mineclonia
update.

## How it works

Detection is driven by the players. Every server step each connected player is
checked — one `get_node` if they aren't in water — and if they are, a downward
scan looks for a soul sand or magma block under an unbroken run of water.
Finding one registers a column and drives that player on the spot.

This began as an ABM on the source blocks instead, and it registered nothing at
all in game. ABMs only run in active mapblocks and their scheduling isn't
observable from Lua, so a column that never appeared couldn't be diagnosed. The
player scan is deterministic, costs almost nothing when nobody is swimming, and
is tied directly to the thing that has to be affected. An ABM is still
registered, but only so unoccupied columns keep drawing their bubbles — where
failing is merely cosmetic.

A globalstep then walks that registry and does the physics. Keeping the
registry means the expensive call — `get_objects_in_area` — scales with the
number of live columns rather than with the number of objects in the world.

**The player lift is entirely client-side, and the server never touches a
rising player's velocity.** That is the single most important thing about this
mod, and it took several wrong turns to arrive at.

`add_velocity` arbitrates against `get_velocity()`, which lags the client by
however far behind the last position update is. Rewriting velocity every step
against a stale reading overshoots whenever the reading is low, so the client
gets pushed past target and the next step pushes again. That produced both the
jitter and a bounce at the surface that grew with every cycle. It needs no help
from any other setting to happen — it is inherent to server-driving a player.

Instead, `physics_override` (Luanti 5.8+) retunes the client's own liquid model
and then gets out of the way:

* **`liquid_sink`** negative — a multiplier on liquid sink *speed*, so the
  player rises at a constant rate with no acceleration runway to compound. The
  client applies it continuously at its own frame rate, so it is smooth by
  construction. **This is the climb speed control for players.**
* **`liquid_fluidity`** slightly raised — removes some of the resistance that
  otherwise damps the climb to ordinary swim-up speed. It only subtracts
  damping, so it cannot drive anything. Kept modest, because high values also
  let the player retain momentum like air and carry speed up out of the water.
* **`gravity` = 0** — stops gravity fighting the sink. Note it cannot *lift*:
  measured in game, gravity forced to `-1.0` in a 16-deep column still gave
  `v.y = -0.30`, still sinking. Luanti uses the liquid model here, not gravity.

Approaching the surface the mod switches to a second lift state with a fraction
of the sink, so the player eases up and floats rather than being carried clear
and falling back in. It is a state change rather than a per-step recalculation
because `playerphysics` serialises to player meta on every write.

`up_speed` and `accel` now apply only to entities. Mobs, boats and dropped items
are server-side objects with no client predicting them, so `add_velocity` on
those behaves normally and they keep the eased velocity drive.

**The lift runs while any part of you is in water**, feet included, so it
carries you the last node clear of the surface rather than cutting out with
your head 1.4 nodes short of it. That is only safe because the lift is a
client-side override: the engine applies it solely while you are actually in
liquid, so it ends by itself, and there is no server/client arbitration left to
pump energy into a bounce. The same widening alongside a velocity drive is what
made the player bob at the surface indefinitely.

Players are released the *instant* they leave the water, with no grace period:
holding `gravity = 0` for even a third of a second after they shoot out turns
the exit arc into a coast, so they reach a higher apex, fall back in faster and
launch higher still. That resonance grew with every bounce. Entities keep a
short grace because they run on the coarser cadence.

Velocity injection every server step — the `mcl_potions` levitation pattern,
and so what shulker bullets rely on — is what got this working at all, and
remains the fallback when the liquid overrides can't hold the speed.

Whirlpools work the same way, with a *positive* `liquid_sink`. They were the
last thing still driven from the server, and they reproduced both server-drive
symptoms exactly — dragging the player to the bottom almost instantly, and the
bounce that grew every cycle. Gravity is left alone there; going down it is an
ally.

Entities (mobs, boats, dropped items) are simulated server-side where
`add_velocity` behaves normally, so they stay on the coarser cadence and are
eased towards a terminal speed — which also means an entity already falling
fast is braked to the whirlpool's speed rather than accelerated past it.

## Tuning the climb speed

    /bubblespeed          -- show both climb and sink speeds
    /bubblespeed -2.2     -- negative sets the updraft
    /bubblespeed 2.5      -- positive sets the whirlpool
    /bubbletaper          -- show how it eases off at the surface
    /bubbletaper 0.5 0.7  -- ease later (0.5 nodes) and less (keep 70%)

Climb speed and surface behaviour can only really be judged by riding a
column, so both are adjustable in game without a restart. The taper distance is
measured from your **head**, so it means the water you can actually see above
you. Negative rises; more negative is faster. Players
already in a column pick the new value up on the next step. The command prints
the `minetest.conf` line to keep a value you like. Needs the `server` priv.

## Diagnosing a column that does nothing

    /bubblecheck

Run it standing in the column. It walks every stage — source block found,
column height measured, column present in the live registry, objects in the
box, gravity hold applied — names the one that fails, and reports your actual
`v.y`. That last number is the one that matters: it is what proved the gravity
override was being applied and doing nothing.

`bubble_columns_debug = true` in `minetest.conf` traces the same pipeline to
`debug.txt` continuously, which is noisier but catches intermittent problems.

The bubbles are the game's own `mcl_particles_bubble.png`, the sprite
`mcl_player` uses for the underwater breath trail. Luanti's media namespace is
flat, so it needs no dependency and the mod ships no textures of its own.

## Behaviour notes

* **Columns run through water *source* blocks only**, stopping at flowing
  water, as in Minecraft. Tested by group, so river water counts too. (Vanilla
  players exploit this with kelp, which converts flowing water to source.)
* **Both directions replenish air.** The wiki describes this for bubble columns
  generally, not just rising ones. A whirlpool is still dangerous because it
  pins you against a magma block, which burns.
* **The whirlpool is drawn as a rotating vortex.** One spawner cannot do this:
  `attract` only sets a particle's *birth* velocity, and there is no sustained
  centripetal force in the API, so every particle in a spawner travels one
  straight or parabolic path. The swirl is instead built from several narrow
  spawners spaced around the axis, each launching along its own tangent with a
  constant acceleration pointing back at the centre, which bends the path into
  an arc. Arc plus descent reads as a helix, and the whole ring is rotated a
  little on each refresh so it turns.
* **Soul soil does not make a column**, matching Minecraft. Note that Soul Sand
  is `mcl_nether:soul_sand` while Soul Soil is `mcl_blackstone:soul_soil` —
  different mods, no alias, sharing only the `soul_block` group, and near
  identical in the creative inventory. That is why the mod matches node names
  rather than the group, and why it is so easy to build a test column on the
  wrong block. Set `bubble_columns_soul_soil_too = true` to allow both.
* **Updrafts refill your air, whirlpools do not.** This mirrors Minecraft, and
  is what makes a magma whirlpool actually dangerous. Turn it off with
  `bubble_columns_restore_air = false`.
* **Riders are not pushed.** An attached object is driven by its parent, so
  moving it here would fight the attachment rather than carry the rider. Ride a
  boat into a column and the boat is what gets carried.
* Columns are capped at 24 nodes by default, which clears any ocean in
  practice.

## Settings

All optional, all listed in `settingtypes.txt` and editable from the game's
settings menu.

| setting | default | what |
|---|---|---|
| `bubble_columns_max_height` | 24 | tallest column a single block can drive |
| `bubble_columns_liquid_sink` | -1.6 | **main updraft speed control**; negative sinks upward |
| `bubble_columns_liquid_fluidity` | 3.0 | lowers liquid resistance so the climb isn't clamped |
| `bubble_columns_speed_deadband` | 1.5 | drift either side of target before the server corrects |
| `bubble_columns_surface_taper` | 1.0 | nodes above your **head** where the lift eases off; 0 = launch |
| `bubble_columns_up_speed` | 8.0 | velocity floor for the updraft, nodes/s |
| `bubble_columns_down_sink` | 2.0 | **player sink speed** in a whirlpool; higher sinks faster |
| `bubble_columns_down_speed` | 6.0 | whirlpool speed for **entities only**, nodes/s |
| `bubble_columns_accel` | 30.0 | how sharply an *entity* reaches that speed, nodes/s² |
| `bubble_columns_up_gravity` | 0.0 | *player* gravity multiplier in an updraft; 0 = neutral, NOT a lift |
| `bubble_columns_soul_soil_too` | false | let soul soil make columns too (Minecraft says no) |
| `bubble_columns_restore_air` | true | updraft refills the player's air |
| `bubble_columns_debug` | false | trace the pipeline to `debug.txt` |

## Testing

```bash
python3 tests/run.py
```

Runs `init.lua` against a stubbed engine via the `lupa` Python module — no
Luanti install needed. It builds columns over every relevant block, drives the
ABM and globalstep by hand, and asserts both what the mod does and what it must
deliberately *not* do (soul soil, riders, objects outside the column, expired
columns).

## Status

**Working in game** as of 2026-08-08 — Mineclonia 37652 on Luanti 5.16.1.
Verified: soul sand updrafts lift the player smoothly at the shipped defaults,
carry them clear of the surface, and work on mobs. The shipped values for
`liquid_sink`, `surface_taper` and `surface_sink_scale` are the ones that felt
right in play, not guesses.

Verified since: dropped items, and boats sinking (but not breaking) in a
whirlpool — which matches Minecraft, where a boat "shakes and eventually sinks".

Not yet verified: the source-water restriction and air in whirlpools, both
added after the last in-game session. Not deployed to the
Gondor server.

Known divergences from vanilla, all deliberate: bubbles rise and fall in a
straight column rather than a vortex; water-breathing mobs do not suffocate in
columns; there is no ambient sound; and the surface taper
suppresses vanilla's repeated ~1 block bounce at the top (`/bubbletaper 0`
restores it).

## Compatibility

Targets Mineclonia. VoxeLibre uses the same `mcl_nether:soul_sand`,
`mcl_nether:magma` and `group:water` names, so it will probably work there
unchanged — untested.

## License

Code: GPLv3. No media of its own; the bubble sprite belongs to Mineclonia.
