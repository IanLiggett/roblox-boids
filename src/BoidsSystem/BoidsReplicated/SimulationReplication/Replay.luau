--!strict

local Replay = {}

export type BoidSpawnRecord = {
	id: number, replicaSerial: number, position: Vector3, velocity: Vector3,
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

function Replay.ForEachBatch(recipes: {[number]: BoidSpawnRecord},readState: StateReader,batchSize: number,consume: ({BoidSpawnRecord}) -> ()): ()
	local ids: {number}={}
	for id in recipes do table.insert(ids,id) end
	table.sort(ids)
	local batch: {BoidSpawnRecord}={}
	for _,id in ids do
		local recipe=recipes[id]
		if not recipe then continue end
		local position,velocity=readState(id)
		if not position or not velocity then continue end
		local record=table.clone(recipe)
		record.position,record.velocity=position,velocity
		table.insert(batch,record)
		if #batch==batchSize then consume(batch); batch={} end
	end
	if #batch>0 then consume(batch) end
end

return Replay
