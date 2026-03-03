--[[
  PlayerStatsController.lua
  Client-side Knit controller that manages the player stats UI panel.

  Handles:
    - Opening/closing the stats panel (keybind "P")
    - Fetching player data from DataService (stats, notorietyXP, treasury)
    - Auto-refreshing when data changes while panel is open
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local PlayerStatsPanel =
  require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("PlayerStatsPanel"))

local PlayerStatsController = Knit.CreateController({
  Name = "PlayerStatsController",
})

-- References (set in KnitStart)
local DataService = nil
local SoundController = nil

-- State
local FusionScope = nil
local IsVisible = nil -- Fusion.Value<boolean>
local StatsData = nil -- Fusion.Value<table>
local ScreenGui = nil
local Panel = nil
local LocalPlayer = Players.LocalPlayer
local IsLoading = false

-- Toggle key
local STATS_KEY = Enum.KeyCode.P

--------------------------------------------------------------------------------
-- PANEL MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Builds (or rebuilds) the stats panel.
]]
local function buildPanel()
  if Panel then
    Panel:Destroy()
    Panel = nil
  end

  if not FusionScope or not IsVisible or not StatsData then
    return
  end

  Panel = PlayerStatsPanel.create(FusionScope, IsVisible, StatsData, function()
    PlayerStatsController:Close()
  end)

  if ScreenGui then
    Panel.Parent = ScreenGui
  end
end

--[[
  Fetches fresh player data from the server and updates local state.
]]
local function refreshData()
  if not DataService or IsLoading then
    return
  end

  IsLoading = true

  DataService:GetData()
    :andThen(function(data)
      if StatsData and data then
        StatsData:set({
          stats = data.stats,
          notorietyXP = data.notorietyXP,
          treasury = data.treasury,
        })
        buildPanel()
      end
    end)
    :catch(function(err)
      warn("[PlayerStatsController] Failed to fetch data:", err)
    end)
    :finally(function()
      IsLoading = false
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Opens the stats panel. Fetches fresh data.
]]
function PlayerStatsController:Open()
  if IsVisible and Fusion.peek(IsVisible) then
    return
  end

  if SoundController then
    SoundController:PlayButtonClickSound()
  end

  refreshData()

  if IsVisible then
    IsVisible:set(true)
  end
end

--[[
  Closes the stats panel.
]]
function PlayerStatsController:Close()
  if IsVisible and not Fusion.peek(IsVisible) then
    return
  end

  if SoundController then
    SoundController:PlayButtonClickSound()
  end

  if IsVisible then
    IsVisible:set(false)
  end
end

--[[
  Toggles the stats panel open/closed.
]]
function PlayerStatsController:Toggle()
  if IsVisible and Fusion.peek(IsVisible) then
    self:Close()
  else
    self:Open()
  end
end

--[[
  Returns whether the stats panel is currently visible.
  @return boolean
]]
function PlayerStatsController:IsOpen(): boolean
  if IsVisible then
    return Fusion.peek(IsVisible)
  end
  return false
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function PlayerStatsController:KnitInit()
  FusionScope = Fusion.scoped(Fusion)
  IsVisible = FusionScope:Value(false)
  StatsData = FusionScope:Value({
    stats = { totalEarned = 0, totalStolen = 0, totalRaided = 0, biggestHaul = 0 },
    notorietyXP = 0,
    treasury = 0,
  })

  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "PlayerStatsGui"
  ScreenGui.DisplayOrder = 56 -- Above leaderboard (55)
  ScreenGui.ResetOnSpawn = false
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[PlayerStatsController] Initialized")
end

function PlayerStatsController:KnitStart()
  DataService = Knit.GetService("DataService")
  SoundController = Knit.GetController("SoundController")

  -- Auto-refresh when data changes while panel is open
  DataService.DataChanged:Connect(function(fieldName)
    if not IsVisible or not Fusion.peek(IsVisible) then
      return
    end

    if fieldName == "stats" or fieldName == "notorietyXP" or fieldName == "treasury" then
      refreshData()
    end
  end)

  -- Keybind: P to toggle stats panel
  UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
      return
    end
    if input.KeyCode == STATS_KEY then
      self:Toggle()
    end
  end)

  print("[PlayerStatsController] Started — press P to open player stats")
end

return PlayerStatsController
