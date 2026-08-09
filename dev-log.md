# Drillship Down — Dev Log

---

## Current state (2026-08-08)

**Branch: `density-terrain`.** Terrain has been rebuilt as a density field with
marching-squares collision. Drilling is continuous, tunnels are smooth curves
rather than stair-steps, and steering is a committed action with a lock cycle.
Caves are disabled while drill physics gets tuned.

`main` still holds the working TileMap prototype. `git checkout main` reverts
everything below.

---

## Architecture

Rock is a **float per sample point** (0 = open, 1 = solid), not a boolean per
cell. The wall is the contour where density crosses **ISO = 0.5**, found by
interpolating *between* samples — which is why wall angles are continuous at a
4px cell size.

Everything the ship needs from terrain goes through two methods. Any future
backend only has to provide these:

```gdscript
sample(global_pos) -> Dictionary     # {hardness, tier, material}, {} if open
carve(center_global, radius, strength = 1.0)
```

The ship contains no reference to TileMapLayer, cells, or atlas coordinates.

### Rendering is split three ways

| Cell state | Drawn by |
|---|---|
| Fully solid (all 4 corners ≥ ISO) | TileMapLayer — fast, batched, textured |
| Partial | `_draw()` polygon cut to the contour, flat material colour |
| Fully open | nothing |

Square tiles in partially-filled cells *are* the jagged edge. Only the fringe
needs geometry, so cost scales with tunnel perimeter, not world area.

---

## Project structure

```
res://
├── assets/
│   ├── terrain_tiles_4.png     24×8, 12 materials @ 4px
│   ├── terrain_tileset.tres    shared TileSet resource
│   └── drillship_hull.png      16×10, wheels top and bottom
├── scenes/
│   ├── world.tscn              MAIN SCENE
│   ├── density_terrain.gd      density field, marching squares, generation
│   ├── drill_ship.tscn / .gd
│   ├── terrain.tscn            OLD TileMap terrain — unused on this branch
│   └── terrain_generate.gd     OLD backend, kept for reference
├── drill-ship-game-design-doc.md
└── dev-log.md
```

### world.tscn

```
World                Node2D
├── DrillShip        z_index 10, position (0, 120)
│   ├── Sprite2D     drillship_hull.png
│   ├── CollisionShape2D  CapsuleShape2D radius 5, height 16, rotation 90°
│   ├── DrillPivot   Node2D — the steerable bit mount
│   │   ├── DrillHead    Polygon2D, (7,-4)(11,-3)(20,0)(11,3)(7,4)
│   │   └── RayCast2D    target_position (30, 0)
│   └── Camera2D     zoom (2, 2)
└── DensityTerrain   StaticBody2D — density_terrain.gd
    ├── TileView     TileMapLayer, collision_enabled OFF, visuals only
    └── Chunk_x_y    CollisionShape2D nodes, created at runtime
```

`DensityTerrain._ready()` re-centres itself horizontally, so the ship spawn
stays mid-world at any `width`.

---

## Material table

Now a code table in `density_terrain.gd` — a density field has no tiles to
hang custom data on.

| Idx | Material | hardness | tier |
|---|---|---|---|
| 0 | topsoil | 0.1 | 0 |
| 1 | dirt | 0.2 | 0 |
| 2 | clay | 0.4 | 1 |
| 3 | sandstone | 0.6 | 1 |
| 4 | shale | 1.0 | 2 |
| 5 | granite | 1.5 | 2 |
| 6 | basalt | 1.8 | 3 |
| 7 | deep rock | 2.3 | 4 |
| 8 | **gate rock** | **-1.0** | 9 |
| 9 | magma | 0.3 | 1 |
| 10 | ore | 0.6 | 2 |
| 11 | geode | 0.8 | 2 |

`hardness < 0` means un-boreable *and* no thrust — you can't hover by grinding
on a gate. `MAT_COLOR` holds matching flat colours for the fringe polygons.

---

## Systems

**Steering is a committed action**, not a held aim — three states in
`_update_tilt()`:

- `CENTERED` — bit aligned with hull, boring straight. Only state accepting input.
- `STEERING` — one input tilts the bit `tilt_step_deg` and holds it until the
  **hull has actually turned** `steer_turn_fraction` of that angle. Holding the
  input through the window takes another step, up to the cap.
