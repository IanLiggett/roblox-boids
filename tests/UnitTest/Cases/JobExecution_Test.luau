--!strict
return function(t: any): ()
	local package = game.ReplicatedStorage:WaitForChild("BoidsReplicated")
	local executionFixture = package.Boids.ActorsInitializer.JobExecution:Clone()
	executionFixture.Name = "JobExecutionUnitFixture"
	executionFixture.Parent = package.Boids.ActorsInitializer
	local execution = require(executionFixture)
	local reusableCounts: {[any]: number} = {}
	execution.SetOnActorReusable(function(actor: any): ()
		t.expect.truthy(actor.ready)
		t.expect.equal(actor.execution,nil)
		reusableCounts[actor]=(reusableCounts[actor] or 0)+1
	end)
	local metrics = require(package.RuntimeMetrics).State
	local nextId = -100
	local function fixture(mode: string?): any
		nextId -= 1
		local reply: BindableEvent? = nil
		local group: any = {id = nextId}
		local job: any = {id = nextId, startTime = workspace:GetServerTimeNow() - 0.01, estimatedCost = 10,
			jobCells = {{scheduledBoidCount = 1}}}
		local actor = execution.NewActor({Parent = {SendMessage = function(_: any, name: string, sent: any, event: BindableEvent): ()
			t.expect.equal(name, "NewJob")
			t.expect.equal(sent, job)
			reply = event
			if mode == "dispatch_failed" then error("injected dispatch failure") end
			if mode == "immediate" then
				event:Fire({completionTime = workspace:GetServerTimeNow(), jobCells = {},
					measurement = {detailed=false,executionMs=1,scheduledBoids=1,processedBoids=1,skippedBoids=0,
					survivingBoids=1,migratedBoids=0,observedBoids=1,returnedSourceBoids=1}},0)
			end
		end}} :: any, workspace:GetServerTimeNow())
		local f: any = {actor=actor, group=group, job=job, commits=0, retires=0, outcome=nil, current=true}
		local callbacks: any = {
			IsCurrent = function(): boolean
				if mode == "owner_failed" then error("injected owner check failure") end
				return f.current
			end,
			Commit = function(): boolean
				f.commits += 1
				t.expect.falsy(actor.ready)
				if mode == "merge_failed" then error("injected merge failure") end
				if mode == "yield" then f.gate.Event:Wait() end
				return mode ~= "incomplete"
			end,
			Retire = function(outcome: string): ()
				t.expect.falsy(actor.ready)
				f.retires += 1
				f.outcome = outcome
			end,
		}
		f.gate = Instance.new("BindableEvent")
		f.record = execution.Start(actor, group, job, 0, 4, callbacks)
		f.reply = reply
		function f.result(): any
			return {completionTime = workspace:GetServerTimeNow(), jobCells={},
				measurement={detailed=false,executionMs=1,scheduledBoids=1,processedBoids=1,skippedBoids=0,
				survivingBoids=1,migratedBoids=0,observedBoids=1,returnedSourceBoids=1}}
		end
		function f.finish(): ()
			local event = reply :: BindableEvent
			event:Fire(f.result(),0)
			task.wait()
		end
		function f.cleanup(): ()
			if not actor.ready then
				execution.Cancel(f.record)
				local event = reply :: BindableEvent
				event:Fire(nil, 0, "test cleanup")
				task.wait()
			end
			f.gate:Destroy()
		end
		return f
	end

	t.test("page preflight rejects a bad later page before overwriting the first", function()
		local storage=require(package.BoidStorage)
		local dest=storage.NewPagedBuffer()
		local first=storage.newPage(dest)
		local second=storage.newPage(dest)
		dest.pages={first,second};dest.pageCount=2
		dest.openPages[first.id]=true;dest.openPages[second.id]=true
		storage.MarkPagesPending(dest)
		local original=first.data
		local a=table.clone(first);a.data=buffer.create(buffer.len(first.data))
		buffer.writeu8(a.data,0,91)
		local b=table.clone(second);b.id=-1
		t.expect.throws(function() storage.OverwriteWithJobResults(dest,{pages={a,b},pageCount=2},2) end)
		t.expect.equal(first.data,original)
		t.expect.equal(buffer.readu8(first.data,0),0)
		t.expect.truthy(dest.pendingPages[first.id]);t.expect.truthy(dest.pendingPages[second.id])
		storage.RestorePendingPages(dest)
		t.expect.equal(next(dest.pendingPages),nil)
		t.expect.truthy(dest.openPages[first.id]);t.expect.truthy(dest.openPages[second.id])
		storage.DeletePagedBuffer(dest.id)
		dest.pendingPages[first.id]=true;dest.openPages[first.id]=nil
		storage.RestorePendingPages(dest)
		t.expect.equal(dest.openPages[first.id],nil)
	end)
	t.test("subscribes before immediate reply and only releases after commit and retirement", function()
		local f=fixture("immediate")
		task.wait()
		t.expect.equal(f.commits,1);t.expect.equal(f.retires,1)
		t.expect.equal(f.outcome,"completed");t.expect.truthy(f.actor.ready)
		t.expect.equal(f.actor.execution,nil);t.expect.equal(f.record.phase,"complete")
		t.expect.truthy(f.actor.targetJobWork>=8)
		f.cleanup()
	end)
	t.test("busy reservation cannot be scheduled twice", function()
		local f=fixture()
		t.expect.throws(function() execution.Start(f.actor,{} :: any,{} :: any,0,4,{} :: any) end)
		f.finish();t.expect.equal(f.commits,1);f.cleanup()
	end)
	t.test("timeout retires once, quarantines scratch, and rejects late feedback/result", function()
		local base=metrics.counters.outstandingJobs
		local f=fixture()
		local cost=f.actor.avgMsPerWorkUnit
		execution.Expire(f.record);execution.Expire(f.record)
		t.expect.falsy(f.actor.ready);t.expect.equal(f.record.phase,"quarantined")
		t.expect.equal(f.record.job,nil);t.expect.equal(f.record.callbacks,nil);t.expect.equal(f.record.group,nil)
		t.expect.equal(f.retires,1);t.expect.equal(f.outcome,"timed_out")
		t.expect.equal(metrics.counters.outstandingJobs,base)
		f.finish()
		t.expect.truthy(f.actor.ready);t.expect.equal(f.commits,0);t.expect.equal(f.retires,1)
		t.expect.equal(f.actor.avgMsPerWorkUnit,cost)
		t.expect.equal(metrics.counters.outstandingJobs,base)
		f.cleanup()
	end)
	t.test("actual deadline timer quarantines a worker that never replied", function()
		local f=fixture()
		local deadline=os.clock()+6
		repeat task.wait(0.1) until f.record.phase=="quarantined" or os.clock()>deadline
		t.expect.equal(f.record.phase,"quarantined");t.expect.falsy(f.actor.ready)
		t.expect.equal(f.retires,1);t.expect.equal(f.outcome,"timed_out")
		f.finish();t.expect.truthy(f.actor.ready);f.cleanup()
	end)
	t.test("incomplete return retires without training adaptive feedback", function()
		local f=fixture("incomplete")
		local cost=f.actor.avgMsPerWorkUnit
		f.finish()
		t.expect.equal(f.outcome,"incomplete");t.expect.equal(f.retires,1)
		t.expect.truthy(f.actor.ready);t.expect.equal(f.actor.avgMsPerWorkUnit,cost);f.cleanup()
	end)
	t.test("late duplicate reply cannot finish a replacement execution", function()
		local f=fixture();execution.Expire(f.record);f.finish()
		local retired=0
		local replacement=execution.Start(f.actor,f.group,f.job,0,4,{
			IsCurrent=function() return true end, Commit=function() return true end,
			Retire=function() retired+=1 end,
		})
		f.reply:Fire(f.result(),0);task.wait()
		t.expect.equal(replacement.phase,"running");t.expect.falsy(f.actor.ready)
		t.expect.equal(retired,0)
		replacement.event:Fire(f.result(),0);task.wait()
		t.expect.truthy(f.actor.ready);t.expect.equal(retired,1);f.cleanup()
	end)
	t.test("cancelled work cannot commit even after group ID reuse", function()
		local f=fixture()
		execution.Cancel(f.record)
		f.current=true
		t.expect.falsy(f.actor.ready);t.expect.equal(f.outcome,"cancelled")
		f.finish();t.expect.truthy(f.actor.ready)
		t.expect.equal(f.commits,0);t.expect.equal(f.retires,1);f.cleanup()
	end)
	t.test("replaced owner at terminal reply discards work", function()
		local f=fixture();f.current=false;f.finish()
		t.expect.equal(f.commits,0);t.expect.equal(f.outcome,"cancelled")
		t.expect.truthy(f.actor.ready);f.cleanup()
	end)
	t.test("worker failure acknowledgement releases Actor and reservations once", function()
		local base=metrics.counters.outstandingJobs
		local f=fixture();f.reply:Fire(nil,0,"injected worker failure");task.wait()
		t.expect.equal(f.commits,0);t.expect.equal(f.outcome,"worker_failed")
		t.expect.equal(f.retires,1);t.expect.truthy(f.actor.ready)
		t.expect.equal(metrics.counters.outstandingJobs,base);f.cleanup()
	end)
	t.test("dispatch failure retires logical work without inventing completion", function()
		local f=fixture("dispatch_failed")
		t.expect.equal(f.outcome,"dispatch_failed");t.expect.equal(f.retires,1)
		t.expect.falsy(f.actor.ready);f.finish();t.expect.truthy(f.actor.ready)
		t.expect.equal(f.commits,0);t.expect.equal(f.retires,1);f.cleanup()
	end)
	t.test("commit error still retires and releases Actor", function()
		local f=fixture("merge_failed");f.finish()
		t.expect.equal(f.outcome,"merge_failed");t.expect.equal(f.retires,1)
		t.expect.truthy(f.actor.ready);f.cleanup()
	end)
	t.test("owner-check error still retires and releases Actor", function()
		local f=fixture("owner_failed");f.finish()
		t.expect.equal(f.outcome,"merge_failed");t.expect.equal(f.retires,1)
		t.expect.truthy(f.actor.ready);t.expect.equal(f.commits,0);f.cleanup()
	end)
	t.test("a yielding commit keeps Actor reserved and timer cannot retire it", function()
		local f=fixture("yield");f.reply:Fire(f.result(),0);task.wait()
		t.expect.equal(f.record.phase,"completing");t.expect.falsy(f.actor.ready)
		execution.Expire(f.record);t.expect.equal(f.retires,0)
		f.gate:Fire();task.wait()
		t.expect.truthy(f.actor.ready);t.expect.equal(f.outcome,"completed");f.cleanup()
	end)
	t.test("cancellation while commit is yielded waits for retirement", function()
		local f=fixture("yield");f.reply:Fire(f.result(),0);task.wait()
		execution.Cancel(f.record)
		t.expect.equal(f.retires,0);t.expect.falsy(f.actor.ready)
		f.gate:Fire();task.wait()
		t.expect.equal(f.outcome,"cancelled");t.expect.equal(f.retires,1)
		t.expect.truthy(f.actor.ready);f.cleanup()
	end)
	t.test("reusable notification follows physical release, never logical timeout",function()
		local f=fixture()
		execution.Expire(f.record)
		t.expect.equal(reusableCounts[f.actor],nil)
		f.finish()
		t.expect.equal(reusableCounts[f.actor],1)
		f.cleanup()
		local yielded=fixture("yield")
		yielded.reply:Fire(yielded.result(),0);task.wait()
		t.expect.equal(reusableCounts[yielded.actor],nil)
		yielded.gate:Fire();task.wait()
		t.expect.equal(reusableCounts[yielded.actor],1)
		yielded.cleanup()
	end)
	executionFixture:Destroy()
end
