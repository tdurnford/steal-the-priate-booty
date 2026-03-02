--[[
	SoundController.lua
	Client-side controller for managing sound effects.
	Provides generic 2D/3D sound playback and respects the sfxEnabled player setting.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local SoundController = Knit.CreateController({
  Name = "SoundController",
})

-- Sound asset IDs
local SOUNDS = {
  purchase = "rbxassetid://5863456788",
  purchaseFail = "rbxassetid://4590657391",
  buttonClick = "rbxassetid://6895079853",

  -- Day/night phase transition audio cues
  duskHorn = "rbxassetid://9114046944", -- deep foghorn/horn blast for nightfall
  dawnBell = "rbxassetid://9114049951", -- bell chime / rooster crow for dawn

  -- Combat sounds
  swingSwoosh = "rbxassetid://12222084", -- cutlass swing swoosh
  heavyCharge = "rbxassetid://5206020985", -- rising charge-up whoosh
  heavySwing = "rbxassetid://3750598695", -- heavy swing release (bigger swoosh)
  heavyHit = "rbxassetid://4801618977", -- heavy impact on player (loud thud)
  hitPlayer = "rbxassetid://3932505093", -- impact on player hit
  hitContainer = "rbxassetid://3084680507", -- impact on container hit
  swingMiss = "rbxassetid://12222130", -- miss / air swoosh

  -- Container damage escalation sounds (3 tiers)
  containerHitQuiet = "rbxassetid://3084680507", -- light tap (same base, lower vol)
  containerHitMedium = "rbxassetid://3084680507", -- medium crack
  containerHitLoud = "rbxassetid://3084680507", -- loud cracking/splintering

  -- Container break sound
  containerBreak = "rbxassetid://5743416168", -- satisfying explosion/shatter
  containerBreakVault = "rbxassetid://5743416168", -- louder variant for Captain's Vault

  -- Block sounds
  blockRaise = "rbxassetid://3932505093", -- metallic guard raise
  blockImpact = "rbxassetid://4801618977", -- clank/impact on blocked hit

  -- Doubloon pickup
  coinPickup = "rbxassetid://4612373815", -- coin collect chime
}

-- Volume settings per sound type
local VOLUMES = {
  purchase = 0.5,
  purchaseFail = 0.4,
  buttonClick = 0.3,
  duskHorn = 0.6,
  dawnBell = 0.5,
  swingSwoosh = 0.5,
  heavyCharge = 0.4,
  heavySwing = 0.7,
  heavyHit = 0.8,
  hitPlayer = 0.6,
  hitContainer = 0.6,
  swingMiss = 0.3,
  containerHitQuiet = 0.3,
  containerHitMedium = 0.5,
  containerHitLoud = 0.8,
  containerBreak = 0.7,
  containerBreakVault = 1.0,
  blockRaise = 0.3,
  blockImpact = 0.6,
  coinPickup = 0.4,
}

-- References
local LocalPlayer = Players.LocalPlayer
local DataService = nil

-- Cached settings state
local SfxEnabled = true

--[[
	Checks if sound effects are enabled in player settings.
	@return boolean Whether SFX should play
]]
local function isSfxEnabled(): boolean
  return SfxEnabled
end

--[[
	Creates and plays a 2D UI sound (non-positional).
	@param soundId The sound asset ID to play
	@param volume Volume level (0-1)
]]
local function play2DSound(soundId: string, volume: number)
  if not isSfxEnabled() then
    return
  end

  local sound = Instance.new("Sound")
  sound.SoundId = soundId
  sound.Volume = volume
  sound.Parent = SoundService

  sound:Play()

  -- Clean up after playing
  sound.Ended:Once(function()
    sound:Destroy()
  end)
end

--[[
	Creates and plays a 3D positional sound.
	@param soundId The sound asset ID to play
	@param volume Volume level (0-1)
	@param position World position for the sound, or BasePart to parent to
]]
local function play3DSound(soundId: string, volume: number, parent: BasePart)
  if not isSfxEnabled() then
    return
  end

  local sound = Instance.new("Sound")
  sound.SoundId = soundId
  sound.Volume = volume
  sound.RollOffMinDistance = 10
  sound.RollOffMaxDistance = 100
  sound.Parent = parent

  sound:Play()

  -- Clean up after playing
  sound.Ended:Once(function()
    sound:Destroy()
  end)
end

--[[
	Gets the player's HumanoidRootPart for 3D sound positioning.
	@return BasePart? The root part or nil
]]
local function getPlayerRootPart(): BasePart?
  local character = LocalPlayer.Character
  if character then
    return character:FindFirstChild("HumanoidRootPart")
  end
  return nil
end

--[[
	Updates the cached sfxEnabled state from player data.
	@param enabled Whether SFX is enabled
]]
local function updateSfxEnabled(enabled: boolean)
  SfxEnabled = enabled
  print("[SoundController] SFX enabled:", enabled)
end

--[[
	Plays the purchase success sound.
]]
function SoundController:PlayPurchaseSound()
  play2DSound(SOUNDS.purchase, VOLUMES.purchase)
end

--[[
	Plays the purchase fail sound.
]]
function SoundController:PlayPurchaseFailSound()
  play2DSound(SOUNDS.purchaseFail, VOLUMES.purchaseFail)
end

--[[
	Plays a UI button click sound.
]]
function SoundController:PlayButtonClickSound()
  play2DSound(SOUNDS.buttonClick, VOLUMES.buttonClick)
end

--[[
	Plays the block raise sound (when player enters block stance).
]]
function SoundController:PlayBlockRaiseSound()
  play2DSound(SOUNDS.blockRaise, VOLUMES.blockRaise)
end

--[[
	Plays the block impact sound (when a blocked hit connects).
]]
function SoundController:PlayBlockImpactSound()
  play2DSound(SOUNDS.blockImpact, VOLUMES.blockImpact)
end

--[[
	Plays the coin pickup chime sound.
]]
function SoundController:PlayCoinPickupSound()
  play2DSound(SOUNDS.coinPickup, VOLUMES.coinPickup)
end

--[[
	Plays the phase transition sound for a day/night phase.
	Called by DayNightBannerController on Dawn and Dusk transitions.
	@param phase "Dawn" | "Dusk"
]]
function SoundController:PlayPhaseTransitionSound(phase: string)
  if phase == "Dusk" then
    play2DSound(SOUNDS.duskHorn, VOLUMES.duskHorn)
  elseif phase == "Dawn" then
    play2DSound(SOUNDS.dawnBell, VOLUMES.dawnBell)
  end
end

--[[
	Plays the swing swoosh sound (on every light attack).
]]
function SoundController:PlaySwingSound()
  play2DSound(SOUNDS.swingSwoosh, VOLUMES.swingSwoosh)
end

--[[
	Plays the heavy swing charge-up sound (rising whoosh during hold).
]]
function SoundController:PlayHeavyChargeSound()
  play2DSound(SOUNDS.heavyCharge, VOLUMES.heavyCharge)
end

--[[
	Plays the heavy swing release sound (bigger swoosh on release).
]]
function SoundController:PlayHeavySwingSound()
  play2DSound(SOUNDS.heavySwing, VOLUMES.heavySwing)
end

--[[
	Plays the heavy hit impact sound at a 3D position.
	@param parent BasePart to attach the 3D sound to (or nil for 2D)
]]
function SoundController:PlayHeavyHitSound(parent: BasePart?)
  if parent then
    play3DSound(SOUNDS.heavyHit, VOLUMES.heavyHit, parent)
  else
    play2DSound(SOUNDS.heavyHit, VOLUMES.heavyHit)
  end
end

--[[
	Plays a combat hit sound at a 3D position.
	@param hitType "player" | "container" | "miss"
	@param parent BasePart to attach the 3D sound to (or nil for 2D)
]]
function SoundController:PlayCombatHitSound(hitType: string, parent: BasePart?)
  if hitType == "player" then
    if parent then
      play3DSound(SOUNDS.hitPlayer, VOLUMES.hitPlayer, parent)
    else
      play2DSound(SOUNDS.hitPlayer, VOLUMES.hitPlayer)
    end
  elseif hitType == "container" then
    if parent then
      play3DSound(SOUNDS.hitContainer, VOLUMES.hitContainer, parent)
    else
      play2DSound(SOUNDS.hitContainer, VOLUMES.hitContainer)
    end
  elseif hitType == "miss" then
    play2DSound(SOUNDS.swingMiss, VOLUMES.swingMiss)
  end
end

--[[
	Plays an escalating container hit sound based on damage tier.
	Volume increases as the container approaches breaking.
	@param tier "quiet" | "medium" | "loud"
	@param parent BasePart to attach 3D sound to
]]
function SoundController:PlayContainerHitSound(tier: string, parent: BasePart?)
  local soundKey = "containerHitQuiet"
  if tier == "medium" then
    soundKey = "containerHitMedium"
  elseif tier == "loud" then
    soundKey = "containerHitLoud"
  end

  if parent then
    play3DSound(SOUNDS[soundKey], VOLUMES[soundKey], parent)
  else
    play2DSound(SOUNDS[soundKey], VOLUMES[soundKey])
  end
end

--[[
	Plays the container break sound at a 3D position.
	Captain's Vault gets a louder, more distinct break sound.
	@param containerType The container type ID
	@param position World position for the sound
]]
function SoundController:PlayContainerBreakSound(containerType: string, position: Vector3)
  local soundKey = "containerBreak"
  if containerType == "captains_vault" then
    soundKey = "containerBreakVault"
  end

  -- Create a temporary part at the position for 3D audio
  local anchor = Instance.new("Part")
  anchor.Name = "BreakSoundAnchor"
  anchor.Size = Vector3.new(1, 1, 1)
  anchor.Position = position
  anchor.Anchored = true
  anchor.CanCollide = false
  anchor.CanQuery = false
  anchor.CanTouch = false
  anchor.Transparency = 1
  anchor.Parent = workspace

  play3DSound(SOUNDS[soundKey], VOLUMES[soundKey], anchor)

  -- Clean up anchor after sound finishes
  task.delay(3, function()
    if anchor and anchor.Parent then
      anchor:Destroy()
    end
  end)
end

--[[
	Called when Knit initializes.
]]
function SoundController:KnitInit()
  print("[SoundController] Initializing...")
end

--[[
	Called when Knit starts.
]]
function SoundController:KnitStart()
  -- Get service references
  DataService = Knit.GetService("DataService")

  -- Load initial settings
  DataService:GetData()
    :andThen(function(data)
      if data and data.settings then
        updateSfxEnabled(data.settings.sfxEnabled)
      end
    end)
    :catch(function(err)
      warn("[SoundController] Failed to load settings:", err)
    end)

  -- Listen for settings changes
  DataService.DataChanged:Connect(function(key, value)
    if key == "settings" and type(value) == "string" and value == "sfxEnabled" then
      -- Settings changed, reload
      DataService:GetData()
        :andThen(function(data)
          if data and data.settings then
            updateSfxEnabled(data.settings.sfxEnabled)
          end
        end)
        :catch(function() end)
    end
  end)

  print("[SoundController] Started")
end

return SoundController
