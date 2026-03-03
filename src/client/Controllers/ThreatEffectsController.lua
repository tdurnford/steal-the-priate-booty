--[[
  ThreatEffectsController.lua
  Client-side threat tier visual/audio effects (THREAT-003 / THREAT-004).

  Listens to ThreatEffectsService.ThreatTierChanged for tier transitions.
  Effects:
    - Uneasy (20-39): Faint eerie ambient audio loop (client-only)
    - Hunted (40-59): Screen-edge fog vignette overlay + eerie audio
    - Cursed (60-79): Enhanced vignette (green tint), louder eerie audio,
      trap container explosion VFX on self
    - Doomed (80-100): Intense dark vignette (purple tint), loudest eerie audio,
      screen shake on trap

  Server handles replicated effects (footprints, dark aura particles).
  All effects clean up on tier downgrade or player death/respawn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local ThreatEffectsController = Knit.CreateController({
  Name = "ThreatEffectsController",
})

-- References
local LocalPlayer = Players.LocalPlayer
local ThreatEffectsService = nil
local NotificationController = nil
local SoundController = nil

-- Tier order for comparison
local TIER_ORDER = {
  calm = 1,
  uneasy = 2,
  hunted = 3,
  cursed = 4,
  doomed = 5,
}

-- Current state
local CurrentTierId = "calm"

-- Eerie ambient sound
local EerieSound: Sound? = nil
local EERIE_SOUND_ID = "rbxassetid://9114046944" -- low droning foghorn (reused, lower vol)
local EERIE_VOLUME_UNEASY = 0.08 -- barely audible
local EERIE_VOLUME_HUNTED = 0.15 -- more noticeable
local EERIE_VOLUME_CURSED = 0.25 -- unsettling
local EERIE_VOLUME_DOOMED = 0.35 -- ominous

-- Fog vignette overlay
local VignetteGui: ScreenGui? = nil
local VignetteFrame: Frame? = nil
local VignetteTween: Tween? = nil

-- Trap explosion screen flash
local TrapFlashGui: ScreenGui? = nil
local TrapFlashFrame: Frame? = nil

-- Tier transition notification colors
local TIER_COLORS = {
  calm = Color3.fromRGB(100, 200, 100), -- green
  uneasy = Color3.fromRGB(255, 200, 50), -- yellow
  hunted = Color3.fromRGB(255, 140, 50), -- orange
  cursed = Color3.fromRGB(255, 60, 60), -- red
  doomed = Color3.fromRGB(180, 80, 255), -- purple
}

local TIER_MESSAGES = {
  uneasy = "The island senses your presence...",
  hunted = "You are being hunted!",
  cursed = "A curse follows your every step!",
  doomed = "DOOM approaches! The Captain stirs...",
  calm = "The threat has passed.",
}

-- Vignette settings per tier
local VIGNETTE_SETTINGS = {
  hunted = {
    color = Color3.fromRGB(0, 0, 0),
    transparency = 0.55,
    pulseTarget = 0.7,
  },
  cursed = {
    color = Color3.fromRGB(20, 50, 10), -- greenish-dark
    transparency = 0.45,
    pulseTarget = 0.6,
  },
  doomed = {
    color = Color3.fromRGB(40, 10, 60), -- dark purple
    transparency = 0.35,
    pulseTarget = 0.5,
  },
}

--------------------------------------------------------------------------------
-- EERIE AMBIENT AUDIO
--------------------------------------------------------------------------------

--[[
  Starts or adjusts the eerie ambient audio loop.
  @param volume Target volume (based on tier)
]]
local function startEerieAudio(volume: number)
  if not EerieSound then
    EerieSound = Instance.new("Sound")
    EerieSound.Name = "ThreatEerieAmbient"
    EerieSound.SoundId = EERIE_SOUND_ID
    EerieSound.Volume = 0
    EerieSound.Looped = true
    EerieSound.Parent = SoundService
  end

  if not EerieSound.IsPlaying then
    EerieSound:Play()
  end

  -- Fade volume to target
  TweenService:Create(
    EerieSound,
    TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
    { Volume = volume }
  ):Play()
end

--[[
  Stops the eerie ambient audio with a fade-out.
]]
local function stopEerieAudio()
  if not EerieSound or not EerieSound.IsPlaying then
    return
  end

  local sound = EerieSound
  local fadeOut = TweenService:Create(
    sound,
    TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
    { Volume = 0 }
  )
  fadeOut:Play()
  fadeOut.Completed:Connect(function()
    if sound.Volume <= 0.01 then
      sound:Stop()
    end
  end)
end

--------------------------------------------------------------------------------
-- FOG VIGNETTE OVERLAY
--------------------------------------------------------------------------------

--[[
  Creates the vignette ScreenGui and Frame if not already created.
]]
local function ensureVignetteGui()
  if VignetteGui then
    return
  end

  VignetteGui = Instance.new("ScreenGui")
  VignetteGui.Name = "ThreatVignetteGui"
  VignetteGui.ResetOnSpawn = false
  VignetteGui.DisplayOrder = 90 -- above most HUD, below notifications
  VignetteGui.IgnoreGuiInset = true
  VignetteGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  -- Fullscreen frame with radial gradient (dark edges, transparent center)
  VignetteFrame = Instance.new("Frame")
  VignetteFrame.Name = "Vignette"
  VignetteFrame.Size = UDim2.new(1, 0, 1, 0)
  VignetteFrame.Position = UDim2.new(0, 0, 0, 0)
  VignetteFrame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
  VignetteFrame.BackgroundTransparency = 1 -- start fully transparent
  VignetteFrame.BorderSizePixel = 0
  VignetteFrame.ZIndex = 1

  -- UIGradient for radial vignette effect (dark edges, clear center)
  local gradient = Instance.new("UIGradient")
  gradient.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1), -- center: fully transparent
    NumberSequenceKeypoint.new(0.5, 0.9), -- mid: mostly transparent
    NumberSequenceKeypoint.new(0.8, 0.4), -- near edge: semi-visible
    NumberSequenceKeypoint.new(1, 0), -- edge: fully visible
  })
  gradient.Parent = VignetteFrame

  VignetteFrame.Parent = VignetteGui
