--!strict
-- Reliable, session-scoped identity. Process-local Actor/render lifetimes keep
-- their existing meaning; a replica serial is never used as that lifetime.
local ReplicaIdentity = {}
local serials: {[number]: number} = {}
local sourceCutoffs: {[number]: number} = {}
local nextSerial = 0

function ReplicaIdentity.Issue(id: number): number
	assert(nextSerial < 4294967295,"Replica serial exhausted; start a fresh session")
	nextSerial += 1
	serials[id] = nextSerial
	return nextSerial
end
function ReplicaIdentity.Set(id: number,serial: number): () serials[id] = serial end
function ReplicaIdentity.Get(id: number): number? return serials[id] end
function ReplicaIdentity.GetCeiling(): number return nextSerial end
function ReplicaIdentity.Remove(id: number,sourceCutoff: number?): ()
	serials[id] = nil
	if sourceCutoff then sourceCutoffs[id]=math.max(sourceCutoffs[id] or -math.huge,sourceCutoff) end
end
function ReplicaIdentity.GetSourceCutoff(id: number): number return sourceCutoffs[id] or -math.huge end
return ReplicaIdentity
