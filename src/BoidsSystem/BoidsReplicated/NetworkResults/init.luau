--!strict
-- Public result-delivery facade. Child owners separate pure packets, server
-- transport lifetime, value-only metrics and synchronous local publication.
local PacketCodec = require(script.PacketCodec)
local ServerTransport = require(script.ServerTransport)
local LocalDelivery = require(script.LocalDelivery)
local TransportMetrics = require(script.TransportMetrics)
local NetworkResults = {
    MAX_PACKET_BYTES = PacketCodec.MAX_PACKET_BYTES,
    CELL_HEADER_BYTES = PacketCodec.CELL_HEADER_BYTES,
    BOID_ROW_BYTES = PacketCodec.BOID_ROW_BYTES,
    NewCellSnapshot = PacketCodec.NewCellSnapshot,
    GetOrCreateCellSnapshot = PacketCodec.GetOrCreateCellSnapshot,
    AppendBoid = PacketCodec.AppendBoid,
    ConvertSimulationSnapshotToPackets = PacketCodec.ConvertSimulationSnapshotToPackets,
    ForEachCellHeader = PacketCodec.ForEachCellHeader,
    ForEachBoid = PacketCodec.ForEachBoid,
    StartServer = ServerTransport.StartServer,
    DiscardBoids = ServerTransport.DiscardBoids,
    EnqueueSimulationSnapshotForPlayers = ServerTransport.EnqueueSimulationSnapshotForPlayers,
    PublishSimulationSnapshot = LocalDelivery.PublishSimulationSnapshot,
    GetTransportMetrics = TransportMetrics.Read,
}
return NetworkResults
