--[[
  RogueWaveController.lua
  Client-side controller for rogue wave VFX and SFX (night-only hazard).

  Handles:
    - Listening for WavePhaseChanged signals from RogueWaveService
    - Warning phase (6s): roaring wave SFX, screen-edge water VFX, ocean visibly rises
    - Impact phase: massive wave crash VFX, splash particles, camera shake
    - Recede phase: water retreats with foam
    - WaveHit: local player ragdoll with strong inland push
    - BonusContainersWashedAshore: treasure notification
    - Late-join sync via GetZoneStates RPC

  Depends on: RogueWaveService (server signals), NotificationController, RagdollModule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local RagdollModule = require(Shared:WaitForChild("RagdollModule"))

local RogueWaveController = Knit.CreateController({
  Name = "RogueWaveController",
})

local LocalPlayer = Players.LocalPlayer

-- Lazy-loaded references (set in KnitStart)
local RogueWaveService = nil
local NotificationController = nil

-- Colors
local WAVE_COLOR = Color3.fromRGB(20, 80, 140) -- deep ocean blue
local FOAM_COLOR = Color3.fromRGB(220, 240, 255) -- white foam
local WARNING_COLOR = Color3.fromRGB(60, 130, 180) -- ominous blue
local IMPACT_COLOR = Color3.fromRGB(30, 100, 160) -- wave crash blue

-- Zone VFX state: zoneId → { ... }
local ZoneVFX: {
  [string]: {
    part: BasePart?,
    phase: string,
    waterPart: Part?,
    warningSound: Sound?,
    impactSound: Sound?,
    foamEmitter: ParticleEmitter?,
    sprayEmitter: ParticleEmitter?,
    waterLight: PointLight?,
  },
} =
  {}

-- Track ragdoll state for local player wave hits
local IsWaveRagdolled = false
local WaveCleanupThread: thread? = nil

-- Screen-edge water overlay for warning phase
local ScreenOverlay: Frame? = nil
local ScreenOverlayTween: Tween? = nil

-- Proximity threshold for SFX
local SFX_RANGE = 150 -- studs (louder/farther than tidal surge)

--------------------------------------------------------------------------------
-- VFX HELPERS
--------------------------------------------------------------------------------

--[[
  Finds the wave zone Part in workspace.RogueWaveZones by ID.
]]
local function findZonePart(zoneId: string): BasePart?
  local folder = workspace:FindFirstChild("RogueWaveZones")
  if not folder then
    return nil
  end
  return folder:FindFirstChild(zoneId)
end

--[[
  Creates or retrieves the visual water wall for a zone.
  This is a tall, semi-transparent Part that simulates the incoming wave.
]]
local function getOrCreateWaterWall(zonePart: BasePart): Part
  local existing = zonePart:FindFirstChild("RogueWaveWall")
  if existing then
    return existing :: Part
  end

  -- The wave wall rises from the ocean-side edge of the zone
  -- It's a tall wall that sweeps across the zone
  local water = Instance.new("Part")
  water.Name = "RogueWaveWall"
  water.Size = Vector3.new(zonePart.Size.X, 0.5, zonePart.Size.Z)
  water.CFrame = zonePart.CFrame * CFrame.new(0, -zonePart.Size.Y / 2, 0)
  water.Color = WAVE_COLOR
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
  Creates or gets the screen-edge water overlay for the warning phase.
  Shows a subtle blue water vignette at screen edges to alert the player.
]]
local function getOrCreateScreenOverlay(): Frame
  if ScreenOverlay and ScreenOverlay.Parent then
    return ScreenOverlay
  end

  local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
  if not playerGui then
    return nil :: any
  end

  local screenGui = playerGui:FindFirstChild("RogueWaveOverlay")
  if not screenGui then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "RogueWaveOverlay"
    screenGui.DisplayOrder = 80
    screenGui.IgnoreGuiInset = true
    screenGui.ResetOnSpawn = false
    screenGui.Parent = playerGui
  end

  local overlay = screenGui:FindFirstChild("WaterOverlay")
  if not overlay then
    overlay = Instance.new("Frame")
    overlay.Name = "WaterOverlay"
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.Position = UDim2.fromScale(0, 0)
    overlay.BackgroundColor3 = WARNING_COLOR
    overlay.BackgroundTransparency = 1
    overlay.BorderSizePixel = 0
    overlay.Parent = screenGui

    -- Gradient for vignette effect (transparent center, blue edges)
    local gradient = Instance.new("UIGradient")
    gradient.Transparency = NumberSequence.new({
      NumberSequenceKeypoint.new(0, 0),
      NumberSequenceKeypoint.new(0.3, 0.7),
      NumberSequenceKeypoint.new(0.5, 1),
      NumberSequenceKeypoint.new(0.7, 0.7),
      NumberSequenceKeypoint.new(1, 0),
    })
    gradient.Parent = overlay
  end

  ScreenOverlay = overlay :: Frame
  return ScreenOverlay
end

