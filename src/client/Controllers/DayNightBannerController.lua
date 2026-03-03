--[[
  DayNightBannerController.lua
  Client-side day/night phase transition banners and audio cues.

  On Dusk: queues "Night is falling..." banner + deep horn blast SFX.
  On Dawn: queues "Dawn breaks. The island rests." banner + bell chime SFX.
  Banners are displayed via BannerQueueController for proper queuing
  when multiple events fire close together.

  Depends on: DayNightController, SoundController, BannerQueueController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local DayNightBannerController = Knit.CreateController({
  Name = "DayNightBannerController",
})

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local BANNER_DURATION = GameConfig.DayNight.bannerDuration -- 5 seconds

-- Banner text and colors per phase
local BANNER_CONFIG = {
  Dusk = {
    text = "Night is falling...",
    color = Color3.fromRGB(255, 160, 80), -- warm orange
    glowColor = Color3.fromRGB(200, 100, 40),
  },
  Dawn = {
    text = "Dawn breaks. The island rests.",
    color = Color3.fromRGB(255, 220, 120), -- golden sunrise
    glowColor = Color3.fromRGB(255, 180, 60),
  },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local DayNightController = nil
local SoundController = nil
local BannerQueueController = nil

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Manually trigger a phase banner (useful for testing).
  @param phase "Dawn" | "Dusk"
]]
function DayNightBannerController:ShowBanner(phase: string)
  local config = BANNER_CONFIG[phase]
  if not config or not BannerQueueController then
    return
  end

  BannerQueueController:ShowBanner({
    text = config.text,
    color = config.color,
    glowColor = config.glowColor,
    duration = BANNER_DURATION,
  })
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DayNightBannerController:KnitInit()
  print("[DayNightBannerController] Initialized")
end

function DayNightBannerController:KnitStart()
  DayNightController = Knit.GetController("DayNightController")
  SoundController = Knit.GetController("SoundController")
  BannerQueueController = Knit.GetController("BannerQueueController")

  -- Listen for phase transitions — show banners for Dawn and Dusk only
  DayNightController.PhaseChanged:Connect(function(newPhase: string, _previousPhase: string)
    if BANNER_CONFIG[newPhase] then
      DayNightBannerController:ShowBanner(newPhase)

      -- Play phase transition sound
      if SoundController then
        SoundController:PlayPhaseTransitionSound(newPhase)
      end

      print(string.format("[DayNightBannerController] Queued banner: %s", newPhase))
    end
  end)

  print("[DayNightBannerController] Started")
end

return DayNightBannerController
