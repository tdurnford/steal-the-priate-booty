--[[
  LeaderboardService.lua
  Server-authoritative leaderboard data aggregation.

  Collects held doubloons, treasury, and notoriety rank for all players.
  Refreshes every 5 seconds and exposes sorted leaderboard data to clients
  via a Knit client method. Fires a signal when data updates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local LeaderboardService = Knit.CreateService({
  Name = "LeaderboardService",
  Client = {
    -- Fired to all players when leaderboard data refreshes.
    -- Args: () — clients should re-fetch via GetLeaderboard
    LeaderboardUpdated = Knit.CreateSignal(),
  },
})

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil
local SessionStateService = nil

-- Update interval in seconds
local UPDATE_INTERVAL = 5

-- Cached leaderboard data (sorted arrays)
local CachedHeldDoubloons = {} -- { { userId, name, value } }
local CachedTreasury = {} -- { { userId, name, value } }
local CachedNotoriety = {} -- { { userId, name, value, rankName, rankId } }

--------------------------------------------------------------------------------
-- DATA COLLECTION
--------------------------------------------------------------------------------

--[[
  Collects leaderboard data from all connected players.
  Sorts each category descending by value.
]]
local function refreshLeaderboardData()
  local heldEntries = {}
  local treasuryEntries = {}
  local notorietyEntries = {}

  for _, player in Players:GetPlayers() do
    local userId = player.UserId
    local displayName = player.DisplayName

    -- Held doubloons (from session state)
    local held = SessionStateService:GetHeldDoubloons(player)
    table.insert(heldEntries, {
      userId = userId,
      name = displayName,
      value = held,
    })

    -- Treasury (from persistent data)
    local treasury = DataService:GetTreasury(player)
    table.insert(treasuryEntries, {
      userId = userId,
      name = displayName,
      value = treasury,
    })

    -- Notoriety (from persistent data)
    local data = DataService:GetData(player)
    local xp = if data then data.notorietyXP else 0
    local rankDef = GameConfig.getRankForXP(xp)
    table.insert(notorietyEntries, {
      userId = userId,
      name = displayName,
      value = xp,
      rankName = rankDef.name,
      rankId = rankDef.id,
    })
  end

  -- Sort descending by value
  table.sort(heldEntries, function(a, b)
    return a.value > b.value
  end)
  table.sort(treasuryEntries, function(a, b)
    return a.value > b.value
  end)
  table.sort(notorietyEntries, function(a, b)
    return a.value > b.value
  end)

  CachedHeldDoubloons = heldEntries
  CachedTreasury = treasuryEntries
  CachedNotoriety = notorietyEntries
end

--------------------------------------------------------------------------------
-- CLIENT API
--------------------------------------------------------------------------------

--[[
  Returns the current leaderboard data for all three categories.
  @return { held: array, treasury: array, notoriety: array }
]]
function LeaderboardService.Client:GetLeaderboard(_player: Player)
  return {
    held = CachedHeldDoubloons,
    treasury = CachedTreasury,
    notoriety = CachedNotoriety,
  }
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function LeaderboardService:KnitInit()
  print("[LeaderboardService] Initialized")
end

function LeaderboardService:KnitStart()
  DataService = Knit.GetService("DataService")
  SessionStateService = Knit.GetService("SessionStateService")

  -- Periodic refresh loop
  task.spawn(function()
    while true do
      task.wait(UPDATE_INTERVAL)

      local playerCount = #Players:GetPlayers()
      if playerCount > 0 then
        refreshLeaderboardData()
        -- Notify all connected clients
        for _, player in Players:GetPlayers() do
          LeaderboardService.Client.LeaderboardUpdated:Fire(player)
        end
      end
    end
  end)

  print("[LeaderboardService] Started — refreshing every " .. UPDATE_INTERVAL .. "s")
end

return LeaderboardService
