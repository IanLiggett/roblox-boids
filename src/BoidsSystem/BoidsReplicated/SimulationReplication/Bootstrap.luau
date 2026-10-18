--!strict

local Players = game:GetService("Players")

local Bootstrap = {}

export type Admission = {Request: (Player, number) -> boolean, Forget: (Player) -> ()}
type RequestState = {attempts: number, lastAttempt: number, isRunning: boolean, isComplete: boolean}
local MAX_ATTEMPTS = 3
local RETRY_INTERVAL = 5

-- Admission is per connection, not per client-authored token. A successful
-- reliable replay is one-shot; only a failed send may retry, within fixed bounds.
function Bootstrap.New(sendState: (Player) -> ()): Admission
	local requests: {[Player]: RequestState} = {}

	local function request(player: Player, now: number): boolean
		if player.Parent ~= Players then return false end
		local state = requests[player]
		if not state then
			state = {attempts = 0, lastAttempt = -math.huge, isRunning = false, isComplete = false}
			requests[player] = state
		end
		if state.isRunning or state.isComplete or state.attempts >= MAX_ATTEMPTS
			or now - state.lastAttempt < RETRY_INTERVAL then return false end

		state.attempts += 1
		state.lastAttempt = now
		state.isRunning = true
		local ok, failure = pcall(sendState, player)
		state.isRunning = false
		if requests[player] ~= state then return false end
		state.isComplete = ok
		if not ok then warn("Boids bootstrap replay failed: " .. tostring(failure)) end
		return ok
	end

	local function forget(player: Player): ()
		requests[player] = nil
	end

	return {Request = request, Forget = forget}
end

return Bootstrap
