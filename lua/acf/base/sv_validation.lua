-- Entity validation

-- Local Vars -----------------------------------
local StringFind  = string.find
local TimerSimple = timer.Simple
local Baddies 	  = { -- Ignored by ACF
	gmod_ghost = true,
	acf_debris = true,
	prop_ragdoll = true,
	gmod_wire_hologram = true,
	prop_vehicle_crane = true,
	prop_dynamic = true,
	npc_strider = true,
	npc_dog = true
}
-- Local Funcs ----------------------------------

--[[ ACF Legality Check
	ALL SENTS MUST HAVE:
	ENT.ACF.PhysObj defined when spawned
	ENT.ACF.LegalMass defined when spawned
	ENT.ACF.Model defined when spawned

	ACF_CheckLegal(entity) called when finished spawning

	function ENT:Enable()
		<code>
	end

	function ENT:Disable()
		<code>
	end
]]--
local function IsLegal(Entity)
	local Phys = Entity:GetPhysicsObject()

	if Entity.ACF.PhysObj ~= Phys then
		if Phys:GetVolume() then
			Entity.ACF.PhysObj = Phys -- Updated PhysObj
		else
			Entity:Remove() -- Remove spherical trash
			return false, "Invalid physics" -- This shouldn't even run
		end
	end
	if Entity:GetModel() ~= Entity.ACF.Model then return false, "Incorrect model" end
	if Entity:GetNoDraw() then return false, "Not drawn" end
	if Entity:GetSolid() ~= SOLID_VPHYSICS then return false, "Not solid" end -- Entities must always be solid
	if Entity.ClipData and next(Entity.ClipData) then return false, "Visual Clip" end -- No visclip

	return true
end

local function CheckLegal(Entity)
	local Legal, Reason = IsLegal(Entity)

	if not Legal then -- Not legal
		Entity.Disabled		 = true
		Entity.DisableReason = Reason

		Entity:Disable() -- Let the entity know it's disabled

		if Entity.UpdateOverlay then Entity:UpdateOverlay(true) end -- Update overlay if it has one (Passes true to update overlay instantly)

		TimerSimple(ACF.IllegalDisableTime, function() -- Check if it's legal again in ACF.IllegalDisableTime
			if IsValid(Entity) and CheckLegal(Entity) then
				Entity.Disabled	   	 = nil
				Entity.DisableReason = nil

				Entity:Enable()

				if Entity.UpdateOverlay then Entity:UpdateOverlay(true) end
			end
		end)

		return false
	end

	TimerSimple(math.Rand(1, 3), function() -- Entity is legal... test again in random 1 to 3 seconds
		if IsValid(Entity) then
			CheckLegal(Entity)
		end
	end)

	return true
end
-- Global Funcs ---------------------------------
function ACF_Check(Entity) -- IsValid but for ACF
	if not IsValid(Entity) then return false end

	local Class = Entity:GetClass()
	if Baddies[Class] then return false end

	local PhysObj = Entity:GetPhysicsObject()
	if not IsValid(PhysObj) then return false end

	if not Entity.ACF then
		if Entity:IsWorld() or Entity:IsWeapon() or StringFind(Class, "func_") then
			Baddies[Class] = true

			return false
		end

		ACF_Activate(Entity)
	elseif Entity.ACF.Mass ~= PhysObj:GetMass() or Entity.ACF.PhysObj ~= PhysObj then
		ACF_Activate(Entity, true)
	end

	return Entity.ACF.Type
end

