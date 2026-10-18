# BoidsSystem

A reusable Roblox boid simulation package with shared server/client simulation, rendering/reconciliation, package-owned queries, replication, and developer Scenarios/observation. Host games own combat and control policy. Read the short [architecture](docs/architecture.md) for boundaries; [AGENTS](AGENTS.md) is for development work, not onboarding.

## Try a Scenario

Use Rojo **7.7.1**. From this repository, create a build directory, then:

```powershell
New-Item -ItemType Directory -Force build
rojo build default.project.json --output build/BoidsSystemScenarios.rbxlx
rojo serve default.project.json
```

Open the built place in Studio and connect the matching plugin to localhost **34873**. Start Play. This character-free demonstration needs no game's camera or input scripts. **F6** enters/exits observation; **F8** collapses/expands the dock. Inspector, Camera, and Session / LOD expose the existing tools. Developer authorization and benchmark exclusions still apply.

Select a Scenario using `ActiveBoidsScenario` in [shared metadata](src/BoidsSystem/BoidsReplicated/init.meta.json); the current example is PolarSphereObstacle. `BoidSimulationMode` selects server, client, or both. Configure before a fresh Play session, not as hot reload.

For examples, read the [Scenario catalog](src/BoidsSystem/Server/Scenarios/Registry/Catalog/init.luau) and [fixtures](src/BoidsSystem/Server/Scenarios/Registry/Catalog/Fixtures.luau). They own the paths, groups, fields, and generated world resources; this README does not duplicate their settings.

## Use in a game

Map `src/BoidsSystem` to ServerScriptService.BoidsSystem and the two vendored libraries to ReplicatedStorage.ExternalLibraries, retaining metadata/reference attributes. The project file shows the mappings. PackageBootstrap moves BoidsReplicated and BoidsClient into their runtime services; do not also map duplicate runtime copies.

Host launchers call server `Server.Testing.ScenarioTestInitializer.Start(serverHooks?)` and client `BoidsClient.Testing.ClientScenarioTestInitializer.Start(clientHooks?)` once. Importing those modules does not launch scenarios. Generic client startup remains idempotent. RuntimeConfig resolves generic defaults; scenario/benchmark selection belongs to orchestration, not WorkerCore.

[HostHooks](src/BoidsSystem/BoidsReplicated/Scenarios/HostHooks.luau) defines server `SuspendInput(player)` and client `Suspend()` callbacks, each returning cleanup. Supply them before registration. The observer releases resources on close/Stop; callbacks should return idempotent cleanup without changing simulation authority. Omit hooks only when no host controls need suspension, as in the character-free demo. The package never discovers a game's control modules by name.

## Tests and status

The standalone project maps `ServerStorage.UnitTest`. Before Play, generate its WorkerCore fixture using `UnitTest.PrepareWorkerFixture` from a privileged Studio Edit tool. During Play, run `require(game.ServerStorage.UnitTest.RunUnitTest)()` in the server context. Never start another coordinator from an inspection VM to read live state. A Rojo build is not a complete type check.

Benchmarker and BinaryHeaps are pinned source copies under vendor, including original metadata. Redistribution rights and a package license need review before public publication; local extraction grants no new license.
