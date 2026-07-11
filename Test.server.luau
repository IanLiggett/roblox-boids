--!native

local Boids = require(game:GetService("ServerScriptService").BoidsSystem.Boids)
local Benchmarkers = require(game:GetService("ReplicatedStorage").Libraries.Benchmarker)
local SharedTypes = require(game:GetService("ReplicatedStorage").BoidsReplicated.SharedTypes)
type Group = Boids.Group

game:GetService("Players").PlayerAdded:Wait()

local groups:{Group} = {}

local rng = Random.new()

local function BulkTest(boidCount)
	local BoidGroup = Boids.newGroup()
	table.insert(groups, BoidGroup)
	
	for i = 1, boidCount do
		local isPredator: boolean = rng:NextNumber() > 0.99
		
		local Theta = (i / boidCount) * math.pi*2
		
		local Boid = Boids.newBoid(
			BoidGroup,
			Vector3.new(math.cos(Theta) * 100, math.random(-30, 30), math.sin(Theta) * 100),
			Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit,
			isPredator and 100 or 70,
			3,
			32,
			isPredator and 5 or 20,
			isPredator and 1 or 1,
			isPredator and 10 or 0,
			isPredator and 3 or 0,
			isPredator and 3 or 10,
			isPredator and 10 or 10,
			isPredator and 1 or 10,
			isPredator and SharedTypes.BoidModels.Predator or SharedTypes.BoidModels.Boid
		)
		
		if i % 100 == 0 then
			task.wait()
		end
	end
	
	local lastUpdate = 0
	game:GetService("RunService").Heartbeat:Connect(function()
		if os.clock() - lastUpdate > 15 then
			Boids.setTarget(BoidGroup, {["Position"] = Vector3.new(math.random(-200, 200), math.random(-200, 200), math.random(-200, 200))}, true)
			lastUpdate = os.clock()
		end
	end)
end

--BulkTest(2000)

local function multiGroupStressTest()
	local groups = 5
	local boidsPerGroup = 2000
	for i = 1, groups do
		BulkTest(boidsPerGroup)
	end
end

multiGroupStressTest()

game:BindToClose(function()
	for _, group in groups do
		print(`Group {group.id}: JOBS`)
		Benchmarkers.printStats(group.benchmarker)
	end
end)
