--!strict
-- Shared numeric transport counters; importing readers never imports delivery.
local TransportMetrics = {}
export type Snapshot = {sentPackets: number, sentPayloadBytes: number}
local sentPackets = 0
local sentPayloadBytes = 0
function TransportMetrics.RecordSent(payloadBytes: number): ()
    sentPackets += 1
    sentPayloadBytes += payloadBytes
end
function TransportMetrics.Read(): Snapshot
    return {sentPackets=sentPackets,sentPayloadBytes=sentPayloadBytes}
end
return TransportMetrics
