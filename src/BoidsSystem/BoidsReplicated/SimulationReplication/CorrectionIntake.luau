--!strict
-- O(1) relay. Actors own acceptance and decode the original trusted buffer.
local CorrectionIntake = {}
export type Intake = {Consume: (buffer, number) -> (), Retire: ({number}, number?) -> ()}
type BoidsApi = {
	SetReconciliationTargets: (buffer, number) -> (),
	RetireReconciliationTargets: ({number}, number?) -> (),
}
function CorrectionIntake.New(boids: BoidsApi): Intake
	return {
		Consume = function(packet: buffer, sourceTime: number): () boids.SetReconciliationTargets(packet, sourceTime) end,
		Retire = boids.RetireReconciliationTargets,
	}
end
return CorrectionIntake
