--!strict
-- Mathematical sphere proxies only. No Instance or physics-query dependency.
local Geometry = {}
export type Shape = {kind: "Segment" | "Sphere" | "Box", origin: Vector3, direction: Vector3?, radius: number?, frame: CFrame?, halfExtents: Vector3?}

function Geometry.Sweep(origin: Vector3, displacement: Vector3, center: Vector3, radius: number): number?
	local offset = origin-center
	local c = offset:Dot(offset)-radius*radius
	if c <= 0 then return 0 end
	local a = displacement:Dot(displacement)
	if a <= 1e-12 then return nil end
	local b = offset:Dot(displacement)
	if b >= 0 then return nil end
	local discriminant = b*b-a*c
	if discriminant < 0 then return nil end
	local alpha = (-b-math.sqrt(discriminant))/a
	return if alpha >= 0 and alpha <= 1 then alpha else nil
end

function Geometry.Intersect(shape: Shape, position: Vector3, proxyRadius: number, motion: Vector3?): number?
	if shape.kind == "Segment" then
		local direction = shape.direction or Vector3.zero
		local alpha = Geometry.Sweep(shape.origin,direction-(motion or Vector3.zero),position,proxyRadius+(shape.radius or 0))
		return if alpha then alpha*direction.Magnitude else nil
	end
	if shape.kind == "Sphere" then
		local distance = (position-shape.origin).Magnitude
		return if distance <= proxyRadius+(shape.radius or 0) then distance else nil
	end
	local localPosition = assert(shape.frame):PointToObjectSpace(position)
	local extent = assert(shape.halfExtents)
	local outside = Vector3.new(math.max(0,math.abs(localPosition.X)-extent.X),math.max(0,math.abs(localPosition.Y)-extent.Y),math.max(0,math.abs(localPosition.Z)-extent.Z))
	return if outside:Dot(outside) <= proxyRadius*proxyRadius then math.max(0,extent.Z-localPosition.Z) else nil
end

function Geometry.Corridor(shape: Shape): (Vector3,Vector3,number)
	if shape.kind == "Box" then
		local frame,extent = assert(shape.frame),assert(shape.halfExtents)
		local direction = frame.LookVector*(extent.Z*2)
		return frame.Position-direction*0.5,direction,math.sqrt(extent.X*extent.X+extent.Y*extent.Y)
	end
	return shape.origin,shape.direction or Vector3.zero,shape.radius or 0
end

function Geometry.IntersectsBounds(origin: Vector3,direction: Vector3,minimum: Vector3,maximum: Vector3): boolean
	local enter,leave = 0,1
	for axis=1,3 do
		local o = if axis==1 then origin.X elseif axis==2 then origin.Y else origin.Z
		local d = if axis==1 then direction.X elseif axis==2 then direction.Y else direction.Z
		local low = if axis==1 then minimum.X elseif axis==2 then minimum.Y else minimum.Z
		local high = if axis==1 then maximum.X elseif axis==2 then maximum.Y else maximum.Z
		if math.abs(d)<1e-9 then
			if o<low or o>high then return false end
		else
			local a,b = (low-o)/d,(high-o)/d
			if a>b then a,b=b,a end
			enter,leave = math.max(enter,a),math.min(leave,b)
			if enter>leave then return false end
		end
	end
	return true
end
return Geometry
