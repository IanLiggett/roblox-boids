--!strict

local Replay = {}

export type BoidSpawnRecord = {
	id: number, position: Vector3, velocity: Vector3,
	maxSpeed: number, minSpeed: number, sight: number, avoidance: number,
	separation: number, repulsion: number, repulsionStrength: number,
	alignment: number, cohesion: number, targetBias: number, model: number,
}
export type StateReader = (number) -> (Vector3?, Vector3?)

-- Recipes own tuning, not current pose. The running coordinator supplies its
-- latest settled pose at serialization, without scheduling work or extrapolation.
-- This pose can be old under LOD; the read clock is not a new simulation time.
function Replay.CopyBoids(recipes: {[number]: BoidSpawnRecord}, readState: StateReader): {BoidSpawnRecord}
	local records: {BoidSpawnRecord} = {}
	for id, recipe in recipes do
		local position, velocity = readState(id)
		if not position or not velocity then continue end
		local record = table.clone(recipe)
		record.position, record.velocity = position, velocity
		table.insert(records, record)
	end
	table.sort(records, function(a: BoidSpawnRecord, b: BoidSpawnRecord): boolean
		return a.id < b.id
	end)
	return records
end

return Replay
