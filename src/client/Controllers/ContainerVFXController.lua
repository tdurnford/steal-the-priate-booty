--[[
  ContainerVFXController.lua
  Client-side VFX controller for container damage and break feedback.

  Handles:
    - Tracking container HP states via ContainerService signals
    - Hit impact particle burst on each container damage event
    - Cracking VFX overlay at 50% HP
    - Gold light leak VFX at 25% HP
    - Satisfying break explosion with coin scatter visual on container destroy
    - Escalating hit sound feedback as containers approach breaking

  All VFX are driven by server-authoritative signals (ContainerDamaged,
  ContainerBroken, ContainerSpawned). No client-side prediction.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))

local ContainerVFXController = Knit.CreateController({
  Name = "ContainerVFXController",
})

-- Lazy-loaded references
local ContainerService = nil
local SoundController = nil

-- Track container states on the client
-- { [containerId]: { model: Model?, hpFraction: number, vfxState: string } }
local TrackedContainers: {
  [string]: {
    model: Model?,
    hpFraction: number,
    vfxState: string, -- "healthy" | "cracking" | "leaking"
  },
} =
  {}

-- VFX threshold constants
local CRACK_THRESHOLD = 0.5 -- 50% HP
local LEAK_THRESHOLD = 0.25 -- 25% HP

-- Sound escalation: quiet above 50%, medium 25-50%, loud below 25%

--------------------------------------------------------------------------------
-- CONTAINER MODEL LOOKUP
--------------------------------------------------------------------------------

--[[
  Finds the container model in workspace by container ID.
  @param containerId The container instance ID string
  @return Model? The container model, or nil
]]
local function findContainerModel(containerId: string): Model?
  local containersFolder = workspace:FindFirstChild("Containers")
  if not containersFolder then
    return nil
  end
  return containersFolder:FindFirstChild("Container_" .. containerId) :: Model?
end

--[[
  Finds the Body part inside a container model.
  @param model The container model
  @return BasePart? The body part, or nil
]]
local function getBody(model: Model): BasePart?
  return model:FindFirstChild("Body") :: BasePart?
end

--------------------------------------------------------------------------------
-- HIT IMPACT VFX
--------------------------------------------------------------------------------