--[[
  Shows/hides the screen-edge water warning overlay.
]]
local function setScreenOverlayVisible(visible: boolean, duration: number?)
  local overlay = getOrCreateScreenOverlay()
  if not overlay then
    return
  end

  if ScreenOverlayTween then
    ScreenOverlayTween:Cancel()
    ScreenOverlayTween = nil
  end

  local targetTransparency = visible and 0.6 or 1
  local tweenDuration = duration or 1

  ScreenOverlayTween =
    TweenService:Create(overlay, TweenInfo.new(tweenDuration, Enum.EasingStyle.Quad), {
      BackgroundTransparency = targetTransparency,
    })
  ScreenOverlayTween:Play()
end

--------------------------------------------------------------------------------
-- PHASE VFX
--------------------------------------------------------------------------------

--[[
  Creates warning phase VFX: ocean rises, roaring buildup SFX, screen-edge water.
]]
local function createWarningVFX(zonePart: BasePart, vfx: any)
  local water = getOrCreateWaterWall(zonePart)
  vfx.waterPart = water

  -- Tween water to slowly rise — the ocean is building
  TweenService:Create(water, TweenInfo.new(4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
    Transparency = 0.5,
    Color = WARNING_COLOR,
    Size = Vector3.new(zonePart.Size.X, 8, zonePart.Size.Z),
    CFrame = zonePart.CFrame * CFrame.new(0, 3, 0),
  }):Play()

  -- Roaring wave buildup SFX (louder and more dramatic than tidal surge)
  local sound = Instance.new("Sound")
  sound.Name = "WaveWarning"
  sound.SoundId = "rbxassetid://9116222901" -- deep rumble / rushing water
  sound.Volume = 0
  sound.Looped = true
  sound.RollOffMinDistance = 20
  sound.RollOffMaxDistance = SFX_RANGE
  sound.PlaybackSpeed = 0.8 -- deeper, more ominous
  sound.Parent = zonePart
  sound:Play()
  vfx.warningSound = sound

  -- Fade volume up to louder than tidal surge
  TweenService:Create(sound, TweenInfo.new(5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
    Volume = 0.8,
    PlaybackSpeed = 1.2, -- pitch rises as wave approaches
  }):Play()

  -- Screen-edge water VFX if player is nearby
  local character = LocalPlayer.Character
  if character then
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
      local dist = (hrp.Position - zonePart.Position).Magnitude
      if dist < SFX_RANGE then
        setScreenOverlayVisible(true, 4)
      end
    end
  end
end

--[[
  Creates impact phase VFX: massive wave crash, splash particles, glow.
]]
local function createImpactVFX(zonePart: BasePart, vfx: any)
  local water = getOrCreateWaterWall(zonePart)
  vfx.waterPart = water

  -- Wave crashes down — water plane goes tall then flattens
  TweenService
    :Create(water, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
      Transparency = 0.2,
      Color = IMPACT_COLOR,
      Size = Vector3.new(zonePart.Size.X, 3, zonePart.Size.Z),
      CFrame = zonePart.CFrame * CFrame.new(0, zonePart.Size.Y / 2 + 1.5, 0),
    })
    :Play()

  -- Massive spray particles
  local spray = Instance.new("ParticleEmitter")
  spray.Name = "WaveSpray"
  spray.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, FOAM_COLOR),
    ColorSequenceKeypoint.new(0.5, WAVE_COLOR),
    ColorSequenceKeypoint.new(1, FOAM_COLOR),
  })
  spray.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 2),
    NumberSequenceKeypoint.new(0.3, 5),
    NumberSequenceKeypoint.new(1, 2),
  })
  spray.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.1),
    NumberSequenceKeypoint.new(0.4, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  spray.Lifetime = NumberRange.new(1, 3)
  spray.Rate = 50
  spray.Speed = NumberRange.new(10, 30)
  spray.SpreadAngle = Vector2.new(80, 80)
  spray.RotSpeed = NumberRange.new(-90, 90)
  spray.Rotation = NumberRange.new(0, 360)
  spray.Parent = water
  vfx.sprayEmitter = spray

  -- Foam particles
  local foam = Instance.new("ParticleEmitter")
  foam.Name = "WaveFoam"
  foam.Color = ColorSequence.new(FOAM_COLOR)
  foam.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1),
    NumberSequenceKeypoint.new(0.5, 4),
    NumberSequenceKeypoint.new(1, 1),
  })
  foam.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.5, 0.5),
    NumberSequenceKeypoint.new(1, 1),
  })
  foam.Lifetime = NumberRange.new(0.5, 2)
  foam.Rate = 40
  foam.Speed = NumberRange.new(5, 15)
  foam.SpreadAngle = Vector2.new(60, 60)
  foam.Parent = water
  vfx.foamEmitter = foam

  -- Impact glow
  local light = Instance.new("PointLight")
  light.Name = "WaveGlow"
  light.Color = WAVE_COLOR
  light.Brightness = 2
  light.Range = 40
  light.Parent = water
  vfx.waterLight = light

  -- Wave crash sound
  local sound = Instance.new("Sound")
  sound.Name = "WaveImpact"
  sound.SoundId = "rbxassetid://9114227726" -- wave crash
  sound.Volume = 1.0
  sound.Looped = false
  sound.RollOffMinDistance = 25
  sound.RollOffMaxDistance = SFX_RANGE
  sound.PlaybackSpeed = 0.9 -- slightly deeper for rogue wave
  sound.Parent = zonePart
  sound:Play()
  vfx.impactSound = sound

  -- Flash the screen overlay brighter on impact
  setScreenOverlayVisible(true, 0.3)
  task.delay(0.5, function()
    setScreenOverlayVisible(false, 1.5)
  end)
