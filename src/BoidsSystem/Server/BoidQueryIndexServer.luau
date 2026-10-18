--!strict
-- Owns the authoritative derived index and its simulation subscriptions.
-- Game validation policy consumes only the query facade below.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BoidsReplicated = ReplicatedStorage:WaitForChild("BoidsReplicated")
local BoidCollisionConfig = require(BoidsReplicated.BoidCollisionConfig)
local BoidQueryIndex = require(BoidsReplicated.BoidQueryIndex)
local QueryIndexConfig = require(BoidsReplicated.QueryIndexConfig)
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)

local BoidQueryIndexServer = {}
local index: BoidQueryIndex.Index? = nil
local disconnects: {() -> ()} = {}

function BoidQueryIndexServer.Start(boids: RuntimeTypes.IndexSource): boolean
	if index then return true end
	if not QueryIndexConfig.IsEnabledForServer() then return false end
	local owned = BoidQueryIndex.new()
	index = owned
	local function update(id: number, position: Vector3, model: number): ()
		if index ~= owned then return end
		owned:Update(id, position, BoidCollisionConfig.GetRadius(model))
	end
	boids.ForEachBoid(update)
	table.insert(disconnects, boids.SubscribeCreated(update))
	table.insert(disconnects, boids.SubscribePostMerge(function(batch: RuntimeTypes.CompletedBatch): ()
		if index ~= owned then return end
		for row, id in batch.boidIds do
			local model = boids.GetBoidModel(id)
			if model then update(id, batch.positions[row], model) end
		end
	end))
	table.insert(disconnects, boids.SubscribeDeleted(function(ids: {number}): ()
		if index ~= owned then return end
		for _, id in ids do owned:Remove(id) end
	end))
	return true
end

function BoidQueryIndexServer.Stop(): ()
	-- Release all old entries and reject callbacks already queued by the old owner.
	index = nil
	for _, disconnect in disconnects do disconnect() end
	table.clear(disconnects)
end

function BoidQueryIndexServer.IsStarted(): boolean
	return index ~= nil
end
function BoidQueryIndexServer.Raycast(origin: Vector3, direction: Vector3, sweepRadius: number?, ignored: {[number]: boolean}?): BoidQueryIndex.Hit?
	return if index then index:Raycast(origin, direction, sweepRadius, ignored) else nil
end
function BoidQueryIndexServer.QueryRadius(center: Vector3, radius: number, ignored: {[number]: boolean}?): {BoidQueryIndex.Hit}
	return if index then index:QueryRadius(center, radius, ignored) else {}
end
-- Boid-specific geometry stays package-owned; callers decide gameplay consequences.
function BoidQueryIndexServer.QueryExplosion(origin: Vector3, direction: Vector3, radius: number): (Vector3?, {BoidQueryIndex.Hit})
	if not index or radius <= 0 then return nil, {} end
	local impact = index:Raycast(origin, direction)
	local center = if impact then impact.position else origin + direction
	return center, index:QueryRadius(center, radius)
end
function BoidQueryIndexServer.GetEntry(id: number): {position: Vector3, radius: number}?
	return if index then index:GetEntry(id) else nil
end
function BoidQueryIndexServer.GetMetrics(): BoidQueryIndex.Metrics
	return if index then index:GetMetrics() else {entryCount=0,queryCount=0,candidateCount=0,exactTestCount=0,p50Ms=0,p95Ms=0}
end
return BoidQueryIndexServer
