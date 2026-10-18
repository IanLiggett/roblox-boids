--!strict
return function(t: any): ()
	local package = game.ReplicatedStorage.BoidsReplicated
	local codec = require(package.SnapshotCodec)
	local network = require(package.NetworkResults)
	t.test("matches transport snapshot bytes", function()
		local a = codec.NewCellSnapshot(1, Vector3.new(1, 2, 3))
		local b = network.NewCellSnapshot(1, Vector3.new(1, 2, 3))
		codec.AppendBoid(a, 17, Vector3.new(12, 34, 56), Vector3.new(2, -3, 4))
		network.AppendBoid(b, 17, Vector3.new(12, 34, 56), Vector3.new(2, -3, 4))
		t.expect.equal(a.boidCount, b.boidCount)
		t.expect.equal(buffer.tostring(a.networkBoids), buffer.tostring(b.networkBoids))
	end)
	t.test("reserved append preserves bytes at capacity while checked append grows and trimming copies only used rows", function()
		local reserved = codec.NewCellSnapshot(2, Vector3.new(1, 2, 3))
		local checked = codec.NewCellSnapshot(1, Vector3.new(1, 2, 3))
		for boidId = 1, 2 do
			local position = Vector3.new(boidId * 10, boidId * 20, boidId * 30)
			local velocity = Vector3.new(boidId, -boidId, boidId + 1)
			codec.AppendBoidReserved(reserved, boidId, position, velocity)
			codec.AppendBoid(checked, boidId, position, velocity)
		end
		t.expect.equal(reserved.boidCount, 2)
		t.expect.equal(buffer.tostring(reserved.networkBoids), buffer.tostring(checked.networkBoids))
		t.expect.throws(function()
			codec.AppendBoidReserved(reserved, 3, Vector3.zero, Vector3.zero)
		end)
		t.expect.equal(reserved.boidCount, 2)

		codec.AppendBoid(checked, 3, Vector3.zero, Vector3.zero)
		t.expect.equal(checked.boidCount, 3)
		t.expect.equal(buffer.len(checked.networkBoids), 4 * codec.BOID_ROW_BYTES)
		local grownBytes = buffer.tostring(checked.networkBoids)
		codec.TrimUnusedCapacity(checked)
		t.expect.equal(buffer.len(checked.networkBoids), 3 * codec.BOID_ROW_BYTES)
		t.expect.equal(buffer.tostring(checked.networkBoids), string.sub(grownBytes, 1, 3 * codec.BOID_ROW_BYTES))
	end)

	t.test("local publication forwards populated sparse cells without packetization or buffer copies", function()
		local bridge = require(package.ClientRendererBridge)
		local oldConsume = bridge.ConsumeCellSnapshot
		local oldConvert = network.ConvertSimulationSnapshotToPackets
		local a = codec.NewCellSnapshot(8, Vector3.new(128, 0, -128))
		local b = codec.NewCellSnapshot(4, Vector3.new(-128, 128, 0))
		local empty = codec.NewCellSnapshot(16, Vector3.zero)
		codec.AppendBoid(a, 17, Vector3.new(12, 34, 56), Vector3.new(2, -3, 4))
		codec.AppendBoid(b, 19, Vector3.one, Vector3.zero)
		local seen: {[buffer]: boolean} = {}
		local time = 1234.56789
		local ok, failure = xpcall(function()
			network.ConvertSimulationSnapshotToPackets = function(): never
				error("Local publication must not assemble packets")
			end
			bridge.ConsumeCellSnapshot = function(origin: Vector3, rows: buffer, count: number, completionTime: number): ()
				local cell = if rows == a.networkBoids then a elseif rows == b.networkBoids then b else nil
				t.expect.truthy(cell)
				assert(cell)
				t.expect.equal(origin, cell.origin)
				t.expect.equal(count, cell.boidCount)
				t.expect.equal(completionTime, time)
				t.expect.falsy(seen[rows])
				seen[rows] = true
			end
			network.PublishSimulationSnapshot({[23] = a, [9876] = b, [42] = empty}, time)
			t.expect.truthy(seen[a.networkBoids])
			t.expect.truthy(seen[b.networkBoids])
			table.clear(seen)
			network.PublishSimulationSnapshot({}, time)
			network.PublishSimulationSnapshot({[11] = empty}, time)
			t.expect.equal(next(seen), nil)
		end, debug.traceback)
		bridge.ConsumeCellSnapshot = oldConsume
		network.ConvertSimulationSnapshotToPackets = oldConvert
		assert(ok, failure)
	end)
end