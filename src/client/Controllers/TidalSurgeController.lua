--[[
  TidalSurgeController.lua
  Client-side controller for tidal surge VFX and SFX.

  Handles:
    - Listening for SurgePhaseChanged signals from TidalSurgeService
    - Idle phase: calm water, no special VFX
    - Warning phase: water recedes (transparency tween), rushing buildup SFX
    - Flood phase: water floods zone (blue-white wave VFX, splash particles)
    - Recede phase: water retreats
    - SurgeHit: local player ragdoll with push velocity
    - BonusContainerRevealed: sparkle notification
    - Late-join sync via GetZoneStates RPC

  Depends on: TidalSurgeService (server signals), SoundController,
              NotificationController, RagdollModule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local RagdollModule = require(Shared:WaitForChild("RagdollModule"))

local TidalSurgeController = Knit.CreateController({
  Name = "TidalSurgeController",
})

local LocalPlayer = Players.LocalPlayer

-- Lazy-loaded references (set in KnitStart)
local TidalSurgeService = nil
local NotificationController = nil
local SoundController = nil

-- Colors
local WATER_COLOR = Color3.fromRGB(40, 120, 180) -- ocean blue
local FOAM_COLOR = Color3.fromRGB(220, 240, 255) -- white foam
local WARNING_COLOR = Color3.fromRGB(180, 200, 220) -- pale blue

-- Zone VFX state: zoneId → { ... }
local ZoneVFX: {
  [string]: {
    part: BasePart?,
    phase: string,
    waterPart: Part?, -- visual water plane
    warningSound: Sound?,
    floodSound: Sound?,
    floodEmitter: ParticleEmitter?,
    foamEmitter: ParticleEmitter?,
    waterLight: PointLight?,
  },
} =
  {}

-- Track ragdoll state for local player surge hits
local IsSurgeRagdolled = false
local SurgeCleanupThread: thread? = nil

-- Proximity threshold for SFX
local SFX_RANGE = 120 -- studs

--------------------------------------------------------------------------------
-- VFX HELPERS
--------------------------------------------------------------------------------

--[[
  Finds the surge zone Part in workspace.TidalSurgeZones by ID.
]]
local function findZonePart(zoneId: string): BasePart?
  local folder = workspace:FindFirstChild("TidalSurgeZones")
  if not folder then
    return nil
  end
  return folder:FindFirstChild(zoneId)
end

--[[
  Creates or retrieves the visual water plane for a zone.
  This is a semi-transparent blue Part that sits atop the zone Part
  and tweens its properties to simulate water level.
]]
local function getOrCreateWaterPlane(zonePart: BasePart): Part
  local existing = zonePart:FindFirstChild("SurgeWaterPlane")
  if existing then
    return existing :: Part
  end

  local water = Instance.new("Part")
  water.Name = "SurgeWaterPlane"
  water.Size = Vector3.new(zonePart.Size.X, 0.5, zonePart.Size.Z)
  water.CFrame = zonePart.CFrame * CFrame.new(0, zonePart.Size.Y / 2 + 0.25, 0)
  water.Color = WATER_COLOR
  water.Material = Enum.Material.Glass
  water.Transparency = 1 -- start invisible
  water.Anchored = true
  water.CanCollide = false
  water.CanQuery = false
  water.CanTouch = false
  water.CastShadow = false
  water.Parent = zonePart

  return water
end

--[[
  Creates warning phase VFX: water recedes (slight transparency pulse), buildup audio.
]]
local function createWarningVFX(zonePart: BasePart, vfx: any)
  -- Water plane fades in slightly to show "water pulling back"
  local water = getOrCreateWaterPlane(zonePart)
  vfx.waterPart = water

  -- Tween water to slightly visible (receding look)
  TweenService:Create(water, TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
    Transparency = 0.7,
    Color = WARNING_COLOR,
  }):Play()

  -- Rushing water buildup sound (respects sfxEnabled)
  if not SoundController or SoundController:IsSfxEnabled() then
    local sound = Instance.new("Sound")
    sound.Name = "SurgeWarning"
    sound.SoundId = SoundController and SoundController:GetSoundId("surgeWarning")
      or "rbxassetid://9116222901"
    sound.Volume = 0
    sound.Looped = true
    sound.RollOffMinDistance = 15
    sound.RollOffMaxDistance = SFX_RANGE
    sound.Parent = zonePart
    sound:Play()
    vfx.warningSound = sound

    -- Fade volume in
    TweenService:Create(sound, TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
      Volume = SoundController and SoundController:GetVolume("surgeWarning") or 0.5,
    }):Play()
  end