end

--[[
  Shows the fog vignette with a fade-in. Pulses opacity for an unsettling feel.
  @param settings Vignette color, transparency, and pulse target for the tier
]]
local function showVignette(settings: { color: Color3, transparency: number, pulseTarget: number })
  ensureVignetteGui()
  if not VignetteFrame then
    return
  end

  -- Cancel existing pulse
  if VignetteTween then
    VignetteTween:Cancel()
    VignetteTween = nil
  end

  -- Set color for the tier
  VignetteFrame.BackgroundColor3 = settings.color

  -- Fade in
  TweenService:Create(
    VignetteFrame,
    TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
    { BackgroundTransparency = settings.transparency }
  ):Play()

  -- Start pulsing effect
  local pulseTarget = settings.pulseTarget
  task.delay(1.5, function()
    if not VignetteFrame or not VignetteFrame.Parent then
      return
    end
    VignetteTween = TweenService:Create(
      VignetteFrame,
      TweenInfo.new(3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
      { BackgroundTransparency = pulseTarget }
    )
    VignetteTween:Play()
  end)
end

--[[
  Hides the fog vignette with a fade-out.
]]
local function hideVignette()
  if not VignetteFrame then
    return
  end

  if VignetteTween then
    VignetteTween:Cancel()
    VignetteTween = nil
  end

  local fadeOut = TweenService:Create(
    VignetteFrame,
    TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
    { BackgroundTransparency = 1 }
  )
  fadeOut:Play()
end

--------------------------------------------------------------------------------
-- TRAP CONTAINER EXPLOSION VFX
--------------------------------------------------------------------------------

--[[
  Creates the trap flash ScreenGui if not already created.
]]
local function ensureTrapFlashGui()
  if TrapFlashGui then
    return
  end

  TrapFlashGui = Instance.new("ScreenGui")
  TrapFlashGui.Name = "TrapFlashGui"
  TrapFlashGui.ResetOnSpawn = false
  TrapFlashGui.DisplayOrder = 95 -- above vignette
  TrapFlashGui.IgnoreGuiInset = true
  TrapFlashGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  TrapFlashFrame = Instance.new("Frame")
  TrapFlashFrame.Name = "Flash"
  TrapFlashFrame.Size = UDim2.new(1, 0, 1, 0)
  TrapFlashFrame.BackgroundColor3 = Color3.fromRGB(255, 100, 30) -- orange-red explosion
  TrapFlashFrame.BackgroundTransparency = 1
  TrapFlashFrame.BorderSizePixel = 0
  TrapFlashFrame.Parent = TrapFlashGui
end

--[[
  Plays the trap container explosion VFX: screen flash + camera shake.
  @param position The world position of the explosion
]]
local function playTrapExplosionVFX(_containerId: string, _position: Vector3)
  ensureTrapFlashGui()
  if not TrapFlashFrame then
    return
  end

  -- Screen flash: orange-red → fade out
  TrapFlashFrame.BackgroundTransparency = 0.3
  TweenService:Create(
    TrapFlashFrame,
    TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
    { BackgroundTransparency = 1 }
  ):Play()

  -- Camera shake
  local camera = workspace.CurrentCamera
  if camera then
    task.spawn(function()
      local shakeDuration = 0.4
      local shakeIntensity = 1.5
      local startTime = os.clock()
      while os.clock() - startTime < shakeDuration do
        local elapsed = os.clock() - startTime
        local factor = 1 - (elapsed / shakeDuration) -- diminishing intensity
        local offsetX = (math.random() - 0.5) * shakeIntensity * factor
        local offsetY = (math.random() - 0.5) * shakeIntensity * factor
        camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0)
        task.wait()
      end
    end)
  end

  -- Show notification
  if NotificationController then
    NotificationController:ShowNotification(
      "TRAP! The container was cursed!",
      Color3.fromRGB(255, 80, 30),
      3
    )
  end
