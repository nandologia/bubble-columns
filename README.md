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

**The server drives; the client only holds.** Exactly one thing controls
vertical speed — the server, rewriting the player's velocity to the target
every step. The client's liquid model is retuned via `physics_override`
(Luanti 5.8+) only to stop it interfering: `liquid_fluidity` goes up so water
resistance no longer damps the climb back to ordinary swim-up speed, and
`liquid_sink` goes to 0 so the player holds position between updates. Neither
of those *drives* anything.

**Never give the client a drive of its own.** A negative `liquid_sink` makes
the client accelerate the player upward toward its own target while the server
clamps them to `up_speed` twenty times a second — two controllers on one
variable, arbitrating against a velocity reading that lags the client. That
fight pumps energy in, and at the surface it compounds: exit faster, arc
higher, fall back faster, plunge deeper, exit faster still. Every bounce grew,
and no amount of clamping could win it. The mod clamps a configured negative
value back to 0 and logs a warning.

Two things that look like they should work and don't:

* **`physics_override.gravity` does not lift a player in a liquid.** Luanti's
  client uses its liquid model there, not gravity acceleration. Measured in
  game: gravity forced to `-1.0` in a 16-deep column still gave `v.y = -0.30`,
  still sinking. The mod sets the factor to `0` only so gravity can't claw back
  what the lift gains.
* **Raising `up_speed` alone did nothing** until `liquid_fluidity` was raised
  too: liquid resistance clamps the climb to swim-up speed regardless. With
  fluidity raised, `up_speed` is the speed control.

**The lift is capped and tapers at the surface.** The speed correction clamps
symmetrically — only ever *raising* it left the negative `liquid_sink` free to
accelerate without a ceiling, and that closes a feedback loop: a deeper plunge
gives the acceleration a longer runway, so you exit faster, arc higher, fall
back faster and plunge deeper still. Every bounce grew. The lift also eases off
over the last `surface_taper` nodes, so you arrive at the surface and float
instead of being fired clear of it and falling back in.

**The lift needs your head under water, not just your feet.** Breaching the
surface at the top of a column therefore just stops the lift, and you leave on
a normal ballistic arc — which is roughly how Minecraft ejects you. Driving on
feet-in-water instead re-kicked the player to full speed the moment they fell
back far enough to get their feet wet, so they bobbed at the surface forever.
Players are also released the *instant* they leave, with no grace period:
holding `gravity = 0` for even a third of a second after they shoot out turns
the exit arc into a coast, so they reach a higher apex, fall back in faster and
launch higher still. That resonance grew with every bounce. Entities keep a
short grace because they run on the coarser cadence.

Velocity injection every server step — the `mcl_potions` levitation pattern,
and so what shulker bullets rely on — is what got this working at all, and
remains the fallback when the liquid overrides can't hold the speed.

Entities (mobs, boats, dropped items) are simulated server-side where
`add_velocity` behaves normally, so they stay on the coarser cadence and are
eased towards a terminal speed — which also means an entity already falling
fast is braked to the whirlpool's speed rather than accelerated past it.

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
| `bubble_columns_surface_taper` | 2.5 | nodes below the surface where the lift eases off; 0 = launch |
| `bubble_columns_up_speed` | 8.0 | velocity floor for the updraft, nodes/s |
| `bubble_columns_down_speed` | 6.0 | terminal whirlpool speed, nodes/s |
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

**Working in game** as of 2026-08-08 — verified lifting a player in a 16-deep
column in Mineclonia 37652 on Luanti 5.16.1. 76 offline checks pass.

Tune `up_speed` for the climb rate and `surface_taper` for how it behaves at
the top. Still to check: mobs, boats and dropped items in a column, a
magma whirlpool, and particle density. Not yet deployed to the Gondor server.

## Compatibility

Targets Mineclonia. VoxeLibre uses the same `mcl_nether:soul_sand`,
`mcl_nether:magma` and `group:water` names, so it will probably work there
unchanged — untested.

## License

Code: GPLv3. No media of its own; the bubble sprite belongs to Mineclonia.
