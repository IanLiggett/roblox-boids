--!strict

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Startup = require(ServerScriptService.BoidsSystem.Server.Testing.ScenarioTestInitializer)

Players.CharacterAutoLoads = false
Startup.Start(nil)
