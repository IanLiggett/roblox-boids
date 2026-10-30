--!strict
-- Value-only worker aggregates; no correction mirror or per-boid sample lists.
local SharedTypes = require(script.Parent.SharedTypes)
local CorrectionDivergence = {}
export type Sample = SharedTypes.CorrectionDivergenceSample
function CorrectionDivergence.New(): Sample
	return {sampleCount = 0, positionSum = 0, velocitySum = 0, positionSquared = 0, velocitySquared = 0, maxPositionError = 0}
end
function CorrectionDivergence.Observe(sample: Sample, position: Vector3, velocity: Vector3, targetPosition: Vector3, targetVelocity: Vector3, snapshotTime: number, now: number): ()
	local age = now - snapshotTime
	if snapshotTime <= 0 or age < 0 or age > 3 then return end
	local p = (position - targetPosition - targetVelocity * age).Magnitude
	local v = (velocity - targetVelocity).Magnitude
	sample.sampleCount += 1
	sample.positionSum += p
	sample.velocitySum += v
	sample.positionSquared += p * p
	sample.velocitySquared += v * v
	sample.maxPositionError = math.max(sample.maxPositionError, p)
end
function CorrectionDivergence.Merge(target: Sample, sample: Sample): ()
	target.sampleCount += sample.sampleCount
	target.positionSum += sample.positionSum
	target.velocitySum += sample.velocitySum
	target.positionSquared += sample.positionSquared
	target.velocitySquared += sample.velocitySquared
	target.maxPositionError = math.max(target.maxPositionError, sample.maxPositionError)
end
return CorrectionDivergence
