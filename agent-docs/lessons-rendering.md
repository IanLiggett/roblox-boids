# Rendering Lessons

[RENDERING] Snapshot migration must preserve render cadence

Tags: rendering, simulation mode, snapshot intake, cell migration, deadline, LOD, CPU

Rejected

Setting an existing destination cell's nextDueTime to the current time whenever any snapshot row migrates into it.

Reason

Client simulation publishes frequent local snapshots. Ordinary cell crossings then trigger repeated full-cell render passes independently of configured render LOD. A 20k moving-membership probe produced 2.18 million render updates in six seconds, versus 341k after preserving deadlines.

Current guardrail

Preserve existing deadlines for ordinary visible migration; only opacity changes require urgent membership work. Inherit active motion clocks for visible migrants entering new cells. Verify that migrating into a settled cell leaves an existing member's renderedAt unchanged until its scheduled pass. Profile live moving snapshot intake; static visibility tests do not exercise this failure.

---

[RENDERING] Hidden intervals must not become catch-up movement

Tags: rendering, visibility, culling, distance fade, prediction, snapshot age, resume

Rejected

Skipping hidden members while continuing to use wall-clock render delta and snapshot age unchanged on reentry.

Reason

Cached poses stayed frozen, but the first resumed pass integrated the hidden interval and extrapolated stale velocity across it. Moving boids appeared scattered as they faded in, then rapidly corrected. Zero-velocity visibility tests missed this.

Current guardrail

Exclude suspended time from both integration and prediction age, repairing clocks lazily for scheduled members. Preserve source timestamps and normal active prediction; reset prediction offsets on a fresh snapshot. Carry row suspension across cell migration and dense swaps. Verify nonzero velocity with a long hidden interval, frozen pose while hidden, and bounded movement after distance/camera reentry.

---

[RENDERING] Hit highlights

Tags: rendering, hit, Highlight, flash, color, dense combat

Rejected

Creating a Highlight instance for every hit.

Reason

Highlights are limited and can become expensive during dense combat.

Current guardrail

Flash the rendered part's Color for FLASH_DURATION. Track the original color across overlapping flashes. Do not reintroduce Highlight hit indicators.

---

[RENDERING] Snapshot placement and orientation snapping

Tags: rendering, snapshot, reconciliation, interpolation, smoothing, facing, velocity, orientation, snapping

Rejected

Directly placing rendered boids at snapshots, snapping facing from snapshot velocity, sideways movement, or backward movement while smoothing.

Current guardrail

Turn toward the smoothed target first, then move only along current facing. Temporary positional error is preferable to a visual snap.

---

[RENDERING] SnapshotSource transport

Tags: rendering, SnapshotSource, BindableEvent, transport, deep copy, ClientRendererBridge, BoidsRenderer

Rejected

BindableEvent SnapshotSource transport and deep-copying local snapshot/table payloads between simulation and renderer.

Current guardrail

ClientRendererBridge calls BoidsRenderer methods directly for local buffers/tables.

---

[STARTUP] Competing scenario and renderer entry points

Tags: startup, scenario, renderer, LOD, preset, initializer, benchmark, archived baseline

Rejected

Fallback scenario selection, test initializers selecting LOD presets, and enabling archived benchmark loaders alongside the active package.

Current guardrail

Registry alone selects/applies the LOD preset. The active package has one server and one client test entry point. Archived baselines remain inactive and must not run beside production renderers.

---
[RENDERING] Renderer scheduling granularity

Tags: rendering, boids, LODConfig, scheduling, cells, Motor6D, binary heap, dense iteration

Rejected

A priority heap for every boid, or retaining a dense every-frame renderer pass while only conditionally updating each boid.

Reason

Per-boid heap maintenance adds churn proportional to boid movement and does not remove the dense iteration cost. The renderer already receives snapshot cell origins, which are a stable batch ownership boundary.

Current guardrail

Assign boids to dense renderer-owned cell lists from snapshot rows. Renderer cells may subdivide simulation cells, but their membership changes only when an accepted snapshot position crosses a renderer-cell boundary. Schedule only due cells from LODConfig render bands and maintain membership with swap removal when renderer indices change. Use a heap only if a later cell-level scheduler needs one and profiling demonstrates an advantage.

---

[RENDERING] Mouse coordinates and camera projection must share an inset convention

Tags: observer, picking, GetMouseLocation, ViewportPointToRay, ScreenPointToRay, GuiInset, top bar

Rejected

Passing raw UserInputService.GetMouseLocation coordinates to ScreenPointToRay.

Reason

The live section 6 mouse test used a 58-pixel top-bar inset. Applying screen conversion to raw viewport coordinates shifted the picking ray below the visible target even though the rendered-pose intersection API itself passed.

Current guardrail

Pair raw mouse coordinates with ViewportPointToRay (or convert the inset exactly once before a screen-space API). Verify the production click handler against a projected world point, not only the ray/intersection helper, and exclude GUI/text/menu input.


For the observer's inset-aware ScreenGui, GUI hit testing uses mouse minus GuiInset with PlayerGui:GetGuiObjectsAtPosition. Keep raw coordinates for ViewportPointToRay. Verify both a compact-header position and exposed viewport space; a large expanded panel can hide an inset mistake that lets compact-bar clicks select the world.

---

[INPUT] Verify developer shortcut delivery

Tags: observer, dock, shortcuts, F7, F8, InputBegan, gameProcessedEvent, CoreGui

Rejected

Choosing an unused source-level key and assuming it arrives unprocessed.

Reason

The dock's proposed F7 shortcut arrived with gameProcessedEvent=true in the live Studio client, although no project binding used F7. F8 arrived unprocessed and passed physical collapse/restore checks.

Current guardrail

Check live delivery when choosing developer shortcuts. Respect processed input, text focus, and Roblox menus; choose an available key rather than bypassing these exclusions.