--[[
  Spawns a brief particle burst at the container's position on hit.
  Particles fly outward with a quick fade.
  @param body The container body Part
  @param hpFraction Current HP fraction (affects particle intensity)
]]
local function spawnHitImpactVFX(body: BasePart, hpFraction: number)
  -- Create a short-lived particle emitter for the impact burst
  local attachment = Instance.new("Attachment")
  attachment.Position = Vector3.new(0, 0, 0)
  attachment.Parent = body

  local particles = Instance.new("ParticleEmitter")
  particles.Name = "HitImpact"

  -- Color shifts from brown (wood chips) to gold as HP decreases
  if hpFraction <= LEAK_THRESHOLD then
    -- Gold/yellow particles when close to breaking
    particles.Color = ColorSequence.new({
      ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 215, 50)),
      ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 180, 0)),
    })
  elseif hpFraction <= CRACK_THRESHOLD then
    -- Mixed wood/gold particles
    particles.Color = ColorSequence.new({
      ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 140, 60)),
      ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 200, 80)),
    })
  else
    -- Brown wood chip particles
    particles.Color = ColorSequence.new({
      ColorSequenceKeypoint.new(0, Color3.fromRGB(139, 90, 43)),
      ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 65, 30)),
    })
  end

  particles.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.2),
    NumberSequenceKeypoint.new(1, 0),
  })
  particles.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0),
    NumberSequenceKeypoint.new(0.7, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  particles.Lifetime = NumberRange.new(0.3, 0.6)
  particles.Speed = NumberRange.new(5, 12)
  particles.SpreadAngle = Vector2.new(60, 60)
  particles.Rate = 0 -- We'll use :Emit() for a burst
  particles.Parent = attachment

  -- Emit burst — more particles as container gets weaker
  local burstCount = if hpFraction <= LEAK_THRESHOLD
    then 20
    elseif hpFraction <= CRACK_THRESHOLD then 12
    else 6
  particles:Emit(burstCount)

  -- Clean up after particles fade
  Debris:AddItem(attachment, 1)
end

--------------------------------------------------------------------------------
-- CRACKING VFX (50% HP)
--------------------------------------------------------------------------------

--[[
  Applies a cracking visual effect to the container.
  Changes the material to Cracked Lava and adds a subtle dark overlay.
  @param model The container model
]]
local function applyCrackingVFX(model: Model)
  local body = getBody(model)
  if not body then
    return
  end

  -- Store original material so we can restore if needed
  if not body:GetAttribute("OriginalMaterial") then
    body:SetAttribute("OriginalMaterial", body.Material.Name)
    body:SetAttribute("OriginalColor", body.Color)
  end

  -- Change material to show cracks
  body.Material = Enum.Material.CrackedLava

  -- Add a subtle SurfaceGui with crack overlay (text-based for placeholder)
  local existing = body:FindFirstChild("CrackOverlay")
  if not existing then
    -- Add a faint rumble/shake to indicate structural damage
    local highlight = Instance.new("Highlight")
    highlight.Name = "CrackOverlay"
    highlight.Adornee = model
    highlight.FillTransparency = 0.85
    highlight.FillColor = Color3.fromRGB(60, 40, 20)
    highlight.OutlineTransparency = 0.5
    highlight.OutlineColor = Color3.fromRGB(80, 50, 20)
    highlight.Parent = model
  end
end

--------------------------------------------------------------------------------
-- GOLD LIGHT LEAK VFX (25% HP)
--------------------------------------------------------------------------------

--[[
  Applies a gold light leak effect to the container.
  Adds a PointLight and gold particle emitter leaking through cracks.
  @param model The container model
]]
local function applyGoldLeakVFX(model: Model)
  local body = getBody(model)
  if not body then
    return
  end

  -- Update the highlight to gold tint
  local highlight = model:FindFirstChild("CrackOverlay") :: Highlight?
  if highlight then
    highlight.FillColor = Color3.fromRGB(200, 160, 40)
    highlight.FillTransparency = 0.7
    highlight.OutlineColor = Color3.fromRGB(255, 200, 50)
    highlight.OutlineTransparency = 0.3
  end

  -- Add gold point light for the light leak effect
  if not body:FindFirstChild("GoldLeakLight") then
    local light = Instance.new("PointLight")
    light.Name = "GoldLeakLight"
    light.Color = Color3.fromRGB(255, 200, 50)
    light.Brightness = 2
    light.Range = 12
    light.Parent = body

    -- Tween the light to pulse gently
    local tweenInfo =
      TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
    TweenService:Create(light, tweenInfo, { Brightness = 3.5 }):Play()
  end

  -- Add gold particle leak
  if not body:FindFirstChild("GoldLeakParticles") then
    local particles = Instance.new("ParticleEmitter")
    particles.Name = "GoldLeakParticles"
    particles.Color = ColorSequence.new({
      ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 215, 50)),
      ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 180, 0)),
    })
    particles.Size = NumberSequence.new({
      NumberSequenceKeypoint.new(0, 0.1),
      NumberSequenceKeypoint.new(0.5, 0.25),
      NumberSequenceKeypoint.new(1, 0),
    })
    particles.Transparency = NumberSequence.new({
      NumberSequenceKeypoint.new(0, 0.2),
      NumberSequenceKeypoint.new(1, 1),
    })
    particles.Lifetime = NumberRange.new(0.5, 1.2)
    particles.Rate = 8
    particles.Speed = NumberRange.new(1, 3)
    particles.SpreadAngle = Vector2.new(180, 180)
    particles.LightEmission = 0.8
    particles.LightInfluence = 0.2
    particles.Parent = body
  end
end

--------------------------------------------------------------------------------
-- BREAK EXPLOSION VFX
--------------------------------------------------------------------------------

