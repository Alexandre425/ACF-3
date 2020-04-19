AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")

include("shared.lua")

-- Local Vars -----------------------------------

local ACF_RECOIL  = CreateConVar("acf_recoilpush", 1, FCVAR_ARCHIVE, "Whether or not ACF guns apply recoil", 0, 1)
local UnlinkSound = "physics/metal/metal_box_impact_bullet%s.wav"
local CheckLegal  = ACF_CheckLegal
local ClassLink	  = ACF.GetClassLink
local ClassUnlink = ACF.GetClassUnlink
local Shove		  = ACF.KEShove
local TraceRes    = {} -- Output for traces
local TraceData	  = {start = true, endpos = true, filter = true, mask = MASK_SOLID, output = TraceRes}
local Trace		  = util.TraceLine
local TimerExists = timer.Exists
local TimerCreate = timer.Create
local HookRun	  = hook.Run
local EMPTY = { Type = "Empty", PropMass = 0, ProjMass = 0, Tracer = 0 }


do -- Spawn Func --------------------------------
	function MakeACF_Gun(Player, Pos, Angle, Id)
		local List   = ACF.Weapons
		local EID    = List.Guns[Id] and Id or "50mmC"
		local Lookup = List.Guns[EID]
		local Ext  = Lookup.gunclass == "SL" and "_acf_smokelauncher" or "_acf_gun"
		local ClassData = ACF.Classes.GunClass[Lookup.gunclass]
		local Caliber   = Lookup.caliber

		if not Player:CheckLimit(Ext) then return false end -- Check gun spawn limits

		local Gun = ents.Create("acf_gun")

		if not IsValid(Gun) then return end

		Player:AddCleanup("acfmenu", Gun)
		Player:AddCount(Ext, Gun)

		Gun:SetModel(Lookup.model)
		Gun:SetPlayer(Player)
		Gun:SetAngles(Angle)
		Gun:SetPos(Pos)
		Gun:Spawn()

		Gun:PhysicsInit(SOLID_VPHYSICS)
		Gun:SetMoveType(MOVETYPE_VPHYSICS)

		Gun.Id           = Id -- MUST be stored on ent to be duped
		Gun.Owner        = Player -- MUST be stored on ent for PP
		Gun.Outputs 	 = WireLib.CreateOutputs(Gun, { "Status [STRING]", "Entity [ENTITY]", "Shots Left", "Rate of Fire", "Reload Time", "Projectile Mass", "Muzzle Velocity" })

		if Caliber > ACF.MinFuzeCaliber then
			Gun.Inputs = WireLib.CreateInputs(Gun, { "Fire", "Unload", "Reload", "Fuze" } )
		else
			Gun.Inputs = WireLib.CreateInputs(Gun, {"Fire", "Unload", "Reload", "Fuze"})
		end

		-- ACF Specific vars
		Gun.BarrelFilter 	= { Gun }
		Gun.State        	= "Empty"
		Gun.Crates       	= {}
		Gun.Name			= Lookup.name
		Gun.ShortName		= Id
		Gun.EntType			= ClassData.name
		Gun.Caliber			= Caliber
		Gun.Class			= Lookup.gunclass
		Gun.MagReload		= Lookup.magreload
		Gun.MagSize			= Lookup.magsize or 1
		Gun.Cyclic			= Lookup.Cyclic and 60 / Lookup.Cyclic or nil
		Gun.ReloadTime		= Gun.Cyclic or 1
		Gun.CurrentShot		= 0
		Gun.Spread			= ClassData.spread
		Gun.MinLengthBonus 	= 0.75 * 3.1416 * (Caliber / 2) ^ 2 * Lookup.round.maxlength
		Gun.Muzzleflash		= ClassData.muzzleflash
		Gun.PGRoFmod		= math.max(0.01, Lookup.rofmod or 1)
		Gun.RoFmod			= ClassData.rofmod
		Gun.Sound			= ClassData.sound
		Gun.BulletData		= { Type = "Empty", PropMass = 0, ProjMass = 0, Tracer = 0 }
		Gun.HitBoxes		= ACF.HitBoxes[Lookup.model]
		Gun.Long			= ClassData.longbarrel
		Gun.NormalMuzzle	= Gun:WorldToLocal(Gun:GetAttachment(Gun:LookupAttachment("muzzle")).Pos)
		Gun.Muzzle			= Gun.NormalMuzzle

		-- Set NWvars
		Gun:SetNWString("Sound", Gun.Sound)
		Gun:SetNWString("WireName", Lookup.name)
		Gun:SetNWString("ID", Id)
		Gun:SetNWString("Class", Gun.Class)

		-- Adjustable barrel length
		if Gun.Long then
			local Attachment = Gun:GetAttachment(Gun:LookupAttachment(Gun.Long.newpos))

			Gun.LongMuzzle = Attachment and Gun:WorldToLocal(Attachment.Pos)

			timer.Simple(0, function()
				if not IsValid(Gun) then return end
				if not Attachment then return end

				local Long = Gun.Long

				if Gun:GetBodygroup(Long.index) == Long.submodel then
					Gun.Muzzle = Gun.LongMuzzle
				end
			end)
		end

		WireLib.TriggerOutput(Gun, "Status", "Empty")
		WireLib.TriggerOutput(Gun, "Entity", Gun)
		WireLib.TriggerOutput(Gun, "Projectile Mass", 1000)
		WireLib.TriggerOutput(Gun, "Muzzle Velocity", 1000)

		if Gun.Cyclic then -- Automatics don't change their rate of fire
			WireLib.TriggerOutput(Gun, "Reload Time", Gun.Cyclic)
			WireLib.TriggerOutput(Gun, "Rate of Fire", 60 / Gun.Cyclic)
		end

		local Mass = Lookup.weight
		local Phys = Gun:GetPhysicsObject()
		if IsValid(Phys) then Phys:SetMass(Mass) end

		ACF_Activate(Gun)

		Gun.ACF.LegalMass     = Mass
		Gun.ACF.Model         = Lookup.model

		Gun:UpdateOverlay(true)

		CheckLegal(Gun)

		return Gun
	end

	list.Set("ACFCvars", "acf_gun", {"id"} )
	duplicator.RegisterEntityClass("acf_gun", MakeACF_Gun, "Pos", "Angle", "Id")
	ACF.RegisterLinkSource("acf_gun", "Crates")
