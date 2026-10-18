--!strict
-- Synchronous local delivery only: no packet assembly or copied row payload.
local SharedTypes = require(script.Parent.Parent.SharedTypes)
local ClientRendererBridge = require(script.Parent.Parent.ClientRendererBridge)
local LocalDelivery = {}
type SimulationSnapshot = SharedTypes.SimulationSnapshot
type CellSnapshot = SharedTypes.CellSnapshot
function LocalDelivery.PublishSimulationSnapshot(simulationSnapshot: SimulationSnapshot, completionTime: number): ()
	for _, cellSnapshot: CellSnapshot in simulationSnapshot do
		if cellSnapshot.boidCount <= 0 then
			continue
		end

		ClientRendererBridge.ConsumeCellSnapshot(
			cellSnapshot.origin,
			cellSnapshot.networkBoids,
			cellSnapshot.boidCount,
			completionTime
		)
	end
end

return LocalDelivery
