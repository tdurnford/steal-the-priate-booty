--[[
  RankEffectsService.lua
  Server-authoritative rank unlock effects manager.

  Applies gameplay effects based on notoriety rank:
    - Rank 2 (Buccaneer): unlocks cutlass lunge move
    - Rank 3 (Raider): +5% passive movement speed
    - Rank 4 (Captain): unlocks cutlass spin move
    - Rank 5 (Pirate Lord): +10% loot pickup radius
    - Rank 6 (Dread Pirate): title displayed above head with glow

  Listens for rank changes via DataService signals.
  Other services query this service for rank-based bonuses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local RankEffectsService = Knit.CreateService({
  Name = "RankEffectsService",
  Client = {
    -- Fired to a player when their rank unlocks change.
    -- Args: (unlocks: { lunge: boolean, spin: boolean })
    UnlocksChanged = Knit.CreateSignal(),
  },
})

-- Server-side signal: fired when a player's rank effects change.
-- Args: (player: Player, rankNumber: number)
RankEffectsService.RankEffectsApplied = Signal.new()

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil

-- Per-player cached rank number
local PlayerRank: { [Player]: number } = {}

-- Per-player base walk speed (before any rank bonuses)
local BASE_WALK_SPEED = 16 -- Roblox default Humanoid.WalkSpeed

-- Rank thresholds for each unlock
local RANK_LUNGE = 2
local RANK_SPEED = 3
local RANK_SPIN = 4
local RANK_PICKUP = 5
local RANK_TITLE = 6

-- Title BillboardGui references for cleanup
local TitleBillboards: { [Player]: BillboardGui } = {}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Gets the current rank number for a player.
  @param player The player to check
  @return rank number (1-6), defaults to 1
]]
local function getRankNumber(player: Player): number
  if not DataService then
    return 1
  end
  local xp = DataService:GetNotorietyXP(player)
  if not xp then
    return 1
  end
  local rankDef = GameConfig.getRankForXP(xp)
  return rankDef.rank
end

--[[
  Applies the +5% speed bonus to a player's Humanoid if rank >= 3.
  @param player The player
  @param rankNumber The player's current rank
]]
local function applySpeedBonus(player: Player, rankNumber: number)
  local character = player.Character
  if not character then
    return
  end
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if not humanoid then
    return
  end

  if rankNumber >= RANK_SPEED then
    humanoid.WalkSpeed = BASE_WALK_SPEED * (1 + GameConfig.RankBonuses.speedBonusPercent)
  else
    humanoid.WalkSpeed = BASE_WALK_SPEED
  end
end

--[[
  Creates or removes the Dread Pirate title BillboardGui above a player's head.
  @param player The player
  @param rankNumber The player's current rank
]]
local function applyTitleDisplay(player: Player, rankNumber: number)
  -- Remove existing title if any
  if TitleBillboards[player] then
    TitleBillboards[player]:Destroy()
    TitleBillboards[player] = nil
  end

  if rankNumber < RANK_TITLE then
    return
  end

  local character = player.Character
  if not character then
    return
  end
  local head = character:FindFirstChild("Head")
  if not head then
    return
  end

  local billboard = Instance.new("BillboardGui")
  billboard.Name = "DreadPirateTitle"
  billboard.Adornee = head
  billboard.Size = UDim2.new(0, 200, 0, 50)
  billboard.StudsOffset = Vector3.new(0, 3, 0)
  billboard.AlwaysOnTop = false
  billboard.MaxDistance = 100

  -- Title text
  local titleLabel = Instance.new("TextLabel")
  titleLabel.Name = "TitleText"
  titleLabel.Size = UDim2.new(1, 0, 0.6, 0)
  titleLabel.Position = UDim2.new(0, 0, 0, 0)
  titleLabel.BackgroundTransparency = 1
  titleLabel.Text = "DREAD PIRATE"
  titleLabel.TextColor3 = Color3.fromRGB(180, 80, 255) -- purple
  titleLabel.TextStrokeColor3 = Color3.fromRGB(60, 0, 100)
  titleLabel.TextStrokeTransparency = 0.3
  titleLabel.Font = Enum.Font.GothamBold
  titleLabel.TextScaled = true
  titleLabel.Parent = billboard

  -- Player name below title
  local nameLabel = Instance.new("TextLabel")
  nameLabel.Name = "NameText"
  nameLabel.Size = UDim2.new(1, 0, 0.4, 0)
  nameLabel.Position = UDim2.new(0, 0, 0.6, 0)
  nameLabel.BackgroundTransparency = 1
  nameLabel.Text = player.DisplayName
  nameLabel.TextColor3 = Color3.fromRGB(220, 180, 255)
  nameLabel.TextStrokeColor3 = Color3.fromRGB(40, 0, 60)
  nameLabel.TextStrokeTransparency = 0.5
  nameLabel.Font = Enum.Font.GothamMedium
  nameLabel.TextScaled = true
  nameLabel.Parent = billboard

  -- Purple glow effect on the title
  local glow = Instance.new("PointLight")
  glow.Name = "TitleGlow"
  glow.Color = Color3.fromRGB(160, 60, 255)
  glow.Brightness = 1.5
  glow.Range = 8
  glow.Parent = head

  billboard.Parent = head
  TitleBillboards[player] = billboard
