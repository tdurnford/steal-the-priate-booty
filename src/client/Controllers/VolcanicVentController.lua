--[[
  VolcanicVentController.lua
  Client-side controller for volcanic vent VFX and SFX.

  Handles:
    - Listening for VentPhaseChanged signals from VolcanicVentService
    - Dormant phase: faint steam particles on vent Parts
    - Warning phase: increasing steam, orange glow, ground rumble SFX
    - Eruption phase: fire geyser column VFX, eruption SFX
    - VentEruptionHit: local player ragdoll with upward launch
    - Late-join sync via GetVentStates RPC

  Depends on: VolcanicVentService (server signals), SoundController,
              NotificationController, RagdollModule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local RagdollModule = require(Shared:WaitForChild("RagdollModule"))

local VolcanicVentController = Knit.CreateController({
  Name = "VolcanicVentController",
})

local LocalPlayer = Players.LocalPlayer

-- Lazy-loaded references (set in KnitStart)
local VolcanicVentService = nil
local NotificationController = nil
local SoundController = nil

-- Colors
local WARNING_COLOR = Color3.fromRGB(255, 140, 40) -- orange
local ERUPTION_COLOR = Color3.fromRGB(255, 60, 20) -- red-orange
local STEAM_COLOR = Color3.fromRGB(200, 200, 200) -- gray
local FIRE_COLOR_START = Color3.fromRGB(255, 200, 50) -- yellow
local FIRE_COLOR_END = Color3.fromRGB(255, 60, 20) -- red

-- Vent VFX state: ventId → { emitters, lights, sounds, etc. }
local VentVFX: {
  [string]: {
    part: BasePart?,
    phase: string,
    steamEmitter: ParticleEmitter?,
    warningEmitter: ParticleEmitter?,
    warningLight: PointLight?,
    warningSound: Sound?,
    eruptionEmitter: ParticleEmitter?,
    eruptionLight: PointLight?,
    eruptionSound: Sound?,
  },
} =
  {}

-- Track ragdoll state for local player eruption hits
local IsEruptionRagdolled = false
local EruptionCleanupThread: thread? = nil

-- Proximity threshold for rumble/warning SFX
local WARNING_SFX_RANGE = 80 -- studs

--------------------------------------------------------------------------------
-- VFX HELPERS
--------------------------------------------------------------------------------

--[[
  Finds the vent Part in workspace.VolcanicVents by ID.
]]
local function findVentPart(ventId: string): BasePart?
  local folder = workspace:FindFirstChild("VolcanicVents")
  if not folder then
    return nil
  end
  return folder:FindFirstChild(ventId)
end

--[[
  Creates the dormant steam particle emitter for a vent.
  Faint wisps of steam rising slowly.
]]
local function createDormantSteam(part: BasePart): ParticleEmitter
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "VentDormantSteam"
  emitter.Color = ColorSequence.new(STEAM_COLOR)
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.5),
    NumberSequenceKeypoint.new(0.5, 1.5),
    NumberSequenceKeypoint.new(1, 0.3),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.6),
    NumberSequenceKeypoint.new(0.5, 0.8),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(1.5, 3)
  emitter.Rate = 3
  emitter.Speed = NumberRange.new(1, 3)
  emitter.SpreadAngle = Vector2.new(15, 15)
  emitter.RotSpeed = NumberRange.new(-30, 30)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.Parent = part
  return emitter
end

