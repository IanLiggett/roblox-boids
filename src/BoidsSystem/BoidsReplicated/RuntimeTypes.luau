--!strict
-- Capability contracts belong to the runtime, never to scenario spawning.
local SharedTypes = require(script.Parent.SharedTypes)
type Group = SharedTypes.Group
type Target = SharedTypes.Target
type PathNode = SharedTypes.PathNode

export type GroupWriter = {
	NewGroup: (defaultBoidModel: number, explicitId: number?, renderColor: Color3?) -> Group,
	NewBoid: (group: Group, position: Vector3, velocity: Vector3, maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number, model: number?) -> number?,
	SetPath: (group: Group, path: {PathNode}, switchToClosestNode: boolean?, loops: boolean?, debugs: boolean?, pathArrivalRadius: number?) -> (),
	SetTarget: (group: Group, target: Target, debugs: boolean?) -> (),
	AddGravityWell: (position: Vector3, strength: number, influenceRadius: number, groups: {Group}?) -> number,
}
export type ViewerControl = {
	SetViewerObservers: (number, boolean, {Vector3}) -> (),
	ResetViewerObservers: (number) -> (),
}
export type ObstacleCapture = {
	SetObstacleObservation: (number?) -> (),
	GetObstacleObservation: () -> SharedTypes.ObstacleObservation?,
}
export type ServerObservation = ViewerControl & {
	GetBoidObservation: (number) -> SharedTypes.BoidObservation?,
}
export type ClientObservation = ServerObservation & ObstacleCapture & {
	IsServerBoid: (number) -> boolean,
	GetGroupObservation: (number) -> SharedTypes.GroupObservation?,
	SubscribeDeleted: (({number}) -> ()) -> (() -> ()),
}
export type CompletedBatch = {
	groupId: number, boidIds: {number}, positions: {Vector3}, velocities: {Vector3}, completionTime: number,
}
export type IndexSource = {
	ForEachBoid: ((number, Vector3, number) -> ()) -> (),
	SubscribeCreated: ((number, Vector3, number) -> ()) -> (() -> ()),
	SubscribePostMerge: ((CompletedBatch) -> ()) -> (() -> ()),
	SubscribeDeleted: (({number}) -> ()) -> (() -> ()),
	GetBoidModel: (number) -> number?,
}
export type Replication = {
	IsServerBoid: (number) -> boolean,
	ReserveServerBoidId: (number) -> (),
	ReleaseServerBoidId: (number) -> (),
	GetBoidState: (number) -> (Vector3?, Vector3?),
	NewGroup: (number, number?, Color3?) -> Group,
	HasBoid: (number) -> boolean,
	NewBoid: (Group, Vector3, Vector3, number, number, number, number, number, number, number, number, number, number, number?, number?) -> number?,
	SetTarget: (Group, Target, boolean?) -> (),
	SetPath: (Group, {PathNode}, boolean?, boolean?, boolean?, number?) -> (),
	AddGravityWell: (Vector3, number, number, {Group}?, number?) -> number,
	RemoveGravityWell: (number, {Group}?) -> boolean,
	QueueDeleteBoid: (number) -> (),
	IsDeletionPending: (number) -> boolean,
	IsGroupRetiring: (number) -> boolean,
	DestroyGroup: (Group) -> (),
	SetReconciliationTargets: ({{boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number}}) -> (),
}
export type Api = Replication & ClientObservation & IndexSource & {
	GetRuntimeMetrics: ({[string]: number}?) -> SharedTypes.RuntimeMetrics,
	GetRuntimeSummary: () -> SharedTypes.RuntimeSummary,
}
return {}
