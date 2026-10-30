--!strict
-- Pure fixed-row codec shared by coordinator batching and Actor workers.
local StatsCodec = {}

StatsCodec.ROW_BYTES = 16

export type ActorBoidsBatch = {
	groupId: number,
	lifetimes: {number},
	boidCount: number,
	data: buffer,
}

function StatsCodec.ReadBoidRow(data: buffer, index: number): (number, number, number, number, number, number, number, number, number, number, number)
	local offset = index * StatsCodec.ROW_BYTES
	return buffer.readu16(data, offset), buffer.readu8(data, offset + 2), buffer.readu8(data, offset + 3),
		buffer.readu8(data, offset + 4), buffer.readu8(data, offset + 5), buffer.readu8(data, offset + 6),
		buffer.readu8(data, offset + 7), buffer.readu8(data, offset + 8), buffer.readu8(data, offset + 9),
		buffer.readu8(data, offset + 10), buffer.readu8(data, offset + 11)
end

function StatsCodec.WriteBoidRow(data: buffer, index: number, boidId: number, maxSpeed: number, minSpeed: number, sight: number, avoidance: number, separation: number, repulsion: number, repulsionStrength: number, alignment: number, cohesion: number, targetBias: number): ()
	local offset = index * StatsCodec.ROW_BYTES
	buffer.writeu16(data, offset, boidId)
	buffer.writeu8(data, offset + 2, maxSpeed); buffer.writeu8(data, offset + 3, minSpeed)
	buffer.writeu8(data, offset + 4, sight); buffer.writeu8(data, offset + 5, avoidance)
	buffer.writeu8(data, offset + 6, separation); buffer.writeu8(data, offset + 7, repulsion)
	buffer.writeu8(data, offset + 8, repulsionStrength); buffer.writeu8(data, offset + 9, alignment)
	buffer.writeu8(data, offset + 10, cohesion); buffer.writeu8(data, offset + 11, targetBias)
end

return StatsCodec
