--!strict
local UnitTest = require(script.Parent.Parent.RunUnitTest)

return function(t: UnitTest.Context): ()
 local package = (game.ReplicatedStorage:WaitForChild("BoidsReplicated") :: Instance)
		:: typeof(game.ServerScriptService.BoidsSystem.BoidsReplicated)
 local codec = require(package.NetworkResults.PacketCodec)
 t.test("packet splitting copies only used canonical rows and preserves signed origins", function()
  local origin = Vector3.new(-32768,128,32767)
  local cell = codec.NewCellSnapshot(512,origin)
  for id=1,300 do
   codec.AppendBoid(cell,id,Vector3.new(id%100,20,30),Vector3.new(1,-2,3))
  end
  local packets = codec.ConvertSimulationSnapshotToPackets({[17]=cell})
  t.expect.truthy(#packets>1)
  local rows = {}
  local count = 0
  for _,packet in packets do
   t.expect.truthy(buffer.len(packet)<=codec.MAX_PACKET_BYTES)
   for offset,x,y,z,n in codec.ForEachCellHeader(packet) do
    t.expect.equal(Vector3.new(x,y,z),origin)
    table.insert(rows,buffer.readstring(packet,offset,n*codec.BOID_ROW_BYTES))
    for id in codec.ForEachBoid(packet,offset,n) do
     count+=1
     t.expect.equal(id,count)
    end
   end
  end
  t.expect.equal(count,300)
  t.expect.equal(table.concat(rows),buffer.readstring(cell.networkBoids,0,cell.boidCount*codec.BOID_ROW_BYTES))
  t.expect.equal(#codec.ConvertSimulationSnapshotToPackets({}),0)
 end)
end
