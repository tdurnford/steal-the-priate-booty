--[[
  HudController.lua
  Client-side Knit controller that manages the main gameplay HUD.
  Displays:
    - Held doubloons counter (UI-001)
    - Ship hold indicator with lock state and treasury (UI-002)
    - Threat level indicator with color-coded tier icon (UI-003)
    - Day/night phase indicator with progress bar (UI-004)
    - Notoriety rank indicator with XP progress (RANK-001)
    - Bounty status integration (EVENT-001)
    - Bounty alert overlay: pulsing skull + "BOUNTY ON YOU!" (UI-007)
    - Raid alert overlay: "YOUR SHIP IS BEING RAIDED!" with raider name (UI-007)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local UIFolder = script.Parent.Parent:WaitForChild("UI")
local HudDoubloonsCounter = require(UIFolder:WaitForChild("HudDoubloonsCounter"))
local ShipHoldIndicator = require(UIFolder:WaitForChild("ShipHoldIndicator"))
local ThreatLevelIndicator = require(UIFolder:WaitForChild("ThreatLevelIndicator"))
local DayNightIndicator = require(UIFolder:WaitForChild("DayNightIndicator"))
local NotorietyIndicator = require(UIFolder:WaitForChild("NotorietyIndicator"))
local BountyAlertOverlay = require(UIFolder:WaitForChild("BountyAlertOverlay"))
local RaidAlertOverlay = require(UIFolder:WaitForChild("RaidAlertOverlay"))

local HudController = Knit.CreateController({
  Name = "HudController",
})

-- References (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local DoubloonService = nil
local ShipService = nil
local SoundController = nil
local DayNightController = nil
local NotorietyController = nil
local BountyController = nil

-- Fusion state
local FusionScope = nil
local HeldDoubloons = nil -- Fusion.Value<number>
local ShipHold = nil -- Fusion.Value<number>
local ShipLocked = nil -- Fusion.Value<boolean>
local Treasury = nil -- Fusion.Value<number>
local ThreatLevel = nil -- Fusion.Value<number>
local DayNightPhase = nil -- Fusion.Value<string>
local DayNightProgress = nil -- Fusion.Value<number>
local NotorietyXP = nil -- Fusion.Value<number>
local NotorietyProgress = nil -- Fusion.Value<number>
local BountyAlertVisible = nil -- Fusion.Value<boolean>
local RaidAlertVisible = nil -- Fusion.Value<boolean>
local RaidAlertRaiderName = nil -- Fusion.Value<string>

-- UI references
local ScreenGui = nil
local DoubloonsPulseFn = nil -- function to trigger doubloons pulse animation
local ShipHoldPulseFn = nil -- function to trigger ship hold pulse animation
local ThreatPulseFn = nil -- function to trigger threat tier change pulse animation
local DayNightPulseFn = nil -- function to trigger day/night phase change pulse animation
local NotorietyPulseFn = nil -- function to trigger notoriety rank-up pulse animation
local ProgressConnection = nil -- Heartbeat connection for progress bar updates

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
  ThreatLevel = FusionScope:Value(0)
  DayNightPhase = FusionScope:Value("Day")
  DayNightProgress = FusionScope:Value(0)
  NotorietyXP = FusionScope:Value(0)
  NotorietyProgress = FusionScope:Value(0)
  BountyAlertVisible = FusionScope:Value(false)
  RaidAlertVisible = FusionScope:Value(false)
  RaidAlertRaiderName = FusionScope:Value("")

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

  -- Create the threat level indicator (UI-003)
  local threatIndicator, triggerThreatPulse = ThreatLevelIndicator.create(FusionScope, ThreatLevel)
  threatIndicator.Parent = ScreenGui
  ThreatPulseFn = triggerThreatPulse

  -- Create the day/night indicator (UI-004)
  local dayNightIndicator, triggerDayNightPulse =
    DayNightIndicator.create(FusionScope, DayNightPhase, DayNightProgress)
  dayNightIndicator.Parent = ScreenGui
  DayNightPulseFn = triggerDayNightPulse

  -- Create the notoriety indicator (RANK-001)
  local notorietyIndicator, triggerNotorietyPulse =
    NotorietyIndicator.create(FusionScope, NotorietyXP, NotorietyProgress)
  notorietyIndicator.Parent = ScreenGui
  NotorietyPulseFn = triggerNotorietyPulse

  -- Create the bounty alert overlay (UI-007)
  local bountyAlert = BountyAlertOverlay.create(FusionScope, BountyAlertVisible)
  bountyAlert.Parent = ScreenGui

  -- Create the raid alert overlay (UI-007)
  local raidAlert = RaidAlertOverlay.create(FusionScope, RaidAlertVisible, RaidAlertRaiderName)
  raidAlert.Parent = ScreenGui
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
  Updates the threat level display and triggers pulse on tier change.
  @param newValue The new threat level (0-100)
]]
local function updateThreatLevel(newValue: number)
  if ThreatLevel then
    local oldValue = Fusion.peek(ThreatLevel)
    ThreatLevel:set(newValue)

    -- Pulse on tier change (not every number change)
    local oldTier = GameConfig.getThreatTier(oldValue)
    local newTier = GameConfig.getThreatTier(newValue)
    if oldTier.id ~= newTier.id and ThreatPulseFn then
      ThreatPulseFn()
    end
  end
end

--[[
  Updates the notoriety XP display and progress bar, triggers pulse on rank change.
  @param newXP The new notoriety XP total
]]
local function updateNotorietyXP(newXP: number)
  if NotorietyXP then
    local oldXP = Fusion.peek(NotorietyXP)
    NotorietyXP:set(newXP)

    -- Update progress to next rank
    if NotorietyController and NotorietyProgress then
      NotorietyProgress:set(NotorietyController:GetProgressToNextRank())
    end

    -- Pulse on rank change
    local oldRank = GameConfig.getRankForXP(oldXP)
    local newRank = GameConfig.getRankForXP(newXP)
    if oldRank.rank ~= newRank.rank and NotorietyPulseFn then
      NotorietyPulseFn()
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
  DayNightController = Knit.GetController("DayNightController")
  NotorietyController = Knit.GetController("NotorietyController")
  BountyController = Knit.GetController("BountyController")

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
        if snapshot.threatLevel then
          updateThreatLevel(snapshot.threatLevel)
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

  -- Listen for session state changes (held doubloons, ship hold, ship locked, threat)
  SessionStateService.SessionStateChanged:Connect(function(fieldName: string, value: any)
    if fieldName == "heldDoubloons" and type(value) == "number" then
      updateDoubloons(value)
    elseif fieldName == "shipHold" and type(value) == "number" then
      updateShipHold(value)
    elseif fieldName == "shipLocked" and type(value) == "boolean" then
      updateShipLocked(value)
    elseif fieldName == "threatLevel" and type(value) == "number" then
      updateThreatLevel(value)
    elseif fieldName == "hasBounty" and type(value) == "boolean" then
      -- Pulse doubloons counter when bounty state changes (visual feedback)
      if value == true and DoubloonsPulseFn then
        DoubloonsPulseFn()
      end
    end
  end)

  -- Listen for treasury and notoriety changes from DataService
  DataService.DataChanged:Connect(function(fieldName: string, value: any)
    if fieldName == "treasury" and type(value) == "number" then
      updateTreasury(value)
    elseif fieldName == "notorietyXP" and type(value) == "number" then
      updateNotorietyXP(value)
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

  -- Get initial notoriety XP from NotorietyController
  if NotorietyController then
    -- XP is fetched async by NotorietyController; listen for updates
    NotorietyController.XPChanged:Connect(function(newXP: number, _rank: any)
      updateNotorietyXP(newXP)
    end)

    -- Set initial value if already available
    local initialXP = NotorietyController:GetXP()
    if initialXP > 0 then
      updateNotorietyXP(initialXP)
    end
  end

  -- Set initial day/night phase from DayNightController
  if DayNightController then
    local phase = DayNightController:GetCurrentPhase()
    if DayNightPhase then
      DayNightPhase:set(phase)
    end
    if DayNightProgress then
      DayNightProgress:set(DayNightController:GetPhaseProgress())
    end

    -- Listen for phase transitions
    DayNightController.PhaseChanged:Connect(function(newPhase: string, _previousPhase: string)
      if DayNightPhase then
        DayNightPhase:set(newPhase)
      end
      -- Reset progress bar on phase change
      if DayNightProgress then
        DayNightProgress:set(0)
      end
      -- Pulse animation on phase change
      if DayNightPulseFn then
        DayNightPulseFn()
      end
    end)

    -- Update progress bar on Heartbeat
    ProgressConnection = RunService.Heartbeat:Connect(function()
      if DayNightProgress and DayNightController then
        DayNightProgress:set(DayNightController:GetPhaseProgress())
      end
    end)
  end

  -- Wire up bounty alert overlay (UI-007)
  if BountyController then
    BountyController.BountyStarted:Connect(
      function(_targetUserId: number, _targetName: string, isLocalPlayer: boolean)
        if BountyAlertVisible and isLocalPlayer then
          BountyAlertVisible:set(true)
        end
      end
    )

    BountyController.BountyEnded:Connect(
      function(_targetUserId: number, _reason: string, wasLocalPlayer: boolean)
        if BountyAlertVisible and wasLocalPlayer then
          BountyAlertVisible:set(false)
        end
      end
    )

    -- Check if local player already has a bounty (late join)
    if BountyAlertVisible and BountyController:IsLocalPlayerBounty() then
      BountyAlertVisible:set(true)
    end
  end

  -- Wire up raid alert overlay (UI-007)
  ShipService.RaidAlert:Connect(function(raiderName: string, _slotIndex: number)
    if RaidAlertVisible and RaidAlertRaiderName then
      RaidAlertRaiderName:set(raiderName)
      RaidAlertVisible:set(true)
    end
  end)

  ShipService.RaidEndedForOwner:Connect(function(_slotIndex: number, _reason: string)
    if RaidAlertVisible then
      RaidAlertVisible:set(false)
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
