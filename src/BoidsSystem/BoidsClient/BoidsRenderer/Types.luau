--!native
--!strict
-- Internal renderer protocol; cross-Actor collections are dense.
local Types = {}
export type Options = {read actorCount: number?}
export type Change = {id: number, lifetime: number, groupId: number, motor: Motor6D?, createdAt: number, cellKey: number?, cellOrigin: Vector3?}
export type Grant = {key: number, first: number, count: number}
export type Frame = {epoch: number, now: number, changes: {Change}, samples: buffer, grants: {Grant}, measure: boolean}
export type Pose = {boidId: number, groupId: number, cframe: CFrame, isRendered: boolean}
export type Sample = Pose & {lifetime: number, sampledAt: number, renderedAt: number?, snapshotAt: number?, velocity: Vector3}
export type Result = {epoch: number, dirty: number, kernelMs: number, synchronizeMs: number, assignmentMs: number, inputMs: number, error: string?}
export type GroupAge = {count: number, oldestRenderedAt: number?, sampledAt: number}
Types.SampleBytes = 56
function Types.WriteSample(data: buffer, offset: number, id: number, lifetime: number, at: number, interval: number?, position: Vector3, velocity: Vector3): ()
 buffer.writeu16(data,offset,id)
 buffer.writef64(data,offset+8,lifetime)
 buffer.writef64(data,offset+16,at)
 buffer.writef32(data,offset+24,interval or -1)
 buffer.writef32(data,offset+28,position.X)
 buffer.writef32(data,offset+32,position.Y)
 buffer.writef32(data,offset+36,position.Z)
 buffer.writef32(data,offset+40,velocity.X)
 buffer.writef32(data,offset+44,velocity.Y)
 buffer.writef32(data,offset+48,velocity.Z)
end
return Types

