--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated")
local ScenarioTypes = require(BoidsReplicated.Scenarios.Types)
local SharedTypes = require(BoidsReplicated.SharedTypes)
local Types = require(script.Parent.Types)
local Fixtures = require(script.Fixtures)
local Catalog = {}
type GroupDefinition = ScenarioTypes.GroupDefinition
type GravityWellDefinition = ScenarioTypes.GravityWellDefinition
type PathNode = SharedTypes.PathNode
type Viewer = Types.Viewer
type LODPresetName = Types.LODPresetName
type Scenario = Types.Scenario
local scenarios: {[string]: Scenario} = {}
local function makeCircularPath(center: Vector3, radius: number, vertical: boolean, phaseRadians: number?): {PathNode}
	local nodes: {PathNode} = table.create(12) :: {PathNode}
	for index = 0, 11 do
		local angle = index / 12 * math.pi * 2 + (phaseRadians or 0)
		nodes[index + 1] = {
			Position = if vertical
				then center + Vector3.new(0, math.cos(angle) * radius, math.sin(angle) * radius)
				else center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius),
			offset = Vector3.zero,
		}
	end
	return nodes
end

local DEFAULT_TUNING = {
	maxSpeed = 20,--20,
	minSpeed = 3,--3,
	sight = 60,--32,
	avoidance = 35, --35,
	separation = 200, --100,
	repulsion = 0,
	repulsionStrength = 3,
	alignment = 100,
	cohesion = 10,
	targetBias = 50,
}