--[[
  Spawns a satisfying break explosion at the container's position.
  Shows debris flying out, gold coin particles, and a brief flash.
  @param position World position of the broken container
  @param containerType The container type ID (for color/intensity)
]]
local function spawnBreakExplosionVFX(position: Vector3, containerType: string)
  -- Create a temporary part as the VFX anchor
  local anchor = Instance.new("Part")
  anchor.Name = "BreakVFX"
  anchor.Size = Vector3.new(1, 1, 1)
  anchor.Position = position + Vector3.new(0, 1.5, 0)
  anchor.Anchored = true
  anchor.CanCollide = false
  anchor.CanQuery = false
  anchor.CanTouch = false
  anchor.Transparency = 1
  anchor.Parent = workspace

  -- Debris burst (wood chips / metal fragments)
  local debrisEmitter = Instance.new("ParticleEmitter")
  debrisEmitter.Name = "DebrisBurst"

  -- Color depends on container type
  local debrisColor = Color3.fromRGB(139, 90, 43) -- default wood
  if containerType == "reinforced_trunk" then
    debrisColor = Color3.fromRGB(100, 100, 110) -- metal
  elseif containerType == "captains_vault" then
    debrisColor = Color3.fromRGB(200, 170, 60) -- gold-tinted
  elseif containerType == "cursed_chest" then
    debrisColor = Color3.fromRGB(100, 40, 130) -- purple
  end

  debrisEmitter.Color = ColorSequence.new(debrisColor)
  debrisEmitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.4),
    NumberSequenceKeypoint.new(0.5, 0.3),
    NumberSequenceKeypoint.new(1, 0),
  })
  debrisEmitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0),
    NumberSequenceKeypoint.new(0.8, 0.4),
    NumberSequenceKeypoint.new(1, 1),
  })
  debrisEmitter.Lifetime = NumberRange.new(0.5, 1.2)
  debrisEmitter.Speed = NumberRange.new(10, 25)
  debrisEmitter.SpreadAngle = Vector2.new(180, 60)
  debrisEmitter.Rate = 0
  debrisEmitter.Rotation = NumberRange.new(0, 360)
  debrisEmitter.RotSpeed = NumberRange.new(-200, 200)
  debrisEmitter.Parent = anchor
  debrisEmitter:Emit(25)

  -- Gold coin particles (the loot scatter visual)
  local coinEmitter = Instance.new("ParticleEmitter")
  coinEmitter.Name = "CoinBurst"
  coinEmitter.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 50)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 180, 0)),
  })
  coinEmitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.3, 0.35),
    NumberSequenceKeypoint.new(1, 0),
  })
  coinEmitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0),
    NumberSequenceKeypoint.new(0.6, 0),
    NumberSequenceKeypoint.new(1, 1),
  })
  coinEmitter.Lifetime = NumberRange.new(0.8, 1.5)
  coinEmitter.Speed = NumberRange.new(8, 18)
  coinEmitter.SpreadAngle = Vector2.new(180, 120)
  coinEmitter.Rate = 0
  coinEmitter.LightEmission = 1
  coinEmitter.LightInfluence = 0.1
  coinEmitter.Rotation = NumberRange.new(0, 360)
  coinEmitter.RotSpeed = NumberRange.new(-300, 300)
  coinEmitter.Parent = anchor
  coinEmitter:Emit(30)

  -- Brief flash light
  local flash = Instance.new("PointLight")
  flash.Name = "BreakFlash"
  flash.Color = Color3.fromRGB(255, 220, 80)
  flash.Brightness = 5
  flash.Range = 20
  flash.Parent = anchor

  -- Fade the flash out quickly
  local flashTween = TweenService:Create(
    flash,
    TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
    { Brightness = 0 }
  )
  flashTween:Play()

  -- Clean up the whole anchor after particles finish
  Debris:AddItem(anchor, 2)
end

--------------------------------------------------------------------------------
-- VFX STATE MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Determines the VFX state for a given HP fraction.
  @param hpFraction Number 0-1
  @return "leaking" | "cracking" | "healthy"
]]
local function getVFXState(hpFraction: number): string
  if hpFraction <= LEAK_THRESHOLD then
    return "leaking"
  elseif hpFraction <= CRACK_THRESHOLD then
    return "cracking"
  else
    return "healthy"
  end
end

--[[
  Cleans up all VFX from a container model.
  @param model The container model
]]
local function cleanupContainerVFX(model: Model)
  local body = getBody(model)

  -- Remove highlight overlay
  local highlight = model:FindFirstChild("CrackOverlay")
  if highlight then
    highlight:Destroy()
  end

  if body then
    -- Remove gold leak light
    local light = body:FindFirstChild("GoldLeakLight")
    if light then
      light:Destroy()
    end

    -- Remove gold leak particles
    local leakParticles = body:FindFirstChild("GoldLeakParticles")
    if leakParticles then
      leakParticles:Destroy()
    end

    -- Restore original material
    local origMaterial = body:GetAttribute("OriginalMaterial")
    if origMaterial then
      local success, material = pcall(function()
        return (Enum.Material :: any)[origMaterial]
      end)
      if success and material then
        body.Material = material
      end
    end
  end
end

--[[
  Updates the VFX state for a tracked container based on its HP fraction.
  @param containerId The container instance ID
  @param hpFraction Current HP as fraction (0-1)
]]
local function updateContainerVFXState(containerId: string, hpFraction: number)
  local tracked = TrackedContainers[containerId]
  if not tracked then
    return
  end

  local newState = getVFXState(hpFraction)
  tracked.hpFraction = hpFraction

  -- Only update VFX if state changed
  if tracked.vfxState == newState then
    return
  end

  local model = tracked.model
  if not model or not model.Parent then
    -- Try to find the model if we don't have it cached
    model = findContainerModel(containerId)
    if model then
      tracked.model = model
    else
      return
    end
  end

  -- Clean up previous VFX before applying new state
  if newState == "healthy" then
    cleanupContainerVFX(model)
  elseif newState == "cracking" then
    -- Apply cracking (builds on clean state)
    if tracked.vfxState == "leaking" then
      cleanupContainerVFX(model)
    end
    applyCrackingVFX(model)
  elseif newState == "leaking" then
    -- Apply both cracking and gold leak
    if tracked.vfxState == "healthy" then
      applyCrackingVFX(model)
    end
    applyGoldLeakVFX(model)
  end

  tracked.vfxState = newState
