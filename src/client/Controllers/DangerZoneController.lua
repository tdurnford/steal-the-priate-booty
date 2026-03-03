--[[
  DangerZoneController.lua
  Client-side controller for danger zone enter/exit feedback.

  Handles:
    - Listening for DangerZoneChanged signal from DangerZoneService
    - Showing warning notifications on enter/exit
    - Late-join sync via session snapshot

  Depends on: DangerZoneService (server signal), SessionStateService (snapshot),
              NotificationController, SoundController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))

local DangerZoneController = Knit.CreateController({
  Name = "DangerZoneController",
})

-- Lazy-loaded references (set in KnitStart)
local SessionStateService = nil
local NotificationController = nil
local SoundController = nil
local DangerZoneService = nil

-- Colors for notifications
local DANGER_ENTER_COLOR = Color3.fromRGB(255, 80, 80) -- red
local DANGER_EXIT_COLOR = Color3.fromRGB(255, 220, 100) -- gold/yellow

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DangerZoneController:KnitInit()
  print("[DangerZoneController] Initialized")
end

function DangerZoneController:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DangerZoneService = Knit.GetService("DangerZoneService")
  NotificationController = Knit.GetController("NotificationController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for danger zone changes via the dedicated signal
  DangerZoneService.DangerZoneChanged:Connect(function(inDangerZone: boolean, zoneName: string?)
    if inDangerZone then
      local displayName = zoneName or "Danger Zone"
      if NotificationController then
        NotificationController:ShowNotification(
          "Entering " .. displayName .. " — Threat rising!",
          DANGER_ENTER_COLOR,
          4
        )
      end
    else
      if NotificationController then
        NotificationController:ShowNotification("Leaving Danger Zone", DANGER_EXIT_COLOR, 3)
      end
    end
  end)

  -- Late-join sync: check if already in a danger zone
  SessionStateService:GetSessionSnapshot()
    :andThen(function(snapshot)
      if snapshot and snapshot.inDangerZone then
        local displayName = snapshot.dangerZoneName or "Danger Zone"
        if NotificationController then
          NotificationController:ShowNotification(
            "You are in " .. displayName .. " — Threat rising!",
            DANGER_ENTER_COLOR,
            4
          )
        end
      end
    end)
    :catch(function(_err)
      -- Silently ignore — snapshot may not be ready yet
    end)

  print("[DangerZoneController] Started")
end

return DangerZoneController
