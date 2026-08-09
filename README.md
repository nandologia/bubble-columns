# Bubble Columns

Underwater currents for **Mineclonia** and **Voxelibre**, made from two blocks you already have.

Put **soul sand** on the floor under water and the whole column of water above
it fills with rising bubbles. Swim into it and you are carried straight to the
surface. Put **magma** there instead and you get a whirlpool: the bubbles pour
downward and everything in the column is dragged to the bottom.

Players, mobs, boats and dropped items are all carried.

A **boat** caught in a whirlpool gets its own treatment: it rocks harder and
harder for three seconds, the way a boat does when it is about to break, and
then goes under and stays on the bottom. Paddle clear while it is rocking and
you keep the boat.

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

Either kind breaks the water surface above it with a patch of froth, so you
can spot one from a boat or the shore rather than having to swim down and look.
An updraft boils through the surface; a whirlpool dimples it and draws back
under. A column that stops under an overhang has no surface to break, and draws
nothing.

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
| `bubble_columns_liquid_sink` | -1.4 | how fast an updraft carries you up; more negative is faster |
| `bubble_columns_down_sink` | 2.0 | how fast a whirlpool drags you down |
| `bubble_columns_boat_rock_time` | 3.0 | seconds a boat rocks before a whirlpool takes it; lower is crueller |
| `bubble_columns_restore_air` | true | columns refill your air, so you cannot drown in one |
| `bubble_columns_surface_bubbles` | true | froth on the water above a column |
| `bubble_columns_soul_soil_too` | false | let soul soil make columns as well |
| `bubble_columns_debug` | false | log column detection to `debug.txt` |

### Tuning in game

How fast a column feels is much easier to judge by riding one than by
guessing, so the speeds can be changed without restarting. These need the
`server` privilege.

    /bubblespeed          show current rise and sink speeds
    /bubblespeed -2.2     negative sets the rise speed
    /bubblespeed 2.5      positive sets the whirlpool sink speed

    /bubbletaper          show how the lift eases off near the surface
    /bubbletaper 0.5 0.7  ease later (0.5 nodes) and less (keep 70%)

    /bubbleboat           show how a whirlpool treats a boat
    /bubbleboat 2 4       rock for 2 seconds, then sink at 4 nodes/second
    /bubbleboat 3 3 2.5   the same, rocking 2.5 times a second

Each prints the `minetest.conf` line for whatever you settle on. A few of
those lines are for values that are not in the settings menu — how sharply
mobs and items are pulled along, how the climb eases off at the surface, how
fast a boat goes under. They are tuned already and most servers will never
want them, but they can go in `minetest.conf` all the same.

### If a column does nothing

    /bubblecheck

Run it standing in the column. It checks each step in turn — the block below
you, the water above it, whether the column is live, and what it is doing to
you — and says which one is failing.

## Compatibility

Works in **Mineclonia** and **VoxeLibre**. Both have soul sand and magma under
the same names, and the mod adds no blocks of its own, so it can go into an
existing world or come back out of one freely.

Anywhere without those blocks it refuses to enable
rather than starting up and doing nothing.

Needs Luanti 5.10 or newer on the server, and players need a 5.8 or newer
client: the movement is applied through the client, and older ones will simply
not be carried.

## Testing

    python3 tests/run.py

Runs the mod against a stubbed engine via the `lupa` Python module, so no
Luanti install is needed. 188 checks covering column detection, the physics
applied to players, entities and boats, air, surface behaviour and the chat
commands.

## License

Code: **GPL-3.0-only**, see
[LICENSE.txt](https://github.com/nandologia/bubble-columns/blob/master/LICENSE.txt).
The mod ships no media of its own; the bubble texture belongs to the game.
