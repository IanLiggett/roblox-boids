--!strict
--[[
ClientSimulationController
==========================
Bootstraps the client simulation runtime. Scenario selection, client-only
spawns, and benchmark collection are intentionally delegated to Testing.
]]

-- Load the selected renderer before the simulation can publish local state.
-- This must match ClientRendererBridge so only one renderer exists per client.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)

-- ClientSimulation.Start composes and binds the renderer before simulation.

-- The runtime owns only client simulation lifecycle. Scenario selection,
-- spawning, and telemetry live in Testing.ClientScenarioTestInitializer.
local ClientSimulation = require(script.Parent.ClientSimulation)
local Delivery = require(BoidsReplicated.Scenarios.Delivery)
local BenchmarkHarness = require(BoidsReplicated.Testing.BenchmarkHarness)
Delivery.StartClient()
ClientSimulation.Start(BenchmarkHarness.GetStartupConfiguration(), BenchmarkHarness.GetStartupRendererConfiguration())
