--!strict

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local boidsClient = player:WaitForChild("PlayerScripts"):WaitForChild("BoidsClient")
local Startup = require(boidsClient.Testing.ClientScenarioTestInitializer)

local camera = workspace.CurrentCamera
if camera then
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(Vector3.new(150, 120, 280), Vector3.new(150, 0, 0))
end
Startup.Start(nil)
