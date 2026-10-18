--!strict
--[[
ScenarioTestInitializer
=======================
Single server-side test entry point. It selects the active persistent scenario,
spawns its server-owned groups, publishes client-owned definitions, and starts
server telemetry. Game-owned systems remain responsible for gameplay only.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local packageRoot = script.Parent.Parent.Parent :: typeof(game:GetService("ServerScriptService").BoidsSystem)
local Scenarios = require(packageRoot.Server.Scenarios.Registry)
local Observation = require(packageRoot.Server.Scenarios.Observation)
local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated")
local Boids = require(BoidsReplicated:WaitForChild("Boids"))
local Testing = BoidsReplicated:WaitForChild("Testing")
local PerformanceTelemetry = require(Testing:WaitForChild("PerformanceTelemetry"))
local BenchmarkHarness = require(Testing:WaitForChild("BenchmarkHarness"))
local Delivery = require(BoidsReplicated.Scenarios.Delivery)
local QueryIndexConfig = require(BoidsReplicated.QueryIndexConfig)
local BoidQueries = require(packageRoot.Server.BoidQueryIndexServer)
local HostHooks = require(BoidsReplicated.Scenarios.HostHooks)
local ScenarioTestInitializer = {}

local started = false
local isInitialized = false
local hostHooks: HostHooks.Server? = nil

local function serverSimulationEnabled(): boolean
	return BoidsReplicated:GetAttribute("BoidSimulationMode") ~= "client"
end

local function startSelectedTest(): ()
	if started then
		return
	end

	local activeScenario = BoidsReplicated:GetAttribute("ActiveBoidsScenario")
	if type(activeScenario) ~= "string" or activeScenario == "" then
		return
	end

	local player = Players:GetPlayers()[1]
	if not player then
		return
	end

	started = true
	Scenarios.ConfigureRuntime(activeScenario, Boids)
	local runtimeConfig = BenchmarkHarness.GetRuntimeConfiguration(activeScenario)
	Delivery.StartServer()
	Boids.Start(runtimeConfig)
	QueryIndexConfig.Lock()
	BoidQueries.Start(Boids)
	local _, _, scenario, context = Scenarios.StartServerScenario(
		activeScenario,
		Boids,
		player,
		serverSimulationEnabled()
	)
	Observation.RegisterScenario(Boids, context, hostHooks)
	if serverSimulationEnabled() then
		local benchmark = BenchmarkHarness.GetRunOptions(activeScenario)
		PerformanceTelemetry.Start(
			activeScenario,
			Boids,
			if benchmark then benchmark.warmupSeconds else scenario.warmupSeconds,
			if benchmark then benchmark.sampleSeconds else scenario.sampleSeconds,
			nil,
			if benchmark then benchmark.metadata else nil
		)
	end
end

function ScenarioTestInitializer.Start(hooks: HostHooks.Server?): ()
	if isInitialized then return end
	isInitialized = true
	hostHooks = hooks
	Players.PlayerAdded:Connect(startSelectedTest)
	BoidsReplicated:GetAttributeChangedSignal("ActiveBoidsScenario"):Connect(startSelectedTest)
	task.spawn(function(): ()
		while not started do
			startSelectedTest()
			if not started then
				task.wait(0.25)
			end
		end
	end)
end

return ScenarioTestInitializer
