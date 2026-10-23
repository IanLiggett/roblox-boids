--!strict

local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local network = require(package.NetworkResults)
	local intakeModule = require(package.SimulationReplication.CorrectionIntake)
	local replay = require(package.SimulationReplication.Replay)
	local bootstrapModule = require(package.SimulationReplication.Bootstrap)
	type Correction = {boidId: number, position: Vector3, velocity: Vector3, snapshotTime: number}
	type PlayerDouble = {Parent: Players?}
	type AdmissionDouble = {Request: (PlayerDouble, number) -> boolean, Forget: (PlayerDouble) -> ()}

	-- Admission uses only connection identity and Parent. The test keeps that
	-- structural double separate from the engine's nominal Player type.
	local function admission(sendState: () -> ()): AdmissionDouble
		return (bootstrapModule.New(function(_player: Player): () sendState() end) :: unknown) :: AdmissionDouble
	end

	local function packet(id: number): buffer
		local cell = network.NewCellSnapshot(1, Vector3.zero)
		network.AppendBoid(cell, id, Vector3.one, Vector3.xAxis)
		return network.ConvertSimulationSnapshotToPackets({cell})[1]
	end

	t.test("correction freshness, live lifetime and malformed packet rejection", function()
		local live, deleting = true, false
		local received: {Correction} = {}
		local intake = intakeModule.New({
			IsServerBoid = function(): boolean return live end,
			IsDeletionPending = function(): boolean return deleting end,
			SetReconciliationTargets = function(data: buffer, snapshotTime: number, accept: (number, Vector3, Vector3, number) -> boolean): ()
				for offset, ox, oy, oz, count in network.ForEachCellHeader(data) do
					for id, px, py, pz, vx, vy, vz in network.ForEachBoid(data, offset, count) do
						local position, velocity = Vector3.new(ox+px, oy+py, oz+pz), Vector3.new(vx, vy, vz)
						if accept(id, position, velocity, snapshotTime) then
							table.insert(received, {boidId=id, position=position, velocity=velocity, snapshotTime=snapshotTime})
						end
					end
				end
			end,
		})
		local data = packet(7)
		intake.Consume(data, 10)
		intake.Consume(data, 9)
		intake.Consume(data, 10)
		t.expect.equal(#received, 1)
		intake.Consume(data, 11)
		t.expect.equal(#received, 2)
		live = false
		intake.Consume(data, 12)
		live, deleting = true, true
		intake.Consume(data, 12)
		t.expect.equal(#received, 2)
		deleting = false
		intake.Retire(7, 12)
		intake.Consume(data, 11)
		intake.Consume(data, 12)
		intake.Consume(data, 13)
		t.expect.equal(#received, 3)
		t.expect.equal(received[3].snapshotTime, 13)
		intake.Consume(data, 0/0)
		intake.Consume(data, math.huge)
		intake.Consume(buffer.create(1), 14)
		local truncated = buffer.create(buffer.len(data) - 1)
		buffer.copy(truncated, 0, data, 0, buffer.len(truncated))
		intake.Consume(truncated, 14)
		t.expect.equal(#received, 3)
		intake.Consume(data, 14)
		t.expect.equal(#received, 4)
	end)

	t.test("correction duplicates in one packet only reach steering once", function()
		local calls = 0
		local cell = network.NewCellSnapshot(2, Vector3.zero)
		network.AppendBoid(cell, 7, Vector3.one, Vector3.zero)
		network.AppendBoid(cell, 7, Vector3.one * 2, Vector3.zero)
		local intake = intakeModule.New({
			IsServerBoid = function(): boolean return true end,
			IsDeletionPending = function(): boolean return false end,
			SetReconciliationTargets = function(data: buffer, snapshotTime: number, accept: (number, Vector3, Vector3, number) -> boolean): ()
				for offset, _ox, _oy, _oz, count in network.ForEachCellHeader(data) do
					for id in network.ForEachBoid(data, offset, count) do
						if accept(id, Vector3.zero, Vector3.zero, snapshotTime) then calls += 1 end
					end
				end
			end,
		})
		intake.Consume(network.ConvertSimulationSnapshotToPackets({cell})[1], 1)
		t.expect.equal(calls, 1)
	end)

	t.test("client-local ownership rejects corrections across the full u16 range", function()
		local isServer = false
		local calls = 0
		local intake = intakeModule.New({
			IsServerBoid = function(): boolean return isServer end,
			IsDeletionPending = function(): boolean return false end,
			SetReconciliationTargets = function(data: buffer, snapshotTime: number, accept: (number, Vector3, Vector3, number) -> boolean): ()
				for offset, _ox, _oy, _oz, count in network.ForEachCellHeader(data) do
					for id in network.ForEachBoid(data, offset, count) do
						if accept(id, Vector3.zero, Vector3.zero, snapshotTime) then calls += 1 end
					end
				end
			end,
		})
		intake.Consume(packet(0), 1)
		intake.Consume(packet(65535), 1)
		t.expect.equal(calls, 0)
		isServer = true
		intake.Consume(packet(65535), 2)
		t.expect.equal(calls, 1)
		intake.Retire(65535, 3)
		isServer = false
		intake.Consume(packet(65535), 4)
		t.expect.equal(calls, 1)
	end)

	t.test("replay uses settled pose, preserves recipes and excludes retired state", function()
		local recipe: {id: number, position: Vector3, velocity: Vector3, maxSpeed: number, model: number} = {id=1, position=Vector3.zero, velocity=Vector3.zero, maxSpeed=20, model=0}
		local records = replay.CopyBoids({[1]=recipe :: replay.BoidSpawnRecord, [2]=table.clone(recipe) :: replay.BoidSpawnRecord}, function(id: number): (Vector3?, Vector3?)
			if id == 2 then return nil, nil end
			return Vector3.new(100, 20, 30), Vector3.xAxis * 10
		end)
		t.expect.equal(#records, 1)
		t.expect.equal(records[1].position, Vector3.new(100, 20, 30))
		t.expect.equal(records[1].velocity, Vector3.xAxis * 10)
		t.expect.equal(records[1].maxSpeed, 20)
		t.expect.equal(recipe.position, Vector3.zero)
		t.expect.falsy(records[1] == recipe)
	end)

	t.test("bootstrap admits one successful replay and suppresses reentrant/duplicate requests", function()
		local player: PlayerDouble = {Parent=game:GetService("Players")}
		local count = 0
		local bootstrap: AdmissionDouble
		bootstrap = admission(function(): ()
			count += 1
			t.expect.falsy(bootstrap.Request(player, 100))
		end)
		t.expect.truthy(bootstrap.Request(player, 10))
		for i = 1, 100 do t.expect.falsy(bootstrap.Request(player, 10+i)) end
		t.expect.equal(count, 1)
		bootstrap.Forget(player)
		player.Parent = nil
		t.expect.falsy(bootstrap.Request(player, 200))
		local replacement: PlayerDouble = {Parent=game:GetService("Players")}
		t.expect.truthy(bootstrap.Request(replacement, 200))
		t.expect.equal(count, 2)
	end)

	t.test("failed bootstrap retries have a cooldown and a finite connection budget", function()
		local count = 0
		local player: PlayerDouble = {Parent=game:GetService("Players")}
		local bootstrap: AdmissionDouble = admission(function(): () count += 1; error("expected injected bootstrap failure") end)
		bootstrap.Request(player, 10)
		bootstrap.Request(player, 11)
		t.expect.equal(count, 1)
		bootstrap.Request(player, 15)
		bootstrap.Request(player, 20)
		bootstrap.Request(player, 30)
		t.expect.equal(count, 3)
	end)
end
