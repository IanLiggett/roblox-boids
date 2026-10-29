--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local codec = require(package.NetworkResults.PacketCodec)
	local prediction = require(package.NetworkResults.PredictionState)
	local transportMetrics = require(package.NetworkResults.TransportMetrics)

	local function consider(state: prediction.State, id: number, position: Vector3, velocity: Vector3, time: number, positionError: number?, velocityError: number?, origin: Vector3?): boolean
		local cell = codec.NewCellSnapshot(1, origin or Vector3.zero)
		codec.AppendBoid(cell, id, position - cell.origin, velocity)
		for readId, px, py, pz, vx, vy, vz in codec.ForEachBoid(cell.networkBoids, 0, 1) do
			return prediction.Consider(state, readId, cell.origin.X + px, cell.origin.Y + py, cell.origin.Z + pz, vx, vy, vz, time,
				(positionError or 4) ^ 2, (velocityError or 2) ^ 2, cell.origin, cell.networkBoids, 0)
		end
		error("Missing authored test row")
	end

	local function send(state: prediction.State): number
		local byTime, times = prediction.BuildSnapshots(state)
		local sent = 0
		for _, time in times do
			for _, packet in codec.ConvertSimulationSnapshotToPackets(byTime[time]) do
				sent += prediction.RecordSent(state, packet, time)
			end
		end
		prediction.ClearPending(state)
		return sent
	end

	t.test("baseline starts only on send and unchanged quantized velocity does not retrigger", function()
		local state = prediction.New()
		t.expect.truthy(consider(state, 7, Vector3.one * 20, Vector3.xAxis * 10, 1))
		t.expect.equal(state.baselineCount, 0)
		t.expect.equal(send(state), 1)
		t.expect.equal(state.baselineCount, 1)
		t.expect.falsy(consider(state, 7, Vector3.new(21, 20, 20), Vector3.xAxis * 10, 1.1))
		t.expect.equal(state.count, 0)
	end)

	t.test("position error triggers independently of velocity", function()
		local state = prediction.New()
		consider(state, 7, Vector3.one * 20, Vector3.xAxis * 10, 1)
		send(state)
		t.expect.truthy(consider(state, 7, Vector3.new(26, 20, 20), Vector3.xAxis * 10, 1.01))
	end)

	t.test("velocity turn triggers independently of position and recipient baselines differ", function()
		local near, far = prediction.New(), prediction.New()
		consider(near, 7, Vector3.one * 20, Vector3.xAxis * 10, 1)
		consider(far, 7, Vector3.one * 20, Vector3.xAxis * 10, 1)
		send(near)
		send(far)
		local turned = Vector3.new(10, 4, 0)
		t.expect.truthy(consider(near, 7, Vector3.one * 20, turned, 1.01, 4, 2))
		t.expect.falsy(consider(far, 7, Vector3.one * 20, turned, 1.01, 16, 8))
		send(near)
		t.expect.falsy(consider(near, 7, Vector3.one * 20, turned, 1.02, 4, 2))
		t.expect.truthy(consider(far, 7, Vector3.one * 20, turned, 1.02, 16, 2))
	end)

	t.test("accurate straight trajectory has no age refresh beyond 24 seconds", function()
		local state = prediction.New()
		consider(state, 7, Vector3.one * 20, Vector3.new(10, 1, 1), 1)
		local byTime = prediction.BuildSnapshots(state)
		local packet = codec.ConvertSimulationSnapshotToPackets(byTime[1])[1]
		prediction.RecordSent(state, packet, 1)
		prediction.ClearPending(state)
		for offset, ox, oy, oz, count in codec.ForEachCellHeader(packet) do
			for id, px, py, pz, vx, vy, vz in codec.ForEachBoid(packet, offset, count) do
				local v = Vector3.new(vx, vy, vz)
				local p = Vector3.new(ox + px, oy + py, oz + pz) + v * 60
				local origin = Vector3.new((p.X // 64) * 64, (p.Y // 64) * 64, (p.Z // 64) * 64)
				t.expect.falsy(consider(state, id, p, v, 61, 4, 2, origin))
			end
		end
	end)

	t.test("pending rows coalesce, stale rows cannot replace them, and retirement permits ID reuse", function()
		local state = prediction.New()
		consider(state, 1, Vector3.one, Vector3.xAxis, 1)
		consider(state, 2, Vector3.one * 2, Vector3.xAxis, 1)
		consider(state, 1, Vector3.one * 3, Vector3.yAxis, 3)
		t.expect.falsy(consider(state, 1, Vector3.one * 2, Vector3.xAxis, 2))
		t.expect.equal(state.count, 2)
		prediction.Discard(state, 2)
		t.expect.equal(state.count, 1)
		local byTime, times = prediction.BuildSnapshots(state)
		t.expect.equal(times[1], 3)
		t.expect.equal(byTime[3][1].boidCount, 1)
		send(state)
		t.expect.falsy(consider(state, 1, Vector3.one, Vector3.xAxis, 2))
		prediction.Discard(state, 1)
		t.expect.equal(state.baselineCount, 0)
		t.expect.truthy(consider(state, 1, Vector3.one, Vector3.xAxis, 4))
	end)

	t.test("pending correction is cancelled when a newer state rejoins the sent trajectory", function()
		local state = prediction.New()
		consider(state, 1, Vector3.one * 20, Vector3.xAxis, 1)
		send(state)
		consider(state, 1, Vector3.one * 40, Vector3.yAxis * 20, 1.1)
		t.expect.equal(state.count, 1)
		t.expect.falsy(consider(state, 1, Vector3.one * 20, Vector3.xAxis, 1.2))
		t.expect.equal(state.count, 0)
	end)

	t.test("dropped unsent batches do not advance prediction baselines", function()
		local state = prediction.New()
		consider(state, 1, Vector3.one * 20, Vector3.xAxis, 1)
		prediction.ClearPending(state)
		t.expect.equal(state.baselineCount, 0)
		t.expect.truthy(consider(state, 1, Vector3.one * 20, Vector3.xAxis, 2))
		send(state)
		consider(state, 1, Vector3.one * 40, Vector3.yAxis * 20, 3)
		prediction.ClearPending(state)
		t.expect.truthy(consider(state, 1, Vector3.one * 40, Vector3.yAxis * 20, 4))
	end)

	t.test("large mixed-time batches split packets and preserve distinct signed origins", function()
		local state = prediction.New()
		for id = 1, 300 do
			local origin = if id % 2 == 0 then Vector3.new(-64, 64, 0) else Vector3.zero
			consider(state, id, origin + Vector3.one * 20, Vector3.xAxis, if id % 3 == 0 then 2 else 1, 4, 2, origin)
		end
		local byTime, times = prediction.BuildSnapshots(state)
		t.expect.equal(#times, 2)
		t.expect.equal(times[1], 1)
		t.expect.equal(times[2], 2)
		local packets = codec.ConvertSimulationSnapshotToPackets(byTime[1])
		t.expect.truthy(#packets > 1)
		for _, packet in packets do t.expect.truthy(buffer.len(packet) <= codec.MAX_PACKET_BYTES) end
		t.expect.equal(send(state), 300)
		t.expect.equal(state.baselineCount, 300)
		t.expect.truthy(prediction.GetBufferBytes(state) > 300 * 33)
	end)

	t.test("sending a full packet retains partial pending rows and their source-time counts", function()
		local state = prediction.New()
		for id = 1, 125 do consider(state, id, Vector3.one * 20, Vector3.xAxis, 1) end
		consider(state, 300, Vector3.one * 20, Vector3.yAxis, 2)
		local byTime = prediction.BuildSnapshots(state)
		local packets = codec.ConvertSimulationSnapshotToPackets(byTime[1])
		t.expect.equal(prediction.RecordSent(state, packets[1], 1), 120)
		t.expect.equal(state.count, 6)
		t.expect.equal(state.rowsByTime[1], 5)
		t.expect.equal(state.rowsByTime[2], 1)
		t.expect.equal(send(state), 6)
		t.expect.equal(next(state.rowsByTime), nil)
		t.expect.equal(state.baselineCount, 126)
	end)

	t.test("metrics reads copy recipient state", function()
		transportMetrics.SetRecipientState(1234, 2, 100, 1)
		local first = transportMetrics.Read()
		first.recipients[1234].baselineCount = 999
		t.expect.equal(transportMetrics.Read().recipients[1234].baselineCount, 2)
		transportMetrics.RemoveRecipient(1234)
	end)
end
