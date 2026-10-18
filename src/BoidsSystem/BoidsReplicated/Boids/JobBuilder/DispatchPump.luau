--!strict
-- One coordinator dispatch allowance per Heartbeat, shared by all wakeup sources.
local DispatchPump = {}

export type Trigger = "heartbeat" | "completion" | "timer"
export type StopReason = "budget" | "noActors" | "noDue"
export type Hooks = {
	Clock: () -> number,
	Defer: (callback: () -> ()) -> (),
	Delay: (seconds: number, callback: () -> ()) -> thread,
	Cancel: (thread) -> (),
	Run: (deadline: number, trigger: Trigger) -> (StopReason, number?),
	Observe: (trigger: Trigger, reason: StopReason, seconds: number) -> (),
}
export type Pump = {BeginFrame: () -> (), Request: (trigger: Trigger) -> ()}

function DispatchPump.New(allowance: number, hooks: Hooks): Pump
	assert(allowance > 0, "Dispatch allowance must be positive")
	local spent = allowance
	local isPending, isRunning = false, false
	local pendingTrigger: Trigger = "heartbeat"
	local timer: thread? = nil
	local generation = 0
	local request: (Trigger) -> ()

	local function cancelWakeup(): ()
		generation += 1
		if timer then hooks.Cancel(timer); timer = nil end
	end

	local function run(): ()
		isPending = false
		if isRunning or spent >= allowance then return end
		cancelWakeup()
		isRunning = true
		local trigger = pendingTrigger
		local started = hooks.Clock()
		local ok, reason, delaySeconds = pcall(hooks.Run, started + allowance - spent, trigger)
		local elapsed = hooks.Clock() - started
		spent += elapsed
		isRunning = false
		if not ok then error(reason) end
		if reason == "budget" then spent = math.max(spent, allowance) end
		hooks.Observe(trigger, reason, elapsed)
		if reason == "noDue" and delaySeconds and spent < allowance then
			local token = generation
			timer = hooks.Delay(math.max(delaySeconds, 0.001), function(): ()
				if token ~= generation then return end
				timer = nil
				request("timer")
			end)
		end
	end

	request = function(trigger: Trigger): ()
		if spent >= allowance then return end
		cancelWakeup()
		if isPending then return end
		pendingTrigger = trigger
		isPending = true
		hooks.Defer(run)
	end

	return {
		Request = request,
		BeginFrame = function(): ()
			spent = 0
			-- A pending completion request now spends the new frame's allowance.
			pendingTrigger = "heartbeat"
			request("heartbeat")
		end,
	}
end

return DispatchPump
