# Boids API

The included Scenarios are test and development harnesses. A game can create its own groups and boids through the server-side coordinator without using the Scenario registry.

After inserting the release model under `ServerScriptService` and allowing `PackageBootstrap` to run, the coordinator is available at `ReplicatedStorage.BoidsReplicated.Boids`. Start it once on the server before creating groups:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated")
local Boids = require(BoidsReplicated.Boids)
local SharedTypes = require(BoidsReplicated.SharedTypes)

Boids.Start()
local group = Boids.NewGroup(SharedTypes.BoidModels.Boid)
local boidId = Boids.NewBoid(
	group,
	Vector3.new(0, 20, 0), -- position
	Vector3.new(0, 0, -1), -- velocity
	20, 3, -- max and min speed
	60, 35, 200, 0, 3, -- sight, avoidance, separation, repulsion, repulsion strength
	100, 10, 50 -- alignment, cohesion, target bias
)
```

Use `SetTarget` or `SetPath` to direct a group. Use `AddGravityWell` and `RemoveGravityWell` for shared influence fields. Call `DeleteBoid` or `DestroyGroup` when gameplay removes them. The coordinator owns simulation and replication; host code owns gameplay rules and effects.

Boids share 65,536 IDs (`0–65535`) per process. Server creation takes the lowest free ID; client-local creation takes the highest. `NewBoid` returns `nil` when no unreserved slot is available. A server replica arriving at an occupied local ID deletes that local boid through the normal lifecycle, even if other slots are free. Observe removals through `SubscribeDeleted`; surviving boid IDs never change, and evicted locals are not automatically respawned. `IsServerBoid(id)` returns whether the ID currently belongs to a live server boid/replica and is not pending deletion. Use it before reporting client hits; the numeric ID alone does not establish ownership.

`Boids.NewBoid` accepts a `BoidModel` ID; the built-in IDs are in `SharedTypes.BoidModels`. See the [coordinator API declarations](../src/BoidsSystem/BoidsReplicated/Boids/init.luau) and [shared types](../src/BoidsSystem/BoidsReplicated/SharedTypes.luau) for signatures, optional arguments, and result types. Query boid geometry through the package's server query API, [BoidQueryIndexServer](../src/BoidsSystem/Server/BoidQueryIndexServer.luau), rather than maintaining a second index in the host game.

DO NOT enable CanQuery on boids if you can avoid it, when dealing with particularly large swarms. They will slow down raycasts by orders of magnitude. I encourage you to test it yourself if you feel it will work find for your situation.

## Network accuracy

`LODConfig` network presets select position and velocity error tolerances by observer distance. Updates are sent when either tolerance is exceeded against that recipient's last-sent quantized trajectory; quiet predictable boids have no periodic refresh. Each mode profile also sets `minSendIntervalSeconds` (both modes default to zero in every quality preset, disabling cooldown). After a successful send, further corrections for that boid/recipient wait for this interval while retaining the newest qualifying state. Returning within tolerance cancels the pending correction. First observations bypass cooldown; eligible rows still use normal packet batching. Error can exceed tolerance during cooldown. Renderer LOW starts at 8 to 32 studs and 4 to 16 studs/second, MEDIUM at 2 to 8 and 1 to 4, HIGH at 1 to 4 and 1 to 2. Each preset has separate `network.simulation` and `network.renderer` profiles; simulation position and velocity tolerances are three times renderer values. `LODConfig.GetNetworkConfig()` selects the profile using the startup presentation mode and active quality preset. Both presentation modes use the same error-trigger policy. Server simulation cadence and transport latency still limit correction timing.

`BenchmarkNear30k` supplies a dense 30,000-boid validation population. Validation can force nearest LODs in the live test runtime to exercise the close-view workload even after the flock spreads; see the implementation and measurement record in [error network LOD plan](error-network-lod-plan.md).
