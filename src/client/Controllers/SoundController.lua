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
  hitPlayer = "rbxassetid://3932505093", -- impact on player hit
  hitContainer = "rbxassetid://3084680507", -- impact on container hit
  swingMiss = "rbxassetid://12222130", -- miss / air swoosh
}

-- Volume settings per sound type
local VOLUMES = {
  purchase = 0.5,
  purchaseFail = 0.4,
  buttonClick = 0.3,
  duskHorn = 0.6,
  dawnBell = 0.5,
  swingSwoosh = 0.5,
  hitPlayer = 0.6,
  hitContainer = 0.6,
  swingMiss = 0.3,
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
	Plays the swing swoosh sound (on every attack).
]]
function SoundController:PlaySwingSound()
  play2DSound(SOUNDS.swingSwoosh, VOLUMES.swingSwoosh)
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
