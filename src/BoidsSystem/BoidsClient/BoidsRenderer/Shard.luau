--!native
--!strict
local Kernel=require(script.Parent.Kernel)
local Types=require(script.Parent.Types)
local Shard={}
type Row={id: number,lifetime: number,groupId: number,motor: Motor6D,cellKey: number?,cellSlot: number?,hasRendered: boolean}
export type State={data: buffer,rows: {Row},byId: {[number]: number},cells: {[number]: {number}},transforms: {CFrame},dirty: {number}}
local function removeCell(state: State,index: number): ()
	local row=state.rows[index]
	local key,slot=row.cellKey,row.cellSlot
	if key==nil or slot==nil then return end
	local members=state.cells[key]
	local moved=members[#members]
	members[slot]=moved
	state.rows[moved].cellSlot=slot
	members[#members]=nil
	if #members==0 then state.cells[key]=nil end
	row.cellKey,row.cellSlot=nil,nil
end
local function removeRow(state: State,index: number): ()
	local row=state.rows[index]
	removeCell(state,index)
	local last=#state.rows
	local moved=state.rows[last]
	state.byId[row.id]=nil
	if index~=last then
		state.rows[index]=moved
		state.byId[moved.id]=index
		state.transforms[index]=state.transforms[last]
		buffer.copy(state.data,(index-1)*Kernel.RowBytes,state.data,(last-1)*Kernel.RowBytes,Kernel.RowBytes)
		if moved.cellKey and moved.cellSlot then state.cells[moved.cellKey][moved.cellSlot]=index end
	end
	state.rows[last]=nil
	state.transforms[last]=nil
end
function Shard.New(): State
	return {data=buffer.create(Kernel.RowBytes*128),rows={},byId={},cells={},transforms={},dirty={}}
end
function Shard.Apply(state: State,changes: {Types.Change},samples: buffer): ()
	for _,change in changes do
		local index=state.byId[change.id]
		if index and (state.rows[index].lifetime~=change.lifetime or change.motor==nil) then removeRow(state,index)
		index=nil end
		local motor=change.motor
		if not motor then continue end
		if not index then
			index=#state.rows+1
			if index*Kernel.RowBytes>buffer.len(state.data) then
				local nextData=buffer.create(buffer.len(state.data)*2)
				buffer.copy(nextData,0,state.data)
				state.data=nextData
			end
			state.rows[index]={id=change.id,lifetime=change.lifetime,groupId=change.groupId,motor=motor,hasRendered=false}
			state.byId[change.id]=index
			state.transforms[index]=motor.Transform
			Kernel.Init(state.data,index,change.createdAt)
		end
		local rowIndex=assert(index)
		local row=state.rows[rowIndex]
		if row.cellKey~=change.cellKey then
			removeCell(state,rowIndex)
			local key=change.cellKey
			if key then
				local members=state.cells[key]
				if not members then members={}
				state.cells[key]=members end
				members[#members+1]=rowIndex
				row.cellKey,row.cellSlot=key,#members
			end
		end
	end
	for offset=0,buffer.len(samples)-Types.SampleBytes,Types.SampleBytes do
		local index=state.byId[buffer.readu16(samples,offset)]
		if not index or state.rows[index].lifetime~=buffer.readf64(samples,offset+8) then continue end
		local interval=buffer.readf32(samples,offset+24)
		Kernel.Push(state.data,index,buffer.readf64(samples,offset+16),
			Vector3.new(buffer.readf32(samples,offset+28),buffer.readf32(samples,offset+32),buffer.readf32(samples,offset+36)),
			Vector3.new(buffer.readf32(samples,offset+40),buffer.readf32(samples,offset+44),buffer.readf32(samples,offset+48)),
			if interval>=0 then interval else nil)
	end
end
function Shard.Calculate(state: State,grants: {Types.Grant},now: number): ()
	table.clear(state.dirty)
	for _,grant in grants do
		local members=assert(state.cells[grant.key],"Missing render fragment")
		for slot=grant.first,grant.first+grant.count-1 do
			local index=assert(members[slot],"Invalid render grant")
			local transform=Kernel.Step(state.data,index,now)
			if transform then state.transforms[index]=transform
			state.dirty[#state.dirty+1]=index end
		end
	end
end
function Shard.Commit(state: State): number
	local count=0
	for _,index in state.dirty do
		local row=state.rows[index]
		local motor=row.motor
		-- Deleted lifetimes retain their original destroyed Motor reference.
		if motor.Parent==nil then continue end
		motor.Transform=state.transforms[index]
		if not row.hasRendered then row.hasRendered=true
		motor:SetAttribute("HasRendered",true) end
		count+=1
	end
	return count
end
function Shard.Sample(state: State,id: number,lifetime: number): Types.Sample?
	local index=state.byId[id]
	if not index then return nil end
	local row=state.rows[index]
	if row.lifetime~=lifetime or row.motor.Parent==nil then return nil end
	local sample=Kernel.Read(state.data,index)
	return {boidId=id,groupId=row.groupId,lifetime=lifetime,cframe=state.transforms[index],
		isRendered=row.hasRendered,velocity=sample.velocity,renderedAt=sample.renderedAt,
		snapshotAt=sample.snapshotAt,sampledAt=workspace:GetServerTimeNow()}
end
function Shard.GroupAge(state: State,groupId: number): Types.GroupAge
	local count,oldest=0,math.huge
	for index,row in state.rows do
		if row.groupId~=groupId or not row.hasRendered or row.motor.Parent==nil then continue end
		local sample=Kernel.Read(state.data,index)
		if sample.renderedAt then count+=1
		oldest=math.min(oldest,sample.renderedAt) end
	end
	return {count=count,oldestRenderedAt=if count>0 then oldest else nil,sampledAt=workspace:GetServerTimeNow()}
end
return Shard