end ---------------------------------------------

do -- Metamethods --------------------------------
	do -- Inputs/Outputs/Linking ----------------
		ACF.RegisterClassLink("acf_gun", "acf_ammo", function(Weapon, Target)
			if Weapon.Crates[Target] then return false, "This weapon is already linked to this crate." end
			if Target.Weapons[Weapon] then return false, "This weapon is already linked to this crate." end
			if Weapon.Id ~= Target.BulletData.Id then return false, "Wrong ammo type for this weapon." end

			Weapon.Crates[Target]  = true
			Target.Weapons[Weapon] = true

			Weapon:UpdateOverlay(true)
			Target:UpdateOverlay(true)

			return true, "Weapon linked successfully."
		end)

		ACF.RegisterClassUnlink("acf_gun", "acf_ammo", function(Weapon, Target)
			if Weapon.Crates[Target] or Target.Weapons[Weapon] then
				Weapon.Crates[Target]  = nil
				Target.Weapons[Weapon] = nil

				Weapon:UpdateOverlay(true)
				Target:UpdateOverlay(true)

				return true, "Weapon unlinked successfully."
			end


			if not Weapon.Crates[Target] then return false, "This weapon is not linked to this crate." end
		end)

		local WireTable	  = {
			gmod_wire_adv_pod = true,
			gmod_wire_joystick = true,
			gmod_wire_expression2 = true,
			gmod_wire_joystick_multi = true,
			gmod_wire_pod = function(_, Input)
				if Input.Pod then
					return Input.Pod:GetDriver()
				end
			end,
			gmod_wire_keyboard = function(_, Input)
				if Input.ply then
					return Input.ply
				end
			end,
		}

		local function FindUser(Entity, Input, Checked)
			local Function = WireTable[Input:GetClass()]

			return Function and Function(Entity, Input, Checked or {})
		end

		WireTable.gmod_wire_adv_pod			= WireTable.gmod_wire_pod
		WireTable.gmod_wire_joystick		= WireTable.gmod_wire_pod
		WireTable.gmod_wire_joystick_multi	= WireTable.gmod_wire_pod
		WireTable.gmod_wire_expression2		= function(This, Input, Checked)
			for _, V in pairs(Input.Inputs) do
				if V.Src and not Checked[V.Src] and WireTable[V.Src:GetClass()] then
					Checked[V.Src] = true -- We don't want to start an infinite loop

					return FindUser(This, V.Src, Checked)
				end
			end
		end

		function ENT:GetUser(Input)
			if not Input then return end

			return FindUser(self, Input)
		end

		function ENT:TriggerInput(Input, Value)
			if self.Disabled then return end -- Ignore all input if the gun is disabled

			local Bool = tobool(Value)

			if Input == "Fire" then
				self.Firing = Bool

				if Bool then
					self.User = self:GetUser(self.Inputs.Fire.Src) or self.Owner

					if self:CanFire() then
						self:Shoot()
					end
				end
			elseif Input == "Fuze" then
				self.SetFuze = Bool and math.abs(Value) or nil
			elseif Input == "Unload" then
				if Bool and self.State == "Loaded" then
					self:Unload()
				end
			elseif Input == "Reload" then
				if Bool then
					if self.State == "Loaded" then
						self:Unload(true) -- Unload, then reload
					elseif self.State == "Empty" then
						self:Load()
					end
				end
			end
		end

		function ENT:Link(Target)
			if not IsValid(Target) then return false, "Attempted to link an invalid entity." end
			if self == Target then return false, "Can't link a weapon to itself." end

			local Function = ClassLink(self:GetClass(), Target:GetClass())

			if Function then
				return Function(self, Target)
			end

			return false, "Guns can't be linked to '" .. Target:GetClass() .. "'."
		end

		function ENT:Unlink(Target)
			if not IsValid(Target) then return false, "Attempted to unlink an invalid entity." end
			if self == Target then return false, "Can't unlink a weapon from itself." end

			local Function = ClassUnlink(self:GetClass(), Target:GetClass())

			if Function then
				return Function(self, Target)
			end

			return false, "Guns can't be unlinked from '" .. Target:GetClass() .. "'."
		end
	end -----------------------------------------

	do -- Shooting ------------------------------
		function ENT:BarrelCheck()
			if not CPPI then return self:LocalToWorld(self.Muzzle) end

			TraceData.start	 = self:LocalToWorld(Vector())
			TraceData.endpos = self:LocalToWorld(self.Muzzle)
			TraceData.filter = self.BarrelFilter

			Trace(TraceData)

			if TraceRes.Hit and TraceRes.Entity:CPPIGetOwner() == self.Owner then
				self.BarrelFilter[#self.BarrelFilter + 1] = TraceRes.Entity

				return self:BarrelCheck()
			end

			return TraceRes.HitPos
		end

		function ENT:CanFire()
			if not IsValid(self) then return false end -- Weapon doesn't exist
			if not self.Firing then return false end -- Nobody is holding the trigger
			if self.Disabled then return false end -- Disabled
			if self.State ~= "Loaded" then -- Weapon is not loaded
				if self.State == "Empty" and not self.Retry then
					if not self:Load() then
						self:EmitSound("weapons/pistol/pistol_empty.wav", 500, 100) -- Click!
					end

					self.Retry = true

					timer.Simple(1, function() -- Try again after a second
						if IsValid(self) then
							self.Retry = nil

							if self:CanFire() then
								self:Shoot()
							end
						end
					end)
				end

				return false
			end
			if HookRun("ACF_FireShell", self) == false then return false end -- Something hooked into ACF_FireShell said no

			return true
		end

		function ENT:GetSpread()
			local SpreadScale = ACF.SpreadScale
			local IaccMult    = math.Clamp(((1 - SpreadScale) / 0.5) * ((self.ACF.Health / self.ACF.MaxHealth) - 1) + 1, 1, SpreadScale)

			return self.Spread * ACF.GunInaccuracyScale * IaccMult
		end

		function ENT:Shoot()
			local Cone = math.tan(math.rad(self:GetSpread()))
			local randUnitSquare = (self:GetUp() * (2 * math.random() - 1) + self:GetRight() * (2 * math.random() - 1))
			local Spread = randUnitSquare:GetNormalized() * Cone * (math.random() ^ (1 / ACF.GunInaccuracyBias))
			local Dir = (self:GetForward() + Spread):GetNormalized()

			self.BulletData.Owner  = self.User -- Must be updated on every shot
			self.BulletData.Gun	   = self      -- because other guns share this table
			self.BulletData.Pos    = self:BarrelCheck()
			self.BulletData.Flight = Dir * self.BulletData.MuzzleVel * 39.37 + self:GetAncestor():GetVelocity()
			self.BulletData.Fuze   = self.Fuze -- Must be set when firing as the table is shared

			ACF.RoundTypes[self.BulletData.Type].create(self, self.BulletData) -- Spawn projectile
			self:MuzzleEffect()
			self:Recoil()

			if self.MagSize then -- Mag-fed/Automatically loaded
				self.CurrentShot = self.CurrentShot - 1

				if self.CurrentShot > 0 then -- Not empty
					self:Chamber(self.Cyclic)
				else -- Reload the magazine
					self:Load()
				end
			else -- Single-shot/Manually loaded
				self.CurrentShot = 0 -- We only have one shot, so shooting means we're at 0
				self:Chamber()
			end
		end

		function ENT:MuzzleEffect()
			local Effect = EffectData()
				Effect:SetEntity(self)
				Effect:SetScale(self.BulletData.PropMass)
				Effect:SetMagnitude(self.ReloadTime)

			util.Effect("ACF_Muzzle_Flash", Effect, true, true)
		end

		function ENT:ReloadEffect(Time)
			local Effect = EffectData()
				Effect:SetEntity(self)
				Effect:SetScale(0)
				Effect:SetMagnitude(Time)

			util.Effect("ACF_Muzzle_Flash", Effect, true, true)
		end

		function ENT:Recoil()
			if not ACF_RECOIL:GetBool() then return end

			local MassCenter = self:LocalToWorld(self:GetPhysicsObject():GetMassCenter())

			Shove(self, MassCenter, -self:GetForward(), self.BulletData.ProjMass * self.BulletData.MuzzleVel * 39.37 + self.BulletData.PropMass * 3000 * 39.37)
		end
	end -----------------------------------------

	do -- Loading -------------------------------
		local function FindNextCrate(Gun)
			if not next(Gun.Crates) then return end

			-- Find the next available crate to pull ammo from --
			local Current = Gun.CurrentCrate
			local NextKey = (IsValid(Current) and Gun.Crates[Current]) and Current or nil
			local Select = next(Gun.Crates, NextKey) or next(Gun.Crates)
			local Start  = Select

			repeat
				if Select.Load then return Select end -- Return select

				Select = next(Gun.Crates, Select) or next(Gun.Crates)
			until
				Select == Start

			return Select.Load and Select
		end

		function ENT:Unload(Reload)
			if self.Disabled then return end
			if IsValid(self.CurrentCrate) then self.CurrentCrate:Consume(-1) end -- Put a shell back in the crate, if possible

			local Time = self.MagReload or self.ReloadTime

			self:ReloadEffect(Reload and Time * 2 or Time)
			self:SetState("Unloading")
			self:EmitSound("weapons/357/357_reload4.wav", 500, 100)
			self.CurrentShot = 0
			self.BulletData  = EMPTY

			timer.Simple(Time, function()
				if IsValid(self) then
					if Reload then
						self:Load()
					else
						self:SetState("Empty")
					end
				end
			end)
		end

		function ENT:Chamber(TimeOverride)
			if self.Disabled then return end

			local Crate = FindNextCrate(self)

			if IsValid(Crate) then -- Have a crate, start loading
				self:SetState("Loading") -- Set our state to loading
				Crate:Consume() -- Take one round of ammo out of the current crate (Must be called *after* setting the state to loading)

				local BulletData = Crate.BulletData
				local Time		 = TimeOverride or (ACF.BaseReload + (BulletData.ProjMass + BulletData.PropMass) * ACF.MassToTime)

				self.CurrentCrate = Crate
				self.ReloadTime   = Time
				self.BulletData   = BulletData
				self.NextFire 	  = CurTime() + Time

				if not TimeOverride then -- Mag-fed weapons don't change rate of fire
					WireLib.TriggerOutput(self, "Reload Time", self.ReloadTime)
					WireLib.TriggerOutput(self, "Rate of Fire", 60 / self.ReloadTime)
				end

				timer.Simple(Time, function()
					if IsValid(self) then
						self:SetState("Loaded")
						self.NextFire = nil

						if self.BulletData.CanFuze and self.SetFuze then
							local Variance = math.Rand(-0.015, 0.015) * (20.3 - self.Caliber) * 0.1

							self.Fuze = math.max(self.SetFuze, 0.02) + Variance -- Set fuze when done loading a round
						else
							self.Fuze = nil
						end

						if self.CurrentShot == 0 then
							self.CurrentShot = self.MagSize
						end

						WireLib.TriggerOutput(self, "Shots Left", self.CurrentShot)
						WireLib.TriggerOutput(self, "Projectile Mass", math.Round(self.BulletData.ProjMass * 1000, 2))
						WireLib.TriggerOutput(self, "Muzzle Velocity", math.Round(self.BulletData.MuzzleVel * ACF.Scale, 2))

						if self:CanFire() then self:Shoot() end
					end
				end)
			else -- No available crate to pull ammo from, out of ammo!				
				self:SetState("Empty")

				self.CurrentShot = 0
				self.BulletData  = EMPTY
			end
		end

		function ENT:Load()
			if self.Disabled then return false end
			if not FindNextCrate(self) then -- Can't load without having ammo being provided
				self:SetState("Empty")

				self.CurrentShot = 0
				self.BulletData  = EMPTY

				return false
			end

			self:SetState("Loading")

			if self.MagReload then -- Mag-fed/Automatically loaded
				self:EmitSound("weapons/357/357_reload4.wav", 500, 100)

				timer.Simple(self.MagReload, function() -- Reload timer
					if IsValid(self) then
						self:Chamber(self.Cyclic) -- One last timer to chamber the round
					end
				end)
			else -- Single-shot/Manually loaded
				self:Chamber()
			end

			return true
		end
	end -----------------------------------------

	do -- Duplicator Support --------------------
		function ENT:PreEntityCopy()
			if next(self.Crates) then
				local Entities = {}

				for Crate in pairs(self.Crates) do
					Entities[#Entities + 1] = Crate:EntIndex()
				end

				duplicator.StoreEntityModifier(self, "ACFCrates", Entities)
			end

			-- Wire dupe info
			self.BaseClass.PreEntityCopy(self)
		end

		function ENT:PostEntityPaste(Player, Ent, CreatedEntities)
			local EntMods = Ent.EntityMods

			-- Backwards compatibility
			if EntMods.ACFAmmoLink then
				local Entities = EntMods.ACFAmmoLink.entities

				for _, EntID in ipairs(Entities) do
					self:Link(CreatedEntities[EntID])
				end

				EntMods.ACFAmmoLink = nil
			end

			if EntMods.ACFCrates then
				for _, EntID in pairs(EntMods.ACFCrates) do
					self:Link(CreatedEntities[EntID])
				end

				EntMods.ACFCrates = nil
			end

			self.BaseClass.PostEntityPaste(self, Player, Ent, CreatedEntities)
		end
	end -----------------------------------------

	do -- Overlay -------------------------------
		local function Overlay(Ent)
			local Status
			local AmmoType  = Ent.BulletData.Type .. (Ent.BulletData.Tracer ~= 0 and "-T" or "")
			local Firerate  = math.floor(60 / Ent.ReloadTime)
			local CrateAmmo = 0

			if Ent.DisableReason then
				Status = "Disabled: " .. Ent.DisableReason
			elseif not next(Ent.Crates) then
				Status = "Not linked to an ammo crate!"
			else
				Status = Ent.State == "Loaded" and "Loaded with " .. AmmoType or Ent.State
			end

			for Crate in pairs(Ent.Crates) do -- Tally up the amount of ammo being provided by active crates
				if Crate.Load then
					CrateAmmo = CrateAmmo + Crate.Ammo
				end
			end

			Ent:SetOverlayText(string.format("%s\n\nRate of Fire: %s rpm\nShots Left: %s\nAmmo Available: %s", Status, Firerate, Ent.CurrentShot, CrateAmmo))
		end

		function ENT:UpdateOverlay(Instant)
			if Instant then
				Overlay(self)
				return
			end

			if not TimerExists("ACF Overlay Buffer" .. self:EntIndex()) then
				TimerCreate("ACF Overlay Buffer" .. self:EntIndex(), 1, 1, function()
					if IsValid(self) then
						Overlay(self)
					end
				end)
			end
		end
	end -----------------------------------------

	do -- Misc ----------------------------------
		function ENT:SetState(State)
			self.State = State

			self:UpdateOverlay()

			WireLib.TriggerOutput(self, "Status", State)
		end

		function ENT:Think()
			if next(self.Crates) then
				local Pos = self:GetPos()

				for Crate in pairs(self.Crates) do
					if Crate:GetPos():DistToSqr(Pos) > 62500 then -- 250 unit radius
						self:Unlink(Crate)

						self:EmitSound(UnlinkSound:format(math.random(1, 3)), 500, 100)
						Crate:EmitSound(UnlinkSound:format(math.random(1, 3)), 500, 100)
					end
				end
			end

			self:NextThink(CurTime() + 1)

			return true
		end

		function ENT:Enable()
			self:UpdateOverlay()
		end

		function ENT:Disable()
			self.Firing   = false -- Stop firing

			self:Unload() -- Unload the gun for being a big baddie
			self:UpdateOverlay()
		end

		function ENT:CanProperty(_, Property)
			if self.Long and Property == "bodygroups" then
				timer.Simple(0, function()
					if not IsValid(self) then return end

					local Long = self.Long
					local IsLong = self:GetBodygroup(Long.index) == Long.submodel

					self.Muzzle = IsLong and self.LongMuzzle or self.NormalMuzzle
				end)
			end

			return true
		end

		function ENT:OnRemove()
			for Crate in pairs(self.Crates) do
				self:Unlink(Crate)
			end

			WireLib.Remove(self)
		end
	end -----------------------------------------
end