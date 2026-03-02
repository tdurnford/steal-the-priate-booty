--[[
  HudController.lua
  Client-side Knit controller that manages the main gameplay HUD.
  Currently displays the held doubloons counter (UI-001).
  Future HUD elements (ship hold, threat, day/night, minimap) will be added here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local HudDoubloonsCounter =
  require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("HudDoubloonsCounter"))

local HudController = Knit.CreateController({
  Name = "HudController",
})

-- References (set in KnitStart)
local SessionStateService = nil
local DoubloonService = nil
local SoundController = nil

-- Fusion state
local FusionScope = nil
local HeldDoubloons = nil -- Fusion.Value<number>

-- UI references
local ScreenGui = nil
local PulseFn = nil -- function to trigger pulse animation

-- Local player
local LocalPlayer = Players.LocalPlayer

--[[
  Creates the HUD ScreenGui and mounts all HUD components.
]]
local function createHud()
  FusionScope = Fusion.scoped(Fusion)
  HeldDoubloons = FusionScope:Value(0)

  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "HudGui"
  ScreenGui.DisplayOrder = 10
  ScreenGui.ResetOnSpawn = false
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  -- Create the doubloons counter
  local counter, triggerPulse = HudDoubloonsCounter.create(FusionScope, HeldDoubloons)
  counter.Parent = ScreenGui
  PulseFn = triggerPulse
end

--[[
  Updates the held doubloons display value and triggers pulse animation.
  @param newValue The new held doubloons count
]]
local function updateDoubloons(newValue: number)
  if HeldDoubloons then
    local oldValue = Fusion.peek(HeldDoubloons)
    HeldDoubloons:set(newValue)

    -- Pulse on change
    if newValue ~= oldValue and PulseFn then
      PulseFn()
    end
  end
end

--[[
  Called when Knit initializes. Creates the HUD GUI.
]]
function HudController:KnitInit()
  createHud()
  print("[HudController] Initialized")
end

--[[
  Called when Knit starts. Connects to server services for data.
]]
function HudController:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DoubloonService = Knit.GetService("DoubloonService")
  SoundController = Knit.GetController("SoundController")

  -- Get initial value from session snapshot
  SessionStateService:GetSessionSnapshot()
    :andThen(function(snapshot)
      if snapshot and snapshot.heldDoubloons then
        updateDoubloons(snapshot.heldDoubloons)
      end
    end)
    :catch(function(err)
      warn("[HudController] Failed to get session snapshot:", err)
    end)

  -- Listen for held doubloons changes from SessionStateService
  SessionStateService.SessionStateChanged:Connect(function(fieldName: string, value: any)
    if fieldName == "heldDoubloons" and type(value) == "number" then
      updateDoubloons(value)
    end
  end)

  -- Listen for doubloon pickups for coin SFX
  DoubloonService.DoubloonCollected:Connect(function(_pickupPosition: Vector3, _amount: number)
    -- The SessionStateChanged signal updates the counter value;
    -- this signal gives us the pickup event for sound feedback.
    if SoundController then
      SoundController:PlayCoinPickupSound()
    end
  end)

  print("[HudController] Started")
end

--[[
  Returns the current held doubloons count.
  @return number
]]
function HudController:GetHeldDoubloons(): number
  if HeldDoubloons then
    return Fusion.peek(HeldDoubloons)
  end
  return 0
end

return HudController
