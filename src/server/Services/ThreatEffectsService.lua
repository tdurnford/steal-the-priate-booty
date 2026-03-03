--[[
  ThreatEffectsService.lua
  Server-authoritative threat tier effects (THREAT-003).

  Activates gameplay effects based on each player's threat tier:
    - Calm (0-19): No effects
    - Uneasy (20-39): NPCs within 60 studs of this player gain +10% speed;
      client plays eerie ambient audio
    - Hunted (40-59): Bonus Cursed Skeleton spawns targeting this player;
      aggro range extended to 60 studs; client shows fog vignette

  Per-player tracking:
    - Listens to SessionStateService.StateChanged for "threatLevel" changes
    - Compares old vs new tier; fires client signals on transitions
    - Spawns / despawns bonus NPCs on Hunted entry / exit

  Other services query this for per-player overrides:
    - GetSpeedBonusNearPosition(pos) — NPC speed bonus from nearby Uneasy+ players
    - GetAggroRangeForPlayer(player) — aggro range override for Hunted+ players
    - IsBonusNPC(npcId) — whether an NPC was spawned by threat effects
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local ThreatEffectsService = Knit.CreateService({
  Name = "ThreatEffectsService",
  Client = {
    -- Fired to a specific player when their threat tier changes.
    -- Args: (tierId: string, tierName: string, isUpward: boolean)
    ThreatTierChanged = Knit.CreateSignal(),
  },
})

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local NPCService = nil
local DayNightService = nil

-- Config shortcuts
local THREAT = GameConfig.Threat

-- Tier ID → index for ordering comparisons
local TIER_ORDER = {
  calm = 1,
  uneasy = 2,
  hunted = 3,
  cursed = 4,
  doomed = 5,
}

-- Per-player state tracking
local PlayerThreatTiers: { [Player]: string } = {} -- current tier ID per player

-- Bonus NPC tracking: player → { npcId: number }
-- Each Hunted player gets one bonus skeleton
local BonusNPCs: { [Player]: { npcId: number } } = {}

-- Uneasy+ player positions cached each tick for NPC speed lookups
-- Updated lazily (NPCService queries when needed)
local UneasyPlayers: { [Player]: boolean } = {} -- players at Uneasy+ tier

--------------------------------------------------------------------------------
-- BONUS NPC MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Spawns a bonus Cursed Skeleton that targets a specific player.
  The skeleton spawns near the player's current position (offset 20 studs).
]]
local function spawnBonusSkeleton(player: Player)
  if BonusNPCs[player] then
    return -- already has a bonus NPC
  end

  if not NPCService then
    return
  end

  local character = player.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  -- Spawn 20 studs away in a random direction
  local angle = math.random() * math.pi * 2
  local offset = Vector3.new(math.cos(angle) * 20, 0, math.sin(angle) * 20)
  local spawnPos = hrp.Position + offset

  local entry = NPCService:SpawnBonusSkeleton(spawnPos, player)
  if entry then
    BonusNPCs[player] = { npcId = entry.id }
    print(
      string.format(
        "[ThreatEffectsService] Spawned bonus skeleton #%d targeting %s (Hunted tier)",
        entry.id,
        player.Name
      )
    )
  end
end

--[[
  Despawns the bonus skeleton assigned to a player.
]]
local function despawnBonusSkeleton(player: Player)
  local bonus = BonusNPCs[player]
  if not bonus then
    return
  end

  if NPCService then
    NPCService:DespawnBonusNPC(bonus.npcId)
  end

  BonusNPCs[player] = nil
  print(string.format("[ThreatEffectsService] Despawned bonus skeleton for %s", player.Name))
end

--------------------------------------------------------------------------------
-- TIER CHANGE DETECTION
--------------------------------------------------------------------------------

--[[
  Called when a player's threat level changes.
  Detects tier transitions and activates/deactivates effects.
]]
local function onThreatChanged(player: Player, newThreatLevel: number)
  local newTier = GameConfig.getThreatTier(newThreatLevel)
  local oldTierId = PlayerThreatTiers[player] or "calm"
  local newTierId = newTier.id

  if oldTierId == newTierId then
    return -- same tier, no transition
  end

  local oldOrder = TIER_ORDER[oldTierId] or 1
  local newOrder = TIER_ORDER[newTierId] or 1
  local isUpward = newOrder > oldOrder

  PlayerThreatTiers[player] = newTierId

  -- Update Uneasy tracking
  if newOrder >= TIER_ORDER.uneasy then
    UneasyPlayers[player] = true
  else
    UneasyPlayers[player] = nil
  end

  -- Handle Hunted bonus skeleton spawn/despawn
  if newOrder >= TIER_ORDER.hunted and oldOrder < TIER_ORDER.hunted then
    -- Entered Hunted+: spawn bonus skeleton
    spawnBonusSkeleton(player)
  elseif newOrder < TIER_ORDER.hunted and oldOrder >= TIER_ORDER.hunted then
    -- Left Hunted: despawn bonus skeleton
    despawnBonusSkeleton(player)
  end

  -- Notify client for VFX/audio
  ThreatEffectsService.Client.ThreatTierChanged:Fire(player, newTierId, newTier.name, isUpward)

  print(
    string.format(
      "[ThreatEffectsService] %s tier changed: %s → %s (%s)",
      player.Name,
      oldTierId,
      newTierId,
      if isUpward then "up" else "down"
    )
  )
