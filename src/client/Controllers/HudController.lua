--[[
  HudController.lua
  Client-side Knit controller that manages the main gameplay HUD.
  Displays:
    - Held doubloons counter (UI-001)
    - Ship hold indicator with lock state and treasury (UI-002)
  Future HUD elements (threat, day/night, minimap) will be added here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local UIFolder = script.Parent.Parent:WaitForChild("UI")
local HudDoubloonsCounter = require(UIFolder:WaitForChild("HudDoubloonsCounter"))
local ShipHoldIndicator = require(UIFolder:WaitForChild("ShipHoldIndicator"))

local HudController = Knit.CreateController({
  Name = "HudController",
})

-- References (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local DoubloonService = nil
local ShipService = nil
local SoundController = nil

-- Fusion state
local FusionScope = nil
local HeldDoubloons = nil -- Fusion.Value<number>
local ShipHold = nil -- Fusion.Value<number>
local ShipLocked = nil -- Fusion.Value<boolean>
local Treasury = nil -- Fusion.Value<number>

-- UI references
local ScreenGui = nil
local DoubloonsPulseFn = nil -- function to trigger doubloons pulse animation
local ShipHoldPulseFn = nil -- function to trigger ship hold pulse animation

-- Local player
local LocalPlayer = Players.LocalPlayer

--[[
  Creates the HUD ScreenGui and mounts all HUD components.
]]
local function createHud()
  FusionScope = Fusion.scoped(Fusion)
  HeldDoubloons = FusionScope:Value(0)
  ShipHold = FusionScope:Value(0)
  ShipLocked = FusionScope:Value(true)
  Treasury = FusionScope:Value(0)

  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "HudGui"
  ScreenGui.DisplayOrder = 10
  ScreenGui.ResetOnSpawn = false
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  -- Create the doubloons counter (UI-001)
  local counter, triggerDoubloonsPulse = HudDoubloonsCounter.create(FusionScope, HeldDoubloons)
  counter.Parent = ScreenGui
  DoubloonsPulseFn = triggerDoubloonsPulse

  -- Create the ship hold indicator (UI-002)
  local shipIndicator, triggerShipPulse =
    ShipHoldIndicator.create(FusionScope, ShipHold, ShipLocked, Treasury)
  shipIndicator.Parent = ScreenGui
  ShipHoldPulseFn = triggerShipPulse
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
    if newValue ~= oldValue and DoubloonsPulseFn then
      DoubloonsPulseFn()
    end
  end
end

--[[
  Updates the ship hold display value and triggers pulse animation.
  @param newValue The new ship hold doubloon count
]]
local function updateShipHold(newValue: number)
  if ShipHold then
    local oldValue = Fusion.peek(ShipHold)
    ShipHold:set(newValue)

    if newValue ~= oldValue and ShipHoldPulseFn then
      ShipHoldPulseFn()
    end
  end
end

--[[
  Updates the ship locked display state.
  @param locked Whether the ship is locked
]]
local function updateShipLocked(locked: boolean)
  if ShipLocked then
    ShipLocked:set(locked)
  end
end

--[[
  Updates the treasury display value and triggers pulse animation.
  @param newValue The new treasury total
]]
local function updateTreasury(newValue: number)
  if Treasury then
    local oldValue = Fusion.peek(Treasury)
    Treasury:set(newValue)

    if newValue ~= oldValue and ShipHoldPulseFn then
      ShipHoldPulseFn()
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
  DataService = Knit.GetService("DataService")
  DoubloonService = Knit.GetService("DoubloonService")
  ShipService = Knit.GetService("ShipService")
  SoundController = Knit.GetController("SoundController")

  -- Get initial values from session snapshot
  SessionStateService:GetSessionSnapshot()
    :andThen(function(snapshot)
      if snapshot then
        if snapshot.heldDoubloons then
          updateDoubloons(snapshot.heldDoubloons)
        end
        if snapshot.shipHold then
          updateShipHold(snapshot.shipHold)
        end
        if snapshot.shipLocked ~= nil then
          updateShipLocked(snapshot.shipLocked)
        end
      end
    end)
    :catch(function(err)
      warn("[HudController] Failed to get session snapshot:", err)
    end)

  -- Get initial treasury from DataService
  DataService:GetTreasury()
    :andThen(function(treasury)
      if treasury then
        updateTreasury(treasury)
      end
    end)
    :catch(function(err)
      warn("[HudController] Failed to get treasury:", err)
    end)

  -- Listen for session state changes (held doubloons, ship hold, ship locked)
  SessionStateService.SessionStateChanged:Connect(function(fieldName: string, value: any)
    if fieldName == "heldDoubloons" and type(value) == "number" then
      updateDoubloons(value)
    elseif fieldName == "shipHold" and type(value) == "number" then
      updateShipHold(value)
    elseif fieldName == "shipLocked" and type(value) == "boolean" then
      updateShipLocked(value)
    end
  end)

  -- Listen for treasury changes from DataService
  DataService.DataChanged:Connect(function(fieldName: string, value: any)
    if fieldName == "treasury" and type(value) == "number" then
      updateTreasury(value)
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