end

--[[
  Creates flood phase VFX: water plane rises, splash particles, wave sound.
]]
local function createFloodVFX(zonePart: BasePart, vfx: any)
  local water = getOrCreateWaterPlane(zonePart)
  vfx.waterPart = water

  -- Tween water to visible, higher position, ocean blue
  TweenService:Create(water, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
    Transparency = 0.3,
    Color = WATER_COLOR,
  }):Play()

  -- Raise the water plane slightly to simulate flood
  local raisedCF = zonePart.CFrame * CFrame.new(0, zonePart.Size.Y / 2 + 1.5, 0)
  TweenService:Create(water, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
    CFrame = raisedCF,
    Size = Vector3.new(zonePart.Size.X, 2, zonePart.Size.Z),
  }):Play()

  -- Splash/foam particle emitter
  local foam = Instance.new("ParticleEmitter")
  foam.Name = "SurgeFoam"
  foam.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, FOAM_COLOR),
    ColorSequenceKeypoint.new(0.5, WATER_COLOR),
    ColorSequenceKeypoint.new(1, FOAM_COLOR),
  })
  foam.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1),
    NumberSequenceKeypoint.new(0.5, 3),
    NumberSequenceKeypoint.new(1, 1),
  })
  foam.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.5, 0.4),
    NumberSequenceKeypoint.new(1, 1),
  })
  foam.Lifetime = NumberRange.new(0.5, 1.5)
  foam.Rate = 25
  foam.Speed = NumberRange.new(5, 15)
  foam.SpreadAngle = Vector2.new(60, 60)
  foam.RotSpeed = NumberRange.new(-60, 60)
  foam.Rotation = NumberRange.new(0, 360)
  foam.Parent = water
  vfx.foamEmitter = foam

  -- Water glow
  local light = Instance.new("PointLight")
  light.Name = "SurgeGlow"
  light.Color = WATER_COLOR
  light.Brightness = 1
  light.Range = 25
  light.Parent = water
  vfx.waterLight = light

  -- Crash/splash sound (respects sfxEnabled)
  if not SoundController or SoundController:IsSfxEnabled() then
    local sound = Instance.new("Sound")
    sound.Name = "SurgeFlood"
    sound.SoundId = SoundController and SoundController:GetSoundId("waveCrash")
      or "rbxassetid://9114227726"
    sound.Volume = SoundController and SoundController:GetVolume("waveCrash") or 0.7
    sound.Looped = false
    sound.RollOffMinDistance = 20
    sound.RollOffMaxDistance = SFX_RANGE
    sound.Parent = zonePart
    sound:Play()
    vfx.floodSound = sound
  end
end

--[[
  Creates recede phase VFX: water retreats, fades out.
]]
local function createRecedeVFX(zonePart: BasePart, vfx: any)
  local water = vfx.waterPart
  if not water then
    water = getOrCreateWaterPlane(zonePart)
    vfx.waterPart = water
  end

  -- Tween water back down and fade out
  local baseCF = zonePart.CFrame * CFrame.new(0, zonePart.Size.Y / 2 + 0.25, 0)
  TweenService:Create(water, TweenInfo.new(2.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
    Transparency = 1,
    CFrame = baseCF,
    Size = Vector3.new(zonePart.Size.X, 0.5, zonePart.Size.Z),
  }):Play()
end

--[[
  Cleans up all VFX for a specific zone.
]]
local function cleanupZoneVFX(zoneId: string)
  local vfx = ZoneVFX[zoneId]
  if not vfx then
    return
  end

  if vfx.warningSound then
    vfx.warningSound:Stop()
    vfx.warningSound:Destroy()
    vfx.warningSound = nil
  end
  if vfx.floodSound then
    vfx.floodSound:Stop()
    vfx.floodSound:Destroy()
    vfx.floodSound = nil
  end
  if vfx.foamEmitter then
    vfx.foamEmitter:Destroy()
    vfx.foamEmitter = nil
  end
  if vfx.waterLight then
    vfx.waterLight:Destroy()
    vfx.waterLight = nil
  end
end

--------------------------------------------------------------------------------
-- PHASE TRANSITIONS
--------------------------------------------------------------------------------

