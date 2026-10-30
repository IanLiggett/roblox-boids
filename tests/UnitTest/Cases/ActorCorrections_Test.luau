--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)
return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance) :: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local corrections = require(package.Boids.ActorCorrections)
	local codec = require(package.NetworkResults.PacketCodec)
	local function packet(id: number, x: number): buffer
		local cell = codec.NewCellSnapshot(1, Vector3.zero)
		codec.AppendBoid(cell, id, Vector3.new(x, 0, 0), Vector3.xAxis)
		return codec.ConvertSimulationSnapshotToPackets({cell})[1]
	end
	t.test("worker batch and correction handlers are registered in parallel", function()
		local template = game.ServerStorage.UnitTest.Fixtures.WorkerCoreStep01
		local FixtureTypes = require(template)
		local clone = template:Clone()
		clone.Parent = template.Parent
		local loadWorker: (ModuleScript) -> typeof(FixtureTypes) = require
		local core = loadWorker(clone)
		local registered: {[string]: boolean} = {}
		core.Start({
			BindToMessage = function(): () error("Actor control work registered serially") end,
			BindToMessageParallel = function(_: FixtureTypes.ActorDouble, topic: string, _handler: unknown): () registered[topic] = true end,
		})
		for _, topic in {"NewJob", "NewBoidsStatsBatch", "SetBoidReconciliationTargets", "RetireCorrections", "RetireBoids"} do
			t.expect.truthy(registered[topic])
		end
		clone:Destroy()
	end)
	t.test("decoded targets update stable records and reject reordered rows in the same pass", function()
		local state: corrections.State = {}
		local record = assert(corrections.Register(state, 7, 10, true))
		corrections.Consume(state, packet(7, 1), 1, 10)
		corrections.Consume(state, packet(7, 4), 2, 10)
		local position = record.position
		corrections.Consume(state, packet(7, 8), 1, 10)
		corrections.Consume(state, packet(7, 8), 2, 10)
		t.expect.equal(state[7], record)
		t.expect.equal(record.position, position)
		t.expect.equal(record.snapshotTime, 2)
		t.expect.equal(record.expiresAt, 8)
	end)
	t.test("correction before stats is retained only if the lifetime existed at forwarding", function()
		local state: corrections.State = {}
		corrections.Consume(state, packet(7, 4), 2, 10)
		local record = assert(corrections.Register(state, 7, 10, true))
		t.expect.equal(record.snapshotTime, 2)
		corrections.Consume(state, packet(8, 4), 2, 10)
		local future = assert(corrections.Register(state, 8, 11, true))
		t.expect.equal(future.expiresAt, 0)
	end)
	t.test("ownership uses lifecycle metadata across the full u16 range", function()
		local state: corrections.State = {}
		local localBoid = assert(corrections.Register(state, 0, 1, false))
		local replica = assert(corrections.Register(state, 65535, 2, true))
		corrections.Consume(state, packet(0, 4), 2, 2)
		corrections.Consume(state, packet(65535, 4), 2, 2)
		t.expect.equal(localBoid.expiresAt, 0)
		t.expect.equal(replica.snapshotTime, 2)
	end)
	t.test("retirement and lifetime ceilings fence old packets and delayed controls", function()
		local state: corrections.State = {}
		corrections.Register(state, 7, 10, true)
		corrections.Consume(state, packet(7, 4), 2, 10)
		corrections.Retire(state, 7, 10, 3)
		t.expect.equal(corrections.Register(state, 7, 10, true), nil)
		local replacement = assert(corrections.Register(state, 7, 11, true))
		corrections.Consume(state, packet(7, 4), 4, 10)
		corrections.Consume(state, packet(7, 4), 2, 11)
		t.expect.equal(replacement.expiresAt, 0)
		corrections.Consume(state, packet(7, 5), 4, 11)
		corrections.Retire(state, 7, 10, 3)
		t.expect.equal(replacement.snapshotTime, 4)
	end)
	t.test("trusted truncated rows fail at decoding without a validation traversal", function()
		local data = packet(7, 1)
		local truncated = buffer.create(buffer.len(data) - 1)
		buffer.copy(truncated, 0, data, 0, buffer.len(truncated))
		t.expect.throws(function(): () corrections.Consume({}, truncated, 2, 10) end)
	end)
end
