--!strict
-- Owns the authoritative derived index and its simulation subscriptions.
-- Game validation policy consumes only the query facade below.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local BoidsReplicated = (ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
	:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
local BoidCollisionConfig = require(BoidsReplicated.BoidCollisionConfig)
local BoidQueryIndex = require(BoidsReplicated.CollisionIndex)
local ReplicaIdentity = require(BoidsReplicated.ReplicaIdentity)
local BoidStorage = require(BoidsReplicated.BoidStorage)
local QueryIndexConfig = require(BoidsReplicated.QueryIndexConfig)
local RuntimeTypes = require(BoidsReplicated.RuntimeTypes)
local PrecisionRegions = require(BoidsReplicated.PrecisionRegions)
local LifecycleTransport = require(BoidsReplicated.SimulationReplication.LifecycleTransport)

local BoidQueryIndexServer = {}
local index: BoidQueryIndex.Index? = nil
local disconnects: {() -> ()} = {}
type PendingCell = {origin: Vector3,time: number,ceiling: number,pages: {{data: buffer,dead: buffer,cursor: number}},page: number,slot: number,bytes: number,migrants: {number | Vector3}?}
local pending: {[string]: PendingCell} = {}
local order: {string} = {}
local head,tail,queuedCount = 1,0,0
local queuedBytes,droppedCells,migrantSequence = 0,0,0
local source: RuntimeTypes.IndexSource? = nil
local function enqueue(cellKey: string,cell: PendingCell): ()
	local old = pending[cellKey]
	if queuedBytes-(if old then old.bytes else 0)+cell.bytes>8388608 or (not old and queuedCount>=8192) then droppedCells+=1; return end
	queuedBytes+=cell.bytes-(if old then old.bytes else 0)
	if old then
		-- Keep dense-cell progress when a newer completed sample supersedes it.
		cell.page,cell.slot=old.page,old.slot
	else tail=tail%8192+1; order[tail]=cellKey; queuedCount+=1 end
	pending[cellKey]=cell
end

function BoidQueryIndexServer.Start(boids: RuntimeTypes.IndexSource): boolean
	if index then return true end
	if not QueryIndexConfig.IsEnabledForServer() then return false end
	local owned = BoidQueryIndex.new({cellSize=64,historySlots=12})
	index = owned
	source = boids
	local function update(id: number, position: Vector3, model: number): ()
		if index ~= owned then return end
		local serial = ReplicaIdentity.Get(id)
		if serial then owned:Update(id,position,BoidCollisionConfig.GetRadius(model),serial,workspace:GetServerTimeNow(),nil,boids.GetBoidMaxSpeed(id)) end
	end
	boids.ForEachBoid(update)
	table.insert(disconnects, boids.SubscribeCreated(update))
	table.insert(disconnects, boids.SubscribeCompletedCells(function(batch: RuntimeTypes.CompletedCells): ()
		if index ~= owned then return end
		for _,cell in batch.cells do
			local bytes = 0
			for _,page in cell.pages do bytes+=buffer.len(page.data)+buffer.len(page.dead) end
			enqueue(`{batch.groupId}:{cell.id}`,{origin=cell.origin,time=batch.completionTime,ceiling=batch.replicaCeiling,pages=cell.pages,page=1,slot=0,bytes=bytes})
		end
		for _,migrant in batch.migrants do
			-- A migration batch is not a whole destination cell. Never replace an
			-- earlier batch just because a later migrant has the same destination.
			migrantSequence+=1
			enqueue(`m:{migrantSequence}`,{origin=Vector3.zero,time=batch.completionTime,ceiling=batch.replicaCeiling,pages={},page=1,slot=0,bytes=#migrant.rows*16,migrants=migrant.rows})
		end
	end))
	table.insert(disconnects, boids.SubscribeDeleted(function(ids: {number}): ()
		if index ~= owned then return end
		for _, id in ids do owned:Remove(id) end
	end))
	if not QueryIndexConfig.UsesExternalBudget() then
		local connection=RunService.Heartbeat:Connect(function(): ()
			if index==owned then BoidQueryIndexServer.Maintain(8192,os.clock()+0.0015) end
		end)
		table.insert(disconnects,function(): () connection:Disconnect() end)
	end
	return true
end

function BoidQueryIndexServer.Stop(): ()
	-- Release all old entries and reject callbacks already queued by the old owner.
	index = nil
	source = nil
	table.clear(pending); table.clear(order); head=1; tail=0; queuedCount=0; queuedBytes=0
	for _, disconnect in disconnects do disconnect() end
	table.clear(disconnects)
end

function BoidQueryIndexServer.Maintain(maxRows: number,deadline: number): number
	local owned,boids = index,source
	if not owned or not boids then return 0 end
	local rows = 0
	while queuedCount>0 and rows<maxRows and os.clock()<deadline do
		local cellKey = order[head]
		order[head]=nil; head=head%8192+1; queuedCount-=1
		local cell = pending[cellKey]
		local isDone = false
		local slice = 0
		while slice<64 and rows<maxRows and os.clock()<deadline do
			local id: number
			local position: Vector3
			local velocity: Vector3
			if cell.migrants then
				local at = cell.slot*6+1
				if at>#cell.migrants then isDone=true; break end
				local values = cell.migrants
				id,position,velocity=values[at] :: number,values[at+1] :: Vector3,values[at+2] :: Vector3
				cell.slot+=1
			else
				local page = cell.pages[cell.page]
				if not page then isDone=true; break end
				if cell.slot>=page.cursor then cell.page+=1; cell.slot=0; continue end
				local slot = cell.slot
				cell.slot+=1; rows+=1; slice+=1
				if bit32.band(buffer.readu32(page.dead,math.floor(slot/32)*4),bit32.lshift(1,slot%32))~=0 then continue end
				id=BoidStorage.ReadBoidId(page.data,slot)
				position=cell.origin+Vector3.new(BoidStorage.ReadPosition(page.data,slot))
				velocity=Vector3.new(BoidStorage.ReadVelocity(page.data,slot))*BoidStorage.ReadSpeed(page.data,slot)
			end
			if cell.migrants then rows+=1; slice+=1 end
			local serial,model = ReplicaIdentity.Get(id),boids.GetBoidModel(id)
			if serial and serial<=cell.ceiling and model and boids.IsServerBoid(id) then owned:Update(id,position,BoidCollisionConfig.GetRadius(model),serial,cell.time,velocity,boids.GetBoidMaxSpeed(id)) end
		end
		if isDone then queuedBytes-=cell.bytes; pending[cellKey]=nil
		else tail=tail%8192+1; order[tail]=cellKey; queuedCount+=1 end
	end
	return rows
end

function BoidQueryIndexServer.GetRef(id: number): BoidQueryIndex.BoidRef?
	local serial = ReplicaIdentity.Get(id)
	return if serial and source and source.IsServerBoid(id) then {id=id,replicaSerial=serial} else nil
end
function BoidQueryIndexServer.HasReplicationCapacity(): boolean return LifecycleTransport.HasCombatCapacity() end
function BoidQueryIndexServer.RequestPrecisionRegion(userId: number,shape: BoidQueryIndex.Shape,time: number,budget: BoidQueryIndex.Budget): ()
	PrecisionRegions.Request(userId,shape,time)
	local owned,boids = index,source
	if not owned or not boids then return end
	local result = owned:Query({shape=shape,maxHits=64,maxCandidates=128,maxCells=128},budget)
	local ids: {number} = {}
	for _,hit in result.hits do if PrecisionRegions.Select(userId,hit.boidId,hit.proxyPosition) then table.insert(ids,hit.boidId) end end
	boids.PrioritizeBoids(ids,time+0.25)
end
function BoidQueryIndexServer.QueryBatch(requests: {BoidQueryIndex.Request},budget: BoidQueryIndex.Budget): {BoidQueryIndex.Result}
	if not index then return {} end
	local results=index:QueryBatch(requests,budget)
	if queuedCount>0 then for _,result in results do result.hasCoverage=false end end
	return results
end
function BoidQueryIndexServer.ValidateHint(ref: BoidQueryIndex.BoidRef,shape: BoidQueryIndex.Shape,position: Vector3,at: number,allowance: number): BoidQueryIndex.Hit?
	local current = BoidQueryIndexServer.GetRef(ref.id)
	if not current or current.replicaSerial~=ref.replicaSerial or not index then return nil end
	local owned = assert(index)
	local boids=source
	if boids then
		local sample=boids.GetCollisionSample(ref.id)
		local model=boids.GetBoidModel(ref.id)
		if sample and model then owned:Update(ref.id,sample.position,BoidCollisionConfig.GetRadius(model),ref.replicaSerial,sample.sourceTime,sample.velocity,boids.GetBoidMaxSpeed(ref.id)) end
	end
	return owned:ValidateHint(ref,shape,position,at,allowance)
end
function BoidQueryIndexServer.GetMaintenanceMetrics(): {queuedBytes: number,pendingCells: number,droppedCells: number}
	return {queuedBytes=queuedBytes,pendingCells=queuedCount,droppedCells=droppedCells}
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
	return if index then index:GetMetrics() else {entryCount=0,queryCount=0,candidateCount=0,exactTestCount=0,p50Ms=0,p95Ms=0,membershipCount=0,incompleteEntries=0,gatheredRows=0,reusedCandidateRows=0}
end
return BoidQueryIndexServer
