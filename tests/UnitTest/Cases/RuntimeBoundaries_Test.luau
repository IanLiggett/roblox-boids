--!strict
return function(t: any): ()
	local package = game.ReplicatedStorage.BoidsReplicated
	local diagnostics = require(package.Boids.Diagnostics)
	local benchmarkers = require(package.Dependencies.Benchmarker.Value)

	local function fixture(): (any, any)
		local stats = benchmarkers.newBenchmarker(10)
		benchmarkers.push(stats, 4)
		benchmarkers.push(stats, 8)
		local group: any = {
			id=17,boidCount=6,cellCount=2,
			jobMsStats=stats,neighborItersPerJob=stats,jobSendStats=stats,jobReceiveStats=stats,
			cellsPerSecond=stats,boidsPerSecond=stats,
			scheduler={schedulees={
				[1]={entity={id=1,boidCount=4},alreadyScheduled=false,lastUpdated=workspace:GetServerTimeNow()-2},
				[2]={entity={id=2,boidCount=2},alreadyScheduled=true,lastUpdated=workspace:GetServerTimeNow()-1},
			}},
		}
		return {[17]=group}, {{timeIdleStats=stats,completedJobs=2,processedBoids=6,workerExecutionMs=12}}
	end

	t.test("diagnostic reads copy nested data and preserve group/cell ownership", function()
		local groups, actors = fixture()
		local function isDue(cell: any, _: number): boolean return not cell.alreadyScheduled end
		local first = diagnostics.Read(groups, actors, isDue, true)
		t.expect.equal(first.summary.groupCount,1)
		t.expect.equal(first.summary.population,6)
		t.expect.equal(first.summary.cellCount,2)
		t.expect.equal(first.summary.actorCount,1)
		t.expect.equal(first.cells.total,2)
		t.expect.equal(first.cells.valid,1)
		t.expect.equal(first.cells.scheduled,1)
		t.expect.equal(first.cells.maxPopulation,4)
		t.expect.equal(first.groups[1].jobMs.average,6)
		t.expect.equal(first.actors[1].idleSeconds.sampleCount,2)
		local function onlyValues(value: any): ()
			if type(value) == "table" then
				for _, child in value do onlyValues(child) end
			else
				t.expect.truthy(type(value)=="number" or type(value)=="boolean" or type(value)=="string")
			end
		end
		onlyValues(first)
		first.groups[1].jobMs.average = 999
		first.actors[1].idleSeconds.sampleCount = 999
		first.summary.population = 999
		local second = diagnostics.Read(groups, actors, isDue, true)
		t.expect.equal(second.groups[1].jobMs.average,6)
		t.expect.equal(second.actors[1].idleSeconds.sampleCount,2)
		t.expect.equal(second.summary.population,6)
		t.expect.falsy(groups[17].scheduler.schedulees[1].alreadyScheduled)
	end)

	t.test("minimal and empty diagnostics keep unavailable measurements explicit", function()
		local groups, actors = fixture()
		local empty = benchmarkers.newBenchmarker(10)
		actors[1].timeIdleStats = empty
		local snapshot = diagnostics.Read(groups,actors,function(): boolean return false end,false)
		t.expect.equal(snapshot.groups[1].neighborWorkPerJob,nil)
		t.expect.equal(snapshot.actors[1].idleSeconds.minimum,nil)
		t.expect.equal(snapshot.actors[1].idleSeconds.maximum,nil)
		t.expect.equal(snapshot.actors[1].idleSeconds.sampleCount,0)
		local summary = diagnostics.ReadSummary({},0)
		t.expect.equal(summary.groupCount,0)
		t.expect.equal(summary.population,0)
		t.expect.equal(summary.actorCount,0)
	end)
end
