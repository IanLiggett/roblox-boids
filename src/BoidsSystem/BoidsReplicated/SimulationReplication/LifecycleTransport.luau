--!strict
-- Reliable lifecycle stays ordered and is paced separately from replaceable
-- poses. Bootstrap streams batches; it does not allocate a full pose copy/player.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LifecycleTransport = {}
type Message = {kind: string,args: {unknown},count: number,bytes: number,fieldKey: string?,hasField: boolean?}
type Recipient = {queue: {[number]: Message},head: number,tail: number,bytes: number,tokens: number,credit: number,isReplaying: boolean,replaceable: {[string]: number},publishedFields: {[string]: boolean}}
local recipients: {[Player]: Recipient} = {}
local remote: RemoteEvent? = nil
local globalCredit = 104857
local recipientCursor=0
local MAX_MESSAGES = 8192
local MAX_BYTES = 8388608
local function recipient(player: Player): Recipient
	local state=recipients[player]
	if state then return state end
	local created: Recipient={queue={},head=1,tail=0,bytes=0,tokens=3,credit=6553,isReplaying=false,replaceable={},publishedFields={}}
	recipients[player]=created
	return created
end
local function fieldKey(kind: string,args: {unknown}): (string?,boolean?)
	if kind=="GlobalWell" then return `g:{(args[1] :: {id: number}).id}`,true end
	if kind=="RemoveGlobalWell" then return `g:{args[1] :: number}`,false end
	if kind=="GroupWell" then return `c:{args[1] :: number}:{(args[2] :: {id: number}).id}`,true end
	if kind=="RemoveGroupWell" then return `c:{args[1] :: number}:{args[2] :: number}`,false end
	return nil,nil
end
local function sizeOf(kind: string,args: {unknown}): number
	if kind=="Boids" and typeof(args[2])=="buffer" then return buffer.len(args[2] :: buffer)+32 end
	if kind=="DeleteBoids" and typeof(args[1])=="buffer" then return buffer.len(args[1] :: buffer)+32 end
	if kind=="Path" then return 512 end
	return 128
end
local function send(player: Player,state: Recipient,message: Message): boolean
	if state.tokens<1 or state.credit<message.bytes or globalCredit<message.bytes then return false end
	state.tokens-=1; state.credit-=message.bytes; globalCredit-=message.bytes
	assert(remote):FireClient(player,message.kind,table.unpack(message.args,1,message.count))
	if message.fieldKey then state.publishedFields[message.fieldKey]=if message.hasField then true else nil end
	return true
end
function LifecycleTransport.Start(event: RemoteEvent): ()
	if remote then return end
	remote=event
	Players.PlayerRemoving:Connect(function(player: Player): () recipients[player]=nil end)
	RunService.PostSimulation:Connect(function(dt: number): ()
		globalCredit=math.min(104857,globalCredit+1048576*dt)
		local players=Players:GetPlayers()
		local count=#players
		for offset=0,count-1 do
			local player=players[(recipientCursor+offset)%count+1]
			local state=recipients[player]
			if not state then continue end
			state.tokens=math.min(3,state.tokens+25*dt)
			state.credit=math.min(6553,state.credit+65536*dt)
			if state.isReplaying then continue end
			for _=1,3 do
				if state.tokens<1 then break end
				local batch: {{kind: string,args: {unknown}}}={}
				local bytes=32
				-- Commands share one reliable packet while retaining FIFO order.
				-- Bound assembly, including cancelled replaceable slots.
				for _slot=1,64 do
					if state.head>state.tail or #batch>=32 then break end
					local slot=(state.head-1)%MAX_MESSAGES+1
					local message=state.queue[slot]
					if not message then state.head+=1; continue end
					if bytes+message.bytes>math.min(6553,state.credit,globalCredit) then break end
					bytes+=message.bytes
					table.insert(batch,{kind=message.kind,args=message.args})
					if message.fieldKey and state.replaceable[message.fieldKey]==slot then state.replaceable[message.fieldKey]=nil end
					if message.fieldKey then state.publishedFields[message.fieldKey]=if message.hasField then true else nil end
					state.bytes-=message.bytes; state.queue[slot]=nil; state.head+=1
				end
				if #batch==0 then break end
				state.tokens-=1; state.credit-=bytes; globalCredit-=bytes
				assert(remote):FireClient(player,"Batch",batch)
			end
			if state.head>state.tail then state.head=1; state.tail=0 end
		end
		recipientCursor=(recipientCursor+1)%math.max(1,count)
	end)
end
function LifecycleTransport.Broadcast(kind: string,...: unknown): ()
	local args={...}
	local key,hasField=fieldKey(kind,args)
	local message: Message={kind=kind,args=args,count=select("#",...),bytes=sizeOf(kind,args),fieldKey=key,hasField=hasField}
	for _,player in Players:GetPlayers() do
		-- Before the first admitted replay the client has no authoritative
		-- lifecycle. The replay ledger supplies that population; queueing it
		-- here as well doubles bootstrap traffic and retains redundant rows.
		local state=recipients[player]
		if not state then continue end
		if kind=="DestroyGroup" then
			-- A replacement group's controls must not move before its creation
			-- by replacing a slot belonging to the retired group's force state.
			local prefix=`c:{args[1] :: number}:`
			for pendingKey in state.replaceable do
				if pendingKey:sub(1,#prefix)==prefix then state.replaceable[pendingKey]=nil end
			end
		end
		local previous=if key then state.replaceable[key] else nil
		if key and hasField==false and not state.publishedFields[key] and not state.isReplaying then
			if previous then state.bytes-=state.queue[previous].bytes; state.queue[previous]=nil; state.replaceable[key]=nil end
			continue
		end
		if previous then state.bytes+=message.bytes-state.queue[previous].bytes; state.queue[previous]=message; continue end
		assert(state.tail-state.head+1<MAX_MESSAGES and state.bytes+message.bytes<=MAX_BYTES,"Trusted lifecycle producer exceeded bounded transport capacity")
		state.tail+=1
		local slot=(state.tail-1)%MAX_MESSAGES+1
		state.queue[slot]=message; state.bytes+=message.bytes
		if key then state.replaceable[key]=slot end
	end
end
function LifecycleTransport.BeginReplay(player: Player): () recipient(player).isReplaying=true end
function LifecycleTransport.HasRecipient(player: Player): boolean return recipients[player]~=nil end
function LifecycleTransport.SendReplay(player: Player,kind: string,...: unknown): ()
	local state=recipient(player)
	local args={...}
	local key,hasField=fieldKey(kind,args)
	local message: Message={kind=kind,args=args,count=select("#",...),bytes=sizeOf(kind,args),fieldKey=key,hasField=hasField}
	while player.Parent==Players and not send(player,state,message) do task.wait(0.02) end
end
function LifecycleTransport.EndReplay(player: Player): ()
	local state=recipients[player]
	if state then state.isReplaying=false end
end
function LifecycleTransport.HasCombatCapacity(): boolean
	for _,state in recipients do if state.bytes>4194304 or state.tail-state.head>4096 then return false end end
	return true
end
function LifecycleTransport.GetMetrics(): {queuedBytes: number,queuedMessages: number,maxRecipientBytes: number}
	local bytes,messages,maximum=0,0,0
	for _,state in recipients do bytes+=state.bytes; messages+=state.tail-state.head+1; maximum=math.max(maximum,state.bytes) end
	return {queuedBytes=bytes,queuedMessages=messages,maxRecipientBytes=maximum}
end
return LifecycleTransport
