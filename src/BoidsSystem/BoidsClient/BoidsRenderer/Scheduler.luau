--!native
--!strict
local Types=require(script.Parent.Types)
local Scheduler={}
type Config=typeof(require(game.ServerScriptService.BoidsSystem.BoidsReplicated.LODConfig).GetActive().client)
export type Fragment={ids: {number},resume: number}
export type Cell={key: number,origin: Vector3,fragments: {[number]: Fragment},count: number,nextDue: number,interval: number,deferred: number?,finished: boolean,distance: number,desiredInterval: number}
export type Member={key: number,owner: number,slot: number,lifetime: number}
export type State={cells: {[number]: Cell},members: {[number]: Member},actorCount: number,agingCursor: number,config: Config?}
export type Plan={grants: {{Types.Grant}},completed: {Cell},attempted: number,scheduledCells: number,activeCells: number,agedCells: number}
local radius=32*math.sqrt(3)
local function interval(cell: Cell,view: CFrame,cosine: number,config: Config): (number,number)
	local delta=cell.origin+Vector3.one*32-view.Position
	local length=delta.Magnitude
	local dot=delta:Dot(view.LookVector)
	if length>radius and dot<length*cosine-radius then return 1/config.offscreenHertz,length end
	local forward=if length>0 then dot/length else 1
	local edge=math.clamp((1-forward)/math.max(0.0001,1-cosine),0,1)
	local ramp=math.clamp((edge-0.75)/0.25,0,1)
	ramp=ramp*ramp*(3-2*ramp)
	local effective=math.max(0,length-radius)*(1+config.peripheralLodDistanceScale*ramp)
	local bands=config.visibleRenderBands
	local lo,hi,selected=1,#bands,#bands
	while lo<=hi do
		local middle=math.floor((lo+hi)*0.5)
		if effective<=bands[middle].range then selected=middle
		hi=middle-1 else lo=middle+1 end
	end
	return 1/bands[selected].hertz,length
end
function Scheduler.New(actorCount: number): State
	return {cells={},members={},actorCount=actorCount,agingCursor=1}
end
local function remove(state: State,id: number): ()
	local member=state.members[id]
	if not member then return end
	local cell=state.cells[member.key]
	local fragment=cell.fragments[member.owner]
	local moved=fragment.ids[#fragment.ids]
	fragment.ids[member.slot]=moved
	state.members[moved].slot=member.slot
	fragment.ids[#fragment.ids]=nil
	fragment.resume=math.min(fragment.resume,member.slot)
	cell.count-=1
	if #fragment.ids==0 then cell.fragments[member.owner]=nil end
	if cell.count==0 then state.cells[cell.key]=nil end
	state.members[id]=nil
end
function Scheduler.Apply(state: State,change: Types.Change,owner: number,now: number): ()
	local member=state.members[change.id]
	if member and member.lifetime==change.lifetime and member.key==change.cellKey and change.motor then return end
	remove(state,change.id)
	local key,origin=change.cellKey,change.cellOrigin
	if not change.motor or key==nil or origin==nil then return end
	local cell=state.cells[key]
	if not cell then
		local created: Cell={key=key,origin=origin,fragments={},count=0,nextDue=now,interval=0,finished=false,distance=0,desiredInterval=0}
		cell=created
		state.cells[key]=cell
	end
	local fragment=cell.fragments[owner]
	if not fragment then fragment={ids={},resume=1}
	cell.fragments[owner]=fragment end
	fragment.ids[#fragment.ids+1]=change.id
	cell.count+=1
	state.members[change.id]={key=key,owner=owner,slot=#fragment.ids,lifetime=change.lifetime}
end
function Scheduler.Plan(state: State,view: CFrame,fov: number,config: Config,now: number): Plan
	local plan: Plan={grants={},completed={},attempted=0,scheduledCells=0,activeCells=0,agedCells=0}
	for owner=1,state.actorCount do plan.grants[owner]={} end
	local due: {Cell}={}
	local aged: {Cell}={}
	local selected: {[number]: boolean}={}
	local cosine=math.cos(math.rad(fov*0.5))
	local changed=state.config~=config
	state.config=config
	for _,cell in state.cells do
		plan.activeCells+=1
		cell.finished=false
		local desired,cellDistance=interval(cell,view,cosine,config)
		cell.distance,cell.desiredInterval=cellDistance,desired
		if changed or desired<cell.interval then cell.nextDue=math.min(cell.nextDue,now) end
		if cell.nextDue<=now or cell.deferred~=nil then
			cell.deferred=cell.deferred or now
			due[#due+1]=cell
			if now-(cell.deferred :: number)>=0.5 then aged[#aged+1]=cell end
		end
	end
	plan.agedCells=#aged
	-- Stable cell ordering gives the persistent round-robin cursor a stable meaning.
	table.sort(aged,function(a: Cell,b: Cell): boolean return a.key<b.key end)
	local function grant(cell: Cell,limit: number): ()
		if cell.finished then return end
		local remaining=math.min(limit,config.maxRenderBoidsPerFrame-plan.attempted)
		if remaining<=0 then return end
		local added=0
		local finished=true
		for owner=1,state.actorCount do
			local fragment=cell.fragments[owner]
			if not fragment then continue end
			local available=#fragment.ids-fragment.resume+1
			local take=math.min(remaining,available)
			if take>0 then
				local grants=plan.grants[owner]
				local previous=grants[#grants]
				if previous and previous.key==cell.key and previous.first+previous.count==fragment.resume then
					previous.count+=take
				else grants[#grants+1]={key=cell.key,first=fragment.resume,count=take} end
				fragment.resume+=take
				remaining-=take
				added+=take
			end
			if fragment.resume<=#fragment.ids then finished=false end
		end
		plan.attempted+=added
		if added>0 and not selected[cell.key] then selected[cell.key]=true
		plan.scheduledCells+=1 end
		if finished then
			cell.finished=true
			plan.completed[#plan.completed+1]=cell
			cell.interval=cell.desiredInterval
		end
	end
	local reserve=math.min(config.maxRenderBoidsPerFrame,math.max(1,math.floor(config.maxRenderBoidsPerFrame*0.1)))
	local misses=0
	while #aged>0 and plan.attempted<reserve and misses<#aged do
		if state.agingCursor>#aged then state.agingCursor=1 end
		local cell=aged[state.agingCursor]
		state.agingCursor+=1
		local before=plan.attempted
		grant(cell,1)
		misses=if plan.attempted==before then misses+1 else 0
	end
	table.sort(due,function(a: Cell,b: Cell): boolean
		local da,db=a.distance,b.distance
		return if da==db then a.key<b.key else da<db
	end)
	for _,cell in due do
		if plan.attempted>=config.maxRenderBoidsPerFrame then break end
		grant(cell,math.huge)
	end
	return plan
end
function Scheduler.Settle(plan: Plan,renderedAt: number): ()
	for _,cell in plan.completed do
		for _,fragment in cell.fragments do fragment.resume=1 end
		cell.nextDue=renderedAt+cell.interval
		cell.deferred=nil
		cell.finished=false
	end
end
return Scheduler

