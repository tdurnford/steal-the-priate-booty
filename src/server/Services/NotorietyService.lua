--[[
  NotorietyService.lua
  Server-authoritative notoriety XP tracking and accumulation.

  Listens to gameplay events and awards XP via DataService:AddNotorietyXP().
  XP actions (from GameConfig.NotorietyXP):
    - deposit_100:        Deposit 100+ doubloons          (10 XP)
    - hit_player:         Hit another player               (5 XP)
    - pickup_spilled_loot: Pick up doubloon pickups        (3 XP, 5s cooldown)
    - break_container:    Break a container                 (2 XP)
    - kill_skeleton:      Kill a Cursed Skeleton            (8 XP)
    - kill_ghost_pirate:  Kill a Ghost Pirate               (6 XP)
    - kill_phantom_captain: Kill a Phantom Captain          (20 XP)
    - survive_full_night: Survive full night outside Harbor (15 XP)
    - raid_ship:          Raid another player's ship        (10 XP)
    - hit_bounty_target:  Hit the bounty target             (15 XP)
    - survive_bounty:     Deposit while bounty is on you    (25 XP)

  All XP values come from GameConfig.getNotorietyXP(actionId).
  XP is permanently saved via DataService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local NotorietyService = Knit.CreateService({
  Name = "NotorietyService",
  Client = {
    -- Fired to the player when XP is awarded (for client-side toast/feedback).
    -- Args: (actionId: string, xpAmount: number, newTotalXP: number)
    XPAwarded = Knit.CreateSignal(),
  },
})

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil
local SessionStateService = nil
local CombatService = nil
local ContainerService = nil
local DoubloonService = nil
local ShipService = nil
local DayNightService = nil
local NPCService = nil

-- Per-player cooldown for pickup_spilled_loot (prevent XP spam from bulk collecting)
local PICKUP_XP_COOLDOWN = 5 -- seconds
local LastPickupXPTime: { [Player]: number } = {}

-- Night survival tracking: players who were outside harbor when Night started
local NightSurvivalCandidates: { [Player]: boolean } = {}

--------------------------------------------------------------------------------
-- CORE XP AWARD
--------------------------------------------------------------------------------

--[[
  Awards notoriety XP for a gameplay action.
  Delegates to DataService:AddNotorietyXP() and fires client signal for feedback.
  @param player The player to award XP to
  @param actionId The action ID from GameConfig.NotorietyXP (e.g. "hit_player")
]]
function NotorietyService:AwardXP(player: Player, actionId: string)
  local xp = GameConfig.getNotorietyXP(actionId)
  if xp <= 0 then
    return
  end

  if not DataService then
    return
  end

  local success = DataService:AddNotorietyXP(player, xp)
  if success then
    local data = DataService:GetData(player)
    local newTotalXP = if data then data.notorietyXP else 0
    self.Client.XPAwarded:Fire(player, actionId, xp, newTotalXP)
  end
end

--------------------------------------------------------------------------------
-- CLIENT API
--------------------------------------------------------------------------------

--[[
  Returns the player's current notoriety XP.
  @param player The requesting player
  @return number
]]
function NotorietyService.Client:GetNotorietyXP(player: Player): number
  if not DataService then
    return 0
  end
  return DataService:GetNotorietyXP(player)
end

--[[
  Returns the player's current rank definition.
  @param player The requesting player
  @return RankDef table
]]
function NotorietyService.Client:GetRank(player: Player): GameConfig.RankDef
  if not DataService then
    return GameConfig.Ranks[1]
  end
  local xp = DataService:GetNotorietyXP(player)
  return GameConfig.getRankForXP(xp)
end

--------------------------------------------------------------------------------
-- HOOK CONNECTIONS
--------------------------------------------------------------------------------

--[[
  Connects all gameplay event hooks. Called from KnitStart after services resolve.
]]
local function connectHooks(self)
  -- Hook: Hit player (5 XP) + Hit bounty target (15 XP bonus)
  CombatService.PlayerHitPlayer:Connect(
    function(attacker: Player, target: Player, _spillAmount: number)
      self:AwardXP(attacker, "hit_player")

      -- Bounty target bonus (requires SESSION bounty state from EVENT-001)
      if SessionStateService and SessionStateService:HasBounty(target) then
        self:AwardXP(attacker, "hit_bounty_target")
      end
    end
  )

  -- Hook: Break container (2 XP)
  ContainerService.ContainerBroken:Connect(function(_containerEntry: any, player: Player?)
    if player then
      self:AwardXP(player, "break_container")
    end
  end)

  -- Hook: Pick up doubloon pickups (3 XP, throttled to once per 5s per player)
  DoubloonService.DoubloonCollected:Connect(
    function(player: Player, _amount: number, _position: Vector3)
      local now = os.clock()
      local lastTime = LastPickupXPTime[player]
      if lastTime and (now - lastTime) < PICKUP_XP_COOLDOWN then
        return
      end
      LastPickupXPTime[player] = now
      self:AwardXP(player, "pickup_spilled_loot")
    end
  )

  -- Hook: Kill NPC (8/6/20 XP based on type)
  NPCService.NPCDied:Connect(function(npcEntry: any, killedByPlayer: Player?)
    if not killedByPlayer then
      return
    end

    local npcType = npcEntry.npcType
    if npcType == "skeleton" then
      self:AwardXP(killedByPlayer, "kill_skeleton")
    elseif npcType == "ghost_pirate" then
      self:AwardXP(killedByPlayer, "kill_ghost_pirate")
    elseif npcType == "phantom_captain" then
      self:AwardXP(killedByPlayer, "kill_phantom_captain")
    end
  end)

  -- Hook: Deposit >= 100 doubloons (10 XP)
  ShipService.DepositCompleted:Connect(
    function(player: Player, amountDeposited: number, _newShipHold: number)
      if amountDeposited >= 100 then
        self:AwardXP(player, "deposit_100")
      end
    end
  )

  -- Hook: Raid ship (10 XP)
  ShipService.RaidCompleted:Connect(function(raider: Player, _owner: Player, _amountStolen: number)
    self:AwardXP(raider, "raid_ship")
  end)

  -- Hook: Survive bounty — lock ship while having a bounty (25 XP)
  ShipService.LockCompleted:Connect(
    function(player: Player, _amountLocked: number, _newTreasury: number)
      if SessionStateService and SessionStateService:HasBounty(player) then
        self:AwardXP(player, "survive_bounty")
      end
    end
  )

  -- Hook: Survive full night (15 XP)
  -- When Night starts, record players outside harbor.
  -- When Dawn arrives, award XP to those who were candidates and are still online.
  DayNightService.PhaseChanged:Connect(function(newPhase: string, previousPhase: string)
    if newPhase == "Night" then
      -- Record all online players outside harbor as night survival candidates
      NightSurvivalCandidates = {}
      for _, player in Players:GetPlayers() do
        if SessionStateService and SessionStateService:IsInitialized(player) then
          if not SessionStateService:IsInHarbor(player) then
            NightSurvivalCandidates[player] = true
          end
        end
      end
    elseif newPhase == "Dawn" and previousPhase == "Night" then
      -- Award XP to all candidates who are still connected
      for player, _ in NightSurvivalCandidates do
        if player.Parent then -- still in game
          self:AwardXP(player, "survive_full_night")
        end
      end
      NightSurvivalCandidates = {}
    end
  end)

  -- Clean up tracking tables on player leave
  Players.PlayerRemoving:Connect(function(player: Player)
    LastPickupXPTime[player] = nil
    NightSurvivalCandidates[player] = nil
  end)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function NotorietyService:KnitInit()
  print("[NotorietyService] Initialized")
end

function NotorietyService:KnitStart()
  -- Resolve lazy service references
  DataService = Knit.GetService("DataService")
  SessionStateService = Knit.GetService("SessionStateService")
  CombatService = Knit.GetService("CombatService")
  ContainerService = Knit.GetService("ContainerService")
  DoubloonService = Knit.GetService("DoubloonService")
  ShipService = Knit.GetService("ShipService")
  DayNightService = Knit.GetService("DayNightService")
  NPCService = Knit.GetService("NPCService")

  connectHooks(self)

  print("[NotorietyService] Started — listening for XP events")
end

return NotorietyService