function ACF_Activate(Entity, Recalc)
	--Density of steel = 7.8g cm3 so 7.8kg for a 1mx1m plate 1m thick
	local PhysObj = Entity:GetPhysicsObject()

	if not IsValid(PhysObj) then return end

	Entity.ACF = Entity.ACF or {}
	Entity.ACF.PhysObj = Entity:GetPhysicsObject()

	if Entity.ACF_Activate then
		Entity:ACF_Activate(Recalc)
		return
	end

	local Count = PhysObj:GetMesh() and #PhysObj:GetMesh() or nil

	if Count and Count > 100 then
		Entity.ACF.Area = (PhysObj:GetSurfaceArea() * 6.45) * 0.52505066107
	else
		local Size = Entity.OBBMaxs(Entity) - Entity.OBBMins(Entity)

		Entity.ACF.Area = ((Size.x * Size.y) + (Size.x * Size.z) + (Size.y * Size.z)) * 6.45 --^ 1.15
	end

	Entity.ACF.Ductility = Entity.ACF.Ductility or 0
	local Area = Entity.ACF.Area
	local Ductility = math.Clamp(Entity.ACF.Ductility, -0.8, 0.8)
	local Armour = ACF_CalcArmor(Area, Ductility, Entity:GetPhysicsObject():GetMass()) -- So we get the equivalent thickness of that prop in mm if all its weight was a steel plate
	local Health = (Area / ACF.Threshold) * (1 + Ductility) -- Setting the threshold of the prop Area gone
	local Percent = 1

	if Recalc and Entity.ACF.Health and Entity.ACF.MaxHealth then
		Percent = Entity.ACF.Health / Entity.ACF.MaxHealth
	end

	Entity.ACF.Health = Health * Percent
	Entity.ACF.MaxHealth = Health
	Entity.ACF.Armour = Armour * (0.5 + Percent / 2)
	Entity.ACF.MaxArmour = Armour * ACF.ArmorMod
	Entity.ACF.Type = nil
	Entity.ACF.Mass = PhysObj:GetMass()

	if Entity:IsPlayer() or Entity:IsNPC() then
		Entity.ACF.Type = "Squishy"
	elseif Entity:IsVehicle() then
		Entity.ACF.Type = "Vehicle"
	else
		Entity.ACF.Type = "Prop"
	end
end

do -- Entity Links ------------------------------
	local EntityLink = {}
	local function GetEntityLinks(Entity, VarName, SingleEntry)
		if not Entity[VarName] then return {} end

		if SingleEntry then
			return { [Entity[VarName]] = true }
		end

		local Result = {}

		for K in pairs(Entity[VarName]) do
			Result[K] = true
		end

		return Result
	end

	-- If your entity can link/unlink other entities, you should use this
	function ACF.RegisterLinkSource(Class, VarName, SingleEntry)
		local Data = EntityLink[Class]

		if not Data then
			EntityLink[Class] = {
				[VarName] = function(Entity)
					return GetEntityLinks(Entity, VarName, SingleEntry)
				end
			}
		else
			Data[VarName] = function(Entity)
				return GetEntityLinks(Entity, VarName, SingleEntry)
			end
		end
	end

	function ACF.GetAllLinkSources(Class)
		if not EntityLink[Class] then return {} end

		local Result = {}

		for K, V in pairs(EntityLink[Class]) do
			Result[K] = V
		end

		return Result
	end

	function ACF.GetLinkSource(Class, VarName)
		if not EntityLink[Class] then return end

		return EntityLink[Class][VarName]
	end

	local ClassLink = { Link = {}, Unlink = {} }
	local function RegisterNewLink(Action, Class1, Class2, Function)
		if not isfunction(Function) then return end

		local Target = ClassLink[Action]
		local Data1 = Target[Class1]

		if not Data1 then
			Target[Class1] = {
				[Class2] = function(Ent1, Ent2)
					return Function(Ent1, Ent2)
				end
			}
		else
			Data1[Class2] = function(Ent1, Ent2)
				return Function(Ent1, Ent2)
			end
		end

		if Class1 == Class2 then return end

		local Data2 = Target[Class2]

		if not Data2 then
			Target[Class2] = {
				[Class1] = function(Ent2, Ent1)
					return Function(Ent1, Ent2)
				end
			}
		else
			Data2[Class1] = function(Ent2, Ent1)
				return Function(Ent1, Ent2)
			end
		end
	end

	function ACF.RegisterClassLink(Class1, Class2, Function)
		RegisterNewLink("Link", Class1, Class2, Function)
	end

	function ACF.GetClassLink(Class1, Class2)
		if not ClassLink.Link[Class1] then return end

		return ClassLink.Link[Class1][Class2]
	end

	function ACF.RegisterClassUnlink(Class1, Class2, Function)
		RegisterNewLink("Unlink", Class1, Class2, Function)
	end

	function ACF.GetClassUnlink(Class1, Class2)
		if not ClassLink.Unlink[Class1] then return end

		return ClassLink.Unlink[Class1][Class2]
	end
end ---------------------------------------------

-- Globalize ------------------------------------
ACF.GlobalFilter = Baddies
ACF_IsLegal 	 = IsLegal
ACF_CheckLegal 	 = CheckLegal