end

--[[
  Applies all rank effects for a player based on their current rank.
  @param player The player
  @param rankNumber The player's current rank number
]]
local function applyAllEffects(player: Player, rankNumber: number)
  PlayerRank[player] = rankNumber

  applySpeedBonus(player, rankNumber)
  applyTitleDisplay(player, rankNumber)

  -- Notify client of unlock state
  RankEffectsService.Client.UnlocksChanged:Fire(player, {
    lunge = rankNumber >= RANK_LUNGE,
    spin = rankNumber >= RANK_SPIN,
  })

  RankEffectsService.RankEffectsApplied:Fire(player, rankNumber)
end

--------------------------------------------------------------------------------
-- PUBLIC API (queried by other services)
--------------------------------------------------------------------------------

--[[
  Returns whether a player has unlocked the lunge move.
  @param player The player to check
  @return boolean
]]
function RankEffectsService:HasLunge(player: Player): boolean
  local rank = PlayerRank[player] or 1
  return rank >= RANK_LUNGE
end

--[[
  Returns whether a player has unlocked the spin move.
  @param player The player to check
  @return boolean
]]
function RankEffectsService:HasSpin(player: Player): boolean
  local rank = PlayerRank[player] or 1
  return rank >= RANK_SPIN
end

--[[
  Returns the pickup radius for a player (base + rank bonus).
  @param player The player to check
  @return number (studs)
]]
function RankEffectsService:GetPickupRadius(player: Player): number
  local rank = PlayerRank[player] or 1
  local baseRadius = GameConfig.Pickups.pickupRadius
  if rank >= RANK_PICKUP then
    return baseRadius * (1 + GameConfig.RankBonuses.pickupRadiusBonusPercent)
  end
  return baseRadius
end

--[[
  Returns the walk speed for a player (base + rank bonus).
  Used by CombatService to know the correct "default" speed when restoring from block.
  @param player The player to check
  @return number (studs/s)
]]
function RankEffectsService:GetWalkSpeed(player: Player): number
  local rank = PlayerRank[player] or 1
  if rank >= RANK_SPEED then
    return BASE_WALK_SPEED * (1 + GameConfig.RankBonuses.speedBonusPercent)
  end
  return BASE_WALK_SPEED
end

--[[
  Returns the player's current cached rank number.
  @param player The player
  @return number (1-6)
]]
function RankEffectsService:GetRankNumber(player: Player): number
  return PlayerRank[player] or 1
end

--[[
  Client-callable: returns current unlocks for the player.
]]
function RankEffectsService.Client:GetUnlocks(player: Player): { lunge: boolean, spin: boolean }
  local rank = self.Server:GetRankNumber(player)
  return {
    lunge = rank >= RANK_LUNGE,
    spin = rank >= RANK_SPIN,
  }
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function RankEffectsService:KnitInit()
  print("[RankEffectsService] Initializing...")
end

function RankEffectsService:KnitStart()
  DataService = Knit.GetService("DataService")

  -- Apply effects on player join (after profile loads)
  Players.PlayerAdded:Connect(function(player: Player)
    -- Wait briefly for profile to load
    task.delay(1, function()
      local rank = getRankNumber(player)
      PlayerRank[player] = rank

      -- Apply effects on first character spawn
      if player.Character then
        applyAllEffects(player, rank)
      end

      -- Re-apply effects on character respawn
      player.CharacterAdded:Connect(function(_character: Model)
        -- Wait for Humanoid to be ready
        task.defer(function()
          local currentRank = PlayerRank[player] or 1
          applyAllEffects(player, currentRank)
        end)
      end)
    end)
  end)

  -- Handle players already in game
  for _, player in Players:GetPlayers() do
    task.defer(function()
      local rank = getRankNumber(player)
      PlayerRank[player] = rank
      applyAllEffects(player, rank)

      player.CharacterAdded:Connect(function(_character: Model)
        task.defer(function()
          local currentRank = PlayerRank[player] or 1
          applyAllEffects(player, currentRank)
        end)
      end)
    end)
  end

  -- Listen for rank changes from DataService (server-side signal)
  DataService.NotorietyRankChanged:Connect(
    function(player: Player, newRankDef: any, oldRankDef: any)
      local newRank = newRankDef.rank or 1
      local oldRank = PlayerRank[player] or 1
      if newRank ~= oldRank then
        applyAllEffects(player, newRank)
        print(
          string.format(
            "[RankEffectsService] %s ranked up: %d → %d (%s)",
            player.Name,
            oldRank,
            newRank,
            newRankDef.name or "?"
          )
        )
      end
    end
  )

  -- Clean up on player leave
  Players.PlayerRemoving:Connect(function(player: Player)
    PlayerRank[player] = nil
    if TitleBillboards[player] then
      TitleBillboards[player]:Destroy()
      TitleBillboards[player] = nil
    end
  end)

  print("[RankEffectsService] Started")
end

return RankEffectsService
