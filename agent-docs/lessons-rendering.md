# Rendering Lessons

[RENDERING] Actor acknowledgement is not the render timestamp

Tags: rendering, Actor, cadence, LOD, epoch, acknowledgement, nextDue

Rejected

Adding the cell interval to acknowledgement receipt time.

Reason

Transport/synchronization delay then becomes an extra interval component. A near cell intended for 30 Hz can fall to every third display frame even when each job completes safely.

Current guardrail

Publish the next deadline only after successful settlement, but anchor it to the epoch's common render timestamp plus the interval. Never overlap epochs or treat a dispatch as completion.

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
