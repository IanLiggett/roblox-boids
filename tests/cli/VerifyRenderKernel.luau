--!strict
-- Replay production math against the feature branch's recorded main baseline.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = (require("@lune/roblox") :: unknown) :: {Vector3: typeof(Vector3), CFrame: typeof(CFrame)}
local root = if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local result = process.exec("git", {"-C", if root == "" then "." else root, "show", "c2b35bbf13097ca9feb92668a39fae0cee7b026b:src/BoidsSystem/BoidsClient/BoidsRenderer/init.luau"})
assert(result.ok, result.stderr)
local original = result.stdout:gsub("\r\n", "\n")
local function slice(first: string, last: string): string
 local a = original:find(first, 1, true)
 assert(a)
 local b = original:find(last, a + #first, true)
 assert(b)
 return original:sub(a, b - 1)
end
local offsets = slice("local F32_SIZE:", "local renderStateBuffer:")
local constants = slice("-- Smooth authoritative", "local COLOR_DEBUG_LOSS:")
local decay = slice("local function exponentialDecayAlpha", "local function safeDirection")
local init = slice("local function initRenderState(", "local function writeNewState("):gsub("\tensureRenderStateCapacity%(index%)\n", "")
local write = slice("local function writeNewState(", "type CompiledRenderBand")
local step = slice("local function renderBoid(", "local dirtyRenderIndices:")
local push = slice("local function pushSnapshot(", "local lastSnapshotTimeByBoid:")
local reference = offsets .. [[
 local renderStateBuffer = buffer.create(96 * 128)
 local renderTransforms = {}
 local renderIndexByBoid = {[1] = 1}
 local function stateOffset(index) return (index-1)*96 end
]] .. constants .. decay .. init .. write .. step .. push .. [[
 return {
 Init=function(now) initRenderState(1,1,now) end,
 Push=function(at,p,v) pushSnapshot(1,at,p.X,p.Y,p.Z,v.X,v.Y,v.Z) end,
 Step=function(now) if renderBoid(1,now,nil) then return renderTransforms[1] end end,
 Bytes=function() return buffer.readstring(renderStateBuffer,0,96) end,
 }
]]
local env = {Vector3=roblox.Vector3,CFrame=roblox.CFrame}
local baseline = luau.load(reference,{environment=env,injectGlobals=true})()
local kernel = luau.load(fs.readFile(root .. "src/BoidsSystem/BoidsClient/BoidsRenderer/Kernel.luau"),{environment=env,injectGlobals=true})()
local Vector3 = roblox.Vector3
local data = buffer.create(kernel.RowBytes)
kernel.Init(data,1,1)
baseline.Init(1)
assert(kernel.Step(data,1,1)==nil and baseline.Step(1)==nil)
local latest: number? = nil
local function push(at: number, p: Vector3, v: Vector3): ()
 baseline.Push(at,p,v)
 if latest and at<=latest then return end
 kernel.Push(data,1,at,p,v,if latest then at-latest else nil)
 latest=at
end
local checks=0
local function stepAt(now: number): ()
 local a,b=baseline.Step(now),kernel.Step(data,1,now)
 assert(a==b, "CFrame mismatch at " .. now)
 assert(baseline.Bytes()==buffer.readstring(data,0,96), "Packed state mismatch at " .. now)
 checks+=1
end
push(1,Vector3.zero,Vector3.new(10,0,0))
stepAt(1)
for i=1,300 do
 local now=1+i/60
 if i%17==0 then
  push(now,Vector3.new(i%43,i%11,-i%23),Vector3.new(if i%34==0 then -10 else 10,0,i%9))
  push(now,Vector3.one,Vector3.zero) -- equal-time rejection
  push(now-1,Vector3.one,Vector3.zero) -- stale rejection
 end
 stepAt(now)
end
push(20,Vector3.new(100,0,0),Vector3.zero)
stepAt(20)
stepAt(20)
stepAt(19) -- nonpositive elapsed time
stepAt(100) -- extrapolation clamp
print("PASS renderer kernel",checks,"identical CFrames and packed rows")

