--[[
  ThreatService.lua
  Server-authoritative threat level tracking and accumulation.

  Per-player threat (0-100) increases from:
    - Time since last ship lock: +5 per minute
    - Held doubloons: +1 per 50 held, checked every 30s
    - Breaking containers: +2 per break
    - Killing NPCs: +3 per kill (called by future NPC services)
    - Being in danger zones: +3 per minute (future ZONE-001 integration)
  Night multiplier: 1.5x all threat gains.
  Threat pauses (does NOT reset) while in Harbor safe zone.

  Threat REDUCTION is handled by other services:
    - Ship deposit: -25 (ShipService.DepositAll already calls AddThreat(-25))
    - Ship lock: reset to 0 (ShipService.LockShip already calls SetThreatLevel(0))
    - Session start: 0 (SessionStateService defaults to 0)

  Other services can call:
    - AddThreatFromAction(player, actionType) for event-driven threat
    - IsInHarbor(player) returns false until HARBOR-001 is implemented
    - OnNPCKilled(player) for NPC death threat gain
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local ThreatService = Knit.CreateService({
  Name = "ThreatService",
  Client = {},
})

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DayNightService = nil
local ContainerService = nil
local CombatService = nil

-- Threat config shortcuts
local THREAT = GameConfig.Threat

-- Accumulation tick interval (seconds). Threat checks run on this cadence.
local TICK_INTERVAL = 1

-- Per-player timers for held-doubloon checks (tracked separately from main tick)
local HeldDoubloonTimers: { [Player]: number } = {}

-- Per-player timers for time-based accumulation
local TimeAccumulators: { [Player]: number } = {}

-- Per-player timers for danger zone accumulation
local DangerZoneAccumulators: { [Player]: number } = {}

-- Harbor zone check placeholder. Returns true if the player is inside the
-- Harbor safe zone. Will be replaced by HARBOR-001 zone detection.
local HarborZonePart: BasePart? = nil

--------------------------------------------------------------------------------
-- HARBOR ZONE CHECK (placeholder until HARBOR-001)
--------------------------------------------------------------------------------

--[[
  Checks whether a player is currently inside the Harbor safe zone.
  Uses a simple Part-based bounding box check. If no HarborZone part exists
  in workspace, always returns false.
  @param player The player to check
  @return true if the player is inside the Harbor
]]
function ThreatService:IsInHarbor(player: Player): boolean
  if not HarborZonePart then
    return false
  end

  local character = player.Character
  if not character then
    return false
  end
  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return false
  end

  -- AABB check against the HarborZone part
  local zoneCF = HarborZonePart.CFrame
  local zoneSize = HarborZonePart.Size / 2
  local localPos = zoneCF:PointToObjectSpace(rootPart.Position)
  return math.abs(localPos.X) <= zoneSize.X
    and math.abs(localPos.Y) <= zoneSize.Y
    and math.abs(localPos.Z) <= zoneSize.Z
end

--------------------------------------------------------------------------------
-- DANGER ZONE CHECK (placeholder until ZONE-001)
--------------------------------------------------------------------------------

--[[
  Checks whether a player is in a danger zone.
  Will be replaced when ZONE-001 implements zone tracking.
  @param player The player to check
  @return true if the player is in a danger zone
]]
function ThreatService:IsInDangerZone(_player: Player): boolean
  -- Placeholder: always false until danger zones are implemented
  return false
end

--------------------------------------------------------------------------------
-- NIGHT MULTIPLIER
--------------------------------------------------------------------------------

--[[
  Returns the threat gain multiplier based on time of day.
  1.0 during day, 1.5 during night.
]]
local function getNightMultiplier(): number
  if DayNightService and DayNightService:IsNight() then
    return THREAT.nightMultiplier
  end
  return 1.0
end

--------------------------------------------------------------------------------
-- THREAT GAIN HELPERS
--------------------------------------------------------------------------------

--[[
  Adds threat to a player with the night multiplier applied.
  Skips if the player is in the Harbor safe zone.
  @param player The player
  @param baseAmount The base threat amount (before night multiplier)
]]
function ThreatService:AddThreatWithMultiplier(player: Player, baseAmount: number)
  if not SessionStateService or not SessionStateService:IsInitialized(player) then
    return
  end

  -- Harbor pauses threat accumulation
  if self:IsInHarbor(player) then
    return
  end

  local amount = baseAmount * getNightMultiplier()
  SessionStateService:AddThreat(player, amount)
end

--------------------------------------------------------------------------------
-- EVENT-DRIVEN THREAT GAINS
--------------------------------------------------------------------------------

--[[
  Called when a player breaks a container.
  Adds +2 threat (before night multiplier).
  @param player The player who broke the container
]]
function ThreatService:OnContainerBroken(player: Player)
  self:AddThreatWithMultiplier(player, THREAT.containerBreakGain)
end

--[[
  Called when a player kills an NPC.
  Adds +3 threat (before night multiplier).
  @param player The player who killed the NPC
]]
function ThreatService:OnNPCKilled(player: Player)
  self:AddThreatWithMultiplier(player, THREAT.npcKillGain)
end

--------------------------------------------------------------------------------
-- PERIODIC ACCUMULATION TICK
--------------------------------------------------------------------------------

--[[
  Called every TICK_INTERVAL seconds. Updates threat for all online players.
  Handles time-based and held-doubloon-based threat accumulation.
]]
local function accumulationTick(dt: number)
  for _, player in Players:GetPlayers() do
    if not SessionStateService or not SessionStateService:IsInitialized(player) then
      continue
    end

    -- Skip players in Harbor
    if ThreatService:IsInHarbor(player) then
      continue
    end

    -- 1. Time-based: +5 per minute since last lock
    --    Accumulate dt and add threat proportionally each second
    TimeAccumulators[player] = (TimeAccumulators[player] or 0) + dt
    if TimeAccumulators[player] >= 1 then
      local seconds = math.floor(TimeAccumulators[player])
      TimeAccumulators[player] = TimeAccumulators[player] - seconds
      -- +5 per 60 seconds = +5/60 per second
      local timeThreat = (THREAT.timeRate / 60) * seconds
      if timeThreat > 0 then
        ThreatService:AddThreatWithMultiplier(player, timeThreat)
      end
    end

    -- 2. Held doubloons: every 30s, +1 per 50 held
    HeldDoubloonTimers[player] = (HeldDoubloonTimers[player] or 0) + dt
    if HeldDoubloonTimers[player] >= THREAT.heldDoubloonsInterval then
      HeldDoubloonTimers[player] = HeldDoubloonTimers[player] - THREAT.heldDoubloonsInterval
      local held = SessionStateService:GetHeldDoubloons(player)
      if held > 0 then
        local threatFromHeld = math.floor(held / THREAT.heldDoubloonsPer) * THREAT.heldDoubloonsRate
        if threatFromHeld > 0 then
          ThreatService:AddThreatWithMultiplier(player, threatFromHeld)
        end
      end
    end

    -- 3. Danger zone: +3 per minute while in danger zone
    if ThreatService:IsInDangerZone(player) then
      DangerZoneAccumulators[player] = (DangerZoneAccumulators[player] or 0) + dt
      if DangerZoneAccumulators[player] >= 1 then
        local seconds = math.floor(DangerZoneAccumulators[player])
        DangerZoneAccumulators[player] = DangerZoneAccumulators[player] - seconds
        local dangerThreat = (THREAT.dangerZoneRate / 60) * seconds
        if dangerThreat > 0 then
          ThreatService:AddThreatWithMultiplier(player, dangerThreat)
        end
      end
    else
      -- Reset accumulator when not in danger zone
      DangerZoneAccumulators[player] = 0
    end
  end
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
  HeldDoubloonTimers[player] = nil
  TimeAccumulators[player] = nil
  DangerZoneAccumulators[player] = nil
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ThreatService:KnitInit()
  -- Look for a HarborZone part in workspace (for HARBOR-001 integration)
  HarborZonePart = workspace:FindFirstChild("HarborZone")
  if HarborZonePart then
    print("[ThreatService] Found HarborZone part — harbor pause enabled")
  end

  print("[ThreatService] Initialized")
end

function ThreatService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DayNightService = Knit.GetService("DayNightService")
  ContainerService = Knit.GetService("ContainerService")
  CombatService = Knit.GetService("CombatService")

  -- Hook into container break events: +2 threat per container broken
  ContainerService.ContainerBroken:Connect(function(_containerEntry, attackingPlayer: Player?)
    if attackingPlayer then
      self:OnContainerBroken(attackingPlayer)
    end
  end)

  -- Hook into player-hit-player events: not threat, but placeholder for NPC kills.
  -- When NPC services are implemented, they will call ThreatService:OnNPCKilled().

  -- Run periodic threat accumulation on Heartbeat
  local tickAccumulator = 0
  RunService.Heartbeat:Connect(function(dt: number)
    tickAccumulator = tickAccumulator + dt
    if tickAccumulator >= TICK_INTERVAL then
      accumulationTick(tickAccumulator)
      tickAccumulator = 0
    end
  end)

  -- Clean up per-player timers on leave
  Players.PlayerRemoving:Connect(onPlayerRemoving)

  print("[ThreatService] Started — accumulation tick every", TICK_INTERVAL, "second(s)")
end

return ThreatService
