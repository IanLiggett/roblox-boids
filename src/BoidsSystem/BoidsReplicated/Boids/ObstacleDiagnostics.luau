--!strict

local SharedTypes = require(script.Parent.Parent.SharedTypes)
local Diagnostics = {}

function Diagnostics.Copy(value: SharedTypes.ObstacleObservation): SharedTypes.ObstacleObservation
	local copy = table.clone(value)
	copy.probes = {}
	copy.candidates = {}
	for index, probe in value.probes do copy.probes[index] = table.clone(probe) end
	for index, candidate in value.candidates do copy.candidates[index] = table.clone(candidate) end
	return copy
end

-- Capture existing query results as values; this module never performs a query.
function Diagnostics.RecordProbe(
	value: SharedTypes.ObstacleObservation,
	role: "Forward" | "Target" | "Heading" | "Escape",
	origin: Vector3,
	vector: Vector3,
	hit: RaycastResult?,
	candidateIndex: number?
): ()
	table.insert(value.probes, {
		role = role, origin = origin, vector = vector, didHit = hit ~= nil,
		candidateIndex = candidateIndex,
		hitPosition = if hit then hit.Position else nil,
		hitDistance = if hit then hit.Distance else nil,
		hitNormal = if hit then hit.Normal else nil,
	})
end

return Diagnostics
