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
