--!strict
--!native

local CorrectionIntake = {}

export type Target = {position: Vector3, velocity: Vector3, snapshotTime: number}
export type Intake = {
	Consume: (buffer, number) -> (),
	Retire: (number, number?) -> (),
	ForEachAccepted: ((number, Vector3, Vector3, number) -> ()) -> (),
}
type BoidsApi = {
	IsServerBoid: (number) -> boolean,
	IsDeletionPending: (number) -> boolean,
	SetReconciliationTargets: (buffer, number, (number, Vector3, Vector3, number) -> boolean) -> (),
}

-- One owner for accepted correction state and retirement cutoffs. Unknown IDs
-- are dropped; live IDs may receive targets before their Actor stats arrive.
function CorrectionIntake.New(boids: BoidsApi): Intake
	local targets: {[number]: Target} = {}
	local retiredAt: {[number]: number} = {}

	local function retire(boidId: number, cutoff: number?): ()
		targets[boidId] = nil
		if cutoff then
			retiredAt[boidId] = math.max(retiredAt[boidId] or -math.huge, cutoff)
		end
	end

	local function consume(packet: buffer, sourceTime: number): ()
		if sourceTime ~= sourceTime or math.abs(sourceTime) == math.huge then return end

		-- Validating a packet from the server is pointless and expensive. It should be allowed to fail and throw an error if the server has made a mistake.
		-- Validate the complete packet before accepting any row.
		-- local cursor = 0
		-- local length = buffer.len(packet)
		-- while cursor < length do
		-- 	if length - cursor < PacketCodec.CELL_HEADER_BYTES then return end
		-- 	local count = buffer.readu16(packet, cursor + 6)
		-- 	cursor += PacketCodec.CELL_HEADER_BYTES + count * PacketCodec.BOID_ROW_BYTES
		-- 	if cursor > length then return end
		-- end

		boids.SetReconciliationTargets(packet, sourceTime, function(id: number, position: Vector3, velocity: Vector3, time: number): boolean
			local previous = targets[id]
			if not boids.IsServerBoid(id) or boids.IsDeletionPending(id)
				or time <= (retiredAt[id] or -math.huge)
				or (previous and time <= previous.snapshotTime) then return false end
			targets[id] = {position = position, velocity = velocity, snapshotTime = time}
			return true
		end)
	end

	-- Scalars/immutable vectors only; diagnostics cannot mutate acceptance state.
	local function forEachAccepted(observer: (number, Vector3, Vector3, number) -> ()): ()
		for id, target in targets do
			observer(id, target.position, target.velocity, target.snapshotTime)
		end
	end

	return {Consume = consume, Retire = retire, ForEachAccepted = forEachAccepted}
end

return CorrectionIntake
