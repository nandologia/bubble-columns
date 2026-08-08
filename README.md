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
Objects are driven *towards* a terminal vertical speed rather than kicked with
an impulse, so the ride is smooth and an object already falling fast gets
braked to the whirlpool's speed instead of accelerated past it.

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
| `bubble_columns_accel` | 30.0 | how sharply you reach that speed, nodes/s² |
| `bubble_columns_restore_air` | true | updraft refills the player's air |

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
