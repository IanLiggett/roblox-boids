--!strict
-- Testing-owned time-aligned comparison, never renderer correction or scheduling.
local Divergence = {}
export type Sample = {
	sampleCount: number,
	positionRmse: number,
	velocityRmse: number,
	maxPositionError: number,
	positionErrors: {number},
	velocityErrors: {number},
}

type Corrections = ((number, Vector3, Vector3, number) -> ()) -> ()
type StateReader = (number) -> (Vector3?, Vector3?)
function Divergence.Read(forEachCorrection: Corrections, readState: StateReader, now: number): Sample?
	local sampleCount = 0
	local positionErrorSquared = 0
	local velocityErrorSquared = 0
	local maxPositionError = 0
	local positionErrors: {number} = {}
	local velocityErrors: {number} = {}

	forEachCorrection(function(boidId: number, targetPosition: Vector3, targetVelocity: Vector3, snapshotTime: number)
		local age = now - snapshotTime
		if age >= 0 and age <= 3 then
			local position, velocity = readState(boidId)
			if position and velocity then
				local expectedPosition = targetPosition + targetVelocity * age
				local positionError = (position - expectedPosition).Magnitude
				local velocityError = (velocity - targetVelocity).Magnitude
				positionErrorSquared += positionError * positionError
				velocityErrorSquared += velocityError * velocityError
				maxPositionError = math.max(maxPositionError, positionError)
				table.insert(positionErrors, positionError)
				table.insert(velocityErrors, velocityError)
				sampleCount += 1
			end
		end
	end)

	if sampleCount == 0 then
		return nil
	end

	return {
		sampleCount = sampleCount,
		positionRmse = math.sqrt(positionErrorSquared / sampleCount),
		velocityRmse = math.sqrt(velocityErrorSquared / sampleCount),
		maxPositionError = maxPositionError,
		positionErrors = positionErrors,
		velocityErrors = velocityErrors,
	}
end

return Divergence
