# Drillship Down — Dev Log

---

## Current state (end of 2026-08-07)

Ship bores tunnels through procedurally generated layered terrain that heals
behind it. Depth tiers, hard gates, and equipment/heat-based dig rates are all
in. Two known rotation bugs, and one open architecture decision.

---

## Project structure

```
res://
├── assets/
│   ├── terrain_tiles_4.png    24×8  — 12 materials @ 4px   ← IN USE
│   ├── terrain_tiles_8.png    48×16 — same, @ 8px          (spare)
│   ├── terrain_tiles.png      96×32 — original @ 16px      (obsolete)
│   └── drillship_hull.png     32×18, nose points +X
├── scenes/
│   ├── world.tscn             MAIN SCENE
│   ├── terrain.tscn           TileMapLayer + TileSet + terrain_generate.gd
│   ├── terrain_generate.gd    proc-gen + carve() + regrowth
│   ├── drill_ship.tscn
│   └── drill_ship.gd
├── drill-ship-game-design-doc.md
└── dev-log.md
```

### world.tscn

```
World                Node2D
├── TileMapLayer     instance of terrain.tscn
│                    ship_path → ../DrillShip   (MUST be set here, not in terrain.tscn)
└── DrillShip        instance of drill_ship.tscn, position (64, -80)
    └── Camera2D     zoom (2, 2)
```

### DrillShip node tree

```
DrillShip            CharacterBody2D — drill_ship.gd
├── Sprite2D         drillship_hull.png, scale (0.969, 0.889) → renders ~31×16
├── CollisionShape2D CapsuleShape2D radius 5, height 24, rotation 90° → 24×10
└── DrillPivot       Node2D — rotates to drill heading (±60°, 15° steps)
    ├── DrillHead    ColorRect, visual only
    └── RayCast2D    position (7,0), target_position (28,0)
```

Capsule needs `rotation = 90°` — Godot's CapsuleShape2D runs along Y by default,
and the drill heading is local +X.

---

## Tile data

**Three numbers must always agree: art resolution per material = `texture_region_size`
= `tile_size`.** Currently all 4. A mismatch here is what caused tiles to render
off-grid and overlap their neighbours.

| Tile | Atlas | hardness | tier |
|---|---|---|---|
| topsoil | 0:0 | 0.1 | 0 |
| dirt | 1:0 | 0.2 | 0 |
| clay | 2:0 | 0.4 | 1 |
| sandstone | 3:0 | 0.6 | 1 |
| shale | 4:0 | 1.0 | 2 |
| granite | 5:0 | 1.5 | 2 |
| basalt | 0:1 | 1.8 | 3 |
| deep rock | 1:1 | 2.3 | 4 |
| **gate rock** | 2:1 | **-1.0** | 9 |
| magma | 3:1 | 0.3 | 1 |
| ore | 4:1 | 0.6 | 2 |
| geode | 5:1 | 0.8 | 2 |

`hardness < 0` = un-boreable (design doc §7 hard gate). It also means *no thrust* —
you can't hover by grinding on a gate.

Unset values default to 0. Godot doesn't serialize defaults, so tier legitimately
appears on only 10 of 12 tiles (topsoil and dirt are tier 0). That's not a gap.

**Atlas source ID is 1, not 0** — rebuilding the atlas for 4px removed source 0 and
IDs aren't reused. Never hardcode it; use `tile_set.get_source_id(0)`.

---

## Systems

**Drill aim.** `pivot` rotates ±`max_tilt_deg` (60) in `tilt_step_deg` (15)
increments, local to the hull. `heading()` reads `pivot.global_rotation` so the
world-space bore direction accounts for hull rotation. Both are exports —
`tilt_step_deg` is the upgrade hook (ship 30°, sell 15°, then finer).

**Steering.** Because the drill is offset relative to a hull that rotates to follow
travel, holding a tilt makes the ship *curve* rather than snap to a heading. Like
directional boring. Any heading is still reachable, it just takes a turn.

**Boring.** Thrust only applies when `_is_boring` — the ray must be touching
breakable rock. No thrust in open air, none against gate rock. Gravity is skipped
while boring (the bit anchors you).

**Dig rate.** `drill_power × _heat_factor() × _gravity_factor() × 0.25^(rock_tier − drill_tier)`.
Tier deficit gives soft walls; negative hardness gives hard walls; `_gravity_factor()`
makes climbing ~0.45× and descending ~1.25×, so going up is expensive rather than
forbidden.

**Carving.** `terrain_generate.carve(center, radius)` removes a disc. Gate rock is
skipped inside the loop — otherwise a wide bore would chew through a hard wall from
an adjacent soft tile and leak the tier gate.

**Regrowth.** Carved cells are recorded as scars with a timestamp and restored after
`regrow_delay` (currently **3.0s**). Cells within `ship_clearance` of the ship are
deferred, not skipped — terrain closes in and waits rather than crushing you.
Natural caves are never scars, so generated open space stays open permanently.

