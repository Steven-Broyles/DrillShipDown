# Drill Ship — Design Doc (Working Title)

*Status: early concept / pre-production, engine work started in Godot. Written for handoff purposes.*

## 1. Core Concept

The player pilots a drill ship descending through an almost infinitely large, procedurally generated underground. The dig begins in terrain resembling Earth's crust and scales with depth into harder, older rock, higher pressure, and rising temperature. The player manages **fuel**, **crew**, and **upgrades** while pushing the ship further and deeper.

Certain rock types are **un-boreable** and serve as hard progress gates between depth tiers.

## 2. Setting & Premise

The game is set on a **remote planet** where a **corporate entity** sends drilling expeditions down to extract valuable minerals and investigate the power source behind the underground's geodes. This backstory explains:
- Why prior expeditions descended in the first place.
- Why some of them never returned — they settled underground rather than coming back.
- Why the company doesn't know: it assumes all past expeditions perished, unaware they're alive and have built lives below.

This single premise underpins the stakes, the settlements' wariness of newcomers, and the opening hook (see Act Structure below).

## 3. Narrative Pillars

- **Driving narrative:** pursuit of the unknown depth, entangled with pursuit of the power held in the underground's geodes.
- **Ancient underground cities:** settlements dug up and inhabited over time by people who originated on the surface (descendants/remnants of prior expeditions) but have lived underground for generations — foreign to the drillship crew. Settlements are mostly **disconnected** from one another, each holding scattered stories and confessions from previous descent expeditions. Their guardedness toward the player is colored by the company's history — the last "company people" who came through are part of why some of them are hiding.
- **Escalating dread arc:** the deeper the player goes, the more cities appear abandoned, with recurring references to a foul entity that forcibly cleared inhabitants out.
- **Climax:** an entire underground kingdom from a distant past — unrecorded by any previous expedition — discovered at maximum depth.
- **Geodes:**
  - *Minor geodes* — small power boosts; narratively signal the kind of power others have coveted and sought.
  - *Sacred/legendary geodes* — a small handful, each granting a necessary direct upgrade (e.g., Heat Resistance, Sharper Drill Bits). These carry real narrative weight to the underground peoples — possibly the object of a religion built around their creation/destruction. Destroying one for power may carry a social/story cost with the settlements (trust, standing, or reputation).
- **The calamity/entity:** stays primarily in lore and flavor — environmental storytelling (abandoned cities, warnings, wreckage) rather than an active mechanical threat that chases the player. This is a deliberate choice: the game wants the player pushing *down*, not fleeing *up*.

## 4. Stakes & Motivation

Three combined drivers answer "why keep going deeper?":
1. **Institutional/company stakes** — pressure from the corporate employer (debt, contract, sealed retreat, etc. — not yet finalized) explaining why turning back isn't simple.
2. **Geodes as a costly carrot** — the upgrades the player needs come at a narrative/trust cost with the settlements, making progression a moral trade-off, not just a resource grind.
3. **A concrete mystery hook** — see Opening Hook below.

No named/personal crew-based stakes are planned (see Crew, below) — human-connection narrative threads are intentionally left open/undecided rather than baked in, to avoid diluting the "world tells the story" approach.

## 5. Opening Hook

The player's starting motivation/artifact is a **geode shard that reached the surface** — evidence that something valuable and only half-understood exists below. This single object fuses the mystery hook with the geode moral-cost mechanic: the very type of object the player will spend the game deciding whether to destroy for power is also the reason the expedition set out in the first place.

## 6. Act Structure (early draft)

**Act 1 — The Company Job (tutorial-as-false-lead):**
- The game opens with simple, sanctioned gameplay: gathering materials for the company and dropping them off at underground resource elevators. This doubles as the tutorial for drill movement and basic mechanics, while also functioning as a deliberate false lead on how the whole game will play.
- Threat in this act: conventional and human — the company enforces a communications-relay range limit. Going past it is a conscious, irreversible rule-break (a literal point of no return) that triggers **"Reclaimer"** enemies sent by the company to retrieve/stop the player.
- Reclaimers are an **early-game-only** threat with a hard depth/time cutoff. Beyond that point they stop pursuing — ideally in a visible, earned moment (signal loss, retreat, a final line of dialogue) that marks the tonal shift, not just a difficulty gate.

