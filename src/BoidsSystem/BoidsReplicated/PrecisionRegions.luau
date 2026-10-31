--!strict
-- Generic bounded interest, requested only by trusted server integration.
-- Selection shares completed rows with transport; it never scans boid storage.
local Geometry = require(script.Parent.CollisionGeometry)
local ReplicaIdentity = require(script.Parent.ReplicaIdentity)
local PrecisionRegions = {}
type Region = {shape: Geometry.Shape,expiresAt: number}
type Viewer = {regions: {Region},cursor: number,selected: {[number]: number},count: number}
local viewers: {[number]: Viewer} = {}
local shared: {[number]: number} = {}
local sharedCount = 0
local nextReset = 0
local now = 0

function PrecisionRegions.Advance(time: number): ()
	now=time
	if time>=nextReset then
		nextReset=time+0.25; table.clear(shared); sharedCount=0
		for _,viewer in viewers do table.clear(viewer.selected); viewer.count=0 end
	end
	for userId,viewer in viewers do
		for i=#viewer.regions,1,-1 do if time>=viewer.regions[i].expiresAt then table.remove(viewer.regions,i) end end
		if #viewer.regions==0 then viewers[userId]=nil end
	end
end
function PrecisionRegions.Request(userId: number,shape: Geometry.Shape,time: number): ()
	local viewer = viewers[userId]
	if not viewer then viewer={regions={},cursor=0,selected={},count=0}; viewers[userId]=viewer end
	viewer.cursor=if #viewer.regions<4 then #viewer.regions+1 else viewer.cursor%4+1
	viewer.regions[viewer.cursor]={shape=table.clone(shape),expiresAt=time+0.25}
end
function PrecisionRegions.Forget(userId: number): () viewers[userId]=nil end
function PrecisionRegions.IntersectsCell(origin: Vector3,size: number): boolean
	local center = origin+Vector3.one*size*0.5
	local radius = size*0.866025404
	for _,viewer in viewers do
		for _,region in viewer.regions do
			if now<region.expiresAt and Geometry.Intersect(region.shape,center,radius) then return true end
		end
	end
	return false
end
function PrecisionRegions.Select(userId: number,id: number,position: Vector3): boolean
	local viewer = viewers[userId]
	if not viewer then return false end
	local serial = ReplicaIdentity.Get(id)
	if not serial then return false end
	if viewer.selected[id]==serial then return true end
	if viewer.count>=128 or (shared[id]~=serial and sharedCount>=4096) then return false end
	for _,region in viewer.regions do
		if now<region.expiresAt and Geometry.Intersect(region.shape,position,2) then
			viewer.selected[id]=serial; viewer.count+=1
			if shared[id]~=serial then shared[id]=serial; sharedCount+=1 end
			return true
		end
	end
	return false
end
function PrecisionRegions.GetInterval(userId: number,id: number,ordinary: number): number
	local viewer = viewers[userId]
	return if viewer and viewer.selected[id]==ReplicaIdentity.Get(id) then math.min(ordinary,0.05) else ordinary
end
function PrecisionRegions.GetDiagnostics(): {viewers: number,regions: number,selected: number}
	local count,regions=0,0
	for _,viewer in viewers do count+=1; regions+=#viewer.regions end
	return {viewers=count,regions=regions,selected=sharedCount}
end
return PrecisionRegions