- `RECENTERING` — bit forced forward and locked until `forward_lock_distance`
  **pixels of bore** have passed, while the hull straightens into its new tunnel.

Default state is *forward*, so boring straight is what happens unless you spend
a steering action.

**Exit conditions are geometric, not temporal.** Earlier versions used fixed
durations, which produced a wide arc in topsoil and a barely-visible kink in
granite from the same keystroke — speed varies with hardness, so time doesn't
control shape. Angle and distance give the same bend and the same straight run
everywhere; hard rock just takes longer in wall-clock time. `steer_hold` and
`forward_lock` survive only as **safety caps** for a stalled ship.

Upgrade hooks: `forward_lock_distance` down = deviate more often;
`steer_turn_fraction` or `max_tilt_deg` up = turn harder.

`steer_progress()` returns 0→1 readiness for a HUD indicator, tracking whichever
release condition is nearer. `drill_state()` exposes the phase for colouring.

**Hull attitude** follows `_travel_dir` — a smoothed record of actual motion —
never `heading()`. Turn rate is gated by speed: a drillship can't pirouette in
its own borehole, so stationary means no rotation.

**Boring is a state with hysteresis** (`bore_grace_time`), not a per-frame
contact test.

**Carving is continuous.** Every frame removes density proportional to dig
rate, with linear falloff from the carve centre. Integrated over
`hardness / dig_rate` seconds this removes the same material as one full-strength
carve — it just arrives smoothly. `bore_speed` is now a *cap*; actual speed
emerges from how fast rock softens.

**Dig rate** = `drill_power × heat_factor × gravity_factor × 0.25^(rock_tier − drill_tier)`.
Tier deficit gives soft walls, negative hardness gives hard walls,
`gravity_factor` makes climbing ~0.45× and descending ~1.25×.

**Regrowth** relaxes density back toward its generated value after
`regrow_delay`. Currently **disabled** to isolate carve behaviour.

---

## The geometry budget

These relationships caused most of the bugs. Worth keeping in one place.

```
hull half-length     = capsule height / 2          = 8
post-carve wall      = half-length + probe_depth + bore_radius
raycast reach        must exceed post-carve wall, or contact is lost
                       every time a carve punches through
tunnel radius        must exceed half-length to rotate freely in place
```

At `bore_radius` 16 the wall sits ~26px out, so the ray needs ≥ 30. At
`bore_radius` 7 it sits ~17px out and a 22px ray suffices.

**Long hull, tight tunnel, fast turning — pick two.** A 16px hull turning 15°
sweeps its ends to ~7px off-axis; a snug 7px-radius tunnel leaves nothing spare.
Shortening the capsule buys tighter tunnels *and* cleaner turns.

---

## Open issues

1. **Cave geometry makes physics feel wrong** — concave corners and thin spurs.
   Caves are off until drilling is settled. This needs solving before they return.
2. **Fringe polygons are flat-coloured** against textured interior rock. One cell
   thick. If it reads badly, `draw_polygon` with UVs would texture them.
3. **`_draw()` re-issues every edge polygon on each redraw.** Fine now; if the
   framerate dips after carving a lot of tunnel, batch into per-material triangle
   arrays.
4. **Startup cost at 200×600** is dominated by ~120,000 `set_cell` calls building
   the tile view. That view is scaffolding and will eventually go.

---

## Deliberate choices that look like bugs

**The sprite is intentionally larger than the collision shape.** Sprite2D scale
is (1.1875, 1.4), rendering the 16×10 hull art at ~19×14 over a 16×10 capsule.
This makes the ship read as filling its bore while collision stays forgiving.

→ When diagnosing contact problems, trust the debug contour and the capsule.
**Never the sprite.** Visual overlap with walls is expected here and means
nothing.

**Where the live tuning actually lives.** Eight properties are overridden on the
DrillShip *instance* in `world.tscn`, and instance overrides beat both
`drill_ship.tscn` and the script defaults:

| Property | Instance value | Script default |
|---|---|---|
| `max_tilt_deg` | 15.0 | 60.0 |
| `steer_hold` | 1.5 ⚠️ | 4.0 (now a cap) |
| `forward_lock` | 4.0 ⚠️ | 8.0 (now a cap) |
| `hull_follow_speed` | 4.0 | 6.0 |
| `hull_level_speed` | 3.0 | 4.0 |
| `bore_radius` | **16.0** | 14.0 (10.0 in drill_ship.tscn) |

