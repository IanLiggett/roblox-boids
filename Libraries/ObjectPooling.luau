local module = {}
local ObjectPools = {}

local ObjectPoolClass = {}
ObjectPoolClass.__index = ObjectPoolClass

local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

function module.NewObjectPool(ObjectConstructor, Name)
	if ObjectPools[Name] then
		error("Object Pool with name " .. Name .. " already exists")
	end
	
	local ObjectPool = setmetatable({
		Pool = {},
		
		ObjectConstructor = ObjectConstructor,
		
		ObjectTagId = HttpService:GenerateGUID(false),
		Name = Name
	}, ObjectPoolClass)
	
	ObjectPools[Name] = ObjectPool
	
	return ObjectPool
end

function module.GetObjectPool(Name)
	return ObjectPools[Name]
end

local function InsertObject(self, Object)
	self.Pool[Object] = true
end

local function RemoveObject(self, Object)
	self.Pool[Object] = nil
end

function ObjectPoolClass:NewObject(...)
	local Object = self.ObjectConstructor(...)
	CollectionService:AddTag(Object, self.ObjectTagId)

	InsertObject(self, Object)

	Object.Destroying:Once(function()
		RemoveObject(self, Object)
	end)

	return Object
end

function ObjectPoolClass:WithdrawObject()
	local Object, _ = next(self.Pool)
	if not Object then
		return nil
	end
	RemoveObject(self, Object)
			
	return Object
end

function ObjectPoolClass:ReturnObject(Object)
	InsertObject(self, Object)
	Object.Parent = nil
end

function ObjectPoolClass:Clear()
	for _, Object in self.Pool do
		Object:Destroy()
	end
	
	table.clear(self.Pool)
end

return module
