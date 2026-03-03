--[[
  BountyController.lua
  Client-side controller for the bounty system (EVENT-001).

  Responsibilities:
    - Listens for BountyStarted/BountyEnded signals from BountyService
    - Tracks the active bounty target on the client
    - Shows "BOUNTY ON YOU!" warning to the bounty target
    - Shows "BOUNTY PLACED ON [name]" notification to other players
    - Exposes bounty state for other controllers (HudController, future minimap)
    - Fires local signals for UI components to react to
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))

local BountyController = Knit.CreateController({
  Name = "BountyController",
})

-- Local signals for UI components
BountyController.BountyStarted = Signal.new() -- (targetUserId: number, targetName: string, isLocalPlayer: boolean)
BountyController.BountyEnded = Signal.new() -- (targetUserId: number, reason: string, wasLocalPlayer: boolean)

-- References (set in KnitStart)
local BountyService = nil
local NotificationController = nil
local SoundController = nil
local BannerQueueController = nil

-- Local player
local LocalPlayer = Players.LocalPlayer

-- Current bounty state
local ActiveBountyUserId: number = 0
local ActiveBountyName: string = ""
local IsLocalPlayerBounty: boolean = false

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns whether a bounty is currently active.
]]
function BountyController:IsBountyActive(): boolean
  return ActiveBountyUserId ~= 0
end

--[[
  Returns the UserId of the current bounty target, or 0 if none.
]]
function BountyController:GetBountyTargetUserId(): number
  return ActiveBountyUserId
end

--[[
  Returns the display name of the current bounty target.
]]
function BountyController:GetBountyTargetName(): string
  return ActiveBountyName
end

--[[
  Returns whether the local player is the bounty target.
]]
function BountyController:IsLocalPlayerBounty(): boolean
  return IsLocalPlayerBounty
end

--------------------------------------------------------------------------------
-- INTERNAL HANDLERS
--------------------------------------------------------------------------------

--[[
  Handles a new bounty being assigned.
  @param targetUserId The UserId of the bounty target
  @param targetDisplayName The display name of the bounty target
]]
local function onBountyStarted(targetUserId: number, targetDisplayName: string)
  ActiveBountyUserId = targetUserId
  ActiveBountyName = targetDisplayName
  IsLocalPlayerBounty = (targetUserId == LocalPlayer.UserId)

  -- Fire local signal for UI components
  BountyController.BountyStarted:Fire(targetUserId, targetDisplayName, IsLocalPlayerBounty)

  -- Show top-center banner announcement for all players
  if BannerQueueController then
    if IsLocalPlayerBounty then
      BannerQueueController:ShowBanner({
        text = "\u{1F480} BOUNTY ON YOU!",
        subtitle = "Other pirates can see your location!",
        color = Color3.fromRGB(255, 50, 50),
        glowColor = Color3.fromRGB(180, 20, 20),
        duration = 5,
      })
    else
      BannerQueueController:ShowBanner({
        text = "\u{1F480} BOUNTY PLACED!",
        subtitle = targetDisplayName .. " has a bounty on their head!",
        color = Color3.fromRGB(255, 170, 50),
        glowColor = Color3.fromRGB(200, 120, 20),
        duration = 4,
      })
    end
  end

  -- Show toast notification as well
  if IsLocalPlayerBounty then
    if NotificationController then
      NotificationController:ShowNotification(
        "\u{1F480} BOUNTY ON YOU! Other pirates can see you!",
        Color3.fromRGB(255, 50, 50),
        6
      )
    end
    -- Play warning sound
    if SoundController then
      SoundController:PlayUISound("bounty_warning")
    end
  else
    if NotificationController then
      NotificationController:ShowNotification(
        "\u{1F480} Bounty placed on " .. targetDisplayName .. "!",
        Color3.fromRGB(255, 170, 50),
        4
      )
    end
  end

  print(
    "[BountyController] Bounty started on",
    targetDisplayName,
    "- isLocal:",
    IsLocalPlayerBounty
  )
end

--[[
  Handles a bounty being cleared.
  @param targetUserId The UserId of the bounty target that was cleared
  @param reason Why the bounty was cleared
]]
local function onBountyEnded(targetUserId: number, reason: string)
  local wasLocal = (targetUserId == LocalPlayer.UserId)

  -- Clear state
  ActiveBountyUserId = 0
  ActiveBountyName = ""
  IsLocalPlayerBounty = false

  -- Fire local signal for UI components
  BountyController.BountyEnded:Fire(targetUserId, reason, wasLocal)

  -- Show notification
  if wasLocal then
    local reasonText = "Bounty cleared!"
    if reason == "timeout" then
      reasonText = "Bounty expired! You survived!"
    elseif reason == "loot_dropped" then
      reasonText = "Bounty cleared — loot dropped below threshold."
    elseif reason == "deposit" then
      reasonText = "Bounty cleared — loot deposited."
    end

    if NotificationController then
      NotificationController:ShowNotification(
        "\u{2705} " .. reasonText,
        Color3.fromRGB(100, 255, 100),
        4
      )
    end
  else
    local reasonText = "Bounty ended."
    if reason == "timeout" then
      reasonText = "Bounty expired."
    elseif reason == "disconnect" then
      reasonText = "Bounty target disconnected."
    end

    if NotificationController then
      NotificationController:ShowNotification(reasonText, Color3.fromRGB(180, 180, 180), 3)
    end
  end

  print("[BountyController] Bounty ended - reason:", reason, "wasLocal:", wasLocal)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function BountyController:KnitInit()
  print("[BountyController] Initialized")
end

function BountyController:KnitStart()
  BountyService = Knit.GetService("BountyService")
  NotificationController = Knit.GetController("NotificationController")
  BannerQueueController = Knit.GetController("BannerQueueController")

  -- SoundController may not have bounty sounds yet; safe to try
  local ok, sound = pcall(function()
    return Knit.GetController("SoundController")
  end)
  if ok then
    SoundController = sound
  end

  -- Listen for bounty signals from server
  BountyService.BountyStarted:Connect(function(targetUserId: number, targetDisplayName: string)
    onBountyStarted(targetUserId, targetDisplayName)
  end)

  BountyService.BountyEnded:Connect(function(targetUserId: number, reason: string)
    onBountyEnded(targetUserId, reason)
  end)

  -- Check if a bounty is already active (late join)
  BountyService:GetBountyTargetUserId()
    :andThen(function(userId: number)
      if userId ~= 0 then
        -- Find the player's display name
        local targetPlayer = Players:GetPlayerByUserId(userId)
        local displayName = if targetPlayer then targetPlayer.DisplayName else "Unknown"
        onBountyStarted(userId, displayName)
      end
    end)
    :catch(function(err)
      warn("[BountyController] Failed to get initial bounty state:", err)
    end)

  print("[BountyController] Started")
end

return BountyController
