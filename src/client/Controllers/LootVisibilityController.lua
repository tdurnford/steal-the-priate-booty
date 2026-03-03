--[[
  LootVisibilityController.lua
  Client-side loot visibility tier change handler (LOOT-006).

  Listens to LootVisibilityService.TierChanged for tier transitions.
  Shows notifications and plays SFX when the local player's tier changes.
  Warning messages escalate with tier to signal increasing risk.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local LootVisibilityController = Knit.CreateController({
  Name = "LootVisibilityController",
})

-- Service/controller references (set in KnitStart)
local LootVisibilityService = nil
local NotificationController = nil
local SoundController = nil

-- Tier notification messages (shown when tier increases)
local TIER_UP_MESSAGES = {
  small = "A small purse hangs at your belt...",
  medium = "Your gold shimmer draws attention!",
  large = "Your overflowing riches attract every pirate nearby!",
}

-- Tier notification colors
local TIER_COLORS = {
  small = Color3.fromRGB(200, 170, 120), -- muted gold
  medium = Color3.fromRGB(255, 200, 50), -- bright gold
  large = Color3.fromRGB(255, 100, 50), -- warning orange-gold
}

-- Tier down message (when tier decreases but still > none)
local TIER_DOWN_MESSAGE = "Your loot burden lightens."
local TIER_DOWN_COLOR = Color3.fromRGB(150, 200, 150) -- soft green

-- Tier order for comparison
local TIER_ORDER = {
  none = 0,
  small = 1,
  medium = 2,
  large = 3,
}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Handles tier change for the local player.
  Shows appropriate notification and plays SFX.
]]
local function onTierChanged(newTier: string, oldTier: string, _doubloons: number)
  local newOrder = TIER_ORDER[newTier] or 0
  local oldOrder = TIER_ORDER[oldTier] or 0

  if newOrder > oldOrder then
    -- Tier increased: show warning
    local message = TIER_UP_MESSAGES[newTier]
    local color = TIER_COLORS[newTier]
    if message and NotificationController then
      NotificationController:ShowNotification(message, color, 4)
    end
    -- Play an escalating coin sound
    if SoundController then
      SoundController:PlaySound("coinPickup")
    end
  elseif newOrder < oldOrder and newOrder > 0 then
    -- Tier decreased but still visible: show relief message
    if NotificationController then
      NotificationController:ShowNotification(TIER_DOWN_MESSAGE, TIER_DOWN_COLOR, 3)
    end
  end
  -- Tier going to "none" from any: no notification (feels natural)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function LootVisibilityController:KnitInit()
  print("[LootVisibilityController] Initialized")
end

function LootVisibilityController:KnitStart()
  LootVisibilityService = Knit.GetService("LootVisibilityService")
  NotificationController = Knit.GetController("NotificationController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for tier changes from the server
  LootVisibilityService.TierChanged:Connect(onTierChanged)

  print("[LootVisibilityController] Started")
end

return LootVisibilityController
