--!strict
--[[
ClientRendererBridge
====================
Client-only direct-call bridge to BoidsClient.BoidsRenderer. Shared simulation
code uses this only while running on a client, avoiding BindableEvent payload
copies between the local simulator and renderer.
]]

local SharedTypes = require(script.Parent.SharedTypes)
local ClientRendererBridge = {}


type Renderer = {
	ConsumeCellSnapshot: (origin: Vector3, networkBoids: buffer, boidCount: number, completionTime: number) -> (),
	ConsumeNetworkPacket: (packet: buffer, sourceTime: number) -> (),
	ReceiveNewBoidBatch: (batch: SharedTypes.NetworkBoidsBatch) -> (),
	ReceiveDeleteBoidBatch: (packet: buffer, lifetimes: {[number]: number}?) -> (),
	ReceiveDeleteGroup: (groupId: number) -> (),
}

local renderer: Renderer? = nil

-- Bound explicitly by client composition before the coordinator can publish.
function ClientRendererBridge.SetRenderer(value: Renderer): ()
	assert(not renderer or renderer == value, "The renderer singleton is already bound")
	renderer = value
end

local function getRenderer(): Renderer
	return assert(renderer, "Client renderer must be started and bound before publication")
end

function ClientRendererBridge.ConsumeCellSnapshot(origin: Vector3, networkBoids: buffer, boidCount: number, completionTime: number): ()
	getRenderer().ConsumeCellSnapshot(origin, networkBoids, boidCount, completionTime)
end

function ClientRendererBridge.ConsumeNetworkPacket(packet: buffer, sourceTime: number): ()
	getRenderer().ConsumeNetworkPacket(packet, sourceTime)
end

function ClientRendererBridge.ReceiveNewBoidBatch(batch: SharedTypes.NetworkBoidsBatch): ()
	getRenderer().ReceiveNewBoidBatch(batch)
end

function ClientRendererBridge.ReceiveDeleteBoidBatch(packet: buffer, lifetimes: {[number]: number}?): ()
	getRenderer().ReceiveDeleteBoidBatch(packet, lifetimes)
end

function ClientRendererBridge.ReceiveDeleteGroup(groupId: number): ()
	getRenderer().ReceiveDeleteGroup(groupId)
end

return ClientRendererBridge