--[[
  Applies VFX for the given phase on a zone.
]]
local function applyPhaseVFX(
  zoneId: string,
  phase: string,
  _position: Vector3,
  _size: Vector3,
  _inlandDirection: Vector3
)
  -- Ensure we have a VFX entry for this zone
  if not ZoneVFX[zoneId] then
    local part = findZonePart(zoneId)
    if not part then
      return
    end

    ZoneVFX[zoneId] = {
      part = part,
      phase = "idle",
    }
  end

  local vfx = ZoneVFX[zoneId]
  local part = vfx.part
  if not part then
    return
  end

  -- Clean up previous phase VFX
  cleanupZoneVFX(zoneId)

  vfx.phase = phase

  if phase == "idle" then
    -- Idle: no special VFX, ensure water plane is invisible
    local water = part:FindFirstChild("SurgeWaterPlane")
    if water then
      water.Transparency = 1
    end
  elseif phase == "warning" then
    createWarningVFX(part, vfx)
  elseif phase == "flood" then
    createFloodVFX(part, vfx)
  elseif phase == "recede" then
    createRecedeVFX(part, vfx)
  end
end

--------------------------------------------------------------------------------
-- SURGE HIT HANDLING
--------------------------------------------------------------------------------

--[[
  Called when the local player is hit by a tidal surge.
  Applies ragdoll with push velocity.
]]
local function onSurgeHit(pushVelocity: Vector3, ragdollDuration: number)
  -- Show notification
  if NotificationController then
    NotificationController:ShowNotification("Tidal surge!", WATER_COLOR, 3)
  end

  -- Cancel any pending surge cleanup
  if SurgeCleanupThread then
    task.cancel(SurgeCleanupThread)
    SurgeCleanupThread = nil
  end

  IsSurgeRagdolled = true

  local character = LocalPlayer.Character
  if character then
    RagdollModule.enable(character, pushVelocity)

    -- Schedule ragdoll cleanup
    SurgeCleanupThread = task.delay(ragdollDuration, function()
      SurgeCleanupThread = nil
      IsSurgeRagdolled = false
      if character and character.Parent then
        RagdollModule.disable(character)
      end
    end)
  end
end

--[[
  Called when a bonus container is revealed after a surge recedes.
]]
local function onBonusContainerRevealed(zoneId: string, containerPosition: Vector3)
  -- Only notify if player is nearby
  local character = LocalPlayer.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  local dist = (hrp.Position - containerPosition).Magnitude
  if dist < 100 then
    if NotificationController then
      NotificationController:ShowNotification(
        "The tide revealed hidden treasure!",
        Color3.fromRGB(255, 200, 50),
        4
      )
    end
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function TidalSurgeController:KnitInit()
  print("[TidalSurgeController] Initialized")
end

function TidalSurgeController:KnitStart()
  TidalSurgeService = Knit.GetService("TidalSurgeService")
  NotificationController = Knit.GetController("NotificationController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for surge phase changes from server
  TidalSurgeService.SurgePhaseChanged:Connect(
    function(
      zoneId: string,
      phase: string,
      position: Vector3,
      size: Vector3,
      inlandDirection: Vector3
    )
      applyPhaseVFX(zoneId, phase, position, size, inlandDirection)
    end
  )

  -- Listen for surge hit on local player
  TidalSurgeService.SurgeHit:Connect(onSurgeHit)

  -- Listen for bonus container reveals
  TidalSurgeService.BonusContainerRevealed:Connect(onBonusContainerRevealed)

  -- Late-join sync: get current zone states
  TidalSurgeService:GetZoneStates()
    :andThen(function(states)
      for _, state in states do
        applyPhaseVFX(state.id, state.phase, state.position, state.size, state.inlandDirection)
      end
    end)
    :catch(function(err)
      warn("[TidalSurgeController] Failed to sync zone states:", err)
    end)

  -- Clean up ragdoll state on character removal
  LocalPlayer.CharacterRemoving:Connect(function(character: Model)
    if IsSurgeRagdolled then
      RagdollModule.cleanup(character)
      IsSurgeRagdolled = false
    end
    if SurgeCleanupThread then
      task.cancel(SurgeCleanupThread)
      SurgeCleanupThread = nil
    end
  end)

  print("[TidalSurgeController] Started")
end

return TidalSurgeController
