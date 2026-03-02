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
}

-- Volume settings per sound type
local VOLUMES = {
  purchase = 0.5,
  purchaseFail = 0.4,
  buttonClick = 0.3,
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
