--!strict
-- Generic client runtime composition. Scenario delivery and experiment policy
-- are installed by the existing process/test entry points before Start.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)
local RuntimeConfig = require(BoidsReplicated.RuntimeConfig)
local ClientPresentationConfig = require(BoidsReplicated.ClientPresentationConfig)
local SimulationReplication = require(BoidsReplicated.SimulationReplication)
local Boids = require(BoidsReplicated.Boids)
local ClientRendererBridge = require(BoidsReplicated.ClientRendererBridge)
local Renderer = require(script.Parent.BoidsRenderer)
local CameraReporter = require(script.CameraReporter)
local ClientSimulation = {}

local started = false

function ClientSimulation.Start(options: RuntimeConfig.Options?): RuntimeTypes.Api
	if started then return Boids end
	local presentationMode = ClientPresentationConfig.Resolve()
	started = true
	CameraReporter.Start()
	Renderer.Start(CameraReporter.Update)
	ClientRendererBridge.SetRenderer(Renderer)
	local runtimeOptions: RuntimeConfig.Options = {
		actorCount = if options then options.actorCount else nil,
		targetActorJobMs = if options then options.targetActorJobMs else nil,
		simulationEnabled = presentationMode == "simulation",
	}
	Boids.Start(runtimeOptions)
	if ClientSimulation.GetSimulationMode() ~= "client" then
		SimulationReplication.StartClient(Boids, presentationMode == "renderer")
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
