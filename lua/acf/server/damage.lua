-- Local Vars -----------------------------------
local ACF_HEPUSH 	= CreateConVar("acf_hepush", 1, FCVAR_NONE, "Whether or not HE pushes on entities", 0, 1)
local ACF_KEPUSH 	= CreateConVar("acf_kepush", 1, FCVAR_NONE, "Whether or not kinetic force pushes on entities", 0, 1)
local TimerCreate 	= timer.Create
local TraceRes 		= {}
local TraceData 	= { output = TraceRes, mask = MASK_SOLID, filter = false }
local Check			= ACF_Check
local HookRun		= hook.Run
local Trace 		= ACF.Trace
local ValidDebris 	= { -- Whitelist for things that can be turned into debris
	acf_ammo = true,
	acf_gun = true,
	acf_gearbox = true,
	acf_fueltank = true,
	acf_engine = true,
	prop_physics = true,
	prop_vehicle_prisoner_pod = true
}
local ChildDebris 	= ACF.ChildDebris
local DragDiv		= ACF.DragDiv
-- Local Funcs ----------------------------------

local function CalcDamage(Entity, Energy, FrArea, Angle)
	local armor = Entity.ACF.Armour -- Armor
	local losArmor = armor / math.abs(math.cos(math.rad(Angle)) ^ ACF.SlopeEffectFactor) -- LOS Armor
	local maxPenetration = (Energy.Penetration / FrArea) * ACF.KEtoRHA --RHA Penetration
	local HitRes = {}


	-- Projectile caliber. Messy, function signature
	local caliber = 20 * (FrArea ^ (1 / ACF.PenAreaMod) / 3.1416) ^ 0.5
	-- Breach probability
	local breachProb = math.Clamp((caliber / Entity.ACF.Armour - 1.3) / (7 - 1.3), 0, 1)
	-- Penetration probability
	local penProb = (math.Clamp(1 / (1 + math.exp(-43.9445 * (maxPenetration / losArmor - 1))), 0.0015, 0.9985) - 0.0015) / 0.997

	-- Breach chance roll
	if breachProb > math.random() and maxPenetration > armor then
		HitRes.Damage = FrArea -- Inflicted Damage
		HitRes.Overkill = maxPenetration - armor -- Remaining penetration
		HitRes.Loss = armor / maxPenetration -- Energy loss in percents

		return HitRes
	elseif penProb > math.random() then
		-- Penetration chance roll
		local Penetration = math.min(maxPenetration, losArmor)
		HitRes.Damage = (Penetration / losArmor) ^ 2 * FrArea
		HitRes.Overkill = (maxPenetration - Penetration)
		HitRes.Loss = Penetration / maxPenetration

		return HitRes
	end

	-- Projectile did not breach nor penetrate armor
	local Penetration = math.min(maxPenetration, losArmor)
	HitRes.Damage = (Penetration / losArmor) ^ 2 * FrArea
	HitRes.Overkill = 0
	HitRes.Loss = 1

	return HitRes
end

local function Shove(Target, Pos, Vec, KE )
	if HookRun("ACF_KEShove", Target, Pos, Vec, KE) == false then return end

	local Phys = Target:GetAncestor():GetPhysicsObject()

	if IsValid(Phys) then
		if Target.CFW then -- If target has connected entities
			local MassData = Target.CFW.Contraption.Mass
			local Ratio    = MassData.Physical / MassData.Parented

			Phys:ApplyForceOffset( Vec:GetNormalized() * KE * Ratio, Pos )
		else -- Entity has nothing connected to it
			Phys:ApplyForceOffset( Vec:GetNormalized() * KE, Pos )
		end
	end
end

ACF.KEShove = Shove
-------------------------------------------------