end

--------------------------------------------------------------------------------
-- TIER TRANSITION HANDLER
--------------------------------------------------------------------------------

--[[
  Called when the player's threat tier changes.
  Activates/deactivates appropriate effects.
  @param tierId The new tier ID
  @param tierName The new tier display name
  @param isUpward Whether the transition was upward
]]
local function onThreatTierChanged(tierId: string, tierName: string, isUpward: boolean)
  local oldTierId = CurrentTierId
  CurrentTierId = tierId
  local tierOrder = TIER_ORDER[tierId] or 1

  -- Show notification on tier change
  local message = TIER_MESSAGES[tierId]
  local color = TIER_COLORS[tierId]
  if message and NotificationController then
    NotificationController:ShowNotification(message, color, 4)
  end

  -- Eerie audio: Uneasy+ only, volume escalates per tier
  if tierOrder >= TIER_ORDER.doomed then
    startEerieAudio(EERIE_VOLUME_DOOMED)
  elseif tierOrder >= TIER_ORDER.cursed then
    startEerieAudio(EERIE_VOLUME_CURSED)
  elseif tierOrder >= TIER_ORDER.hunted then
    startEerieAudio(EERIE_VOLUME_HUNTED)
  elseif tierOrder >= TIER_ORDER.uneasy then
    startEerieAudio(EERIE_VOLUME_UNEASY)
  else
    stopEerieAudio()
  end

  -- Fog vignette: Hunted+ only, with tier-specific settings
  if tierOrder >= TIER_ORDER.doomed then
    showVignette(VIGNETTE_SETTINGS.doomed)
  elseif tierOrder >= TIER_ORDER.cursed then
    showVignette(VIGNETTE_SETTINGS.cursed)
  elseif tierOrder >= TIER_ORDER.hunted then
    showVignette(VIGNETTE_SETTINGS.hunted)
  else
    hideVignette()
  end
end

--------------------------------------------------------------------------------
-- CLEANUP ON RESPAWN
--------------------------------------------------------------------------------

local function onCharacterAdded(character: Model)
  -- Don't clear effects on respawn — threat persists across deaths
  -- But we should sync current tier from server in case of any desync
  if ThreatEffectsService then
    task.delay(1, function()
      local tierId, tierName = ThreatEffectsService:GetThreatTier()
      if tierId ~= CurrentTierId then
        onThreatTierChanged(tierId, tierName, TIER_ORDER[tierId] > TIER_ORDER[CurrentTierId])
      end
    end)
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ThreatEffectsController:KnitInit()
  print("[ThreatEffectsController] Initialized")
end

function ThreatEffectsController:KnitStart()
  ThreatEffectsService = Knit.GetService("ThreatEffectsService")
  NotificationController = Knit.GetController("NotificationController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for tier changes from server
  ThreatEffectsService.ThreatTierChanged:Connect(
    function(tierId: string, tierName: string, isUpward: boolean)
      onThreatTierChanged(tierId, tierName, isUpward)
    end
  )

  -- Listen for trap container explosions (Cursed+ tier)
  ThreatEffectsService.TrapContainerExploded:Connect(
    function(containerId: string, position: Vector3)
      playTrapExplosionVFX(containerId, position)
    end
  )

  -- Sync initial tier on join
  task.spawn(function()
    local tierId, tierName = ThreatEffectsService:GetThreatTier()
    if tierId and tierId ~= "calm" then
      onThreatTierChanged(tierId, tierName, true)
    end
    CurrentTierId = tierId or "calm"
  end)

  -- Re-sync on character respawn
  LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

  print("[ThreatEffectsController] Started — listening for threat tier changes (tiers 1-5)")
end

return ThreatEffectsController