end

--------------------------------------------------------------------------------
-- SOUND ESCALATION
--------------------------------------------------------------------------------

--[[
  Determines hit sound tier based on HP fraction.
  @param hpFraction HP as fraction (0-1)
  @return "quiet" | "medium" | "loud"
]]
local function getHitSoundTier(hpFraction: number): string
  if hpFraction <= LEAK_THRESHOLD then
    return "loud"
  elseif hpFraction <= CRACK_THRESHOLD then
    return "medium"
  else
    return "quiet"
  end
end

--[[
  Plays the appropriate hit sound for a container based on its HP state.
  Volume escalates as the container approaches breaking.
  @param body BasePart to attach 3D sound to
  @param hpFraction Current HP fraction
]]
local function playContainerHitSound(body: BasePart, hpFraction: number)
  if not SoundController then
    return
  end

  local tier = getHitSoundTier(hpFraction)

  -- Use the existing container hit sound with volume scaling
  -- SoundController.PlayCombatHitSound handles 3D positioning
  -- We scale the volume by calling with different parameters
  if tier == "loud" then
    SoundController:PlayContainerHitSound("loud", body)
  elseif tier == "medium" then
    SoundController:PlayContainerHitSound("medium", body)
  else
    SoundController:PlayContainerHitSound("quiet", body)
  end
end

--[[
  Plays the container break sound at a world position.
  @param position World position of the break
  @param containerType Container type ID for special break sounds
]]
local function playContainerBreakSound(position: Vector3, containerType: string)
  if not SoundController then
    return
  end
  SoundController:PlayContainerBreakSound(containerType, position)
end

--------------------------------------------------------------------------------
-- SIGNAL HANDLERS
--------------------------------------------------------------------------------

--[[
  Called when a container is damaged.
  @param containerId The container instance ID
  @param hpFraction Current HP as fraction (0-1)
]]
local function onContainerDamaged(containerId: string, hpFraction: number)
  -- Initialize tracking if needed
  if not TrackedContainers[containerId] then
    TrackedContainers[containerId] = {
      model = findContainerModel(containerId),
      hpFraction = 1,
      vfxState = "healthy",
    }
  end

  local tracked = TrackedContainers[containerId]
  local model = tracked.model
  if not model or not model.Parent then
    model = findContainerModel(containerId)
    if model then
      tracked.model = model
    end
  end

  -- Spawn hit impact particles
  if model then
    local body = getBody(model)
    if body then
      spawnHitImpactVFX(body, hpFraction)
      playContainerHitSound(body, hpFraction)
    end
  end

  -- Update VFX state (cracking / gold leak)
  updateContainerVFXState(containerId, hpFraction)
end

--[[
  Called when a container breaks.
  @param containerId The container instance ID
  @param containerType The container type ID
  @param position World position of the broken container
]]
local function onContainerBroken(containerId: string, containerType: string, position: Vector3)
  -- Spawn break explosion VFX
  spawnBreakExplosionVFX(position, containerType)
  playContainerBreakSound(position, containerType)

  -- Clean up tracking
  local tracked = TrackedContainers[containerId]
  if tracked and tracked.model and tracked.model.Parent then
    cleanupContainerVFX(tracked.model)
  end
  TrackedContainers[containerId] = nil
end

--[[
  Called when a new container spawns.
  @param containerId The container instance ID
  @param containerType The container type ID
  @param position World position
]]
local function onContainerSpawned(containerId: string, containerType: string, position: Vector3)
  -- Start tracking the new container in healthy state
  TrackedContainers[containerId] = {
    model = nil, -- will be found on first damage event
    hpFraction = 1,
    vfxState = "healthy",
  }

  -- Try to find and cache the model immediately
  task.defer(function()
    local tracked = TrackedContainers[containerId]
    if tracked then
      tracked.model = findContainerModel(containerId)
    end
  end)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function ContainerVFXController:KnitInit()
  print("[ContainerVFXController] Initializing...")
end

function ContainerVFXController:KnitStart()
  ContainerService = Knit.GetService("ContainerService")
  SoundController = Knit.GetController("SoundController")

  -- Listen for container events from the server
  ContainerService.ContainerDamaged:Connect(onContainerDamaged)
  ContainerService.ContainerBroken:Connect(onContainerBroken)
  ContainerService.ContainerSpawned:Connect(onContainerSpawned)

  print("[ContainerVFXController] Started — listening for container events")
end

return ContainerVFXController
