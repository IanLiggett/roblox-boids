# BoidsSystem

A reusable Roblox boid simulation package with shared server/client simulation, rendering/reconciliation, package-owned queries, replication, and developer Scenarios/observation. Read the short [architecture](docs/architecture.md) for boundaries; [AGENTS](AGENTS.md) is for development work, not onboarding.

## Use without Rojo

When published, the `.rbxm` attached to a [versioned release](https://github.com/IanLiggett/roblox-boids/releases) is the ready-to-insert package model. In Studio, insert it from file under **ServerScriptService**. Its bootstrap places the client and replicated folders in their runtime services. Then start the server coordinator from a server Script; see the [API overview](docs/api.md) for the minimal startup and how to create your own boids. You do not need the Rojo plugin or CLI to install a release model.

The JSON sourcemap is for editor tooling; it is not an installable Roblox package. A maintainer builds the release model from `install.project.json` with Rojo 7.7.1:

```powershell
.\build-package.cmd
```

The script uses the repo-pinned Rojo executable when this package is inside the game workspace, or `rojo` from `PATH` in a standalone checkout.

## Try a Scenario

Use Rojo **7.7.1**. From this repository, create a build directory, then:

```powershell
New-Item -ItemType Directory -Force build
rojo build default.project.json --output build/BoidsSystemScenarios.rbxlx
rojo serve default.project.json
```

Open the built place in Studio and connect the matching plugin to localhost **34873**. Start Play. This character-free demonstration needs no game's camera or input scripts. **F6** enters/exits observation; **F8** collapses/expands the dock. Inspector, Camera, and Session / LOD expose the existing tools. Developer authorization and benchmark exclusions still apply.

Select a Scenario using `ActiveBoidsScenario` in [shared metadata](src/BoidsSystem/BoidsReplicated/init.meta.json); the current example is PolarSphereObstacle. `BoidSimulationMode` selects server, client, or both. `BoidClientPresentationMode` selects `simulation` (default, client prediction with server corrections) or `renderer` (server packets feed the renderer directly; requires server simulation). Configure before a fresh Play session, not as hot reload.

For examples, read the [Scenario catalog](src/BoidsSystem/Server/Scenarios/Registry/Catalog/init.luau) and [fixtures](src/BoidsSystem/Server/Scenarios/Registry/Catalog/Fixtures.luau). They own the paths, groups, fields, and generated world resources; this README does not duplicate their settings.

The included Scenarios are mainly test and development harnesses. Games can create and manage their own boid groups directly through the [Boids API](docs/api.md); they do not need to use the Scenario registry or scenario startup modules.

## Use from source with Rojo

Map `src/BoidsSystem` to ServerScriptService.BoidsSystem and the two vendored libraries to ReplicatedStorage.ExternalLibraries, retaining metadata/reference attributes. The project file shows the mappings. PackageBootstrap moves BoidsReplicated and BoidsClient into their runtime services; do not also map duplicate runtime copies.

Host launchers call server `Server.Testing.ScenarioTestInitializer.Start(serverHooks?)` and client `BoidsClient.Testing.ClientScenarioTestInitializer.Start(clientHooks?)` once. Importing those modules does not launch scenarios. Generic client startup remains idempotent. RuntimeConfig resolves generic defaults; scenario/benchmark selection belongs to orchestration, not WorkerCore.

[HostHooks](src/BoidsSystem/BoidsReplicated/Scenarios/HostHooks.luau) defines server `SuspendInput(player)` and client `Suspend()` callbacks, each returning cleanup. Supply them before registration. The observer releases resources on close/Stop; callbacks should return idempotent cleanup without changing simulation authority. Omit hooks only when no host controls need suspension, as in the character-free demo. The package never discovers a game's control modules by name.

## Tests and status

The standalone project maps `ServerStorage.UnitTest`. Before Play, generate its production-code fixtures using `UnitTest.PrepareWorkerFixture` and `UnitTest.PrepareSchedulerFixture` from a privileged Studio Edit tool. During Play, run `require(game.ServerStorage.UnitTest.RunUnitTest)()` in the server context. Never start another coordinator from an inspection VM to read live state. A Rojo build is not a complete type check.

For the full suite, pass `nil, 12` to the runner: the actual five-second Actor deadline test exceeds the default five-second per-test timeout. With Lune 0.11.0, run `lune run tests/cli/VerifyDynamicIds.luau` from this package root for isolated allocation, production-coordinator, and client-intake checks without Studio. The script also accepts the host root as its working directory.

The typed WorkerCore and scheduler fixtures are also checked into source so Studio can analyze their contracts before Play. Run `lune run tests/cli/VerifyFixtureSources.luau` to check that they match production source and the Studio generators. `--emit` prints replacement sources as JSON for a reviewed update; it does not write files. The scheduler fixture extracts only the production dispatch slice, with a typed injected environment. Worker and execution tests still require separate clones to preserve module-local isolation.

Benchmarker and BinaryHeaps are pinned source copies under vendor, including original metadata. Redistribution rights and a package license need review before public publication; local extraction grants no new license.
