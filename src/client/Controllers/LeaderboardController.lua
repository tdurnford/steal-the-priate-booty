--[[
  LeaderboardController.lua
  Client-side Knit controller that manages the leaderboard UI panel.

  Handles:
    - Opening/closing the leaderboard (keybind "L")
    - Fetching leaderboard data from LeaderboardService
    - Auto-refreshing when server signals data update
    - Routing tab selection to the panel
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local LeaderboardPanel =
  require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("LeaderboardPanel"))

local LeaderboardController = Knit.CreateController({
  Name = "LeaderboardController",
})

-- References (set in KnitStart)
local LeaderboardService = nil
local SoundController = nil

-- State
local FusionScope = nil
local IsVisible = nil -- Fusion.Value<boolean>
local LeaderboardData = nil -- Fusion.Value<table>
local ActiveTab = "held" -- current tab ID: "held" | "treasury" | "notoriety"
local ScreenGui = nil
local Panel = nil
local LocalPlayer = Players.LocalPlayer
local IsLoading = false

-- Toggle key
local LEADERBOARD_KEY = Enum.KeyCode.L

--------------------------------------------------------------------------------
-- PANEL MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Builds (or rebuilds) the leaderboard panel.
]]
local function buildPanel()
  if Panel then
    Panel:Destroy()
    Panel = nil
  end

  if not FusionScope or not IsVisible or not LeaderboardData then
    return
  end

  Panel = LeaderboardPanel.create(
    FusionScope,
    IsVisible,
    LeaderboardData,
    LocalPlayer.UserId,
    ActiveTab,
    function(tabId)
      -- Tab change callback — update active tab and rebuild
      ActiveTab = tabId
      buildPanel()
    end,
    function()
      LeaderboardController:Close()
    end
  )

  if ScreenGui then
    Panel.Parent = ScreenGui
  end
end

--[[
  Fetches fresh leaderboard data from the server and updates local state.
]]
local function refreshData()
  if not LeaderboardService or IsLoading then
    return
  end

  IsLoading = true

  LeaderboardService:GetLeaderboard()
    :andThen(function(data)
      if LeaderboardData and data then
        LeaderboardData:set(data)
        buildPanel()
      end
    end)
    :catch(function(err)
      warn("[LeaderboardController] Failed to fetch leaderboard:", err)
    end)
    :finally(function()
      IsLoading = false
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Opens the leaderboard panel. Fetches fresh data.
]]
function LeaderboardController:Open()
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
  Closes the leaderboard panel.
]]
function LeaderboardController:Close()
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
  Toggles the leaderboard open/closed.
]]
function LeaderboardController:Toggle()
  if IsVisible and Fusion.peek(IsVisible) then
    self:Close()
  else
    self:Open()
  end
end

--[[
  Returns whether the leaderboard is currently visible.
  @return boolean
]]
function LeaderboardController:IsOpen(): boolean
  if IsVisible then
    return Fusion.peek(IsVisible)
  end
  return false
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function LeaderboardController:KnitInit()
  FusionScope = Fusion.scoped(Fusion)
  IsVisible = FusionScope:Value(false)
  LeaderboardData = FusionScope:Value({
    held = {},
    treasury = {},
    notoriety = {},
  })

  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "LeaderboardGui"
  ScreenGui.DisplayOrder = 55 -- Above HUD (10), near GearShop (50)
  ScreenGui.ResetOnSpawn = false
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[LeaderboardController] Initialized")
end

function LeaderboardController:KnitStart()
  LeaderboardService = Knit.GetService("LeaderboardService")
  SoundController = Knit.GetController("SoundController")

  -- Auto-refresh when server signals updated data
  LeaderboardService.LeaderboardUpdated:Connect(function()
    if IsVisible and Fusion.peek(IsVisible) then
      refreshData()
    end
  end)

  -- Keybind: L to toggle leaderboard
  UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
      return
    end
    if input.KeyCode == LEADERBOARD_KEY then
      self:Toggle()
    end
  end)

  print("[LeaderboardController] Started — press L to open leaderboard")
end

return LeaderboardController
