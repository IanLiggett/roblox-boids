--!strict

--[[
ScenarioRuntime
===============
Shared scenario spawner used by server-owned and client-only scenario groups.
Definitions are plain serializable data so Scenarios can deliver a client group
through SimulationReplication without duplicating boid setup code.
]]

local SharedTypes = require(script.Parent.Parent.SharedTypes)
local RuntimeTypes = require(script.Parent.Parent.RuntimeTypes)
local ScenarioTypes = require(script.Parent.Types)
local Runtime = {}


type BoidsApi = RuntimeTypes.GroupWriter
type GroupDefinition = ScenarioTypes.GroupDefinition
type SpawnedGroup = ScenarioTypes.SpawnedGroup

local function randomDirection(rng: Random): Vector3
	local direction = Vector3.new(
		rng:NextNumber(-1, 1),
		rng:NextNumber(-1, 1),
		rng:NextNumber(-1, 1)
	)
	return if direction.Magnitude > 0.001 then direction.Unit else Vector3.zAxis
end

function Runtime.SpawnGroup(boids: BoidsApi, definition: GroupDefinition): SpawnedGroup
	assert(definition.boidCount > 0, "Scenario group must contain at least one boid")
	assert(definition.spread >= 0, "Scenario group spread must be non-negative")

	local model = definition.model or SharedTypes.BoidModels.Boid
	local group = boids.NewGroup(model, nil, definition.color)
	local tuning = definition.tuning
	local rng = Random.new(definition.seed)
	local boidIds: {number} = {}

	for boidIndex = 1, definition.boidCount do
		local position = definition.center + Vector3.new(
			rng:NextNumber(-definition.spread, definition.spread),
			rng:NextNumber(-definition.spread, definition.spread),
			rng:NextNumber(-definition.spread, definition.spread)
		)

		local boidId = boids.NewBoid(
			group,
			position,
			randomDirection(rng),
			math.max(tuning.maxSpeed + rng:NextInteger(-10, 10), tuning.minSpeed + 1),
			tuning.minSpeed,
			math.max(tuning.sight + rng:NextInteger(-10, 10), 1),
			math.max(tuning.avoidance + rng:NextInteger(-5, 5), 0),
			math.max(tuning.separation + rng:NextInteger(-50, 50), 0),
			tuning.repulsion,
			tuning.repulsionStrength,
			math.max(tuning.alignment + rng:NextInteger(-20, 20), 1),
			math.max(tuning.cohesion + rng:NextInteger(-20, 20), 1),
			math.max(tuning.targetBias + rng:NextInteger(-20, 20), 1),
			model
		)
		if boidId then
			table.insert(boidIds, boidId)
		end

		if boidIndex % 100 == 0 then
			task.wait()
		end
	end

	if definition.path then
		boids.SetPath(
			group,
			definition.path,
			definition.switchToClosestNode,
			definition.loops,
			definition.showDebugPath == true,
			definition.pathArrivalRadius
		)
	elseif definition.target then
		boids.SetTarget(group, definition.target)
	end

	if definition.gravityWells then
		for _, gravityWell in definition.gravityWells do
			boids.AddGravityWell(
				gravityWell.position,
				gravityWell.strength,
				gravityWell.influenceRadius,
				{group}
			)
		end
	end

	return {
		group = group,
		boidIds = boidIds,
	}
end

function Runtime.SpawnGroups(boids: BoidsApi, definitions: {GroupDefinition}): {SpawnedGroup}
	local spawned: {SpawnedGroup} = table.create(#definitions) :: {SpawnedGroup}
	for index, definition in definitions do
		spawned[index] = Runtime.SpawnGroup(boids, definition)
	end
	return spawned
end

return Runtime
