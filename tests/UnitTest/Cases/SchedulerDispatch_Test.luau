--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
	local package = (game:GetService("ReplicatedStorage"):WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
	local Scheduler=require(package.Boids.Scheduler)
	local SharedTypes=require(package.SharedTypes)
	local DispatchPump=require(package.Boids.JobBuilder.DispatchPump)
	local FixtureTypes = require(script.Parent.Parent.Fixtures.SchedulerDispatch)
	type Pages = FixtureTypes.Pages
	type Cell = FixtureTypes.Cell
	type Group = FixtureTypes.Group
	type Actor = FixtureTypes.Actor
	type Job = FixtureTypes.Job
	type CapturedJob = Job & {group: Group, actor: Actor}
	type Builder = FixtureTypes.Builder
	type Environment = FixtureTypes.Environment
	type Fixture = {
		now: number, clock: number, groups: {[number]: Group}, jobs: {CapturedJob}, samples: {[string]: number},
		actors: {Actor}, dispatchCost: number?, builder: Builder,
		group: (number, number, number) -> SharedTypes.Schedulee<Cell>,
		assign: (number?) -> (DispatchPump.StopReason, number?),
	}
	local create: (Environment) -> Builder = FixtureTypes
	local function fixture(): Fixture
		local f={now=100,clock=0,groups={} :: {[number]: Group},jobs={} :: {CapturedJob},
			samples={} :: {[string]: number},actors={{ready=true,targetJobWork=1},{ready=true,targetJobWork=1}} :: {Actor},
			dispatchCost=nil :: number?}
		local environment: Environment={
			RunService={IsClient=function(): boolean return false end},
			workspace={GetServerTimeNow=function(): number return f.now end},
			Clock=function(): number return f.clock end,
			Schedulers=Scheduler,
			ActorsInitializer={actors=f.actors,IsActorFree=function(actor: Actor): boolean return actor.ready end},
			BoidStorage={MarkPagesPending=function(pages: Pages): () t.expect.falsy(pages.pending);pages.pending=true end},
			ViewerLOD={GetInterestedPlayersForCell=function(): ({number}, boolean) return {},false end},
			RuntimeMetrics={State={},Add=function(): () end,Sample=function(_: {},name: string,value: number): () f.samples[name]=value end},
			ResultCommit={Run=function(group: Group,actor: Actor,job: Job): ()
				t.expect.truthy(actor.ready);actor.ready=false
				job.group=group;job.actor=actor
				table.insert(f.jobs,job :: CapturedJob)
				f.clock+=f.dispatchCost or 0
			end},
		}
		for _,actor in f.actors do actor.targetJobWork=1 end
		f.builder=create(environment)
		function f.group(id: number, due: number, count: number): SharedTypes.Schedulee<Cell>
			local scheduler: SharedTypes.Scheduler<Cell> = Scheduler.NewScheduler(function(s: SharedTypes.Schedulee<Cell>): number return s.nextDue end,function(s: SharedTypes.Schedulee<Cell>,now: number): boolean
				return not s.alreadyScheduled and s.entity.boidCount>0 and s.nextDue<=now
			end)
			local group: Group={id=id,cellCount=1,scheduler=scheduler,usesPath=false,averageSight=16}
			local cell: Cell={id=id,origin=Vector3.zero,boidCount=count,pages={pageCount=1}}
			local schedulee=Scheduler.NewSchedulee(scheduler,cell,1)
			schedulee.nextDue=due;Scheduler.EnqueueSchedulee(scheduler,schedulee)
			f.groups[id]=group
			return schedulee
		end
		function f.assign(deadline: number?): (DispatchPump.StopReason, number?)
			f.builder.TestSetRegistry(f.groups)
			return f.builder.TestAssign(deadline or 1,"completion")
		end
		return f
	end

	t.test("oldest due group wins across prediction and local ID spaces",function()
		local f=fixture();f.group(1,99,4000);f.group(32768,98,4000)
		f.assign()
		t.expect.equal(f.jobs[1].group.id,32768);t.expect.equal(f.jobs[2].group.id,1)
		t.expect.equal(f.jobs[1].jobCells[1].scheduledBoidCount,4000)
	end)
	t.test("a completed Actor refills due work before the next frame",function()
		local f=fixture();f.group(1,99,1);f.group(2,99,1);f.group(3,99,1)
		f.assign();t.expect.equal(#f.jobs,2)
		f.actors[1].ready=true
		f.assign();t.expect.equal(#f.jobs,3)
	end)
	t.test("reservations exclude duplicate assignment and future work stays pending",function()
		local f=fixture();local due=f.group(1,99,1);local future=f.group(2,101,1)
		local reason,delay=f.assign()
		t.expect.equal(#f.jobs,1);t.expect.truthy(due.alreadyScheduled)
		t.expect.falsy(future.alreadyScheduled);t.expect.equal(reason,"noDue");t.expect.near(assert(delay),1)
		f.actors[1].ready=true;f.assign();t.expect.equal(#f.jobs,1)
	end)
	t.test("one indivisible assignment can exhaust the epoch but no second job starts",function()
		local f=fixture();f.dispatchCost=0.002;f.group(1,99,4000);f.group(2,99,4000)
		local reason=f.assign(0.001)
		t.expect.equal(reason,"budget");t.expect.equal(#f.jobs,1)
	end)
	t.test("rotation gives the next free Actor first choice",function()
		local f=fixture();f.group(1,99,1);f.assign()
		f.actors[1].ready=true;f.group(2,99,1);f.assign()
		t.expect.equal(f.jobs[2].actor,f.actors[2])
	end)
	t.test("destroyed groups and stale empty heap entries cannot produce a job",function()
		local f=fixture();local empty=f.group(1,99,0);f.group(2,99,1);f.groups[2]=nil
		f.assign();t.expect.equal(#f.jobs,0);t.expect.falsy(empty.alreadyScheduled)
	end)
end
