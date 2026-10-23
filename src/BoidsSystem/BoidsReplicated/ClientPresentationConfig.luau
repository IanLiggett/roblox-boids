--!strict
-- Trusted startup setting shared by the server and client process entrypoints.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)

local ClientPresentationConfig = {}

export type Mode = "simulation" | "renderer"

function ClientPresentationConfig.ResolveValues(mode: unknown?, simulationMode: unknown?): Mode
	if mode == nil then mode = "simulation" end
	assert(mode == "simulation" or mode == "renderer", "BoidClientPresentationMode must be 'simulation' or 'renderer'")
	if mode == "renderer" then
		assert(simulationMode ~= "client", "BoidClientPresentationMode='renderer' requires server simulation; BoidSimulationMode cannot be 'client'")
	end
	return mode :: Mode
end

function ClientPresentationConfig.Resolve(): Mode
	return ClientPresentationConfig.ResolveValues(
		BoidsReplicated:GetAttribute("BoidClientPresentationMode"),
		BoidsReplicated:GetAttribute("BoidSimulationMode")
	)
end

return ClientPresentationConfig