A 1.5s steer plus a 4.0s forward lock means each steering action is a ~5.5s
commitment — that's where the "bores straight, deviates rarely" feel comes from.

→ Editing `drill_ship.tscn` will NOT change these. The Inspector's revert arrow
marks an overridden property.

---

## Decisions, and why

- **Density field over boolean grid.** The lever for smoothness was never
  resolution, it was interpolation. A float field at 4px beats a boolean field
  at 1px, and costs far less.
- **CharacterBody2D, not RigidBody2D.** Rejected twice. Direct control is easier
  to tune kinematically, and "hull holds its attitude" is awkward to get from a
  body with angular momentum.
- **`motion_mode = FLOATING`.** The GROUNDED default applies floor/ceiling
  semantics and `wall_min_slide_angle`, which *stops* sliding on head-on
  surfaces. All wrong for a rotating, often weightless ship.
- **Terrain regrows.** Reinforces §3's "push down, don't flee up" as a mechanic,
  and bounds state for an infinite world.
- **Act 1 backhaul resolved.** Extraction points sit forward of the start; early
  rock is soft so re-drilling costs seconds. → the generator must enforce forward
  placement.
- **Steering as committed action.** Makes "boring straight" the default rather
  than something the player maintains.

---

## Debugging lessons worth not relearning

- **One definition of solid.** Collision used the interpolated contour while
  `sample()` used a per-cell average — so the drill and the wall disagreed about
  where rock was. Everything now goes through `density_at()`.
- **Segment winding matters.** `ConcavePolygonShape2D` infers surface normals
  from segment *direction*. Mirrored marching-squares cases (1/14, 2/13, …) put
  the wall in the same place with rock on opposite sides and must be emitted in
  opposite order. Bad winding = probes stepping into air and depenetration
  pushing the ship *into* rock.
- **Probe along the ray, not the normal.** The ray always travels hull→rock, so
  stepping along it is deeper-into-material by construction.
- **Godot can't triangulate zero-area polygons.** When a corner sits almost
  exactly on ISO the edge crossings collapse onto it. `_push_poly()` now drops
  duplicates and rejects slivers before they reach `_draw()`.
- **Don't gate a diagnostic behind a checkbox** whose saved state you're unsure
  of. The unconditional throttled `_dbg` print found the real bug in one run
  after several rounds of guessing.
- **Atlas source IDs are not reused.** Rebuilding a TileSet atlas gave source 1,
  not 0. Never hardcode it.
- **F5 runs the main scene, F6 runs the open scene.** Running the wrong one
  silently explains a lot.

---

## Next up

**Start here:** clear the ⚠️ `steer_hold` / `forward_lock` overrides in
`world.tscn` (revert arrow) so they fall back to the new cap values — 1.5s would
cut a turn short in hard rock before the hull came round. Then tune
`forward_lock_distance`. The old 4.0s lock at ~120px/s was roughly **480px**;
the new default is 240, so push it up if that spacing felt right.

1. **Steering-ready HUD.** `TextureProgressBar` in a `CanvasLayer`, dimmed drill
   icon as `texture_under`, bright as `texture_progress`, driven by
   `ship.steer_progress() * 100`. A distance-based bar stalls when the ship
   stops, which teaches the actual rule — bore forward to earn the next turn.
   Open question: show it only during RECENTERING (cleaner, and the tilted bit
   already communicates STEERING visually) or during both.
2. Bring caves back and fix the contact behaviour at concave corners and spurs.
4. Re-enable regrowth and retune now that carving is continuous.
5. Fuel, via the `drilled(global_pos, hardness, tier)` signal.
6. Heat, wiring up the `_heat_factor()` stub.
7. Chunk streaming, when world size starts to hurt.
8. Delete the tile view once fringe rendering is trusted; texture the polygons
   or move to a density shader.

---

## Standing checkpoint question

Does grinding through granite read as satisfying weight, or as waiting? Design
doc §102 says validate that the core drilling feel is fun before building
anything else — still unanswered, and now much closer to being answerable.
