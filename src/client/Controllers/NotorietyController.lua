--[[
  NotorietyController.lua
  Client-side Knit controller that tracks the player's notoriety XP and rank.
  Listens for XP award events from NotorietyService and data changes from DataService.
  Exposes reactive state for the HUD to display rank and XP progress.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local NotorietyController = Knit.CreateController({
  Name = "NotorietyController",
})

-- Client-side signal fired when XP changes (for HUD updates).
-- Args: (newXP: number, rank: RankDef)
NotorietyController.XPChanged = Signal.new()

-- Client-side signal fired when an XP award toast should display.
-- Args: (actionId: string, xpAmount: number, newTotalXP: number)
NotorietyController.XPAwarded = Signal.new()

-- Client-side signal fired when rank changes.
-- Args: (newRank: RankDef, oldRank: RankDef)
NotorietyController.RankChanged = Signal.new()

-- Lazy-loaded service references
local NotorietyService = nil
local DataService = nil

-- Current state
local CurrentXP = 0
local CurrentRank = GameConfig.Ranks[1]

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the player's current notoriety XP.
  @return number
]]
function NotorietyController:GetXP(): number
  return CurrentXP
end

--[[
  Returns the player's current rank definition.
  @return RankDef table
]]
function NotorietyController:GetRank(): GameConfig.RankDef
  return CurrentRank
end

--[[
  Returns the XP progress toward the next rank as a fraction (0-1).
  Returns 1 if at max rank.
  @return number between 0 and 1
]]
function NotorietyController:GetProgressToNextRank(): number
  local currentThreshold = CurrentRank.xpThreshold
  local nextRankIndex = CurrentRank.rank + 1

  if nextRankIndex > #GameConfig.Ranks then
    return 1 -- Max rank reached
  end

  local nextRank = GameConfig.Ranks[nextRankIndex]
  local nextThreshold = nextRank.xpThreshold
  local rangeSize = nextThreshold - currentThreshold
  if rangeSize <= 0 then
    return 1
  end

  return math.clamp((CurrentXP - currentThreshold) / rangeSize, 0, 1)
end

--------------------------------------------------------------------------------
-- INTERNAL
--------------------------------------------------------------------------------

--[[
  Updates current XP and rank, fires signals if changed.
  @param newXP The new total XP value
]]
local function updateXP(newXP: number)
  if newXP == CurrentXP then
    return
  end

  CurrentXP = newXP
  local newRank = GameConfig.getRankForXP(newXP)

  NotorietyController.XPChanged:Fire(newXP, newRank)

  -- Check for rank change
  if newRank.rank ~= CurrentRank.rank then
    local oldRank = CurrentRank
    CurrentRank = newRank
    NotorietyController.RankChanged:Fire(newRank, oldRank)
  else
    CurrentRank = newRank
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function NotorietyController:KnitInit()
  print("[NotorietyController] Initialized")
end

function NotorietyController:KnitStart()
  NotorietyService = Knit.GetService("NotorietyService")
  DataService = Knit.GetService("DataService")

  -- Get initial XP from server
  NotorietyService:GetNotorietyXP()
    :andThen(function(xp)
      if xp then
        updateXP(xp)
      end
    end)
    :catch(function(err)
      warn("[NotorietyController] Failed to get initial XP:", err)
    end)

  -- Listen for XP award events (for toast feedback)
  NotorietyService.XPAwarded:Connect(
    function(actionId: string, xpAmount: number, newTotalXP: number)
      updateXP(newTotalXP)
      NotorietyController.XPAwarded:Fire(actionId, xpAmount, newTotalXP)
    end
  )

  -- Also listen for DataChanged in case XP is modified through other means
  DataService.DataChanged:Connect(function(fieldName: string, value: any)
    if fieldName == "notorietyXP" and type(value) == "number" then
      updateXP(value)
    end
  end)

  print("[NotorietyController] Started")
end

return NotorietyController