end

--------------------------------------------------------------------------------
-- PUBLIC API — Queried by NPCService
--------------------------------------------------------------------------------

--[[
  Returns the speed bonus multiplier for an NPC at the given position,
  based on nearby players with Uneasy+ threat.
  @param npcPosition The NPC's world position
  @return Speed multiplier bonus (0.0 if no nearby Uneasy players, 0.10 or 0.20)
]]
function ThreatEffectsService:GetSpeedBonusNearPosition(npcPosition: Vector3): number
  local bestBonus = 0

  for player, _ in UneasyPlayers do
    if not player.Parent then
      continue
    end

    local character = player.Character
    if not character then
      continue
    end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then
      continue
    end

    local dist = (hrp.Position - npcPosition).Magnitude
    if dist > 60 then
      continue
    end

    -- Check player's tier for the bonus amount
    local tierId = PlayerThreatTiers[player] or "calm"
    local tierOrder = TIER_ORDER[tierId] or 1

    if tierOrder >= TIER_ORDER.cursed then
      -- Cursed/Doomed: +20% speed (handled by THREAT-004, but prepped here)
      bestBonus = math.max(bestBonus, THREAT.cursedNpcSpeedBonus)
    elseif tierOrder >= TIER_ORDER.uneasy then
      -- Uneasy/Hunted: +10% speed
      bestBonus = math.max(bestBonus, THREAT.uneasySkeletonSpeedBonus)
    end
  end

  return bestBonus
end

--[[
  Returns the effective aggro range an NPC should use for a specific player.
  Hunted+ players have an extended aggro range of 60 studs.
  @param player The target player
  @return Aggro range in studs (nil means use default)
]]
function ThreatEffectsService:GetAggroRangeForPlayer(player: Player): number?
  local tierId = PlayerThreatTiers[player]
  if not tierId then
    return nil
  end

  local tierOrder = TIER_ORDER[tierId] or 1
  if tierOrder >= TIER_ORDER.hunted then
    return THREAT.huntedAggroRange
  end

  return nil
end

--[[
  Checks if an NPC was spawned as a bonus threat NPC.
  @param npcId The NPC's ID
  @return true if this is a threat-spawned bonus NPC
]]
function ThreatEffectsService:IsBonusNPC(npcId: number): boolean
  for _, bonus in BonusNPCs do
    if bonus.npcId == npcId then
      return true
    end
  end
  return false
end

--[[
  Returns the current threat tier ID for a player.
  @param player The player
  @return Tier ID string ("calm", "uneasy", etc.) or "calm" if not tracked
]]
function ThreatEffectsService:GetPlayerThreatTier(player: Player): string
  return PlayerThreatTiers[player] or "calm"
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS
--------------------------------------------------------------------------------

--[[
  Returns the player's current threat tier (for late-join sync).
]]
function ThreatEffectsService.Client:GetThreatTier(player: Player): (string, string)
  local tierId = PlayerThreatTiers[player] or "calm"
  local tierDef = nil
  for _, tier in GameConfig.ThreatTiers do
    if tier.id == tierId then
      tierDef = tier
      break
    end
  end
  local tierName = if tierDef then tierDef.name else "Calm"
  return tierId, tierName
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
  -- Despawn any bonus NPCs for this player
  despawnBonusSkeleton(player)

  -- Clean up tracking
  PlayerThreatTiers[player] = nil
  UneasyPlayers[player] = nil
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ThreatEffectsService:KnitInit()
  print("[ThreatEffectsService] Initialized")
end

function ThreatEffectsService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  NPCService = Knit.GetService("NPCService")
  DayNightService = Knit.GetService("DayNightService")

  -- Listen for threat level changes via SessionStateService
  SessionStateService.StateChanged:Connect(
    function(player: Player, fieldName: string, newValue: any)
      if fieldName == "threatLevel" then
        onThreatChanged(player, newValue :: number)
      end
    end
  )

  -- Initialize tracking for players already in game
  for _, player in Players:GetPlayers() do
    if SessionStateService:IsInitialized(player) then
      local threatLevel = SessionStateService:GetThreatLevel(player)
      local tier = GameConfig.getThreatTier(threatLevel)
      PlayerThreatTiers[player] = tier.id
      if TIER_ORDER[tier.id] >= TIER_ORDER.uneasy then
        UneasyPlayers[player] = true
      end
    end
  end

  -- Clean up on player leave
  Players.PlayerRemoving:Connect(onPlayerRemoving)

  -- Listen for bonus NPC deaths — respawn if player still Hunted
  NPCService.NPCDied:Connect(function(npcEntry, _killedByPlayer)
    for player, bonus in BonusNPCs do
      if bonus.npcId == npcEntry.id then
        BonusNPCs[player] = nil
        -- Respawn after a delay if player is still Hunted+
        task.delay(10, function()
          if not player.Parent then
            return
          end
          local tierId = PlayerThreatTiers[player]
          if tierId and TIER_ORDER[tierId] >= TIER_ORDER.hunted then
            spawnBonusSkeleton(player)
          end
        end)
        break
      end
    end
  end)

  print("[ThreatEffectsService] Started — listening for threat tier transitions")
end

return ThreatEffectsService
