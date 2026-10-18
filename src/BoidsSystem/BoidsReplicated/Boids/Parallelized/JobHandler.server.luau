--!strict
-- Shared server worker bootstrap. WorkerCore contains the complete algorithm.
if not script.Parent:IsA("Actor") then
	return
end

-- This script is cloned beneath an Actor; the package is outside its local hierarchy.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
require(ReplicatedStorage:WaitForChild("BoidsReplicated").Boids.WorkerCore).Start(script.Parent :: Actor)
