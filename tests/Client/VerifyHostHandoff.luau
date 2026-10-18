--!strict

-- Integration check: call from a normal client LocalScript after scenario startup,
-- with observation closed. A Studio tool VM has a separate module cache.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HostHooks = require(ReplicatedStorage:WaitForChild("BoidsReplicated").Scenarios.HostHooks)

type Result = { acquired: number, released: number, cameraRestored: boolean }

return function(): Result
	assert(RunService:IsClient(), "Run handoff verification in the client runtime")
	local player = Players.LocalPlayer
	local boidsClient = player:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient")
		:: typeof(game.StarterPlayer.StarterPlayerScripts.BoidsClient)
	local handoff = require(boidsClient.Scenarios.Observation.Handoff)
	local camera = workspace.CurrentCamera :: Camera
	local original = camera.CFrame
	local acquired, released = 0, 0
	local hooks: HostHooks.Client = {
		Suspend = function(): HostHooks.Cleanup
			acquired += 1
			return function(): () released += 1 end
		end,
	}
	handoff.Start(function(): () end, hooks)
	handoff.Start(function(): () end, hooks)
	handoff.Stop()
	handoff.Stop()
	assert(acquired == 1 and released == 1, "Duplicate start/stop acquired or released twice")
	handoff.Start(function(): () end, hooks)
	handoff.Stop()
	assert(acquired == 2 and released == 2, "Reentry did not acquire/release a fresh hook")
	assert(camera.CFrame == original, "Handoff did not restore the original camera")
	return { acquired = acquired, released = released, cameraRestored = true }
end
