--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local q = require(package.Quantization)
	local storage = require(package.BoidStorage)
	local codec = require(package.NetworkResults.PacketCodec)
	local SharedTypes = require(package.SharedTypes)
	local BoidQueryIndex = require(package.CollisionIndex)

	t.test("storage and snapshots preserve expanded positions with unchanged row sizes", function()
		local tolerance = q.POSITION_RANGE / 255 / 2 + 0.00001
		local data: buffer = buffer.create(1024)
		local origin: Vector3 = Vector3.new(-128, 64, -64)
		local snapshot: SharedTypes.CellSnapshot = codec.NewCellSnapshot(1, origin)
		for _, axis in {q.POSITION_MIN, math.max(q.POSITION_MIN, -2), 0, 32, q.CELL_SIZE, q.CELL_SIZE + q.CELL_MARGIN} do
			storage.WritePosition(data, 0, axis, axis, axis)
			local x, y, z = storage.ReadPosition(data, 0)
			t.expect.near(x, axis, tolerance)
			t.expect.near(y, axis, tolerance)
			t.expect.near(z, axis, tolerance)
			local position: Vector3 = Vector3.new(axis, axis, axis)
			local cell: SharedTypes.CellSnapshot = codec.NewCellSnapshot(1, origin)
			codec.AppendBoid(cell, 17, position, Vector3.zero)
			t.expect.equal(buffer.len(cell.networkBoids), 8)
			for id, px, py, pz in codec.ForEachBoid(cell.networkBoids, 0, 1) do
				t.expect.equal(id, 17)
				t.expect.equal(px, x)
				t.expect.equal(py, y)
				t.expect.equal(pz, z)
			end
			snapshot = cell
		end
		local packet: buffer = codec.ConvertSimulationSnapshotToPackets({snapshot})[1]
		for offset, ox, oy, oz, count in codec.ForEachCellHeader(packet) do
			t.expect.equal(Vector3.new(ox, oy, oz), origin)
			t.expect.equal(count, 1)
			for id, x, y, z in codec.ForEachBoid(packet, offset, count) do
				t.expect.equal(id, 17)
				t.expect.near(x, q.CELL_SIZE + q.CELL_MARGIN, tolerance)
				t.expect.near(y, x)
				t.expect.near(z, x)
			end
		end
	end)

	t.test("all U8 codes survive a storage round trip", function()
		local data: buffer = buffer.create(1024)
		for code = 0, 255 do
			local position = q.dequantizePositionAxis(code, 255)
			storage.WritePosition(data, 0, position, position, position)
			local x = storage.ReadPosition(data, 0)
			t.expect.equal(q.quantizePositionAxis(x, 255), code)
		end
	end)

	t.test("geometric queries find decoded members outside their simulation cell", function()
		local query: BoidQueryIndex.Index = BoidQueryIndex.new()
		for index, axis in {q.POSITION_MIN, q.CELL_SIZE + q.CELL_MARGIN} do
			local position: Vector3 = Vector3.new(q.dequantizePositionAxis(q.quantizePositionAxis(axis,255),255), 32, 32)
			query:Update(index, position, 0.25)
			local hits: {BoidQueryIndex.Hit} = query:QueryRadius(position, 0.1)
			t.expect.equal(#hits, 1)
			t.expect.equal(hits[1].boidId, index)
			local hit: BoidQueryIndex.Hit? = query:Raycast(position - Vector3.zAxis, Vector3.zAxis * 2)
			assert(hit)
			t.expect.equal(hit.boidId, index)
		end
	end)
end