end

--[[
  Creates recede phase VFX: water retreats, fades out.
]]
local function createRecedeVFX(zonePart: BasePart, vfx: any)
  local water = vfx.waterPart
  if not water then
    water = getOrCreateWaterWall(zonePart)
    vfx.waterPart = water
  end

  -- Tween water back down and fade out
  local baseCF = zonePart.CFrame * CFrame.new(0, -zonePart.Size.Y / 2, 0)
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
  if vfx.impactSound then
    vfx.impactSound:Stop()
    vfx.impactSound:Destroy()
    vfx.impactSound = nil
  end
  if vfx.foamEmitter then
    vfx.foamEmitter:Destroy()
    vfx.foamEmitter = nil
  end
  if vfx.sprayEmitter then
    vfx.sprayEmitter:Destroy()
    vfx.sprayEmitter = nil
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
    -- Idle: no special VFX, ensure water wall is invisible
    local water = part:FindFirstChild("RogueWaveWall")
    if water then
      water.Transparency = 1
    end
    -- Hide screen overlay
    setScreenOverlayVisible(false, 1)
  elseif phase == "warning" then
    createWarningVFX(part, vfx)
  elseif phase == "impact" then
    createImpactVFX(part, vfx)
  elseif phase == "recede" then
    createRecedeVFX(part, vfx)
  end
end

--------------------------------------------------------------------------------
-- WAVE HIT HANDLING
--------------------------------------------------------------------------------

--[[
  Called when the local player is hit by a rogue wave.
  Applies ragdoll with strong inland push velocity.
]]
local function onWaveHit(pushVelocity: Vector3, ragdollDuration: number)
  -- Show notification
  if NotificationController then
    NotificationController:ShowNotification("ROGUE WAVE!", WAVE_COLOR, 4)
  end

  -- Cancel any pending wave cleanup
  if WaveCleanupThread then
    task.cancel(WaveCleanupThread)
    WaveCleanupThread = nil
  end

  IsWaveRagdolled = true

  local character = LocalPlayer.Character
  if character then
    RagdollModule.enable(character, pushVelocity)

    -- Schedule ragdoll cleanup
    WaveCleanupThread = task.delay(ragdollDuration, function()
      WaveCleanupThread = nil
      IsWaveRagdolled = false
      if character and character.Parent then
        RagdollModule.disable(character)
      end
    end)
  end
end

--[[
  Called when bonus containers wash ashore after a wave.
]]
local function onBonusContainersWashedAshore(zoneId: string, containerPositions: { Vector3 })
  -- Only notify if player is nearby
  local character = LocalPlayer.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  -- Check distance to any container position
  local nearestDist = math.huge
  for _, pos in containerPositions do
    local dist = (hrp.Position - pos).Magnitude
    if dist < nearestDist then
      nearestDist = dist
    end
  end

  if nearestDist < 120 then
    if NotificationController then
      NotificationController:ShowNotification(
        "The wave washed treasure ashore!",
        Color3.fromRGB(255, 200, 50),
        5
      )
    end
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function RogueWaveController:KnitInit()
  print("[RogueWaveController] Initialized")
end

function RogueWaveController:KnitStart()
  RogueWaveService = Knit.GetService("RogueWaveService")
  NotificationController = Knit.GetController("NotificationController")

  -- Listen for wave phase changes from server
  RogueWaveService.WavePhaseChanged:Connect(
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

  -- Listen for wave hit on local player
  RogueWaveService.WaveHit:Connect(onWaveHit)

  -- Listen for bonus containers washed ashore
  RogueWaveService.BonusContainersWashedAshore:Connect(onBonusContainersWashedAshore)

  -- Late-join sync: get current zone states
  RogueWaveService:GetZoneStates()
    :andThen(function(states)
      for _, state in states do
        applyPhaseVFX(state.id, state.phase, state.position, state.size, state.inlandDirection)
      end
    end)
    :catch(function(err)
      warn("[RogueWaveController] Failed to sync zone states:", err)
    end)

  -- Clean up ragdoll state on character removal
  LocalPlayer.CharacterRemoving:Connect(function(character: Model)
    if IsWaveRagdolled then
      RagdollModule.cleanup(character)
      IsWaveRagdolled = false
    end
    if WaveCleanupThread then
      task.cancel(WaveCleanupThread)
      WaveCleanupThread = nil
    end
  end)

  print("[RogueWaveController] Started")
end

return RogueWaveController
