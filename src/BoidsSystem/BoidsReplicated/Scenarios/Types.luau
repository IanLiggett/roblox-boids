--!strict
-- Scenario-owned definitions and delivery context, independent of the spawner.
local SharedTypes = require(script.Parent.Parent.SharedTypes)
type Target = SharedTypes.Target
type PathNode = SharedTypes.PathNode
type Group = SharedTypes.Group

export type BoidTuning = {
	maxSpeed: number,
	minSpeed: number,
	sight: number,
	avoidance: number,
	separation: number,
	repulsion: number,
	repulsionStrength: number,
	alignment: number,
	cohesion: number,
	targetBias: number,
}

export type GravityWellDefinition = {
	position: Vector3,
	strength: number,
	influenceRadius: number,
}

export type GroupDefinition = {
	name: string,
	boidCount: number,
	center: Vector3,
	spread: number,
	seed: number,
	color: Color3,
	model: number?,
	tuning: BoidTuning,
	target: Target?,
	path: {PathNode}?,
	switchToClosestNode: boolean?,
	loops: boolean?,
	pathArrivalRadius: number?,
	showDebugPath: boolean?,
	gravityWells: {GravityWellDefinition}?,
}

export type SpawnedGroup = {
	group: Group,
	boidIds: {number},
}


export type GroupBinding = {groupId: number, ownership: "server" | "client", definition: GroupDefinition}
export type ScenarioContext = {name: string, serverGroups: {GroupBinding}}
export type Benchmark = {warmupSeconds: number?, sampleSeconds: number?}
return {}
