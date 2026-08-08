# Bubble Columns

Underwater currents for **Mineclonia**, made from two blocks you already have.

Put **soul sand** on the floor under water and the whole column of water above
it fills with rising bubbles. Swim into it and you are carried straight to the
surface. Put **magma** there instead and you get a whirlpool: the bubbles pour
downward and everything in the column is dragged to the bottom.

Players, mobs, boats and dropped items are all carried.

## Making one

**A lift:** dig a shaft, fill it with water, and place a block of soul sand at
the bottom. Swim in at the bottom and ride it up. Handy at the side of a
mineshaft, or as the way up out of an ocean base.

**A trap, or a fast way down:** the same thing with a block of magma at the
bottom. Anything that swims in gets pulled under and held there. Magma burns
what stands on it, so a whirlpool over a magma floor is genuinely dangerous —
useful for a mob trap, unkind to guests.

Two things to know:

* The water has to be **still water**, not the flowing kind. A column runs up
  through still water and stops the moment it reaches flowing water, so a
  shaft you have poured water down may only work part of the way. Filling it
  bucket by bucket, or planting kelp, turns flowing water into still water.
* **Soul soil does not work**, only soul sand. They look alike and sit near
  each other in the inventory, so if a column does nothing, check which one
  you placed. (There is a setting to allow both, if you would rather.)

Being in a column of either kind keeps your air topped up, so you will not
drown while you are in one.

## Installing

Drop the `bubble_columns` folder into your `mods` directory and enable it for
your world. Nothing else is needed — the mod adds no new blocks or items, so
you can add it to an existing world, or remove it again, without leaving
anything behind.

## Settings

All optional, all with sensible defaults. They appear in the game's settings
menu under **Bubble Columns**, or can go in `minetest.conf`.

| setting | default | what it does |
|---|---|---|
| `bubble_columns_liquid_sink` | -1.4 | how fast you rise; more negative is faster |
| `bubble_columns_down_sink` | 2.0 | how fast a whirlpool pulls you down |
| `bubble_columns_surface_taper` | 1.0 | how far below the surface the lift eases off, so you float rather than being thrown clear; 0 launches you out |
| `bubble_columns_surface_sink_scale` | 0.6 | how much lift is kept while easing off |
| `bubble_columns_max_height` | 24 | tallest column one block can drive |
| `bubble_columns_restore_air` | true | columns refill your air |
| `bubble_columns_soul_soil_too` | false | let soul soil make columns as well |
| `bubble_columns_up_speed` | 8.0 | rise speed for mobs, boats and items |
| `bubble_columns_down_speed` | 6.0 | sink speed for mobs, boats and items |
| `bubble_columns_accel` | 30.0 | how sharply mobs and items reach that speed |
| `bubble_columns_liquid_fluidity` | 1.5 | how freely you move inside a column |
| `bubble_columns_up_gravity` | 0.0 | gravity while in an updraft |
| `bubble_columns_debug` | false | log column detection to `debug.txt` |

### Tuning in game

Rise and sink speed are far easier to judge by riding a column than by
guessing, so they can be changed without restarting. Both need the `server`
privilege.

    /bubblespeed          show current rise and sink speeds
    /bubblespeed -2.2     negative sets the rise speed
    /bubblespeed 2.5      positive sets the whirlpool sink speed

    /bubbletaper          show how the lift eases off near the surface
    /bubbletaper 0.5 0.7  ease later (0.5 nodes) and less (keep 70%)

Each prints the `minetest.conf` line for whatever you settle on.

### If a column does nothing

    /bubblecheck

Run it standing in the column. It checks each step in turn — the block below
you, the water above it, whether the column is live, and what it is doing to
you — and says which one is failing.

## Compatibility

Built for Mineclonia. VoxeLibre uses the same block names, so it will most
likely work there too, though that is untested.

Needs Luanti 5.10 or newer on the server, and players need a 5.8 or newer
client: the movement is applied through the client, and older ones will simply
not be carried.

## Testing

    python3 tests/run.py

Runs the mod against a stubbed engine via the `lupa` Python module, so no
Luanti install is needed. 124 checks covering column detection, the physics
applied to players and entities, air, surface behaviour and the chat commands.

## License

Code: GPLv3, see `LICENSE.txt`. The mod ships no media of its own; the bubble
texture belongs to Mineclonia.
