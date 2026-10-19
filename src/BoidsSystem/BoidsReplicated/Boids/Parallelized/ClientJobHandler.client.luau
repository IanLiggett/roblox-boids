--!strict
-- Shared client worker bootstrap. WorkerCore contains the complete algorithm.
if not script.Parent:IsA("Actor") then
	return
end

-- This script is cloned beneath an Actor; the package is outside its local hierarchy.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
require(BoidsReplicated.Boids.WorkerCore).Start(script.Parent :: Actor)