**Transition:**
- The moment reclaimers give up should coincide with an environmental/tonal shift — terrain change, temperature spike, first hint of the entity/calamity — fusing the mechanical cutoff and the narrative turn into a single beat: "you are now past where the rules — and the company's reach — apply."

**Act 2/3 — The Real Descent:**
- Once past the cutoff, the primary narrative kicks in earnest: settlements, geode lore, the escalating dread arc, and eventually the buried kingdom at the climax.
- The company/reclaimer thread recedes into backstory/possible late-game callback rather than remaining an active antagonist — keeping the entity/calamity as the singular "real" threat and avoiding a two-villain focus problem.

## 7. Gameplay Systems

### Difficulty drivers
- **Primary:** un-boreable rock gates progress by depth tier.
- **Secondary/alternative:** heat and fuel management.
- **Morale:** driven by hunger, progress/money, and inter-personal story beats or decision points (not just numeric resource depletion).

### Crew
- **Decision made:** crew are interchangeable/resource-like, not permanent named characters with backstories. This prioritizes mechanical fun and manageable scope over character-driven narrative.
- Crew manage different parts of the ship; additional labor can be recruited from settlements.
- Narrative weight is deliberately placed in the *world* (the descent, the cities, the geodes, the entity, the company) rather than in individual crew identities.

### Gameplay format — two distinct modes
1. **Drilling / sandbox exploration (2D):**
   - Procedurally generated 2D field of sand, rock, and magma.
   - Free, physics-based linear motion (not grid-locked/90-degree boring, not full 3D) — ship moves and drills with full freedom of motion through deformable terrain.
   - Intended to feel more expansive and less blocky than reference points like *Motherload* or *SteamWorld Dig*.
2. **Settlements / cities / cutscenes (2.5D or 3D — undecided):**
   - Reserved for city stops, NPC interactions, and cutscenes.
   - Thematic intent: leaving the cramped, mobile drill ship to interact with humans face-to-face should make the player feel more human in those moments — a deliberate contrast in camera/presentation language from the drilling layer.
   - Settlements offer respite: repair, rest, lore about the geodes, recruitable labor.

## 8. Open Design Questions (not yet resolved)

- Exact split of 2.5D vs. full 3D for settlements/cutscenes.
- How morale's story-beat triggers should work: crew-state-driven (e.g., prolonged low hunger fires an event) vs. world-state-driven (e.g., arriving at an abandoned city always fires a beat), or both.
- Full mechanical shape of the geode-religion concept and its consequences for destroying sacred geodes.
- How much micro-narrative texture (barks, service-duration callbacks) interchangeable crew should carry, if any.
- Specifics of the institutional/company stakes (what exactly prevents simply turning back).
- Whether/how the company thread resurfaces later (does the player report back? does the company's ignorance become a late-game complication?).
- Whether any human/personal-connection narrative thread gets added later — currently intentionally left open, not yet conceived.

## 9. Technical Direction

- **Engine: Godot** (currently 4.7, or whatever the current stable release is at time of reading — always use current stable rather than pinning to an old version).
  - Free (MIT license), no royalties or runtime fees at any revenue level — low financial risk for solo development.
  - Dedicated 2D rendering pipeline (separate from 3D), well-suited to the deformable free-motion drilling layer.
  - 3D pipeline has matured significantly — capable of handling the settlement/cutscene layer in the same engine, avoiding a two-engine pipeline.
  - GDScript is Python-like and beginner-friendly; C# also supported natively.
  - Trade-off: Unity has a larger hiring/asset-store ecosystem, but that matters more for an industry career path than for shipping this specific project solo.
- **Current status:** designer has completed setup and is partway through Godot's official "Your First 2D Game" tutorial, learning alongside a friend.

### Suggested first steps
1. Complete Godot's official 2D tutorial to get comfortable with scenes/nodes/GDScript.
2. Build a minimal vertical slice: ship with free 2D movement + gravity/momentum (likely RigidBody2D rather than CharacterBody2D, given the desire for real physics-driven movement), drilling into deformable terrain (e.g., via TileMap or a pixel-based destructible terrain approach). Validate that the core drilling feel is fun before building anything else.
3. Layer in one resource (fuel) and one gate (un-boreable rock) before adding heat, morale, or crew systems.
4. Defer the 3D/2.5D settlement layer until the drilling loop is proven fun.

## 10. Reference Points

- *Motherload*, *SteamWorld Dig* — mining/digging feel references (this project intentionally diverges from their grid-locked, blocky movement toward freer, more expansive motion).
