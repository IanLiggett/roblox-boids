--!strict
-- Sparse bounded sphere proxies. History is packed; client current poses are
-- persistent table values supplied by the renderer's ordinary pose work.
local Geometry = require(script.Parent.CollisionGeometry)
local CollisionIndex = {}
export type Shape = Geometry.Shape
export type BoidRef = {id: number, replicaSerial: number}
export type Hit = {boidId: number, replicaSerial: number, position: Vector3, proxyPosition: Vector3, distance: number, normal: Vector3, sourceTime: number}
export type Metrics = {entryCount: number, queryCount: number, candidateCount: number, exactTestCount: number, p50Ms: number, p95Ms: number, membershipCount: number, incompleteEntries: number,gatheredRows: number,reusedCandidateRows: number}
export type Budget = {cellsLeft: number, testsLeft: number, deadline: number}
export type Request = {shape: Shape, sampleTime: number?, endTime: number?, maxHits: number?, maxCells: number?, maxCandidates: number?, ignored: {[number]: boolean}?}
export type Result = {hits: {Hit}, cellVisits: number, candidateTests: number, isTruncated: boolean, hasCoverage: boolean, oldestSourceTime: number?, elapsedMs: number}
export type Options = {cellSize: number?, historySlots: number?, maxMemberships: number?}
type Membership = {id: number, key: string, slot: number}
type Bucket = {members: {Membership}, cursor: number}
type Entry = {position: Vector3, velocity: Vector3, radius: number, serial: number, time: number, members: {Membership}, history: buffer?, head: number, samples: number, isIndexed: boolean,lowCell: Vector3?,highCell: Vector3?,sampleBucket: number?,maxSpeed: number}
type State = {entries: {[number]: Entry}, buckets: {[string]: Bucket}, cellSize: number, slots: number, count: number, memberships: number, maxMemberships: number, incomplete: number, maxRadius: number, samplesMs: {number}, metricCursor: number, queries: number, tests: number,gathers: {[string]: {first: number,ids: {number}}},gatherBudget: Budget?,gatheredRows: number,reusedCandidateRows: number}
local Index = {}
Index.__index = Index
export type Index = typeof(setmetatable({} :: State,Index))

local function key(x: number,y: number,z: number): string return `{x},{y},{z}` end
local function coordinates(position: Vector3,size: number): (number,number,number)
	return math.floor(position.X/size),math.floor(position.Y/size),math.floor(position.Z/size)