--[[
  Creates warning phase VFX: heavier steam, orange glow, rumble audio.
]]
local function createWarningVFX(part: BasePart): (ParticleEmitter, PointLight, Sound)
  -- Heavy steam with orange tint
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "VentWarningSteam"
  emitter.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, STEAM_COLOR),
    ColorSequenceKeypoint.new(0.5, WARNING_COLOR),
    ColorSequenceKeypoint.new(1, STEAM_COLOR),
  })
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1),
    NumberSequenceKeypoint.new(0.5, 3),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.5),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(1, 2)
  emitter.Rate = 12
  emitter.Speed = NumberRange.new(3, 8)
  emitter.SpreadAngle = Vector2.new(25, 25)
  emitter.RotSpeed = NumberRange.new(-60, 60)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.Parent = part

  -- Orange glow
  local light = Instance.new("PointLight")
  light.Name = "VentWarningGlow"
  light.Color = WARNING_COLOR
  light.Brightness = 0
  light.Range = 20
  light.Parent = part

  -- Tween the light brightness up during warning phase
  TweenService:Create(light, TweenInfo.new(4.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
    Brightness = 3,
  }):Play()

  -- Rumble sound (ground rumble, respects sfxEnabled)
  local sound = nil
  if not SoundController or SoundController:IsSfxEnabled() then
    sound = Instance.new("Sound")
    sound.Name = "VentRumble"
    sound.SoundId = SoundController and SoundController:GetSoundId("ventRumble")
      or "rbxassetid://9116222901"
    sound.Volume = 0
    sound.Looped = true
    sound.RollOffMinDistance = 10
    sound.RollOffMaxDistance = WARNING_SFX_RANGE
    sound.Parent = part
    sound:Play()

    -- Fade rumble volume in
    TweenService:Create(sound, TweenInfo.new(3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
      Volume = SoundController and SoundController:GetVolume("ventRumble") or 0.6,
    }):Play()
  end

  return emitter, light, sound
end

--[[
  Creates eruption phase VFX: fire geyser column, bright light, explosion SFX.
]]
local function createEruptionVFX(part: BasePart): (ParticleEmitter, PointLight, Sound)
  -- Fire geyser particles shooting upward
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "VentEruptionFire"
  emitter.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, FIRE_COLOR_START),
    ColorSequenceKeypoint.new(0.6, ERUPTION_COLOR),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 20, 10)),
  })
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 2),
    NumberSequenceKeypoint.new(0.3, 4),
    NumberSequenceKeypoint.new(0.7, 3),
    NumberSequenceKeypoint.new(1, 0.5),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0),
    NumberSequenceKeypoint.new(0.5, 0.2),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(0.8, 1.5)
  emitter.Rate = 40
  emitter.Speed = NumberRange.new(30, 50)
  emitter.SpreadAngle = Vector2.new(8, 8)
  emitter.RotSpeed = NumberRange.new(-90, 90)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.LightEmission = 1
  emitter.LightInfluence = 0
  emitter.Parent = part

  -- Bright eruption light
  local light = Instance.new("PointLight")
  light.Name = "VentEruptionGlow"
  light.Color = ERUPTION_COLOR
  light.Brightness = 5
  light.Range = 40
  light.Parent = part

  -- Eruption sound (respects sfxEnabled)
  local sound = nil
  if not SoundController or SoundController:IsSfxEnabled() then
    sound = Instance.new("Sound")
    sound.Name = "VentEruption"
    sound.SoundId = SoundController and SoundController:GetSoundId("ventEruption")
      or "rbxassetid://9114227726"
    sound.Volume = SoundController and SoundController:GetVolume("ventEruption") or 0.8
    sound.Looped = false
    sound.RollOffMinDistance = 15
    sound.RollOffMaxDistance = 120
    sound.Parent = part
    sound:Play()
  end

  return emitter, light, sound
end

--[[
  Cleans up all VFX for a specific vent, resetting to default state.
]]
local function cleanupVentVFX(ventId: string)
  local vfx = VentVFX[ventId]
  if not vfx then
    return
  end

  if vfx.warningEmitter then
    vfx.warningEmitter:Destroy()
    vfx.warningEmitter = nil
  end
  if vfx.warningLight then
    vfx.warningLight:Destroy()
    vfx.warningLight = nil
  end
  if vfx.warningSound then
    vfx.warningSound:Stop()
    vfx.warningSound:Destroy()
    vfx.warningSound = nil
  end
  if vfx.eruptionEmitter then
    vfx.eruptionEmitter:Destroy()
    vfx.eruptionEmitter = nil
  end
  if vfx.eruptionLight then
    vfx.eruptionLight:Destroy()
    vfx.eruptionLight = nil
  end
  if vfx.eruptionSound then
    vfx.eruptionSound:Stop()
    vfx.eruptionSound:Destroy()
    vfx.eruptionSound = nil
  end
end

