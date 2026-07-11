local CLIENT_PARENT = game:GetService("StarterPlayer").StarterPlayerScripts
local SERVER_PARENT = game:GetService("ReplicatedStorage")

script.Parent.BoidsClient.Parent = CLIENT_PARENT
script.Parent.BoidsReplicated.Parent = SERVER_PARENT
