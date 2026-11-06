--!strict
-- Real packed codecs and recipient state; no networking or Actor scheduling.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local root = if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local base = root.."src/BoidsSystem/BoidsReplicated/"
local package: any = {SharedTypes={}}
local function load(path: string,parent: any): any
	return luau.load(fs.readFile(base..path),{debugName=path,injectGlobals=true,environment={
		script={Parent=parent},Vector3=roblox.Vector3,CFrame=roblox.CFrame,
		require=function(value: any): any return value end,
	}})()
end
package.Quantization = load("Quantization.luau",package)
package.BoidStorage = load("BoidStorage.luau",package)
package.SnapshotCodec = load("SnapshotCodec.luau",package)
local network: any = {Parent=package}
package.NetworkResults = network
network.PacketCodec = load("NetworkResults/PacketCodec.luau",network)
network.PredictionState = load("NetworkResults/PredictionState.luau",network)
network.TransportMetrics = load("NetworkResults/TransportMetrics.luau",network)
local passed,failed = 0,0
local expect: any = {}
function expect.equal(actual: any,expected: any): () assert(actual==expected,`expected {expected}, got {actual}`) end
function expect.truthy(value: any): () assert(value,"expected truthy") end
function expect.falsy(value: any): () assert(not value,"expected falsy") end
for _, name in {"PredictionState", "PacketCodec"} do
	local cases: any = luau.load(fs.readFile(root.."tests/UnitTest/Cases/"..name.."_Test.luau"),{
		debugName=name.."_Test",injectGlobals=true,environment={
			script={Parent={Parent={RunUnitTest={}}}},
			game={ReplicatedStorage={WaitForChild=function(): any return package end}},
			Vector3=roblox.Vector3,require=function(value: any): any return value end,
		},
	})()
	cases({expect=expect,test=function(name: string,fn: () -> ()): ()
		local ok,failure = pcall(fn)
		if ok then passed+=1;print("PASS",name) else failed+=1;warn("FAIL",name,failure) end
	end})
end
assert(failed==0,`{failed} network cases failed`)
print(`SUMMARY {passed} network cases passed`)
