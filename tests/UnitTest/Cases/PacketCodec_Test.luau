--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)
return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local codec = require(package.NetworkResults.PacketCodec)
	local SharedTypes = require(package.SharedTypes)
	local function roundTrip(ids: {number}, expectedMode: number?): ()
		local origin = Vector3.new(-32768, 128, 32767)
		local cell = codec.NewCellSnapshot(#ids + 17, origin)
		for index, id in ids do codec.AppendBoid(cell, id, Vector3.new(index % 64, -4, 68), Vector3.new(0, -127, 127)) end
		local packets = codec.ConvertSimulationSnapshotToPackets({cell})
		local seen = 0
		for _, packet in packets do
			t.expect.truthy(buffer.len(packet) <= codec.MAX_PACKET_BYTES)
			for offset, x, y, z, count in codec.ForEachCellHeader(packet) do
				t.expect.equal(Vector3.new(x, y, z), origin)
				if expectedMode then t.expect.equal(buffer.readu8(packet, offset - 1), expectedMode) end
				for id, px, py, pz, vx, vy, vz in codec.ForEachPacketBoid(packet, offset, count) do
					seen += 1
					t.expect.equal(id, ids[seen])
					local copy = codec.NewCellSnapshot(1, origin)
					codec.AppendBoid(copy, id, Vector3.new(px, py, pz), Vector3.new(vx, vy, vz))
					t.expect.equal(buffer.tostring(copy.networkBoids), buffer.readstring(cell.networkBoids, (seen - 1) * 8, 8))
					t.expect.equal(vx, 0)
					t.expect.equal(vy, -127)
					t.expect.equal(vz, 127)
				end
			end
		end
		t.expect.equal(seen, #ids)
	end
	t.test("explicit IDs preserve arbitrary full-u16 order", function() roundTrip({0, 65535, 256, 1, 32768}, 0) end)
	t.test("page IDs preserve unsorted membership", function() roundTrip({513, 520, 519, 767}, 1) end)
	t.test("bitmap IDs preserve gaps and page-edge bits", function()
		local ids: {number} = {}
		for i = 0, 39 do ids[#ids + 1] = 65280 + i * 6 end
		ids[#ids + 1] = 65535
		roundTrip(ids, 2)
	end)
	t.test("consecutive IDs need only one starting ID and split at packet bounds", function()
		local ids: {number} = {}
		for id = 65000, 65535 do ids[#ids + 1] = id end
		roundTrip(ids, 3)
		local cell = codec.NewCellSnapshot(100, Vector3.zero)
		for id = 1, 100 do codec.AppendBoid(cell, id, Vector3.one, Vector3.zero) end
		local packet = codec.ConvertSimulationSnapshotToPackets({cell})[1]
		t.expect.equal(buffer.len(packet), 8 + 2 + 600)
	end)
	t.test("mixed cells and empty snapshots retain framing", function()
		local cells: {SharedTypes.CellSnapshot} = {}
		for i = 1, 100 do
			local cell = codec.NewCellSnapshot(1, Vector3.new(i * 64, 0, 0))
			codec.AppendBoid(cell, i, Vector3.zero, Vector3.zero)
			cells[i] = cell
		end
		local seen = 0
		for _, packet in codec.ConvertSimulationSnapshotToPackets(cells) do
			for offset, x, _, _, n in codec.ForEachCellHeader(packet) do
				for id in codec.ForEachPacketBoid(packet, offset, n) do seen += 1; t.expect.equal(x, id * 64) end
			end
		end
		t.expect.equal(seen, 100)
		t.expect.equal(#codec.ConvertSimulationSnapshotToPackets({}), 0)
	end)
	t.test("mixed identity prefixes survive splitting without sorting or mutation", function()
		local ids: {number} = {}
		for i = 0, 999 do ids[#ids + 1] = (i * 3571) % 65536 end
		roundTrip(ids)
		for i = 1, 1000 do ids[i] = i end
		roundTrip(ids)
	end)

end