--------------------------------------------------------------------------------
-- PHASE TRANSITIONS
--------------------------------------------------------------------------------

--[[
  Applies VFX for the given phase on a vent.
]]
local function applyPhaseVFX(ventId: string, phase: string, position: Vector3, size: Vector3)
  -- Ensure we have a VFX entry for this vent
  if not VentVFX[ventId] then
    local part = findVentPart(ventId)
    if not part then
      return
    end

    -- Create dormant steam (always present)
    local steam = createDormantSteam(part)

    VentVFX[ventId] = {
      part = part,
      phase = "dormant",
      steamEmitter = steam,
    }
  end

  local vfx = VentVFX[ventId]
  local part = vfx.part
  if not part then
    return
  end

  -- Clean up previous phase VFX
  cleanupVentVFX(ventId)

  vfx.phase = phase

  if phase == "dormant" then
    -- Dormant: just the faint steam (already exists)
    if vfx.steamEmitter then
      vfx.steamEmitter.Rate = 3
    end
  elseif phase == "warning" then
    -- Warning: increase dormant steam + add warning VFX
    if vfx.steamEmitter then
      vfx.steamEmitter.Rate = 8
    end

    local emitter, light, sound = createWarningVFX(part)
    vfx.warningEmitter = emitter
    vfx.warningLight = light
    vfx.warningSound = sound
  elseif phase == "eruption" then
    -- Eruption: suppress dormant steam, show fire geyser
    if vfx.steamEmitter then
      vfx.steamEmitter.Rate = 0
    end

    local emitter, light, sound = createEruptionVFX(part)
    vfx.eruptionEmitter = emitter
    vfx.eruptionLight = light
    vfx.eruptionSound = sound
  end
end

--------------------------------------------------------------------------------
-- ERUPTION HIT HANDLING
--------------------------------------------------------------------------------

--[[
  Called when the local player is hit by a vent eruption.
  Applies ragdoll with upward launch velocity.
]]
local function onEruptionHit(
  ventPosition: Vector3,
  launchVelocity: Vector3,
  ragdollDuration: number
)
  -- Show notification
  if NotificationController then
    NotificationController:ShowNotification("Volcanic eruption!", ERUPTION_COLOR, 3)
  end

  -- Cancel any pending eruption cleanup
  if EruptionCleanupThread then
    task.cancel(EruptionCleanupThread)
    EruptionCleanupThread = nil
  end

  IsEruptionRagdolled = true

  local character = LocalPlayer.Character
  if character then
    RagdollModule.enable(character, launchVelocity)

    -- Schedule ragdoll cleanup
    EruptionCleanupThread = task.delay(ragdollDuration, function()
      EruptionCleanupThread = nil
      IsEruptionRagdolled = false
      if character and character.Parent then
        RagdollModule.disable(character)
      end
    end)
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function VolcanicVentController:KnitInit()
  print("[VolcanicVentController] Initialized")
end

function VolcanicVentController:KnitStart()
  VolcanicVentService = Knit.GetService("VolcanicVentService")
  NotificationController = Knit.GetController("NotificationController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for vent phase changes from server
  VolcanicVentService.VentPhaseChanged:Connect(
    function(ventId: string, phase: string, position: Vector3, size: Vector3)
      applyPhaseVFX(ventId, phase, position, size)
    end
  )

  -- Listen for eruption hit on local player
  VolcanicVentService.VentEruptionHit:Connect(onEruptionHit)

  -- Late-join sync: get current vent states
  VolcanicVentService:GetVentStates()
    :andThen(function(states)
      for _, state in states do
        applyPhaseVFX(state.id, state.phase, state.position, state.size)
      end
    end)
    :catch(function(err)
      warn("[VolcanicVentController] Failed to sync vent states:", err)
    end)

  -- Clean up ragdoll state on character removal
  LocalPlayer.CharacterRemoving:Connect(function(character: Model)
    if IsEruptionRagdolled then
      RagdollModule.cleanup(character)
      IsEruptionRagdolled = false
    end
    if EruptionCleanupThread then
      task.cancel(EruptionCleanupThread)
      EruptionCleanupThread = nil
    end
  end)

  print("[VolcanicVentController] Started")
end

return VolcanicVentController
