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

	t.test("correction relay forwards the original trusted buffer without a row walk", function()
        local data = buffer.create(1)
        local received: buffer? = nil
        local time = 0
        local retired = 0
        local intake = intakeModule.New({
            SetReconciliationTargets = function(packet: buffer, sourceTime: number): () received=packet;time=sourceTime end,
            RetireReconciliationTargets = function(ids: {number}, cutoff: number?): () retired=ids[1];time=cutoff or 0 end,
        })
        intake.Consume(data, 12)
        t.expect.equal(received, data)
        t.expect.equal(time, 12)
        intake.Retire({7}, 13)
        t.expect.equal(retired, 7)
        t.expect.equal(time, 13)
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
