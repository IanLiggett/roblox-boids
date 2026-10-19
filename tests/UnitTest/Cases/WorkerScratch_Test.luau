--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game:GetService("ReplicatedStorage"):WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local storage = require(package.BoidStorage)
	local template = game.ServerStorage.UnitTest.Fixtures.WorkerCoreStep01
	local FixtureTypes = require(template)
	-- A clone has the template's contract, but owns an isolated require cache.
	local loadWorker: (ModuleScript) -> typeof(FixtureTypes) = require
	local SharedTypes = require(package.SharedTypes)

	local function worker(): (FixtureTypes.Core, FixtureTypes.Handlers, ModuleScript)
		local clone = template:Clone()
		clone.Parent = template.Parent
		local registrations: {[string]: unknown} = {}
		local actor: FixtureTypes.ActorDouble = {
			BindToMessageParallel=function(_: FixtureTypes.ActorDouble, topic: string, callback: unknown): () registrations[topic]=callback end,
			BindToMessage=function(_: FixtureTypes.ActorDouble, topic: string, callback: unknown): () registrations[topic]=callback end,
		}
		local core: FixtureTypes.Core = loadWorker(clone)
		core.Start(actor)
		local handlers: FixtureTypes.Handlers = registrations :: FixtureTypes.Handlers
		local stats=buffer.create(160*16)
		for index=0,159 do
			buffer.writeu16(stats,index*16,index+1)
			buffer.writeu8(stats,index*16+2,20)
			buffer.writeu8(stats,index*16+3,1)
			buffer.writeu8(stats,index*16+4,16)
		end
		handlers.NewBoidsStatsBatch({boidCount=160,data=stats,lifetimes=table.create(160,1)})
		handlers.NewGroupTarget(1,{Position=Vector3.new(1000,40,40)},1)
		return core,handlers,clone
	end

	local function job(counts: {number}, position: number): FixtureTypes.Input
		local cells: {FixtureTypes.Cell} = {}
		for cellId,count in counts do
			local pages: {SharedTypes.Page} = {}
			for start=0,count-1,64 do
				local size=math.min(64,count-start)
				local page: SharedTypes.Page={id=#pages+1,setId=1,index=#pages+1,size=size,deadCount=0,
					firstDeadWord=0,cursor=size,data=buffer.create(1024),dead=buffer.create(8)}
				for slot=0,size-1 do
					storage.WriteBoidId(page.data,slot,start+slot+1)
					storage.WritePosition(page.data,slot,position,40,40)
					storage.WriteVelocity(page.data,slot,1,0,0)
					storage.WriteSpeed(page.data,slot,20)
					storage.WriteLastTick(page.data,slot,99)
				end
				table.insert(pages,page)
			end
			table.insert(cells,{id=cellId,origin=Vector3.zero,networkTick=1,networkInterval=1,emitSnapshot=true,
				pages={pages=pages,pageCount=#pages,openPages={},pendingPages={}},pageCount=#pages,
				scheduledBoidCount=count,processedBoidCount=0,boidCount=count})
		end
		return {id=1,groupId=1,usesPath=false,jobCells=cells,averageSight=16,detailedMetrics=true,movedBoids={}}
	end

	local function execute(handlers: FixtureTypes.Handlers, input: FixtureTypes.Input): (FixtureTypes.Result?, string?)
		local result: FixtureTypes.Result?
		local failure: string?
		handlers.NewJob(input,{Fire=function(_: FixtureTypes.Reply,value: FixtureTypes.Result?,_delay: number?,err: string?): () result=value;failure=err end},1,100/60)
		return result,failure
	end

	local function sameResult(actual: FixtureTypes.Result?, expected: FixtureTypes.Result?): ()
		t.expect.truthy(actual)
		assert(actual and expected)
		t.expect.equal(actual.measurement.processedBoids,expected.measurement.processedBoids)
		for index,cell in expected.jobCells do
			for pageIndex,page in cell.pages.pages do
				t.expect.equal(buffer.tostring(actual.jobCells[index].pages.pages[pageIndex].data),buffer.tostring(page.data))
			end
		end
		for sourceId,snapshots in expected.snapshotGroups do
			for cellId,cell in snapshots do
				t.expect.equal(buffer.tostring(actual.snapshotGroups[sourceId][cellId].networkBoids),buffer.tostring(cell.networkBoids))
			end
		end
	end

	for _,failsInner in {false,true} do
		t.test("overlapping scratch stays isolated after " .. (if failsInner then "worker failure" else "successful work"),function()
			local controlCore,control,controlClone=worker()
			local expected=execute(control,job({128,3,129},40))
			local core,handlers,clone=worker()
			t.expect.truthy(core ~= controlCore)
			local paused=false
			local shouldFail=false
			core.SetTestRaycastProvider(function(): FixtureTypes.RaycastHit?
				if shouldFail then shouldFail=false;error("injected scratch-isolation failure") end
				if not paused then paused=true;coroutine.yield() end
				return nil
			end)
			local actual: FixtureTypes.Result?
			local outer=coroutine.create(function() actual=execute(handlers,job({128,3,129},40)) end)
			local ok,err=coroutine.resume(outer);assert(ok,tostring(err))
			t.expect.equal(coroutine.status(outer),"suspended")
			shouldFail=failsInner
			local inner,failure=execute(handlers,job({140},80))
			if failsInner then t.expect.truthy(failure) else t.expect.truthy(inner) end
			ok,err=coroutine.resume(outer);assert(ok,tostring(err))
			t.expect.equal(coroutine.status(outer),"dead")
			sameResult(actual,expected)
			-- A later invocation cannot mutate buffers already returned by the outer job.
			execute(handlers,job({150},90))
			sameResult(actual,expected)
			sameResult(execute(handlers,job({128,3,129},40)),expected)
			clone:Destroy();controlClone:Destroy()
		end)
	end
end