local POLAR_SPHERE_CENTER = Vector3.new(150, 0, 0)
local POLAR_SPHERE_RADIUS = 100
local function makeStaticPath(positions: {Vector3}): {PathNode}
	local path: {PathNode} = table.create(#positions) :: {PathNode}
	for index, position in positions do
		path[index] = {
			Position = position,
			offset = Vector3.zero,
		}
	end
	return path
end

local function makePolarCrossingPath(): {PathNode}
	local center = POLAR_SPHERE_CENTER
	local radius = POLAR_SPHERE_RADIUS
	local outerRadius = radius + 32
	local northPole = center + Vector3.yAxis * radius
	local southPole = center - Vector3.yAxis * radius
	local northOuterPole = center + Vector3.yAxis * outerRadius
	local southOuterPole = center - Vector3.yAxis * outerRadius
	local positions: {Vector3} = {
		northPole,
		center + Vector3.yAxis * (radius * 0.5),
		center,
		center - Vector3.yAxis * (radius * 0.5),
		southPole,
		southOuterPole,
	}

	-- The group exits along the south pole axis, follows a close outside
	-- semicircle, then returns along the north pole axis through its opening.
	for index = 1, 23 do
		local angle = math.pi - index / 24 * math.pi
		positions[#positions + 1] = center + Vector3.new(
			math.sin(angle) * outerRadius,
			math.cos(angle) * outerRadius,
			0
		)
	end
	positions[#positions + 1] = northOuterPole
	return makeStaticPath(positions)
end

local function makePolarFigureEightPath(): {PathNode}
	local center = POLAR_SPHERE_CENTER
	local radius = POLAR_SPHERE_RADIUS
	local interiorRadius = 100
	local outerRadius = radius + 36
	local positions: {Vector3} = {}
	local interiorCenter = center + Vector3.yAxis * (radius - interiorRadius)

	-- This interior lobe is tangent to the +Y opening, so the group enters and
	-- exits through the same portal.
	for index = 0, 15 do
		local angle = index / 16 * math.pi * 2
		positions[#positions + 1] = interiorCenter + Vector3.new(
			math.sin(angle) * interiorRadius,
			math.cos(angle) * interiorRadius,
			0
		)
	end

	-- The outer lobe is a vertical circle around the sphere; its lower half
	-- passes below the +Y entry opening.
	for index = 0, 31 do
		local angle = index / 32 * math.pi * 2
		positions[#positions + 1] = center + Vector3.new(
			math.sin(angle) * outerRadius,
			math.cos(angle) * outerRadius,
			0
		)
	end
	return makeStaticPath(positions)
end

local function makeLegacyGravityWells(path: {PathNode}): {GravityWellDefinition}
	local wells: {GravityWellDefinition} = {}
	for nodeIndex = 1, #path, 4 do
		table.insert(wells, {
			position = path[nodeIndex].Position,
			strength = 5000,
			influenceRadius = 160,
		})
	end
	return wells
end

function Catalog.NewScenario(name: string, serverGroups: {GroupDefinition} | ((Player) -> {GroupDefinition}), clientGroups: {GroupDefinition}, viewers: {Viewer}, warmupSeconds: number?, sampleSeconds: number?, lodPreset: LODPresetName, queryIndexMode: ("none" | "client" | "server" | "both")?): Scenario
	assert(name ~= "", "Scenario name must not be empty")
	assert(not scenarios[name], `Scenario {name} is already registered`)

	local scenario: Scenario = {
		name = name,
		lodPreset = lodPreset,
		serverGroups = serverGroups,
		clientGroups = clientGroups,
		viewers = viewers,
		warmupSeconds = warmupSeconds or 8,
		sampleSeconds = sampleSeconds or 20,
		queryIndexMode = queryIndexMode or "both",
	}
	scenarios[name] = scenario
	return scenario
end

function Catalog.GetScenario(scenarioName: string): Scenario?
	return scenarios[scenarioName]
end

local function getCharacterRoot(player: Player): BasePart
	local character = player.Character or player.CharacterAdded:Wait()
	return character:WaitForChild("HumanoidRootPart") :: BasePart
end

local function makePlayerRelativeCircularPath(root: BasePart, radius: number): {PathNode}	
	local nodes: {PathNode} = {{
		Position = root,
		offset = Vector3.zero,
	}}
	for index = 1, 11 do
		local angle = index / 12 * math.pi * 2
		nodes[index + 1] = {
			Position = root,
			offset = Vector3.new(math.sin(angle) * radius, 0, radius * (1 - math.cos(angle))),
		}
	end
	return nodes
end

local legacyHorizontalPath = makeCircularPath(Vector3.zero, 100, false)
local legacyVerticalPath = makeCircularPath(Vector3.zero, 200, true)

Catalog.NewScenario(
	"LegacyDemo",
	{
		{
			name = "LegacyServerHorizontal",
			boidCount = 5000,
			center = legacyHorizontalPath[1].Position,
			spread = 450,
			seed = 1,
			color = Color3.fromRGB(55, 220, 90),
			tuning = DEFAULT_TUNING,
			path = legacyHorizontalPath,
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 48,
			gravityWells = makeLegacyGravityWells(legacyHorizontalPath),
		},
		{
			name = "LegacyServerVertical",
			boidCount = 5000,
			center = legacyVerticalPath[1].Position,
			spread = 45,
			seed = 2,
			color = Color3.fromRGB(235, 70, 70),
			tuning = DEFAULT_TUNING,
			path = legacyVerticalPath,
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 48,
			gravityWells = makeLegacyGravityWells(legacyVerticalPath),
		},
	},
	{
		{
			name = "LegacyClientHorizontal",
			boidCount = 5000,
			center = legacyHorizontalPath[1].Position,
			spread = 450,
			seed = 1,
			color = Color3.fromRGB(50, 130, 255),
			tuning = DEFAULT_TUNING,
			path = legacyHorizontalPath,
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 48,
			gravityWells = makeLegacyGravityWells(legacyHorizontalPath),
		},
		{
			name = "LegacyClientVertical",
			boidCount = 5000,
			center = legacyVerticalPath[1].Position,
			spread = 45,
			seed = 2,
			color = Color3.fromRGB(245, 220, 55),
			tuning = DEFAULT_TUNING,
			path = legacyVerticalPath,
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 48,
			gravityWells = makeLegacyGravityWells(legacyVerticalPath),
		},
	},
	{},
	8,
	20,
	"low"
)

Catalog.NewScenario(
	"ServerClientReplicationComparison",
	{
		{
			name = "ServerReplicaGreen",
			boidCount = 1500,
			center = Vector3.new(-275, 0, 0),
			spread = 45,
			seed = 101,
			color = Color3.fromRGB(55, 220, 90),
			tuning = DEFAULT_TUNING,
			path = makeCircularPath(Vector3.new(-275, 0, 0), 260, false),
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 42,
			gravityWells = {
				{ position = Vector3.new(-15, 0, 0), strength = 12000, influenceRadius = 150 },
				{ position = Vector3.new(-535, 0, 0), strength = 12000, influenceRadius = 150 },
			},
		},
	},
	{
		{
			name = "ClientOnlyBlue",
			boidCount = 1500,
			center = Vector3.new(275, 0, 0),
			spread = 45,
			seed = 202,
			color = Color3.fromRGB(50, 130, 255),
			tuning = DEFAULT_TUNING,
			path = makeCircularPath(Vector3.new(275, 0, 0), 260, true),
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 42,
			gravityWells = {
				{ position = Vector3.new(275, 260, 0), strength = 12000, influenceRadius = 150 },
				{ position = Vector3.new(275, -260, 0), strength = 12000, influenceRadius = 150 },
			},
		},
	},
	{
		{ id = 1, position = Vector3.zero },
	},
	8,
	20,
	"low"
)

Catalog.NewScenario(
	"PlayerTracking",
	function(player: Player)
		local root = getCharacterRoot(player)
		local pathRadius = 180
		return {
			{
				name = "PlayerThroughCircle",
				boidCount = 5000,
				center = root.Position + Vector3.new(0, 0, pathRadius),
				spread = 30,
				seed = 303,
				color = Color3.fromRGB(75, 210, 255),
				tuning = DEFAULT_TUNING,
				path = makePlayerRelativeCircularPath(root, pathRadius),
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 36,
			},
			{
				name = "PlayerTargetChasers",
				boidCount = 5000,
				center = root.Position + Vector3.new(0, 65, -220),
				spread = 30,
				seed = 404,
				color = Color3.fromRGB(255, 175, 70),
				tuning = DEFAULT_TUNING,
				target = root,
			},
		}
	end,
	{},
	{},
	8,
	20,
	"low"
)

Catalog.NewScenario(
	"CirclingStressTest",
	function(player: Player)
		local root = getCharacterRoot(player)
		
		local groupCount = 10
		
		local groups = {}
		for i = 1, groupCount do
			local pathRadius = i * 2000
			table.insert(groups, {
				name = "circle1",
				boidCount = 5000,
				center = root.Position + Vector3.new(0, 0, pathRadius),
				spread = 30,
				seed = i,
				color = Color3.new(10 / i, 0, 10 / i),
				tuning = DEFAULT_TUNING,
				path = makePlayerRelativeCircularPath(root, pathRadius),
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 40
			})
		end
		
		return groups
	end,
	{},
	{},
	8,
	20,
	"low"
)

Catalog.NewScenario(
	"FancyStressTest",
	function(player: Player)
		local root = getCharacterRoot(player)

		local groups = {}
		for i = 1, 10 do
			local pathRadius = i * 50
			table.insert(groups, {
				name = "circle1",
				boidCount = 500,
				center = root.Position + Vector3.new(0, 0, pathRadius),
				spread = 30,
				seed = i,
				color = Color3.new(10 / i, 0, 10 / i),
				tuning = DEFAULT_TUNING,
				path = makePlayerRelativeCircularPath(root, pathRadius),
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 40
			})
		end

		return groups
	end,
	{},
	{},
	8,
	20,
	"high"
)

Catalog.NewScenario(
	"RandomTargetStress",
	function(_player: Player)
		local targets = Fixtures.CreateRandomTargets()
		local groups: {GroupDefinition} = {}
		for index, target in targets do
			groups[index] = {
				name = "RandomTargetGroup_" .. index,
				boidCount = 2000, center = target.Position, spread = 40,
				seed = 20000 + index, color = target.Color,
				tuning = DEFAULT_TUNING, target = target,
			}
		end
		return groups
	end,
	{},
	{},
	8,
	20,
	"low"
)

Catalog.NewScenario(
	"ObstacleAvoidance",
	function(_player: Player)
		Fixtures.CreateObstacleCourse()

		-- Each loop crosses its matching course obstacle between path nodes, so
		-- avoidance remains observable lap after lap instead of ending at a target.
		-- The phase keeps every waypoint outside its course part while segments
		-- still cross the obstacles, avoiding embedded destinations.
		local coursePathPhase = math.pi / 12
		local wallPath = makeCircularPath(Vector3.new(0, 100, 100), 100, false, coursePathPhase)
		local cornerPath = makeCircularPath(Vector3.new(290, 0, 0), 100, false, coursePathPhase)
		local gapPath = makeCircularPath(Vector3.new(500, 0, 100), 100, false, coursePathPhase)

		return {
			{
				name = "ObstacleWall",
				boidCount = 5000,
				center = wallPath[1].Position,
				spread = 16,
				seed = 51001,
				color = Color3.fromRGB(75, 210, 255),
				tuning = DEFAULT_TUNING,
				path = wallPath,
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 24,
			},
			{
				name = "ObstacleCorner",
				boidCount = 5000,
				center = cornerPath[1].Position,
				spread = 16,
				seed = 51002,
				color = Color3.fromRGB(255, 175, 70),
				tuning = DEFAULT_TUNING,
				path = cornerPath,
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 24,
			},
			{
				name = "ObstacleGap",
				boidCount = 5000,
				center = gapPath[1].Position,
				spread = 7,
				seed = 51003,
				color = Color3.fromRGB(120, 235, 120),
				tuning = DEFAULT_TUNING,
				path = gapPath,
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 24,
			},
		}
	end,
	{},
	{},
	8,
	20,
	"low",
	"none"
)

Catalog.NewScenario(
	"PolarSphereObstacle",
	function(_player: Player)
		Fixtures.CreatePolarSphere()
		local crossingPath = makePolarCrossingPath()
		local figureEightPath = makePolarFigureEightPath()

		return {
			{
				name = "PolarSphereCrossing",
				boidCount = 5000,
				center = crossingPath[1].Position,
				spread = 16,
				seed = 51004,
				color = Color3.fromRGB(75, 210, 255),
				tuning = DEFAULT_TUNING,
				path = crossingPath,
				switchToClosestNode = true,
				loops = true,
				pathArrivalRadius = 24,
			},
			--{
			--	name = "PolarSphereFigureEight",
			--	boidCount = 5000,
			--	center = figureEightPath[1].Position,
			--	spread = 16,
			--	seed = 51005,
			--	color = Color3.fromRGB(255, 175, 70),
			--	tuning = DEFAULT_TUNING,
			--	path = figureEightPath,
			--	switchToClosestNode = true,
			--	loops = true,
			--	pathArrivalRadius = 24,
			--},
		}
	end,
	{},
	{},
	8,
	20,
	"high",
	"none"
)

-- WorkerCore Step 3 benchmark fixtures. Paths, seeds, LOD, and query-index mode
-- are fixed; BenchmarkHarness only varies run timing and baseline/candidate labels.
local function makeBenchmarkGroups(groupCount: number, boidsPerGroup: number, spread: number, spacing: number, seedBase: number): {GroupDefinition}
	local groups: {GroupDefinition} = table.create(groupCount) :: {GroupDefinition}
	for index = 1, groupCount do
		local column = (index - 1) % 5
		local row = (index - 1) // 5
		local center = Vector3.new((column - 2) * spacing, 0, (row - 0.5) * spacing)
		groups[index] = {
			name = `BenchmarkGroup_{groupCount}_{boidsPerGroup}_{index}`,
			boidCount = boidsPerGroup,
			center = center,
			spread = spread,
			seed = seedBase + index,
			color = Color3.fromHSV((index - 1) / groupCount, 0.8, 1),
			tuning = DEFAULT_TUNING,
			path = makeCircularPath(center, math.max(64, spacing * 0.4), false),
			switchToClosestNode = true,
			loops = true,
			pathArrivalRadius = 36,
		}
	end
	return groups
end

Catalog.NewScenario(
	"BenchmarkReference20k",
	makeBenchmarkGroups(10, 2000, 40, 420, 31000),
	{},
	{ { id = 1, position = Vector3.new(0, 200, 700) } },
	15,
	45,
	"low",
	"both"
)

Catalog.NewScenario(
	"BenchmarkConcentrated30k",
	makeBenchmarkGroups(3, 10000, 12, 96, 32000),
	{},
	{ { id = 1, position = Vector3.new(0, 200, 700) } },
	15,
	45,
	"low",
	"both"
)


Catalog.CleanupFixtures = Fixtures.Stop
return Catalog
