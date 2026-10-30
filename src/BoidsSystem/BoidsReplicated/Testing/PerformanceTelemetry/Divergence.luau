--!strict
-- Exact moments over worker/job samples. Medians require retaining individual
-- errors; they are intentionally unavailable without a per-boid diagnostic copy.
local Aggregate = require(script.Parent.Parent.Parent.CorrectionDivergence)
local Divergence = {}
export type Sample = Aggregate.Sample
export type Report = {
 sampleCount: number, sampling: string, positionRmse: number, velocityRmse: number,
 maxPositionError: number, positionAverage: number, velocityAverage: number,
 positionStandardDeviation: number, velocityStandardDeviation: number,
 positionMedian: number?, velocityMedian: number?,
}
Divergence.New = Aggregate.New
Divergence.Merge = Aggregate.Merge
function Divergence.Read(sample: Sample): Report?
 local n = sample.sampleCount
 if n == 0 then return nil end
 local p, v = sample.positionSum / n, sample.velocitySum / n
 return {sampleCount = n, sampling = "worker-jobs", positionRmse = math.sqrt(sample.positionSquared / n),
  velocityRmse = math.sqrt(sample.velocitySquared / n), maxPositionError = sample.maxPositionError,
  positionAverage = p, velocityAverage = v,
  positionStandardDeviation = math.sqrt(math.max(0, sample.positionSquared / n - p*p)),
  velocityStandardDeviation = math.sqrt(math.max(0, sample.velocitySquared / n - v*v))}
end
return Divergence
