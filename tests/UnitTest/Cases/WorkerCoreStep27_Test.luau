--!strict
-- Step 27 characterization fixtures. These preserve observed behavior; they do not define a preferred flocking algorithm.
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game:GetService("ReplicatedStorage"):WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local Storage = require(package.BoidStorage)
	local template = game.ServerStorage.UnitTest.Fixtures.WorkerCoreStep01
	local FixtureTypes = require(template)
	-- A clone has the template's contract, but owns an isolated require cache.
	local loadWorker: (ModuleScript) -> typeof(FixtureTypes) = require
	local SharedTypes = require(package.SharedTypes)
	local cloneId = 0

	type Row = {position: Vector3, velocity: Vector3, speed: number?, lastTick: number?}
	type StatsSpec = {
		maxSpeed: number?, minSpeed: number?, sight: number?, avoidance: number?, separation: number?,
		repulsion: number?, repulsionStrength: number?, alignment: number?, cohesion: number?, targetBias: number?,
	}

	local function run(rows: {Row}, stats: {StatsSpec}): FixtureTypes.Result
		cloneId += 1
		local clone = template:Clone()
		clone.Name = "RunningStep27Fixture_" .. cloneId
		clone.Parent = template.Parent
		local ok, result = pcall(function(): FixtureTypes.Result
			local registrations: {[string]: unknown} = {}
			local actor = {}
			function actor.BindToMessageParallel(_self: FixtureTypes.ActorDouble, name: string, fn: unknown): () registrations[name] = fn end
			function actor.BindToMessage(_self: FixtureTypes.ActorDouble, name: string, fn: unknown): () registrations[name] = fn end
			local core: FixtureTypes.Core = loadWorker(clone)
			core.Start(actor)
			local handlers: FixtureTypes.Handlers = registrations :: FixtureTypes.Handlers
			local count = #rows
			local batch = buffer.create(count * 16)
			for index, spec in stats do
				local offset = (index - 1) * 16
				buffer.writeu16(batch, offset, index)
				buffer.writeu8(batch, offset + 2, spec.maxSpeed or 20)
				buffer.writeu8(batch, offset + 3, spec.minSpeed or 1)
				buffer.writeu8(batch, offset + 4, spec.sight or 16)
				buffer.writeu8(batch, offset + 5, spec.avoidance or 0)
				buffer.writeu8(batch, offset + 6, spec.separation or 0)
				buffer.writeu8(batch, offset + 7, spec.repulsion or 0)
				buffer.writeu8(batch, offset + 8, spec.repulsionStrength or 1)
				buffer.writeu8(batch, offset + 9, spec.alignment or 0)
				buffer.writeu8(batch, offset + 10, spec.cohesion or 0)
				buffer.writeu8(batch, offset + 11, spec.targetBias or 0)
			end
			handlers.NewBoidsStatsBatch({ boidCount = count, data = batch, lifetimes = table.create(count, 1) })
			local pages: {SharedTypes.Page} = {}
			for start = 1, count, 64 do
				local size = math.min(64, count - start + 1)
				local page: SharedTypes.Page = { id = #pages + 1, setId = 1, index = #pages + 1, size = size, deadCount = 0, firstDeadWord = 0, cursor = size, data = buffer.create(1024), dead = buffer.create(8) }
				for localSlot = 0, size - 1 do
					local slot = start + localSlot
					local row = rows[slot]
					Storage.WriteBoidId(page.data, localSlot, slot)
					Storage.WritePosition(page.data, localSlot, row.position.X, row.position.Y, row.position.Z)
					Storage.WriteVelocity(page.data, localSlot, row.velocity.X, row.velocity.Y, row.velocity.Z)
					Storage.WriteSpeed(page.data, localSlot, row.speed or 20)
					Storage.WriteLastTick(page.data, localSlot, row.lastTick or 99)
				end
				table.insert(pages, page)
			end
			local cell: FixtureTypes.Cell = { id = 1, origin = Vector3.zero, networkTick = 1, networkInterval = 1, emitSnapshot = false, pages = { id = 1, pages = pages, openPages = {}, pendingPages = {}, pageCount = #pages }, pageCount = #pages, scheduledBoidCount = count, processedBoidCount = 0, boidCount = count }
			local job: FixtureTypes.Input = { id = 1, groupId = 1, usesPath = false, jobCells = { cell }, movedBoids = {}, cellCount = 1, startTime = 0, completionTime = -1, estimatedCost = 1, averageSight = 16, detailedMetrics = true }
			local returned: FixtureTypes.Result?
			handlers.NewJob(job, { Fire = function(_: FixtureTypes.Reply, value: FixtureTypes.Result?, _delay: number?, _failure: string?): () returned = value end }, 1, 100 / 60)
			return assert(returned, "Worker fixture did not return a result")
		end)
		clone:Destroy()
		assert(ok, tostring(result))
		return result
	end

	local function specs(count: number, override: StatsSpec?): {StatsSpec}
		local result: {StatsSpec} = table.create(count) :: {StatsSpec}
		for index = 1, count do result[index] = override and table.clone(override) or {} end
		return result
	end

	-- Records the no-neighbor baseline without treating it as a behavior correction.
	t.test("isolated boid has no contributing neighbors", function()
		local job = run({ { position = Vector3.new(64, 64, 64), velocity = Vector3.new(1, 0, 0) } }, specs(1, { cohesion = 20 }))
		t.expect.equal(job.measurement.candidateExaminations, 1)
		t.expect.equal(job.measurement.acceptedDirectInteractions, 0)
		t.expect.equal(job.measurement.processedBoids, 1)
	end)

	-- Captures the quantized inside/outside sight edge and asymmetric per-neighbor repulsion.
	t.test("radius edges and heterogeneous repulsion preserve asymmetric candidates", function()
		local inside = run({ { position = Vector3.new(40, 40, 40), velocity = Vector3.xAxis }, { position = Vector3.new(55, 40, 40), velocity = Vector3.xAxis } }, specs(2))
		local outside = run({ { position = Vector3.new(40, 40, 40), velocity = Vector3.xAxis }, { position = Vector3.new(57, 40, 40), velocity = Vector3.xAxis } }, specs(2))
		local heterogeneous = run({ { position = Vector3.new(40, 40, 40), velocity = Vector3.xAxis }, { position = Vector3.new(60, 40, 40), velocity = Vector3.xAxis } }, { {}, { repulsion = 32 } })
		t.expect.equal(inside.measurement.acceptedDirectInteractions, 2)
		t.expect.equal(outside.measurement.acceptedDirectInteractions, 0)
		t.expect.equal(heterogeneous.measurement.acceptedDirectInteractions, 1)
	end)

	-- Captures the 100/101 dense-cell algorithm switch without treating either result as a correction target.
	t.test("100 and 101 occupants retain distinct neighbor accounting", function()
		local function rows(count: number): {Row}
			local result: {Row} = table.create(count) :: {Row}
			for index = 1, count do result[index] = { position = Vector3.new(64, 64, 64), velocity = Vector3.xAxis } end
			return result
		end
		local hundred = run(rows(100), specs(100))
		local hundredOne = run(rows(101), specs(101))
		t.expect.equal(hundred.measurement.candidateExaminations, 10000)
		t.expect.equal(hundredOne.measurement.candidateExaminations, 10200)
		t.expect.equal(hundredOne.measurement.acceptedDirectInteractions, 10100)
	end)

	-- Exercises coincident vectors, u8 edges, tick wrap, and a cell migration in one deterministic fixture.
	t.test("coincident and boundary rows remain processable across tick wrap", function()
		local job = run({
			{ position = Vector3.new(0, 64, 64), velocity = Vector3.xAxis, lastTick = 65535 },
			{ position = Vector3.new(0, 64, 64), velocity = Vector3.xAxis, lastTick = 65535 },
			{ position = Vector3.new(128, 64, 64), velocity = Vector3.xAxis },
		}, specs(3))
		t.expect.equal(job.measurement.processedBoids, 3)
		t.expect.equal(job.measurement.migratedBoids, 1)
		t.expect.equal(job.jobCells[1].boidCount, 2)
	end)
end