end
local function detach(self: State,entry: Entry): ()
	for _,member in entry.members do
		local bucket = self.buckets[member.key]
		local last = bucket.members[#bucket.members]
		bucket.members[member.slot] = last
		last.slot = member.slot
		bucket.members[#bucket.members] = nil
		if #bucket.members == 0 then self.buckets[member.key] = nil end
		self.memberships -= 1
	end
	table.clear(entry.members)
	if not entry.isIndexed then self.incomplete -= 1 end
	entry.isIndexed = true
end
local function readSample(entry: Entry,slot: number): (number,Vector3,Vector3)
	local history,offset = assert(entry.history),(slot-1)*32
	return buffer.readf64(history,offset),Vector3.new(buffer.readf32(history,offset+8),buffer.readf32(history,offset+12),buffer.readf32(history,offset+16)),Vector3.new(buffer.readf32(history,offset+20),buffer.readf32(history,offset+24),buffer.readf32(history,offset+28))
end
local function sampleAt(entry: Entry,slots: number,at: number?): (Vector3?,number,number)
	if not at or slots == 0 then return entry.position,entry.time,0 end
	if at>=entry.time then
		local elapsed=at-entry.time
		local error=(entry.maxSpeed+entry.velocity.Magnitude)*elapsed
		return if elapsed<=0.1 and error<=2 then entry.position+entry.velocity*elapsed else nil,entry.time,error
	end
	local beforeTime,afterTime = -math.huge,entry.time
	local beforeSlot,afterSlot = 0,-1
	for slot=1,entry.samples do
		local time = buffer.readf64(assert(entry.history),(slot-1)*32)
		if entry.time-time>0.5 then continue end
		if time <= at and time > beforeTime then beforeTime,beforeSlot = time,slot end
		if time >= at and time < afterTime then afterTime,afterSlot = time,slot end
	end
	if beforeSlot>0 and afterSlot~=0 then
		local _,beforePosition = readSample(entry,beforeSlot)
		local afterPosition = entry.position
		if afterSlot>0 then local _,position=readSample(entry,afterSlot); afterPosition=position end
		-- Bound deviation using the intersection of the two time-specific
		-- reachable balls. Quantized chords may slightly exceed configured speed;
		-- contact padding covers quantization independently of this motion bound.
		local interval=afterTime-beforeTime
		local chord=(afterPosition-beforePosition).Magnitude
		local alpha=if interval==0 then 0 else (at-beforeTime)/interval
		local speed=math.max(entry.maxSpeed,if interval>0 then chord/interval else 0)
		local r1,r2=speed*(at-beforeTime),speed*(afterTime-at)
		local error=math.min(r1,r2)
		if chord>1e-6 then
			local a=alpha*chord
			local low,high=math.max(-r1,chord-r2),math.min(r1,chord+r2)
			local cross=(r1*r1-r2*r2+chord*chord)/(2*chord)
			local x=if low>high then (low+high)*0.5 else math.clamp(cross,low,high)
			error=math.sqrt(math.max(0,math.min(r1*r1-2*a*x+a*a,r2*r2+2*(chord-a)*x+a*a-chord*chord)))
		end
		if error>2 then return nil,beforeTime,error end
		return beforePosition:Lerp(afterPosition,alpha),beforeTime,error
	end
	return nil,entry.time,math.huge
end

function CollisionIndex.new(options: Options?): Index
	local config: Options = options or {}
	return setmetatable({entries={},buckets={},cellSize=config.cellSize or 32,slots=config.historySlots or 0,count=0,memberships=0,maxMemberships=config.maxMemberships or 524288,incomplete=0,maxRadius=0,samplesMs={},metricCursor=0,queries=0,tests=0,gathers={},gatherBudget=nil,gatheredRows=0,reusedCandidateRows=0},Index)
end
function Index.Remove(self: State,id: number): ()
	local entry = self.entries[id]
	if not entry then return end
	self.gatherBudget=nil
	detach(self,entry)
	self.entries[id] = nil
	self.count -= 1
end
function Index.Update(self: State,id: number,position: Vector3,radius: number,serial: number?,time: number?,velocity: Vector3?,maxSpeed: number?): ()
	local entry: Entry? = self.entries[id]
	local sourceTime,replicaSerial = time or 0,serial or 0
	if entry and entry.serial ~= replicaSerial then Index.Remove(self,id); entry = nil end
	if entry and sourceTime < entry.time then return end
	-- Invalidate in constant time. Clearing a retained gather table for every
	-- rendered/authoritative pose repeats work proportional to cache capacity.
	-- Query clears it once before its next read, including same-budget mutations.
	self.gatherBudget=nil
	if not entry then
		local created: Entry = {position=position,velocity=velocity or Vector3.zero,radius=radius,serial=replicaSerial,time=sourceTime,members={},history=if self.slots>0 then buffer.create(self.slots*32) else nil,head=0,samples=0,isIndexed=true,lowCell=nil,highCell=nil,sampleBucket=nil,maxSpeed=maxSpeed or (velocity or Vector3.zero).Magnitude}
		entry=created
		self.entries[id] = entry
		self.count += 1
	end
	local active: Entry = assert(entry)
	-- Only temporal queries consume the speed bound. Rendered-pose indexes need
	-- the current proxy, without deriving historical motion on every visual row.
	if active.history then
		if maxSpeed then active.maxSpeed=maxSpeed
		else active.maxSpeed=math.max(active.maxSpeed,(velocity or Vector3.zero).Magnitude,if sourceTime>active.time then (position-active.position).Magnitude/(sourceTime-active.time) else 0) end
	end
	active.position,active.velocity,active.radius,active.time = position,velocity or Vector3.zero,radius,sourceTime
	local low: Vector3 = position
	local high: Vector3 = position
	if active.history then
		local sampleBucket = math.floor(sourceTime*20)
		local replace = active.head>0 and active.sampleBucket==sampleBucket
		active.sampleBucket=sampleBucket
		if not replace then active.head=active.head%self.slots+1; active.samples=math.min(self.slots,active.samples+1) end
		if not replace then
			local offset = (active.head-1)*32
			buffer.writef64(active.history,offset,sourceTime)
			buffer.writef32(active.history,offset+8,position.X)
			buffer.writef32(active.history,offset+12,position.Y)
			buffer.writef32(active.history,offset+16,position.Z)
			buffer.writef32(active.history,offset+20,active.velocity.X)
			buffer.writef32(active.history,offset+24,active.velocity.Y)
			buffer.writef32(active.history,offset+28,active.velocity.Z)
		end
		for slot=1,active.samples do
			local offset = (slot-1)*32
			local sampleTime = buffer.readf64(active.history,offset)
			if sourceTime-sampleTime <= 0.5 then
				local samplePosition = Vector3.new(buffer.readf32(active.history,offset+8),buffer.readf32(active.history,offset+12),buffer.readf32(active.history,offset+16))
				low=low:Min(samplePosition); high=high:Max(samplePosition)
			end
		end
		local predicted = position+active.velocity*0.1
		low,high = low:Min(predicted),high:Max(predicted)
	end
	local x0,y0,z0 = coordinates(assert(low),self.cellSize)
	local x1,y1,z1 = x0,y0,z0
	if active.history then x1,y1,z1=coordinates(assert(high),self.cellSize) end
	self.maxRadius=math.max(self.maxRadius,radius)
	local previousLow,previousHigh = active.lowCell,active.highCell
	if active.isIndexed and previousLow and previousHigh
		and previousLow.X==x0 and previousLow.Y==y0 and previousLow.Z==z0
		and previousHigh.X==x1 and previousHigh.Y==y1 and previousHigh.Z==z1 then return end
	local lowCell = Vector3.new(x0,y0,z0)
	local highCell = if active.history then Vector3.new(x1,y1,z1) else lowCell
	detach(self,active)
	active.lowCell,active.highCell=lowCell,highCell
	local needed = (x1-x0+1)*(y1-y0+1)*(z1-z0+1)
	if needed>64 or self.memberships+needed>self.maxMemberships then active.isIndexed=false; self.incomplete+=1; return end
	for x=x0,x1 do for y=y0,y1 do for z=z0,z1 do
		local cellKey = key(x,y,z)
		local bucket = self.buckets[cellKey]
		if not bucket then bucket={members={},cursor=0}; self.buckets[cellKey]=bucket end
		local member: Membership = {id=id,key=cellKey,slot=#bucket.members+1}
		bucket.members[member.slot] = member
		table.insert(active.members,member)
		self.memberships += 1
	end end end
	self.maxRadius = math.max(self.maxRadius,radius)
end
function Index.GetEntry(self: State,id: number): {position: Vector3,radius: number,replicaSerial: number,sourceTime: number}?
	local e = self.entries[id]
	return if e then {position=e.position,radius=e.radius,replicaSerial=e.serial,sourceTime=e.time} else nil
end
function Index.Sample(self: State,ref: BoidRef,at: number): {position: Vector3,radius: number,sourceTime: number}?
	local entry = self.entries[ref.id]
	if not entry or entry.serial ~= ref.replicaSerial then return nil end
	local position,sourceTime = sampleAt(entry,self.slots,at)
	return if position then {position=position,radius=entry.radius,sourceTime=sourceTime} else nil
end
local function makeHit(id: number,entry: Entry,shape: Shape,position: Vector3,distance: number,sourceTime: number): Hit
	local contact = position
	if shape.kind == "Segment" then
		local direction = shape.direction or Vector3.zero
		contact = if distance>0 and direction.Magnitude>0 then shape.origin+direction.Unit*distance else shape.origin
	end
	local normal = contact-position
	return {boidId=id,replicaSerial=entry.serial,position=contact,proxyPosition=position,distance=distance,normal=if normal.Magnitude>1e-6 then normal.Unit else Vector3.yAxis,sourceTime=sourceTime}
end
function Index.ValidateHint(self: State,ref: BoidRef,shape: Shape,visiblePosition: Vector3,at: number,allowance: number): Hit?
	local entry = self.entries[ref.id]
	if not entry or entry.serial ~= ref.replicaSerial then return nil end
	local position,sourceTime = sampleAt(entry,self.slots,at)
	if not position and math.abs(at-entry.time)<=0.1 then
		-- Presentation validation uses one fixed nearby authoritative sample,
		-- independently of the stricter two-stud collision-motion quality bound.
		position=entry.position+entry.velocity*(at-entry.time); sourceTime=entry.time
	end
	if not position then
		-- A low-frequency authoritative cell can be older than our history.
		-- Compare with that actual settled pose, never extrapolate it without
		-- bound or pretend it represents the requested presentation time. The
		-- caller's hard displacement envelope still limits every accepted hint.
		position=entry.position; sourceTime=entry.time
	end
	if not position or (position-visiblePosition).Magnitude>allowance then return nil end
	local distance = Geometry.Intersect(shape,visiblePosition,entry.radius+1)
	return if distance then makeHit(ref.id,entry,shape,visiblePosition,distance,sourceTime) else nil
end
function Index.Query(self: State,request: Request,shared: Budget?): Result
	local started = os.clock()
	if not shared or self.gatherBudget~=shared then table.clear(self.gathers); self.gatherBudget=shared end
	local maxCells = math.min(request.maxCells or 256,if shared then shared.cellsLeft else 256)
	local maxTests = math.min(request.maxCandidates or 1024,if shared then shared.testsLeft else 1024)
	local deadline = if shared then shared.deadline else started+0.002
	local limit = math.clamp(request.maxHits or 64,0,64)
	local result: Result = {hits={},cellVisits=0,candidateTests=0,isTruncated=false,hasCoverage=self.incomplete==0,oldestSourceTime=nil,elapsedMs=0}
	local seen: {[number]: boolean} = {}
	local seenCells: {[string]: boolean} = {}
	local hasStopped = false
	local corridorOrigin,corridorDirection,corridorRadius = Geometry.Corridor(request.shape)
	local expansion = Vector3.one*(corridorRadius+self.maxRadius)
	local probes = 0
	local function visit(x: number,y: number,z: number): ()
		if hasStopped then return end
		probes += 1
		if probes>maxCells*27 or os.clock()>=deadline then hasStopped=true; result.isTruncated=true; return end
		local cellKey = key(x,y,z)
		if seenCells[cellKey] then return end
		if result.cellVisits>=maxCells or os.clock()>=deadline then hasStopped=true; result.isTruncated=true; return end
		seenCells[cellKey] = true
		result.cellVisits += 1
		local bucket = self.buckets[cellKey]
		if not bucket then return end
		local count = #bucket.members
		local first = if request.shape.kind=="Sphere" then bucket.cursor%count else 0
		local gather=self.gathers[cellKey]
		if not gather or gather.first~=first then gather={first=first,ids={}}; self.gathers[cellKey]=gather end
		for offset=0,count-1 do
			if result.candidateTests>=maxTests or os.clock()>=deadline then hasStopped=true; result.isTruncated=true; bucket.cursor=(first+offset)%count; return end
			-- Duplicates and ignored memberships count against work too.
			result.candidateTests += 1
			local id=gather.ids[offset+1]
			if id then self.reusedCandidateRows+=1
			else id=bucket.members[(first+offset)%count+1].id; gather.ids[offset+1]=id; self.gatheredRows+=1 end
			if seen[id] then continue end
			seen[id] = true
			if request.ignored and request.ignored[id] then continue end
			local entry = self.entries[id]
			local position,sourceTime,startError = sampleAt(entry,self.slots,request.sampleTime)
			if not position then result.hasCoverage=false; continue end
			result.oldestSourceTime = math.min(result.oldestSourceTime or sourceTime,sourceTime)
			local motion: Vector3? = nil
			if request.endTime then
				local endpoint,_,endError = sampleAt(entry,self.slots,request.endTime)
				if not endpoint or startError+endError>2 then result.hasCoverage=false; continue end
				motion = endpoint-position
			end
			local distance = Geometry.Intersect(request.shape,position,entry.radius,motion)
			if not distance or limit==0 then continue end
			local impactPosition=position
			if motion and request.shape.kind=="Segment" then
				local length=(request.shape.direction or Vector3.zero).Magnitude
				local alpha=if length>0 then math.clamp(distance/length,0,1) else 0
				impactPosition=position+(motion :: Vector3)*alpha
			end
			local hits = result.hits
			if #hits<limit then table.insert(hits,makeHit(id,entry,request.shape,impactPosition,distance,sourceTime))
			else
				result.isTruncated = true
				local farthest = 1
				for i=2,#hits do if hits[i].distance>hits[farthest].distance then farthest=i end end
				if distance<hits[farthest].distance then hits[farthest]=makeHit(id,entry,request.shape,impactPosition,distance,sourceTime) end
			end
			if request.shape.kind=="Sphere" and #hits==limit then
				-- Dense area effects need a plausible bounded set, not a sorted
				-- census. Rotate the next effect past this accepted slice.
				bucket.cursor=(first+offset+1)%count
				result.isTruncated=true
				hasStopped=true
				return
			end
		end
		bucket.cursor = (first+math.min(count,maxTests))%count
	end
	local origin,direction = corridorOrigin,corridorDirection
	local x,y,z = coordinates(origin,self.cellSize)
	local endX,endY,endZ = coordinates(origin+direction,self.cellSize)
	local sx,sy,sz = math.sign(direction.X),math.sign(direction.Y),math.sign(direction.Z)
	local dx = if sx==0 then math.huge else self.cellSize/math.abs(direction.X)
	local dy = if sy==0 then math.huge else self.cellSize/math.abs(direction.Y)
	local dz = if sz==0 then math.huge else self.cellSize/math.abs(direction.Z)
	local tx = if sx==0 then math.huge else ((if sx>0 then x+1 else x)*self.cellSize-origin.X)/direction.X
	local ty = if sy==0 then math.huge else ((if sy>0 then y+1 else y)*self.cellSize-origin.Y)/direction.Y
	local tz = if sz==0 then math.huge else ((if sz>0 then z+1 else z)*self.cellSize-origin.Z)/direction.Z
	local enteredAt = 0
	while not hasStopped do
		local leavingAt = math.min(1,tx,ty,tz)
		local a,b = origin+direction*enteredAt,origin+direction*leavingAt
		local low,high = a:Min(b)-expansion,a:Max(b)+expansion
		local x0,y0,z0 = coordinates(low,self.cellSize)
		local x1,y1,z1 = coordinates(high,self.cellSize)
		for cx=x0,x1 do if hasStopped then break end
			for cy=y0,y1 do if hasStopped then break end
				for cz=z0,z1 do if hasStopped then break end
					visit(cx,cy,cz)
				end
			end
		end
		if x==endX and y==endY and z==endZ then break end
		local nextT = math.min(tx,ty,tz)
		if nextT>1 then break end
		enteredAt=nextT
		if tx<=nextT+1e-9 then x+=sx; tx+=dx end
		if ty<=nextT+1e-9 then y+=sy; ty+=dy end
		if tz<=nextT+1e-9 then z+=sz; tz+=dz end
	end
	table.sort(result.hits,function(a: Hit,b: Hit): boolean return if a.distance==b.distance then a.boidId<b.boidId else a.distance<b.distance end)
	result.elapsedMs = (os.clock()-started)*1000
	if shared then shared.cellsLeft-=result.cellVisits; shared.testsLeft-=result.candidateTests end
	self.queries+=1; self.tests+=result.candidateTests
	self.metricCursor=self.metricCursor%120+1; self.samplesMs[self.metricCursor]=result.elapsedMs
	return result
end
function Index.QueryBatch(self: State,requests: {Request},budget: Budget): {Result}
	assert(#requests<=64,"Query batch exceeds its trusted request limit")
	local results: {Result} = {}
	for i,request in requests do
		local reused: Result? = nil
		for j=1,i-1 do
			local previous = requests[j]
			local a,b = previous.shape,request.shape
			if not results[j].isTruncated and previous.sampleTime==request.sampleTime and previous.endTime==request.endTime and previous.ignored==request.ignored and previous.maxHits==request.maxHits and previous.maxCells==request.maxCells and previous.maxCandidates==request.maxCandidates
				and a.kind==b.kind and a.origin==b.origin and a.direction==b.direction and a.radius==b.radius and a.frame==b.frame and a.halfExtents==b.halfExtents then reused=results[j]; break end
		end
		if reused then
			local copy = table.clone(reused)
			copy.hits = {}
			for _,hit in reused.hits do table.insert(copy.hits,table.clone(hit)) end
			copy.cellVisits,copy.candidateTests,copy.elapsedMs = 0,0,0
			results[i] = copy
		else results[i]=Index.Query(self,request,budget) end
	end
	return results
end
function Index.Raycast(self: State,origin: Vector3,direction: Vector3,sweepRadius: number?,ignored: {[number]: boolean}?): Hit?
	return Index.Query(self,{shape={kind="Segment",origin=origin,direction=direction,radius=sweepRadius},maxHits=1,ignored=ignored}).hits[1]
end
function Index.QueryRadius(self: State,center: Vector3,radius: number,ignored: {[number]: boolean}?): {Hit}
	return Index.Query(self,{shape={kind="Sphere",origin=center,radius=radius},ignored=ignored}).hits
end
function Index.GetCount(self: State): number return self.count end
function Index.GetMetrics(self: State): Metrics
	local samples = table.clone(self.samplesMs); table.sort(samples)
	return {entryCount=self.count,queryCount=self.queries,candidateCount=self.tests,exactTestCount=self.tests,p50Ms=samples[math.max(1,math.ceil(#samples*0.5))] or 0,p95Ms=samples[math.max(1,math.ceil(#samples*0.95))] or 0,membershipCount=self.memberships,incompleteEntries=self.incomplete,gatheredRows=self.gatheredRows,reusedCandidateRows=self.reusedCandidateRows}
end
return CollisionIndex
