--[[ PackageBootstrap
Description:
	Places package folders into their expected Roblox runtime services.
	BoidsClient is moved to StarterPlayerScripts and BoidsReplicated is moved
	to ReplicatedStorage.

Public API:
	None. This is an executable server bootstrap script.
]]

local CLIENT_PARENT = game:GetService("StarterPlayer").StarterPlayerScripts
local SERVER_PARENT = game:GetService("ReplicatedStorage")

script.Parent.BoidsClient.Parent = CLIENT_PARENT
script.Parent.BoidsReplicated.Parent = SERVER_PARENT
