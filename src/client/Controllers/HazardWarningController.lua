--[[
  HazardWarningController.lua
  Client-side Knit controller that shows proximity-based hazard warning prompts
  when environmental hazards are imminent near the local player.

  Listens to warning-phase signals from all 4 hazard services:
    - VolcanicVentService.VentPhaseChanged → "warning" phase (5s before eruption)
    - TidalSurgeService.SurgePhaseChanged → "warning" phase (4s before flood)
    - RogueWaveService.WavePhaseChanged   → "warning" phase (6s before impact)
    - QuicksandService.PatchStateChanged  → when a patch activates near player

  Only shows warnings when the player is within proximity range of the hazard.
  Different visual style per hazard type (icon, color, text).
  Warnings auto-clear when the hazard phase advances past the warning state.

  Depends on: VolcanicVentService, TidalSurgeService, RogueWaveService,
              QuicksandService (server signals), HazardWarningPanel (UI).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local UIFolder = script.Parent.Parent:WaitForChild("UI")
local HazardWarningPanel = require(UIFolder:WaitForChild("HazardWarningPanel"))

local HazardWarningController = Knit.CreateController({
  Name = "HazardWarningController",
})

local LocalPlayer = Players.LocalPlayer

-- Lazy-loaded service references (set in KnitStart)
local VolcanicVentService = nil
local TidalSurgeService = nil
local RogueWaveService = nil
local QuicksandService = nil

-- Proximity ranges for each hazard type (studs)
local PROXIMITY = {
  volcanic_vent = 60,
  tidal_surge = 80,
  rogue_wave = 100,
  quicksand = 40,
}

-- Fusion state
local FusionScope = nil
local WarningVisibility = {} -- { [hazardType] = Fusion.Value<boolean> }

-- Track active warning sources: { [hazardType] = { [sourceId] = true } }
-- A hazard type stays visible as long as at least one source is active
local ActiveSources = {
  volcanic_vent = {},
  tidal_surge = {},
  rogue_wave = {},
  quicksand = {},
}

-- UI references
local ScreenGui = nil

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Returns the HumanoidRootPart position of the local player, or nil.
]]
local function getLocalPlayerPosition(): Vector3?
  local character = LocalPlayer.Character
  if not character then
    return nil
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return nil
  end
  return hrp.Position
end

--[[
  Checks if the local player is within proximity range of a hazard position.
  @param hazardPosition The world position of the hazard
  @param hazardType The type of hazard (for range lookup)
  @return true if player is within range
]]
local function isPlayerNearHazard(hazardPosition: Vector3, hazardType: string): boolean
  local playerPos = getLocalPlayerPosition()
  if not playerPos then
    return false
  end

  local range = PROXIMITY[hazardType] or 60
  local dist = (playerPos - hazardPosition).Magnitude
  return dist <= range
end

--[[
  Updates the visibility state for a hazard type based on active sources.
  @param hazardType The hazard type to update
]]
local function updateVisibility(hazardType: string)
  local visibility = WarningVisibility[hazardType]
  if not visibility then
    return
  end

  -- Check if any sources are active
  local hasActive = false
  for _ in ActiveSources[hazardType] do
    hasActive = true
    break
  end

  visibility:set(hasActive)
end

--[[
  Adds a warning source for a hazard type.
  @param hazardType The hazard type
  @param sourceId Unique identifier for this source (e.g., vent/zone/patch ID)
]]
local function addWarningSource(hazardType: string, sourceId: string)
  if not ActiveSources[hazardType] then
    return
  end
  ActiveSources[hazardType][sourceId] = true
  updateVisibility(hazardType)
end

--[[
  Removes a warning source for a hazard type.
  @param hazardType The hazard type
  @param sourceId Unique identifier for this source
]]
local function removeWarningSource(hazardType: string, sourceId: string)
  if not ActiveSources[hazardType] then
    return
  end
  ActiveSources[hazardType][sourceId] = nil
  updateVisibility(hazardType)
end

--------------------------------------------------------------------------------
-- VOLCANIC VENT WARNINGS
--------------------------------------------------------------------------------

--[[
  Handles vent phase changes. Shows warning when a vent enters "warning" phase
  and the player is nearby. Clears when vent enters "eruption" or "dormant".
]]
local function onVentPhaseChanged(ventId: string, phase: string, position: Vector3, _size: Vector3)
  if phase == "warning" then
    -- Check proximity
    if isPlayerNearHazard(position, "volcanic_vent") then
      addWarningSource("volcanic_vent", ventId)
    end
  else
    -- Eruption or dormant — clear this vent's warning
    removeWarningSource("volcanic_vent", ventId)
  end
end

--------------------------------------------------------------------------------
-- TIDAL SURGE WARNINGS
--------------------------------------------------------------------------------