**Generation.** Depth bands follow the tier progression. Gate seams at y=237/307/377
span the full width and are written *before* the cave check, so noise can never punch
a hole through a tier gate. Ore/geode/magma come from a second noise layer.

---

## Open issues

**1. Hull swings wildly when climbing.** Two separate causes, fixes drafted but not
yet applied:

- The `velocity.length() > 8.0` guard toggles. Boring head-on, `move_and_slide()`
  cancels velocity, the guard fails, the hull starts levelling, a cell breaks, the
  guard passes again. Slow digging → more time blocked → worse. Fix: follow
  `heading().angle()` instead of `velocity.angle()` while boring; the drill direction
  is stable even when grinding stationary.
- `_level_target()` picks 0 or PI from the *current* rotation, so pointing straight up
  sits exactly on the decision boundary and jitter flips it 180°. Fix: a sticky
  `_facing` int updated only on clear horizontal intent.

**2. `bore_radius` is very generous.** 14.0 → a 28px tunnel for a 24×10 hull. Part of
why nothing snags, but it's why tunnels read as oversized. For a near-exact fit it
wants to be ~6–7. Note the ray reaches 35px ahead of hull centre (position 7 +
target 28), so the carve disc is centred well forward of the ship.

**3. Sprite is larger than collision.** Sprite renders ~31×16, capsule is 24×10.
Visual overhangs the hull.

**4. Drive is world-X** while the hull may be rotated. Matters less now that the hull
levels when idle.

---

## Decisions made

- **CharacterBody2D, not RigidBody2D.** Design doc §102 suggested rigid. Rejected
  twice, for different reasons: direct player control is easier to tune kinematically,
  and "hull stays horizontal when no forces act" is awkward to get from a body with
  angular momentum — it'd need torque controllers fighting it back to level.
- **Terrain regrows (3s).** Reinforces §3's "push down, don't flee up" as a mechanic
  rather than a hope. Also bounds state: an infinite world with permanent destruction
  would mean unbounded data to persist.
- **Act 1 backhaul resolved.** Extraction points sit generally *forward* of the start
  rather than requiring backtracking; early rock is soft so re-drilling costs seconds.
  No permanent tunnels needed. → Generator must enforce forward placement as a rule.
- **Climbing is expensive, not forbidden** — via `_gravity_factor()`, not geometry.
- **Gravity should apply only in pre-set open space.** Agreed, not yet implemented.
- **4px tiles.** ~4px is the practical floor for TileMap: below that the grid overhead
  simulates something that isn't a grid, and a 4×4 material patch is already just a
  flat colour with one speckle.

---

## Open decision: terrain architecture

Three options on the table, to be settled next session.

1. **Stay on TileMap at 4px.** Keeps everything already built. Ceiling: walls are
   always somewhat stepped, carve shapes are always grid-quantized.
2. **Hybrid** — TileMapLayer for material data and rendering, physics disabled, custom
   marching-squares collision generated from the cell grid. Smooth walls and exact hull
   fit while keeping the TileSet editor and custom-data UI. Roughly a fifth of the work
   of a rewrite.
3. **Full pixel terrain** — `Image` + marching squares + chunk streaming. The only
   option that gives genuinely smooth walls and arbitrary carve shapes. Costs: the
   TileSet editor entirely, self-implemented collision generation and rendering,
   mandatory day-one chunking, slow per-pixel GDScript access, and much harder
   debugging.

**Suggested order:** fix the two rotation bugs and make gravity open-space-only first,
since those are what the "swinging / doesn't fit" complaint actually is. Re-evaluate
after. Go to (3) only when a carve shape is wanted that the grid can't express — that's
the one problem with no cheaper answer.

---

## Next up

1. Apply the two hull-rotation fixes.
2. Gravity only in pre-set open space.
3. Settle the terrain architecture question.
4. Tune `bore_radius` toward exact hull fit; reconcile sprite scale with collision.
5. Hardness-scaled collapse delay — loose topsoil caves in fast, granite holds a shaft
   open. `regrow_delay × (1.0 + hardness)`, no new data layer needed. **Caveat:** breaks
   the regrowth queue's time-ordering assumption, since `_process` stops at the first
   cell that isn't ready. One slow granite cell at the front would hold back all the
   topsoil behind it. Needs the loop restructured to scan a window instead of breaking.
6. Fuel, via the existing `tile_drilled` signal.
7. Heat, wiring up the `_heat_factor()` stub.
8. Autotiling / Terrain Sets, if staying on TileMap.
9. Chunk streaming, whenever generation startup cost becomes noticeable.

---

## Standing checkpoint question

Does grinding through granite read as satisfying weight, or as waiting? Design doc §102
says validate that the core drilling feel is fun before building anything else. Still
worth answering honestly before fuel and heat go on top.
