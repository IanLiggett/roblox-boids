--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local root = if fs.isDir("packages/BoidsSystem") then "packages/BoidsSystem/" else ""
local base = root.."src/BoidsSystem/BoidsReplicated/"
local function load(path: string,env: {[string]: unknown}): unknown
	env.Vector3,env.CFrame = roblox.Vector3,roblox.CFrame
	return luau.load(fs.readFile(path),{debugName=path,injectGlobals=true,environment=env})()
end
local geometry = load(base.."CollisionGeometry.luau",{})
local index = load(base.."CollisionIndex.luau",{script={Parent={CollisionGeometry=geometry}},require=function(value) return value end})
local package = {CollisionGeometry=geometry,CollisionIndex=index}
function package.WaitForChild(self,name) return self[name] end
local cases = load(root.."tests/UnitTest/Cases/CollisionIndex_Test.luau",{
	game={GetService=function() return {WaitForChild=function() return package end} end},
	script={Parent={Parent={RunUnitTest={}}}},require=function(value) return value end,
})
local failed = 0
local expect = {}
function expect.equal(a,b) assert(a==b,`expected {b}, got {a}`) end
function expect.truthy(value) assert(value,"expected truthy") end
function expect.falsy(value) assert(not value,"expected falsy") end
function expect.near(a,b) assert(a and math.abs(a-b)<1e-5,`expected {b}, got {a}`) end
cases({expect=expect,test=function(name,fn)
	local ok,err=pcall(fn)
	if ok then print("PASS",name) else failed+=1; warn("FAIL",name,err) end
end})
assert(failed==0,`{failed} collision tests failed`)