do
	do -- Explosions ----------------------------
		function ACF_HE(Origin, FillerMass, FragMass, Inflictor, Filter, Gun)
			debugoverlay.Cross(Origin, 15, 15, Color( 255, 255, 255 ), true)
			Filter = Filter or {}

			local Power 	 = FillerMass * ACF.HEPower --Power in KiloJoules of the filler mass of  TNT
			local Radius 	 = FillerMass ^ 0.33 * 8 * 39.37 -- Scaling law found on the net, based on 1PSI overpressure from 1 kg of TNT at 15m
			local MaxSphere  = 4 * 3.1415 * (Radius * 2.54) ^ 2 --Surface Area of the sphere at maximum radius
			local Amp 		 = math.min(Power / 2000, 50)
			local Fragments  = math.max(math.floor((FillerMass / FragMass) * ACF.HEFrag), 2)
			local FragWeight = FragMass / Fragments
			local BaseFragV  = (Power * 50000 / FragWeight / Fragments) ^ 0.5
			local FragArea 	 = (FragWeight / 7.8) ^ 0.33
			local Damaged	 = {}
			local Ents 		 = ents.FindInSphere(Origin, Radius)
			local Loop 		 = true -- Find more props to damage whenever a prop dies

			TraceData.filter = Filter
			TraceData.start  = Origin

			util.ScreenShake(Origin, Amp, Amp, Amp / 15, Radius * 10)

			while Loop and Power > 0 do
				Loop = false

				local PowerSpent = 0
				local Damage 	 = {}

				for K, Ent in ipairs(Ents) do -- Find entities to deal damage to
					if Ent.Exploding then -- Filter out exploding crates
						Ents[K] = nil
						Filter[#Filter + 1] = Ent

						continue
					end

					local IsChar = Ent:IsPlayer() or Ent:IsNPC()
					if IsChar and Ent:Health() <= 0 then
						Ents[K] = nil
						Filter[#Filter + 1] = Ent -- Shouldn't need to filter a dead player but we'll do it just in case

						continue
					end

					if Check(Ent) then -- ACF-valid entity
						local Mul 		 = IsChar and 0.75 or 1 -- Scale down boxes for players/NPCs because the bounding box is way bigger than they actually are
						local Mins, Maxs = Ent:OBBMins() * Mul, Ent:OBBMaxs() * Mul
						local Rand		 = Vector(math.Rand(Mins[1], Maxs[1]), math.Rand(Mins[2], Maxs[2]), math.Rand(Mins[3], Maxs[3]))
						local Target 	 = Ent:LocalToWorld(Rand) -- Try to hit a random spot on the entity
						local Displ		 = Target - Origin

						TraceData.endpos = Origin + Displ:GetNormalized() * (Displ:Length() + 24)
						Trace(TraceData) -- Outputs to TraceRes

						if TraceRes.HitNonWorld then
							if not TraceRes.Entity.Exploding and (TraceRes.Entity == Ent or Check(TraceRes.Entity)) then
								Ent = TraceRes.Entity

								if not Damaged[Ent] and not Damage[Ent] then -- Hit an entity that we haven't already damaged yet (Note: Damaged != Damage)
									debugoverlay.Line(Origin, TraceRes.HitPos, 30, Color(0, 255, 0), true) -- Green line for a hit trace
									debugoverlay.BoxAngles(Ent:GetPos(), Ent:OBBMins() * Mul, Ent:OBBMaxs() * Mul, Ent:GetAngles(), 30, Color(255, 0, 0, 1))

									local Pos		= Ent:GetPos()
									local Distance	= Origin:Distance(Pos)
									local Sphere 	= math.max(4 * 3.1415 * (Distance * 2.54) ^ 2, 1) -- Surface Area of the sphere at the range of that prop
									local Area 		= math.min(Ent.ACF.Area / Sphere, 0.5) * MaxSphere -- Project the Area of the prop to the Area of the shadow it projects at the explosion max radius

									Damage[Ent] = {
										Dist = Distance,
										Vec  = (Pos - Origin):GetNormalized(),
										Area = Area,
										Index = K
									}

									Ents[K] = nil -- Removed from future damage searches (but may still block LOS)
								else
									debugoverlay.Line(Origin, TraceRes.HitPos, 30, Color(150, 150, 0)) -- Yellow line for a hit on an already damaged entity
								end
							else -- If check on new ent fails
								--debugoverlay.Line(Origin, TraceRes.HitPos, 30, Color(255, 0, 0)) -- Red line for a invalid ent

								Ents[K] = nil -- Remove from list
								Filter[#Filter + 1] = Ent -- Filter from traces
							end
						else
							-- Not removed from future damage sweeps so as to provide multiple chances to be hit
							debugoverlay.Line(Origin, TraceRes.HitPos, 30, Color(0, 0, 255)) -- Blue line for a miss
						end
					else -- Target was invalid

						Ents[K] = nil -- Remove from list
						Filter[#Filter + 1] = Ent -- Filter from traces
					end
				end

				for Ent, Table in pairs(Damage) do -- Deal damage to the entities we found
					local Feathering 	= (1 - math.min(1, Table.Dist / Radius)) ^ ACF.HEFeatherExp
					local AreaFraction 	= Table.Area / MaxSphere
					local PowerFraction = Power * AreaFraction -- How much of the total power goes to that prop
					local AreaAdjusted 	= (Ent.ACF.Area / ACF.Threshold) * Feathering
					local Blast 		= { Penetration = PowerFraction ^ ACF.HEBlastPen * AreaAdjusted }
					local BlastRes 		= ACF_Damage(Ent, Blast, AreaAdjusted, 0, Inflictor, 0, Gun, "HE")
					local FragHit 		= math.floor(Fragments * AreaFraction)
					local FragVel 		= math.max(BaseFragV - ((Table.Dist / BaseFragV) * BaseFragV ^ 2 * FragWeight ^ 0.33 / 10000) / DragDiv, 0)
					local FragKE 		= ACF_Kinetic(FragVel, FragWeight * FragHit, 1500)
					local Losses		= BlastRes.Loss * 0.5
					local FragRes

					if FragHit > 0 then
						FragRes = ACF_Damage(Ent, FragKE, FragArea * FragHit, 0, Inflictor, 0, Gun, "Frag")
						Losses 	= Losses + FragRes.Loss * 0.5
					end

					if (BlastRes and BlastRes.Kill) or (FragRes and FragRes.Kill) then -- We killed something
						Filter[#Filter + 1] = Ent -- Filter out the dead prop
						Ents[Table.Index]   = nil -- Don't bother looking for it in the future

						local Debris = ACF_HEKill(Ent, Table.Vec, PowerFraction, Origin) -- Make some debris

						if IsValid(Debris) then
							Filter[#Filter + 1] = Debris -- Filter that out too
						end

						Loop = true -- Check for new targets since something died, maybe we'll find something new
					elseif ACF_HEPUSH:GetBool() then -- Just damaged, not killed, so push on it some
						Shove(Ent, Origin, Table.Vec, PowerFraction * 33.3) -- Assuming about 1/30th of the explosive energy goes to propelling the target prop (Power in KJ * 1000 to get J then divided by 33)
					end

					PowerSpent = PowerSpent + PowerFraction * Losses -- Removing the energy spent killing props
					Damaged[Ent] = true -- This entity can no longer recieve damage from this explosion
				end

				Power = math.max(Power - PowerSpent, 0)
			end
		end

		function ACF_ScaledExplosion( ent ) -- Converts what would be multiple simultaneous cache detonations into one large explosion
			local Inflictor = IsValid(ent.Inflictor) and ent.Inflictor or nil
			local HEWeight

			if ent:GetClass() == "acf_fueltank" then
				HEWeight = (math.max(ent.Fuel, ent.Capacity * 0.0025) / ACF.FuelDensity[ent.FuelType]) * 0.1
			else
				local HE, Propel

				if ent.RoundType == "Refill" then
					HE = 0.001
					Propel = 0.001
				else
					HE = ent.BulletData.FillerMass or 0
					Propel = ent.BulletData.PropMass or 0
				end

				HEWeight = (HE + Propel * (ACF.PBase / ACF.HEPower)) * ent.Ammo
			end

			local Radius = HEWeight ^ 0.33 * 8 * 39.37
			local Pos = ent:LocalToWorld(ent:OBBCenter())
			local ExplodePos = { Pos }
			local LastHE = 0

			local Search = true
			local Filter = { ent }
			while Search do
				for _, Found in pairs(ents.FindInSphere(Pos, Radius)) do
					if Found.IsExplosive and not Found.Exploding then
						local Hitat = Found:NearestPoint(Pos)

						local Occlusion = {
							start = Pos,
							endpos = Hitat,
							filter = Filter
						}

						local Occ = util.TraceLine(Occlusion)

						if Occ.Fraction == 0 then
							table.insert(Filter, Occ.Entity)

							Occlusion = {
								start = Pos,
								endpos = Hitat,
								filter = Filter
							}

							Occ = util.TraceLine(Occlusion)
						end

						if Occ.Hit and Occ.Entity:EntIndex() == Found.Entity:EntIndex() then
							local FoundHEWeight
							if Found:GetClass() == "acf_fueltank" then
								FoundHEWeight = (math.max(Found.Fuel, Found.Capacity * 0.0025) / ACF.FuelDensity[Found.FuelType]) * 0.1
							else
								local HE, Propel

								if Found.RoundType == "Refill" then
									HE = 0.001
									Propel = 0.001
								else
									HE = Found.BulletData.FillerMass or 0
									Propel = Found.BulletData.PropMass or 0
								end

								FoundHEWeight = (HE + Propel * (ACF.PBase / ACF.HEPower)) * Found.Ammo
							end

							table.insert(ExplodePos, Found:LocalToWorld(Found:OBBCenter()))
							HEWeight = HEWeight + FoundHEWeight
							Found.IsExplosive = false
							Found.DamageAction = false
							Found.KillAction = false
							Found.Exploding = true
							table.insert(Filter, Found)
							Found:Remove()
						end
					end
				end

				if HEWeight > LastHE then
					Search = true
					LastHE = HEWeight
					Radius = HEWeight ^ 0.33 * 8 * 39.37
				else
					Search = false
				end
			end

			local totalpos = Vector()
			local countpos = 0

			for _, cratepos in pairs(ExplodePos) do
				totalpos = totalpos + cratepos
				countpos = countpos + 1
			end

			local AvgPos = totalpos / countpos

			ACF_HE(AvgPos, HEWeight, HEWeight * 0.5, Inflictor, { ent }, ent)

			ent:Remove()

			local Effect = EffectData()
			Effect:SetOrigin(AvgPos)
			Effect:SetNormal(Vector(0, 0, -1))
			Effect:SetScale(math.max(Radius, 1))
			Effect:SetRadius(0)

			util.Effect("ACF_Explosion", Effect)
		end
	end

	do -- Deal Damage ---------------------------
		local function SquishyDamage(Entity, Energy, FrArea, Angle, Inflictor, Bone, Gun)
			local Size = Entity:BoundingRadius()
			local Mass = Entity:GetPhysicsObject():GetMass()
			local HitRes = {}
			local Damage = 0

			--We create a dummy table to pass armour values to the calc function
			local Target = {
				ACF = {
					Armour = 0.1
				}
			}

			if (Bone) then
				--This means we hit the head
				if (Bone == 1) then
					Target.ACF.Armour = Mass * 0.02 --Set the skull thickness as a percentage of Squishy weight, this gives us 2mm for a player, about 22mm for an Antlion Guard. Seems about right
					HitRes = CalcDamage(Target, Energy, FrArea, Angle) --This is hard bone, so still sensitive to impact angle
					Damage = HitRes.Damage * 20

					--If we manage to penetrate the skull, then MASSIVE DAMAGE
					if HitRes.Overkill > 0 then
						Target.ACF.Armour = Size * 0.25 * 0.01 --A quarter the bounding radius seems about right for most critters head size
						HitRes = CalcDamage(Target, Energy, FrArea, 0)
						Damage = Damage + HitRes.Damage * 100
					end

					Target.ACF.Armour = Mass * 0.065 --Then to check if we can get out of the other side, 2x skull + 1x brains
					HitRes = CalcDamage(Target, Energy, FrArea, Angle)
					Damage = Damage + HitRes.Damage * 20
				elseif (Bone == 0 or Bone == 2 or Bone == 3) then
					--This means we hit the torso. We are assuming body armour/tough exoskeleton/zombie don't give fuck here, so it's tough
					Target.ACF.Armour = Mass * 0.08 --Set the armour thickness as a percentage of Squishy weight, this gives us 8mm for a player, about 90mm for an Antlion Guard. Seems about right
					HitRes = CalcDamage(Target, Energy, FrArea, Angle) --Armour plate,, so sensitive to impact angle
					Damage = HitRes.Damage * 5

					if HitRes.Overkill > 0 then
						Target.ACF.Armour = Size * 0.5 * 0.02 --Half the bounding radius seems about right for most critters torso size
						HitRes = CalcDamage(Target, Energy, FrArea, 0)
						Damage = Damage + HitRes.Damage * 50 --If we penetrate the armour then we get into the important bits inside, so DAMAGE
					end

					Target.ACF.Armour = Mass * 0.185 --Then to check if we can get out of the other side, 2x armour + 1x guts
					HitRes = CalcDamage(Target, Energy, FrArea, Angle)
				elseif (Bone == 4 or Bone == 5) then
					--This means we hit an arm or appendage, so ormal damage, no armour
					Target.ACF.Armour = Size * 0.2 * 0.02 --A fitht the bounding radius seems about right for most critters appendages
					HitRes = CalcDamage(Target, Energy, FrArea, 0) --This is flesh, angle doesn't matter
					Damage = HitRes.Damage * 30 --Limbs are somewhat less important
				elseif (Bone == 6 or Bone == 7) then
					Target.ACF.Armour = Size * 0.2 * 0.02 --A fitht the bounding radius seems about right for most critters appendages
					HitRes = CalcDamage(Target, Energy, FrArea, 0) --This is flesh, angle doesn't matter
					Damage = HitRes.Damage * 30 --Limbs are somewhat less important
				elseif (Bone == 10) then
					--This means we hit a backpack or something
					Target.ACF.Armour = Size * 0.1 * 0.02 --Arbitrary size, most of the gear carried is pretty small
					HitRes = CalcDamage(Target, Energy, FrArea, 0) --This is random junk, angle doesn't matter
					Damage = HitRes.Damage * 2 --Damage is going to be fright and shrapnel, nothing much		
				else --Just in case we hit something not standard
					Target.ACF.Armour = Size * 0.2 * 0.02
					HitRes = CalcDamage(Target, Energy, FrArea, 0)
					Damage = HitRes.Damage * 30
				end
			else --Just in case we hit something not standard
				Target.ACF.Armour = Size * 0.2 * 0.02
				HitRes = CalcDamage(Target, Energy, FrArea, 0)
				Damage = HitRes.Damage * 10
			end

			--if Ammo == true then
			--	Entity.KilledByAmmo = true
			--end
			Entity:TakeDamage(Damage, Inflictor, Gun)
			--if Ammo == true then
			--	Entity.KilledByAmmo = false
			--end
			HitRes.Kill = false
			--print(Damage)
			--print(Bone)

			return HitRes
		end

		local function VehicleDamage(Entity, Energy, FrArea, Angle, Inflictor, _, Gun)
			local HitRes = CalcDamage(Entity, Energy, FrArea, Angle)
			local Driver = Entity:GetDriver()

			if IsValid(Driver) then
				SquishyDamage(Driver, Energy, FrArea, Angle, Inflictor, math.Rand(0, 7), Gun)
			end

			HitRes.Kill = false

			if HitRes.Damage >= Entity.ACF.Health then
				HitRes.Kill = true
			else
				Entity.ACF.Health = Entity.ACF.Health - HitRes.Damage
				Entity.ACF.Armour = Entity.ACF.Armour * (0.5 + Entity.ACF.Health / Entity.ACF.MaxHealth / 2) --Simulating the plate weakening after a hit
			end

			return HitRes
		end

		local function PropDamage(Entity, Energy, FrArea, Angle)
			local HitRes = CalcDamage(Entity, Energy, FrArea, Angle)
			HitRes.Kill = false

			if HitRes.Damage >= Entity.ACF.Health then
				HitRes.Kill = true
			else
				Entity.ACF.Health = Entity.ACF.Health - HitRes.Damage
				Entity.ACF.Armour = math.Clamp(Entity.ACF.MaxArmour * (0.5 + Entity.ACF.Health / Entity.ACF.MaxHealth / 2) ^ 1.7, Entity.ACF.MaxArmour * 0.25, Entity.ACF.MaxArmour) --Simulating the plate weakening after a hit

				--math.Clamp( Entity.ACF.Ductility, -0.8, 0.8 )
				if Entity.ACF.PrHealth and Entity.ACF.PrHealth ~= Entity.ACF.Health then
					if not ACF_HealthUpdateList then
						ACF_HealthUpdateList = {}

						-- We should send things slowly to not overload traffic.
						TimerCreate("ACF_HealthUpdateList", 1, 1, function()
							local Table = {}

							for _, v in pairs(ACF_HealthUpdateList) do
								if IsValid(v) then
									table.insert(Table, {
										ID = v:EntIndex(),
										Health = v.ACF.Health,
										MaxHealth = v.ACF.MaxHealth
									})
								end
							end

							net.Start("ACF_RenderDamage")
								net.WriteTable(Table)
							net.Broadcast()

							ACF_HealthUpdateList = nil
						end)
					end

					table.insert(ACF_HealthUpdateList, Entity)
				end

				Entity.ACF.PrHealth = Entity.ACF.Health
			end

			return HitRes
		end

		ACF.PropDamage = PropDamage

		function ACF_Damage(Entity, Energy, FrArea, Angle, Inflictor, Bone, Gun, Type)
			local Activated = Check(Entity)

			if HookRun("ACF_BulletDamage", Activated, Entity, Energy, FrArea, Angle, Inflictor, Bone, Gun) == false or Activated == false then
				return {
					Damage = 0,
					Overkill = 0,
					Loss = 0,
					Kill = false
				}
			end

			if Entity.ACF_OnDamage then -- Use special damage function if target entity has one
				return Entity:ACF_OnDamage(Entity, Energy, FrArea, Angle, Inflictor, Bone, Type)
			elseif Activated == "Prop" then
				return PropDamage(Entity, Energy, FrArea, Angle, Inflictor, Bone)
			elseif Activated == "Vehicle" then
				return VehicleDamage(Entity, Energy, FrArea, Angle, Inflictor, Bone, Gun)
			elseif Activated == "Squishy" then
				return SquishyDamage(Entity, Energy, FrArea, Angle, Inflictor, Bone, Gun)
			end
		end
	end -----------------------------------------

	do -- Remove Props ------------------------------
		local function KillChildProps( Entity, BlastPos, Energy )

			local Explosives = {}
			local Children 	 = Entity:GetAllChildren()
			local Count		 = 0

			-- do an initial processing pass on children, separating out explodey things to handle last
			for Ent in pairs( Children ) do
				Ent.ACF_Killed = true  -- mark that it's already processed

				if not ValidDebris[Ent:GetClass()] then
					Children[Ent] = nil -- ignoring stuff like holos, wiremod components, etc.
				else
					Ent:SetParent(nil)

					if Ent.IsExplosive and not Ent.Exploding then
						Explosives[Ent] = true
						Children[Ent] 	= nil
					else
						Count = Count + 1
					end
				end
			end

			-- HE kill the children of this ent, instead of disappearing them by removing parent
			if next(Children) then
				local DebrisChance 	= math.Clamp(ChildDebris / Count, 0, 1)
				local Power 		= Energy / math.min(Count,3)

				for Ent in pairs( Children ) do
					if math.random() < DebrisChance then
						ACF_HEKill(Ent, (Ent:GetPos() - BlastPos):GetNormalized(), Power)
					else
						constraint.RemoveAll(Ent)
						Ent:Remove()
					end
				end
			end

			-- explode stuff last, so we don't re-process all that junk again in a new explosion
			if next(Explosives) then
				for Ent in pairs(Explosives) do
					if Ent.Exploding then continue end

					Ent.Exploding = true
					Ent.Inflictor = Entity.Inflictor
					Ent:Detonate()
				end
			end
		end
		ACF_KillChildProps = KillChildProps

		function ACF_HEKill(Entity, HitVector, Energy, BlastPos) -- blast pos is an optional world-pos input for flinging away children props more realistically
			-- if it hasn't been processed yet, check for children
			if not Entity.ACF_Killed then KillChildProps(Entity, BlastPos or Entity:GetPos(), Energy) end

			local Obj  = Entity:GetPhysicsObject()
			local Mass = IsValid(Obj) and Obj:GetMass() or 50

			constraint.RemoveAll(Entity)
			Entity:Remove()

			if Entity:BoundingRadius() < ACF.DebrisScale then return nil end

			local Debris = ents.Create("acf_debris")
				Debris:SetModel(Entity:GetModel())
				Debris:SetAngles(Entity:GetAngles())
				Debris:SetPos(Entity:GetPos())
				Debris:SetMaterial("models/props_wasteland/metal_tram001a")
				Debris:Spawn()
			Debris:Activate()

			local Phys = Debris:GetPhysicsObject()
			if IsValid(Phys) then
				Phys:SetMass(Mass)
				Phys:ApplyForceOffset(HitVector:GetNormalized() * Energy * 10, Debris:GetPos() + VectorRand() * 10) -- previously energy*350
			end

			if math.random() < ACF.DebrisIgniteChance then
				Debris:Ignite(math.Rand(5, 45), 0)
			end

			return Debris
		end

		function ACF_APKill(Entity, HitVector, Power)

			KillChildProps(Entity, Entity:GetPos(), Power) -- kill the children of this ent, instead of disappearing them from removing parent

			local Obj  = Entity:GetPhysicsObject()
			local Mass = 25

			if IsValid(Obj) then Mass = Obj:GetMass() end

			constraint.RemoveAll(Entity)
			Entity:Remove()

			if Entity:BoundingRadius() < ACF.DebrisScale then return end

			local Debris = ents.Create("acf_debris")
				Debris:SetModel(Entity:GetModel())
				Debris:SetAngles(Entity:GetAngles())
				Debris:SetPos(Entity:GetPos())
				Debris:SetMaterial(Entity:GetMaterial())
				Debris:SetColor(Color(120, 120, 120, 255))
				Debris:Spawn()
			Debris:Activate()

			local Phys = Debris:GetPhysicsObject()
			if IsValid(Phys) then
				Phys:SetMass(Mass)
				Phys:ApplyForceOffset(HitVector:GetNormalized() * Power * 350, Debris:GetPos() + VectorRand() * 20)
			end

			local BreakEffect = EffectData()
				BreakEffect:SetOrigin(Entity:GetPos())
				BreakEffect:SetScale(20)
			util.Effect("WheelDust", BreakEffect)

			return Debris
		end
	end

	do -- Round Impact --------------------------
		local function RicochetVector(Flight, HitNormal)
			local Vec = Flight:GetNormalized()

			return Vec - ( 2 * Vec:Dot(HitNormal) ) * HitNormal
		end

		function ACF_RoundImpact( Bullet, Speed, Energy, Target, HitPos, HitNormal , Bone  )
			Bullet.Ricochets = Bullet.Ricochets or 0
			local Angle = ACF_GetHitAngle( HitNormal , Bullet.Flight )

			local HitRes = ACF_Damage ( --DAMAGE !!
				Target,
				Energy,
				Bullet.PenArea,
				Angle,
				Bullet.Owner,
				Bone,
				Bullet.Gun,
				Bullet.Type
			)

			local Ricochet = 0
			if HitRes.Loss == 1 then
				-- Ricochet distribution center
				local sigmoidCenter = Bullet.DetonatorAngle or ( Bullet.Ricochet - math.abs(Speed / 39.37 - Bullet.LimitVel) / 100 )

				-- Ricochet probability (sigmoid distribution); up to 5% minimal ricochet probability for projectiles with caliber < 20 mm 
				local ricoProb = math.Clamp( 1 / (1 + math.exp( (Angle - sigmoidCenter) / -4) ), math.max(-0.05 * (Bullet.Caliber - 2) / 2, 0), 1 )

				-- Checking for ricochet
				if ricoProb > math.random() and Angle < 90 then
					Ricochet       = math.Clamp(Angle / 90, 0.05, 1) -- atleast 5% of energy is kept
					HitRes.Loss    = 0.25 - Ricochet
					Energy.Kinetic = Energy.Kinetic * HitRes.Loss
				end
			end

			if ACF_KEPUSH:GetBool() then
				Shove(
					Target,
					HitPos,
					Bullet.Flight:GetNormalized(),
					Energy.Kinetic * HitRes.Loss * 1000 * Bullet.ShovePower
				)
			end

			if HitRes.Kill then
				local Debris = ACF_APKill( Target , (Bullet.Flight):GetNormalized() , Energy.Kinetic )
				table.insert( Bullet.Filter , Debris )
			end

			HitRes.Ricochet = false
			if Ricochet > 0 and Bullet.Ricochets < 3 then
				Bullet.Ricochets = Bullet.Ricochets + 1
				Bullet.Pos = HitPos + HitNormal * 0.75
				Bullet.FlightTime = 0
				Bullet.Flight = (RicochetVector(Bullet.Flight, HitNormal) + VectorRand() * 0.025):GetNormalized() * Speed * Ricochet
				Bullet.TraceBackComp = math.max(Target:GetAncestor():GetPhysicsObject():GetVelocity():Dot(Bullet.Flight:GetNormalized()),0)
				HitRes.Ricochet = true
			end

			return HitRes
		end

		function ACF_PenetrateGround( Bullet, Energy, HitPos, HitNormal )
			Bullet.GroundRicos = Bullet.GroundRicos or 0
			local MaxDig = ((Energy.Penetration / Bullet.PenArea) * ACF.KEtoRHA / ACF.GroundtoRHA) / 25.4
			local HitRes = {Penetrated = false, Ricochet = false}

			local DigTr = { }
				DigTr.start = HitPos + Bullet.Flight:GetNormalized() * 0.1
				DigTr.endpos = HitPos + Bullet.Flight:GetNormalized() * (MaxDig + 0.1)
				DigTr.filter = Bullet.Filter
				DigTr.mask = MASK_SOLID_BRUSHONLY
			local DigRes = util.TraceLine(DigTr)
			--print(util.GetSurfacePropName(DigRes.SurfaceProps))

			local loss = DigRes.FractionLeftSolid

			if loss == 1 or loss == 0 then --couldn't penetrate
				local Ricochet = 0
				local Speed = Bullet.Flight:Length() / ACF.Scale
				local Angle = ACF_GetHitAngle( HitNormal, Bullet.Flight )
				local MinAngle = math.min(Bullet.Ricochet - Speed / 39.37 / 30 + 20,89.9)	--Making the chance of a ricochet get higher as the speeds increase
				if Angle > math.random(MinAngle,90) and Angle < 89.9 then	--Checking for ricochet
					Ricochet = Angle / 90 * 0.75
				end

				if Ricochet > 0 and Bullet.GroundRicos < 2 then
					Bullet.GroundRicos = Bullet.GroundRicos + 1
					Bullet.Pos = HitPos + HitNormal * 1
					Bullet.Flight = (RicochetVector(Bullet.Flight, HitNormal) + VectorRand() * 0.05):GetNormalized() * Speed * Ricochet
					HitRes.Ricochet = true
				end
			else --penetrated
				Bullet.Flight = Bullet.Flight * (1 - loss)
				Bullet.Pos = DigRes.StartPos + Bullet.Flight:GetNormalized() * 0.25 --this is actually where trace left brush
				HitRes.Penetrated = true
			end

			return HitRes
		end
	end
end

