--!strict
-- Actor-local records reused by steering; lifecycle controls supply fences.
local PacketCodec = require(script.Parent.Parent.NetworkResults.PacketCodec)
local ActorCorrections = {}
export type Target = {
	position: Vector3, velocity: Vector3, snapshotTime: number, expiresAt: number,
	lifetime: number, retiredLifetime: number, ceiling: number, cutoff: number,
	isLive: boolean, isReplica: boolean,
}
export type State = {[number]: Target}
local function clear(target: Target): ()
	target.position, target.velocity = Vector3.zero, Vector3.zero
	target.snapshotTime, target.expiresAt, target.ceiling = 0, 0, 0
end
local function get(state: State, id: number): Target
	local target = state[id]
	if target then return target end
	target = {position = Vector3.zero, velocity = Vector3.zero, snapshotTime = 0, expiresAt = 0,
		lifetime = 0, retiredLifetime = 0, ceiling = 0, cutoff = -math.huge, isLive = false, isReplica = false}
	state[id] = target
	return target
end
function ActorCorrections.Register(state: State, id: number, lifetime: number, isReplica: boolean): Target?
	local target = get(state, id)
	if lifetime <= target.retiredLifetime or lifetime < target.lifetime then return nil end
	if not isReplica or target.ceiling < lifetime or target.snapshotTime <= target.cutoff then clear(target) end
	target.lifetime, target.isLive, target.isReplica = lifetime, true, isReplica
	return target
end
function ActorCorrections.Retire(state: State, id: number, lifetime: number, cutoff: number): ()
	local target = get(state, id)
	if lifetime < target.lifetime then return end
	target.retiredLifetime = math.max(target.retiredLifetime, lifetime)
	target.cutoff = math.max(target.cutoff, cutoff)
	target.isLive = false
	if target.ceiling <= lifetime or target.snapshotTime <= target.cutoff then clear(target) end
end
function ActorCorrections.Consume(state: State, packet: buffer, sourceTime: number, lifetimeCeiling: number): number
	-- No layout validation, staging table, repacking or second row pass.
	local rows = 0
	for offset, ox, oy, oz, count in PacketCodec.ForEachCellHeader(packet) do
		rows += count
		for id, px, py, pz, vx, vy, vz in PacketCodec.ForEachBoid(packet, offset, count) do
			local target = get(state, id)
			if sourceTime <= target.cutoff or sourceTime <= target.snapshotTime then continue end
			if target.isLive then
				if not target.isReplica or lifetimeCeiling < target.lifetime then continue end
			elseif lifetimeCeiling <= target.retiredLifetime then
				continue
			end
			target.position = Vector3.new(ox + px, oy + py, oz + pz)
			target.velocity = Vector3.new(vx, vy, vz)
			target.snapshotTime, target.expiresAt, target.ceiling = sourceTime, sourceTime + 6, lifetimeCeiling
		end
	end
	return rows
end
return ActorCorrections
