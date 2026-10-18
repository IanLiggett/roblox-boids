--!strict

local SharedTypes = require(script.Parent.Parent.SharedTypes)
local Age = {}
export type Tracker = { tick: number, observedAt: number, seconds: number, isLowerBound: boolean }
local WRAP_SECONDS = 65536 / 60

-- First contact cannot distinguish an old row from a whole u16 cycle ago.
-- Retain elapsed age while the tick is unchanged, including across repeated wraps.
function Age.Observe(previous: Tracker?, state: SharedTypes.BoidObservation): Tracker
	local seconds = ((state.currentTick - state.lastSimulationTick) % 65536) / 60
	local isLowerBound = true
	if previous and state.sampledAt >= previous.observedAt then
		local elapsed = state.sampledAt - previous.observedAt
		if previous.tick == state.lastSimulationTick then
			seconds = math.max(seconds, previous.seconds + elapsed)
			isLowerBound = previous.isLowerBound
		else
			isLowerBound = elapsed >= WRAP_SECONDS or seconds >= WRAP_SECONDS * 0.5
		end
	end
	return { tick = state.lastSimulationTick, observedAt = state.sampledAt, seconds = seconds, isLowerBound = isLowerBound }
end

return Age
