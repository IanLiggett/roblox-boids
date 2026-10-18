--!strict
-- Generic client runtime composition. Scenario delivery and experiment policy
-- are installed by the existing process/test entry points before Start.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated")
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)
local RuntimeConfig = require(BoidsReplicated.RuntimeConfig)
local SimulationReplication = require(BoidsReplicated.SimulationReplication)
local Boids = require(BoidsReplicated.Boids)
local ClientRendererBridge = require(BoidsReplicated.ClientRendererBridge)
local Renderer = require(script.Parent.BoidsRenderer)
local CameraReporter = require(script.CameraReporter)
local ClientSimulation = {}

local started = false

function ClientSimulation.Start(options: RuntimeConfig.Options?): RuntimeTypes.Api
	if started then return Boids end
	started = true
	CameraReporter.Start()
	Renderer.Start(CameraReporter.Update)
	ClientRendererBridge.SetRenderer(Renderer)
	Boids.Start(options)
	if ClientSimulation.GetSimulationMode() ~= "client" then
		SimulationReplication.StartClient(Boids)
	end
	return Boids
end
function ClientSimulation.GetBoids(): RuntimeTypes.Api
	return Boids
end
function ClientSimulation.GetSimulationMode(): string?
	local mode = BoidsReplicated:GetAttribute("BoidSimulationMode")
	return if type(mode) == "string" then mode else nil
end
return ClientSimulation
