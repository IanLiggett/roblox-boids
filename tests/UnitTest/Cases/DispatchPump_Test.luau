--!strict
return function(t: any): ()
	local DispatchPump = require(game.ReplicatedStorage.BoidsReplicated.Boids.JobBuilder.DispatchPump)
	local function fixture(): any
		local f: any = {clock=0, queue={}, timers={}, observations={}, runs=0, cost=0.0002, reason="noActors", delay=nil}
		f.pump = DispatchPump.New(0.001, {
			Clock=function() return f.clock end,
			Defer=function(callback) table.insert(f.queue,callback) end,
			Delay=function(seconds, callback)
				local thread=coroutine.create(callback)
				table.insert(f.timers,{thread=thread,callback=callback,seconds=seconds,cancelled=false})
				return thread
			end,
			Cancel=function(thread)
				for _,timer in f.timers do if timer.thread==thread then timer.cancelled=true end end
			end,
			Run=function(deadline,trigger)
				f.runs+=1; f.deadline=deadline; f.trigger=trigger
				local duringRun: (() -> ())? = f.duringRun
				if duringRun then duringRun() end
				f.clock+=f.cost
				return f.reason,f.delay
			end,
			Observe=function(trigger,reason,seconds) table.insert(f.observations,{trigger=trigger,reason=reason,seconds=seconds}) end,
		})
		function f.flush(): ()
			local queue=f.queue; f.queue={}
			for _,callback in queue do callback() end
		end
		return f
	end

	t.test("completion refills without a Heartbeat and duplicate requests coalesce",function()
		local f=fixture(); f.pump.BeginFrame(); f.flush()
		f.pump.Request("completion"); f.pump.Request("completion"); f.flush()
		t.expect.equal(f.runs,2); t.expect.equal(f.trigger,"completion")
	end)
	t.test("all triggers share the allowance and only Heartbeat replenishes it",function()
		local f=fixture(); f.cost=0.0006
		f.pump.BeginFrame(); f.flush()
		f.pump.Request("completion"); f.flush()
		t.expect.near(f.deadline,0.001)
		f.pump.Request("timer"); f.pump.Request("completion"); f.flush()
		t.expect.equal(f.runs,2)
		f.pump.BeginFrame(); f.flush(); t.expect.equal(f.runs,3)
	end)
	t.test("future work arms one timer and stale callbacks cannot dispatch",function()
		local f=fixture(); f.reason="noDue"; f.delay=0.25
		f.pump.BeginFrame(); f.flush()
		t.expect.equal(#f.timers,1); t.expect.equal(f.timers[1].seconds,0.25)
		local stale=f.timers[1]
		f.pump.Request("completion"); f.flush()
		t.expect.truthy(stale.cancelled); t.expect.equal(#f.timers,2)
		stale.callback(); f.flush(); t.expect.equal(f.runs,2)
		f.timers[2].callback(); f.flush(); t.expect.equal(f.runs,3); t.expect.equal(f.trigger,"timer")
	end)
	t.test("no work, busy Actors and exhausted budget do not poll",function()
		for _,reason in {"noDue","noActors","budget"} do
			local f=fixture(); f.reason=reason
			f.pump.BeginFrame(); f.flush()
			t.expect.equal(#f.timers,0); t.expect.equal(#f.queue,0)
		end
	end)
	t.test("requests during assignment defer rather than reenter",function()
		local f=fixture()
		f.duringRun=function() f.pump.Request("completion") end
		f.pump.BeginFrame(); f.flush()
		t.expect.equal(f.runs,1); t.expect.equal(#f.queue,1)
		f.duringRun=nil; f.flush(); t.expect.equal(f.runs,2)
	end)
	t.test("pending completion uses the new Heartbeat epoch once",function()
		local f=fixture(); f.pump.BeginFrame(); f.flush()
		f.pump.Request("completion"); f.pump.BeginFrame(); f.flush()
		t.expect.equal(f.runs,2); t.expect.equal(f.trigger,"heartbeat")
	end)
end
