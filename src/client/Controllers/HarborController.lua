--[[
  HarborController.lua
  Client-side controller for Harbor safe zone feedback.

  Handles:
    - Listening for harbor entry/exit via SessionStateChanged signal
    - Showing "Safe Zone" / "Leaving Safe Zone" notifications
    - Playing ambient SFX on entry/exit

  Depends on: SessionStateService (client), NotificationController, SoundController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))

local HarborController = Knit.CreateController({
  Name = "HarborController",
})

-- Lazy-loaded references (set in KnitStart)
local SessionStateService = nil
local NotificationController = nil
local SoundController = nil
local HarborService = nil

-- Colors for notifications
local SAFE_ZONE_COLOR = Color3.fromRGB(100, 220, 140) -- green
local LEAVING_COLOR = Color3.fromRGB(255, 180, 80) -- warm orange

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function HarborController:KnitInit()
  print("[HarborController] Initialized")
end

function HarborController:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  HarborService = Knit.GetService("HarborService")
  NotificationController = Knit.GetController("NotificationController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for harbor state changes via the dedicated HarborService signal
  HarborService.HarborStateChanged:Connect(function(inHarbor: boolean)
    if inHarbor then
      if NotificationController then
        NotificationController:ShowNotification("Entered Harbor — Safe Zone", SAFE_ZONE_COLOR, 3)
      end
    else
      if NotificationController then
        NotificationController:ShowNotification(
          "Leaving Harbor — Watch your back!",
          LEAVING_COLOR,
          3
        )
      end
    end
  end)

  -- Also fetch initial state in case player loaded inside harbor
  SessionStateService:GetSessionSnapshot()
    :andThen(function(snapshot)
      if snapshot and snapshot.inHarbor then
        if NotificationController then
          NotificationController:ShowNotification(
            "Entered Harbor — Safe Zone",
            SAFE_ZONE_COLOR,
            3
          )
        end
      end
    end)
    :catch(function(_err)
      -- Silently ignore — snapshot may not be ready yet
    end)

  print("[HarborController] Started")
end

return HarborController
