--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local package = ReplicatedStorage:WaitForChild("BoidsReplicated")
local CollisionIndex = require(package:WaitForChild("CollisionIndex"))
local Geometry = require(package:WaitForChild("CollisionGeometry"))
local TestRunner = require(script.Parent.Parent.RunUnitTest)
type Context = TestRunner.Context

return function(t: Context): ()
	t.test("sweep excludes behind, includes initial overlap and grazing",function()
		t.expect.equal(Geometry.Sweep(Vector3.zero,Vector3.xAxis*10,-Vector3.xAxis*5,1),nil)
		t.expect.equal(Geometry.Sweep(Vector3.zero,Vector3.zero,Vector3.zero,1),0)
		t.expect.near(Geometry.Sweep(Vector3.zero,Vector3.xAxis*10,Vector3.new(5,1,0),1),0.5)
		t.expect.equal(Geometry.Sweep(Vector3.zero,Vector3.zero,Vector3.xAxis*2,1),nil)
	end)
	t.test("sphere and oriented box queries include proxy boundaries",function()
		local index = CollisionIndex.new()
		index:Update(1,Vector3.new(-32,0,-10),1,7)
		index:Update(2,Vector3.new(-32,0,-20),1,8)
		local result = index:Query({shape={kind="Box",origin=Vector3.new(-32,0,0),frame=CFrame.new(-32,0,-10),halfExtents=Vector3.new(1,1,9)},maxHits=64})
		t.expect.equal(#result.hits,2)
		t.expect.truthy(result.hasCoverage)
		t.expect.equal(result.hits[1].replicaSerial,7)
		local sphere = index:Query({shape={kind="Sphere",origin=Vector3.new(-32,0,-10),radius=9}})
		t.expect.equal(#sphere.hits,2)
	end)
	t.test("one dense bucket respects independent work and output caps",function()
		local index = CollisionIndex.new()
		for id=1,30000 do index:Update(id,Vector3.new(1,1,1),1,1) end
		local budget = {cellsLeft=64,testsLeft=128,deadline=os.clock()+10}
		local result = index:Query({shape={kind="Sphere",origin=Vector3.zero,radius=12},maxHits=16,maxCandidates=1000},budget)
		t.expect.truthy(result.candidateTests<=128)
		t.expect.equal(#result.hits,16)
		t.expect.truthy(result.isTruncated)
		t.expect.equal(budget.testsLeft,128-result.candidateTests)
	end)
	t.test("historical membership and relative motion catch crossing targets",function()
		local index = CollisionIndex.new({cellSize=64,historySlots=12})
		index:Update(1,Vector3.new(40,10,0),1,9,1,Vector3.new(0,-200,0))
		index:Update(1,Vector3.new(40,-10,0),1,9,1.1,Vector3.new(0,-200,0))
		local result = index:Query({shape={kind="Segment",origin=Vector3.zero,direction=Vector3.xAxis*80},sampleTime=1,endTime=1.1})
		t.expect.equal(#result.hits,1)
		t.expect.truthy(math.abs(result.hits[1].proxyPosition.Y)<=1,"Moving contact retained the start-of-interval proxy")
		t.expect.truthy(index:ValidateHint({id=1,replicaSerial=9},{kind="Segment",origin=Vector3.zero,direction=Vector3.xAxis*80},Vector3.new(40,0,0),1.05,12))
		t.expect.falsy(index:ValidateHint({id=1,replicaSerial=9},{kind="Segment",origin=Vector3.zero,direction=Vector3.xAxis*80},Vector3.new(90,0,0),1.05,12))
	end)
	t.test("deletion and identity reuse reject queued old hints and history",function()
		local index = CollisionIndex.new({historySlots=12})
		index:Update(1,Vector3.zero,1,10,1)
		index:Remove(1)
		index:Update(1,Vector3.xAxis*5,1,11,2)
		t.expect.falsy(index:Sample({id=1,replicaSerial=10},2))
		t.expect.falsy(index:Sample({id=1,replicaSerial=11},1))
		local entry = index:GetEntry(1)
		entry.position = Vector3.zero
		t.expect.equal(index:GetEntry(1).position,Vector3.xAxis*5)
	end)
	t.test("frequent samples advance the bounded history ring",function()
		local index = CollisionIndex.new({historySlots=12})
		for step=0,30 do index:Update(1,Vector3.xAxis*step,1,9,1+step/60,Vector3.xAxis*60) end
		local sample = index:Sample({id=1,replicaSerial=9},1.25)
		t.expect.truthy(sample)
		t.expect.near(sample.position.X,15)
	end)
	t.test("oversized temporal coverage is explicit and memory bounded",function()
		local index = CollisionIndex.new({historySlots=12})
		index:Update(1,Vector3.zero,1,10,1)
		index:Update(1,Vector3.one*10000,1,10,1.1)
		t.expect.equal(index:GetMetrics().incompleteEntries,1)
		t.expect.equal(index:GetMetrics().membershipCount,0)
		t.expect.falsy(index:Query({shape={kind="Sphere",origin=Vector3.zero,radius=12}}).hasCoverage)
		index:Remove(1)
		t.expect.equal(index:GetMetrics().incompleteEntries,0)
	end)
	t.test("complete randomized queries match the mathematical oracle",function()
		local index=CollisionIndex.new({cellSize=16})
		local seed=5731
		local function random(): number seed=(seed*16807)%2147483647; return seed/2147483647 end
		local positions: {Vector3}={}
		for id=1,32 do
			local position=Vector3.new(random()*80-40,random()*80-40,random()*80-40)
			positions[id]=position; index:Update(id,position,2,id)
		end
		for ordinal=1,90 do
			local origin=Vector3.new(random()*40-20,random()*40-20,random()*40-20)
			local shape: Geometry.Shape
			if ordinal%3==0 then shape={kind="Sphere",origin=origin,radius=20}
			elseif ordinal%3==1 then shape={kind="Segment",origin=origin,direction=Vector3.new(random()*100-50,random()*100-50,random()*100-50),radius=3}
			else shape={kind="Box",origin=origin,frame=CFrame.new(origin)*CFrame.Angles(random(),random(),random()),halfExtents=Vector3.new(12,8,16)} end
			local expected: {[number]: boolean}={}
			for id,position in positions do if Geometry.Intersect(shape,position,2) then expected[id]=true end end
			local result=index:Query({shape=shape,maxHits=64,maxCells=4096,maxCandidates=4096},{cellsLeft=4096,testsLeft=4096,deadline=os.clock()+10})
			t.expect.falsy(result.isTruncated); t.expect.truthy(result.hasCoverage)
			for _,hit in result.hits do t.expect.truthy(expected[hit.boidId]); expected[hit.boidId]=nil end
			t.expect.equal(next(expected),nil)
		end
	end)
	t.test("batch sharing preserves filters and copied results and invalidates on updates",function()
		local index=CollisionIndex.new()
		index:Update(1,Vector3.xAxis*10,1,9)
		local shape: Geometry.Shape={kind="Segment",origin=Vector3.zero,direction=Vector3.xAxis*20}
		local budget={cellsLeft=4096,testsLeft=4096,deadline=os.clock()+10}
		local results=index:QueryBatch({{shape=shape},{shape=shape},{shape=shape,ignored={[1]=true}}},budget)
		t.expect.equal(#results[1].hits,1); t.expect.equal(#results[2].hits,1); t.expect.equal(#results[3].hits,0)
		t.expect.equal(results[2].candidateTests,0)
		results[1].hits[1].replicaSerial=100
		t.expect.equal(results[2].hits[1].replicaSerial,9)
		t.expect.truthy(index:GetMetrics().reusedCandidateRows>0)
		index:Remove(1); index:Update(1,Vector3.xAxis*10,1,10)
		local updated=index:Query({shape=shape},budget)
		t.expect.equal(updated.hits[1].replicaSerial,10)
	end)
	t.test("uncertain motion skips explicitly while settled poses and bounded visible hints remain usable",function()
		local index=CollisionIndex.new({historySlots=12})
		index:Update(1,Vector3.new(10,8,0),1,9,1,Vector3.zero,100)
		local shape: Geometry.Shape={kind="Segment",origin=Vector3.zero,direction=Vector3.xAxis*20}
		local stale=index:Query({shape=shape,sampleTime=1.5,endTime=1.6})
		t.expect.equal(#stale.hits,0); t.expect.falsy(stale.hasCoverage)
		t.expect.truthy(index:ValidateHint({id=1,replicaSerial=9},shape,Vector3.xAxis*10,2,12))
		t.expect.falsy(index:ValidateHint({id=1,replicaSerial=9},shape,Vector3.xAxis*10+Vector3.yAxis*40,2,24))
		index:Update(1,Vector3.xAxis*10,1,9,2,Vector3.zero,100)
		t.expect.equal(#index:Query({shape=shape}).hits,1)
		local turned=index:Query({shape=shape,sampleTime=1.8,endTime=1.9})
		t.expect.falsy(turned.hasCoverage)
	end)
end
