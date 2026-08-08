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

An ABM watches soul sand and magma with `neighbors = {"group:water"}`, which
confines the scan to map blocks the engine already treats as active and rejects
every dry soul sand in the Nether for free. Each hit measures the unbroken
water column above the block, refreshes an entry in a registry, and re-arms a
particle spawner.

A globalstep then walks that registry and does the physics. Keeping the
registry means the expensive call — `get_objects_in_area` — scales with the
number of live columns rather than with the number of objects in the world.

**Players and entities are moved by completely different means, and this
matters.** A player is moved by the *client*, which runs its own gravity and
liquid drag every frame. `add_velocity` on a player is a single nudge into that
simulation: the drag eats it between server ticks, and `lua_api.md` states it
does nothing at all during `free_move` — easy to be in inside a creative world.
So players are not pushed. Their gravity is *inverted* with a physics override
and the client's own movement code does the lifting; water drag caps the speed
by itself, exactly as it does when falling. Entities (mobs, boats, dropped
items) are simulated server-side, where `add_velocity` behaves, so those are
driven *towards* a terminal speed — which also means an entity already falling
fast gets braked to the whirlpool's speed rather than accelerated past it.

## Diagnosing a column that does nothing

    /bubblecheck

Run it standing in the column. It walks every stage — source block found,
column height measured, column present in the live registry, player inside the
column's bounding box, gravity override applied — and names the one that fails.
If it reports the gravity override as correct and you still don't move, you're
in fly mode; press `K`.

`bubble_columns_debug = true` in `minetest.conf` traces the same pipeline to
`debug.txt` continuously, which is noisier but catches intermittent problems.

The bubbles are the game's own `mcl_particles_bubble.png`, the sprite
`mcl_player` uses for the underwater breath trail. Luanti's media namespace is
flat, so it needs no dependency and the mod ships no textures of its own.

## Behaviour notes

* **Soul soil does not make a column**, matching Minecraft. `mcl_nether` puts
  soul soil and soul sand in the same `soul_block` group, so the group is the
  wrong thing to test — the mod matches the node name.
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
| `bubble_columns_up_speed` | 8.0 | terminal updraft speed, nodes/s |
| `bubble_columns_down_speed` | 6.0 | terminal whirlpool speed, nodes/s |
| `bubble_columns_accel` | 30.0 | how sharply an *entity* reaches that speed, nodes/s² |
| `bubble_columns_up_gravity` | -1.0 | *player* gravity multiplier in an updraft; negative lifts |
| `bubble_columns_down_gravity` | 3.0 | *player* gravity multiplier in a whirlpool |
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

Offline tests pass. **Not yet verified in game** — the numbers most likely to
need tuning by feel are `up_speed` and `accel`, and the particle density in
`spawn_particles`.

## Compatibility

Targets Mineclonia. VoxeLibre uses the same `mcl_nether:soul_sand`,
`mcl_nether:magma` and `group:water` names, so it will probably work there
unchanged — untested.

## License

Code: GPLv3. No media of its own; the bubble sprite belongs to Mineclonia.