--[[
  Handles surge zone phase changes. Shows warning when a zone enters "warning"
  phase and the player is nearby. Clears when zone enters "flood" or later.
]]
local function onSurgePhaseChanged(
  zoneId: string,
  phase: string,
  position: Vector3,
  _size: Vector3,
  _inlandDirection: Vector3
)
  if phase == "warning" then
    if isPlayerNearHazard(position, "tidal_surge") then
      addWarningSource("tidal_surge", zoneId)
    end
  else
    removeWarningSource("tidal_surge", zoneId)
  end
end

--------------------------------------------------------------------------------
-- ROGUE WAVE WARNINGS
--------------------------------------------------------------------------------

--[[
  Handles rogue wave phase changes. Shows warning when a zone enters "warning"
  phase and the player is nearby. Clears when zone enters "impact" or later.
]]
local function onWavePhaseChanged(
  zoneId: string,
  phase: string,
  position: Vector3,
  _size: Vector3,
  _inlandDirection: Vector3
)
  if phase == "warning" then
    if isPlayerNearHazard(position, "rogue_wave") then
      addWarningSource("rogue_wave", zoneId)
    end
  else
    removeWarningSource("rogue_wave", zoneId)
  end
end

--------------------------------------------------------------------------------
-- QUICKSAND WARNINGS
--------------------------------------------------------------------------------

--[[
  Handles quicksand patch state changes. Shows warning when a patch activates
  near the player. Clears when patch deactivates.
]]
local function onPatchStateChanged(
  patchId: string,
  isActive: boolean,
  position: Vector3,
  _size: Vector3
)
  if isActive then
    if isPlayerNearHazard(position, "quicksand") then
      addWarningSource("quicksand", patchId)
    end
  else
    removeWarningSource("quicksand", patchId)
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function HazardWarningController:KnitInit()
  -- Create Fusion scope and warning visibility state
  FusionScope = Fusion.scoped(Fusion)

  WarningVisibility = {
    volcanic_vent = FusionScope:Value(false),
    tidal_surge = FusionScope:Value(false),
    rogue_wave = FusionScope:Value(false),
    quicksand = FusionScope:Value(false),
  }

  -- Create ScreenGui
  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "HazardWarningGui"
  ScreenGui.DisplayOrder = 90 -- above HUD (10), below alerts (110)
  ScreenGui.ResetOnSpawn = false
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  -- Create the warning container with all hazard types
  local container = HazardWarningPanel.createContainer(FusionScope, WarningVisibility)
  container.Parent = ScreenGui

  print("[HazardWarningController] Initialized")
end

function HazardWarningController:KnitStart()
  VolcanicVentService = Knit.GetService("VolcanicVentService")
  TidalSurgeService = Knit.GetService("TidalSurgeService")
  RogueWaveService = Knit.GetService("RogueWaveService")
  QuicksandService = Knit.GetService("QuicksandService")

  -- Listen for volcanic vent phase changes
  VolcanicVentService.VentPhaseChanged:Connect(onVentPhaseChanged)

  -- Listen for tidal surge phase changes
  TidalSurgeService.SurgePhaseChanged:Connect(onSurgePhaseChanged)

  -- Listen for rogue wave phase changes
  RogueWaveService.WavePhaseChanged:Connect(onWavePhaseChanged)

  -- Listen for quicksand patch state changes
  QuicksandService.PatchStateChanged:Connect(onPatchStateChanged)

  -- Late-join sync: check current states of all hazards
  VolcanicVentService:GetVentStates()
    :andThen(function(states)
      for _, state in states do
        if state.phase == "warning" then
          onVentPhaseChanged(state.id, state.phase, state.position, state.size)
        end
      end
    end)
    :catch(function(err)
      warn("[HazardWarningController] Failed to sync vent states:", err)
    end)

  TidalSurgeService:GetZoneStates()
    :andThen(function(states)
      for _, state in states do
        if state.phase == "warning" then
          onSurgePhaseChanged(
            state.id,
            state.phase,
            state.position,
            state.size,
            state.inlandDirection
          )
        end
      end
    end)
    :catch(function(err)
      warn("[HazardWarningController] Failed to sync surge states:", err)
    end)

  RogueWaveService:GetZoneStates()
    :andThen(function(states)
      for _, state in states do
        if state.phase == "warning" then
          onWavePhaseChanged(
            state.id,
            state.phase,
            state.position,
            state.size,
            state.inlandDirection
          )
        end
      end
    end)
    :catch(function(err)
      warn("[HazardWarningController] Failed to sync wave states:", err)
    end)

  QuicksandService:GetPatchStates()
    :andThen(function(states)
      for _, state in states do
        if state.isActive then
          onPatchStateChanged(state.id, state.isActive, state.position, state.size)
        end
      end
    end)
    :catch(function(err)
      warn("[HazardWarningController] Failed to sync quicksand states:", err)
    end)

  print("[HazardWarningController] Started")
end

return HazardWarningController
