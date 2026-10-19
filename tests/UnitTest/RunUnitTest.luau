--!strict
-- Manual, isolated test runner; never enabled at startup.
local ServerStorage = game:GetService("ServerStorage")
local expect = {}
function expect.equal(a: unknown, b: unknown): () assert(a == b, "expected " .. tostring(b) .. ", got " .. tostring(a)) end
function expect.truthy(v: unknown): () assert(v, "expected truthy value") end
function expect.falsy(v: unknown): () assert(not v, "expected falsy value") end
function expect.near(a: number, b: number, tolerance: number?): () assert(math.abs(a-b) <= (tolerance or 1e-6), "values not near") end
function expect.throws(fn: () -> ()): () assert(not pcall(fn), "expected error") end
function expect.deepEqual(a: unknown, b: unknown): ()
 if type(a) ~= "table" or type(b) ~= "table" then expect.equal(a,b); return end
 local left: {[unknown]: unknown} = a :: {[unknown]: unknown}
 local right: {[unknown]: unknown} = b :: {[unknown]: unknown}
 for k,v in left do expect.deepEqual(v,right[k]) end
 for k in right do assert(left[k] ~= nil, "missing key") end
end

export type Context = {
 expect: typeof(expect),
 test: (string, () -> ()) -> (),
}

export type Totals = {run: number, passed: number, failed: number}

-- Authored Cases modules share this entry contract; discovery remains dynamic.
local loadCase: (ModuleScript) -> ((Context) -> ()) = require

return function(filter: string?, timeout: number?): Totals
 local totals: Totals = {run=0,passed=0,failed=0}
 for _, module in ServerStorage.UnitTest.Cases:GetChildren() do
  if not module:IsA("ModuleScript") or (filter and not module.Name:find(filter,1,true)) then continue end
  local t = {expect=expect}
  function t.test(name: string, fn: () -> ()): ()
   totals.run += 1
   local done, ok = false, false
   local failure: unknown = nil
   local started = os.clock()
   local thread: thread = task.spawn(function(): () ok,failure=pcall(fn);done=true end)
   while not done and os.clock()-started < (timeout or 5) do task.wait() end
   if not done then task.cancel(thread);failure="timeout";ok=false end
   if ok then totals.passed += 1;print("[PASS] " .. module.Name .. " > " .. name)
   else totals.failed += 1;warn("[FAIL] " .. module.Name .. " > " .. name .. ": " .. tostring(failure)) end
  end
  local ok,err=pcall(function(): () loadCase(module)(t) end)
  if not ok then totals.run+=1;totals.failed+=1;warn("[FAIL] "..module.Name..": "..tostring(err)) end
 end
 print(string.format("[SUMMARY] %d run, %d passed, %d failed",totals.run,totals.passed,totals.failed))
 return totals
end
