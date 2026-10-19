--!strict
--[[
ClientScenarioTestInitializer
=============================
Test-only client orchestration. This is the single place that chooses the
client test behavior, spawns test-owned groups, and starts telemetry. The
simulation itself is exposed by ClientSimulation and stays test-agnostic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientSimulation = require(script.Parent.Parent.ClientSimulation)
local Observation = require(script.Parent.Parent.Scenarios.Observation)
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local ScenarioModules = BoidsReplicated:WaitForChild("Scenarios")
local ScenarioRuntime = require(ScenarioModules:WaitForChild("Runtime"))
local ScenarioTypes = require(ScenarioModules.Types)
local Delivery = require(ScenarioModules.Delivery)
local Testing = BoidsReplicated:WaitForChild("Testing")
local PerformanceTelemetry = require(Testing:WaitForChild("PerformanceTelemetry"))
local Divergence = require(Testing.PerformanceTelemetry.Divergence)
local SimulationReplication = require(BoidsReplicated.SimulationReplication)
local RendererBenchmark = require(script.Parent.RendererBenchmark)
local Renderer = require(script.Parent.Parent.BoidsRenderer)
local BenchmarkHarness = require(Testing:WaitForChild("BenchmarkHarness"))
local HostHooks = require(ScenarioModules.HostHooks)
local ClientScenarioTestInitializer = {}

local startedScenarios: {[string]: boolean} = {}
local isStarted = false
local hostHooks: HostHooks.Client? = nil
type GroupDefinition = ScenarioTypes.GroupDefinition
type ScenarioBenchmark = ScenarioTypes.Benchmark
type ScenarioContext = ScenarioTypes.ScenarioContext

local function benchmarkSeconds(benchmark: ScenarioBenchmark?): (number, number)
	local warmup = if type(benchmark) == "table" and type(benchmark.warmupSeconds) == "number"
		then benchmark.warmupSeconds
		else 8
	local sample = if type(benchmark) == "table" and type(benchmark.sampleSeconds) == "number"
		then benchmark.sampleSeconds
		else 20
	return warmup, sample
end

local function startScenarioTest(scenarioName: string, clientGroups: {GroupDefinition}, benchmark: ScenarioBenchmark?, context: ScenarioContext): ()
	if startedScenarios[scenarioName] then
		return
	end
	startedScenarios[scenarioName] = true

	local boids = ClientSimulation.GetBoids()
	local spawnedGroups = ScenarioRuntime.SpawnGroups(boids, clientGroups)
	Observation.RegisterScenario(boids, context, clientGroups, spawnedGroups, hostHooks)

	local warmupSeconds, sampleSeconds = benchmarkSeconds(benchmark)
	local benchmarkOptions = BenchmarkHarness.GetRunOptions(scenarioName)
	if benchmarkOptions then
		warmupSeconds = benchmarkOptions.warmupSeconds
		sampleSeconds = benchmarkOptions.sampleSeconds
		local camera = workspace.CurrentCamera
		if camera then
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = benchmarkOptions.cameraCFrame
		end
	end
	PerformanceTelemetry.Start(scenarioName, boids, warmupSeconds, sampleSeconds, function()
		return Divergence.Read(SimulationReplication.ForEachClientCorrection, boids.GetBoidState, workspace:GetServerTimeNow())
	end, if benchmarkOptions then benchmarkOptions.metadata else nil)
end

function ClientScenarioTestInitializer.Start(hooks: HostHooks.Client?): ()
	if isStarted then return end
	isStarted = true
	hostHooks = hooks
	RendererBenchmark.Start(Renderer)
	Delivery.StartClient()
	Delivery.SetClientHandler(startScenarioTest)
	ClientSimulation.Start(BenchmarkHarness.GetStartupConfiguration())
end

return ClientScenarioTestInitializer
