local module = {}

local PlayersService = game:GetService("Players")

local players: {[Player]: boolean} = {}

PlayersService.PlayerAdded:Connect(function(player)
	players[player] = true
end)

PlayersService.PlayerRemoving:Connect(function(player)
	players[player] = nil
end)

game:GetService("RunService").PostSimulation:Connect(function()
	
end)

return module
