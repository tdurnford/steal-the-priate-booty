--[[
  RogueWaveService.lua
  Server-authoritative rogue wave environmental hazard (night-only).

  Handles:
    - Loading wave zone Parts from workspace.RogueWaveZones folder
    - Night-only activation: 1-2 rogue waves per night cycle, random timing
    - Wave lifecycle: idle → warning (6s) → impact → recede (3s) → idle
    - Server-side player detection during impact
    - Hit players: 3.0s ragdoll, pushed 20-25 studs inland, 20% loot spill
    - After each wave: scatter 2-3 bonus containers (Crates/Barrels) across the beach
    - Displaces loose doubloon pickups in the wave zone
    - Client signals for VFX/SFX at each phase transition

  Zone Parts should be BaseParts in workspace.RogueWaveZones.
  Each Part defines the wave impact area (AABB). The Part's LookVector is treated
  as the "inland" direction (direction the wave pushes players). Place the Part so
  its front face points away from the ocean / toward land.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local RogueWaveService = Knit.CreateService({
  Name = "RogueWaveService",
  Client = {
    -- Fired to ALL clients when a wave zone changes phase.
    -- Args: (zoneId: string, phase: string, zonePosition: Vector3, zoneSize: Vector3, inlandDirection: Vector3)
    WavePhaseChanged = Knit.CreateSignal(),

    -- Fired to a specific player when they are hit by a rogue wave.
    -- Args: (pushVelocity: Vector3, ragdollDuration: number)
    WaveHit = Knit.CreateSignal(),

    -- Fired to ALL clients when bonus containers wash ashore after a wave.
    -- Args: (zoneId: string, containerPositions: { Vector3 })
    BonusContainersWashedAshore = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
RogueWaveService.PlayerHitByWave = Signal.new() -- (player: Player, zoneId: string, spillAmount: number)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DoubloonService = nil
local DayNightService = nil
local ContainerService = nil

--------------------------------------------------------------------------------
-- ZONE REGISTRY
--------------------------------------------------------------------------------

type WavePhase = "idle" | "warning" | "impact" | "recede"

type ZoneEntry = {
  id: string,
  part: BasePart,
  position: Vector3,
  size: Vector3,
  inlandDirection: Vector3, -- unit vector pointing inland (wave push direction)
  phase: WavePhase,
  phaseTimer: number, -- time remaining in current phase (seconds)
  hitPlayers: { [Player]: boolean }, -- tracks who was already hit this impact
}

-- Active zones keyed by zone ID (Part name)
local Zones: { [string]: ZoneEntry } = {}
local ZoneList: { ZoneEntry } = {} -- ordered list for random selection

-- Config shortcuts
local CFG = GameConfig.RogueWave
local WARNING_DURATION = CFG.warningDuration
local IMPACT_DURATION = 2 -- short impact window
local RECEDE_DURATION = 3 -- water retreats
local RAGDOLL_DURATION = CFG.ragdollDuration
local SPILL_PERCENT = CFG.lootSpillPercent
local PUSH_MIN = CFG.pushDistanceMin
local PUSH_MAX = CFG.pushDistanceMax
local BONUS_COUNT_MIN = CFG.bonusContainerCount.min
local BONUS_COUNT_MAX = CFG.bonusContainerCount.max
local WAVES_PER_NIGHT_MIN = CFG.perNightCount.min
local WAVES_PER_NIGHT_MAX = CFG.perNightCount.max

-- Vertical tolerance: players up to this many studs above the zone surface are hit
local VERTICAL_TOLERANCE = 12

-- Night cycle tracking
local isNightActive = false
local scheduledWaves: { thread } = {} -- scheduled wave coroutines for the current night

--------------------------------------------------------------------------------
-- ZONE DETECTION
--------------------------------------------------------------------------------

--[[
  Checks if a world position is within a wave zone's AABB bounds.
]]
local function isPositionInZone(zone: ZoneEntry, position: Vector3): boolean
  local localPos = zone.part.CFrame:PointToObjectSpace(position)
  local halfSize = zone.size / 2

  if math.abs(localPos.X) > halfSize.X then
    return false
  end
  if math.abs(localPos.Z) > halfSize.Z then
    return false
  end

  if localPos.Y < -halfSize.Y then
    return false
  end
  if localPos.Y > halfSize.Y + VERTICAL_TOLERANCE then
    return false
  end

  return true
end

--[[
  Returns the HumanoidRootPart for a player, or nil.
]]
local function getHRP(player: Player): BasePart?
  local character = player.Character
  if not character then
    return nil
  end
  return character:FindFirstChild("HumanoidRootPart")
end

--------------------------------------------------------------------------------
-- WAVE IMPACT
--------------------------------------------------------------------------------

--[[
  Checks all players against an impacting wave zone and applies effects:
  - 3.0s ragdoll
  - Push 20-25 studs inland
  - 20% held doubloons spill
  Players who are already ragdolled, in i-frames, dead, or already hit are skipped.
]]
local function applyWaveImpact(zone: ZoneEntry)
  for _, player in Players:GetPlayers() do
    if zone.hitPlayers[player] then
      continue
    end

    local hrp = getHRP(player)
    if not hrp then
      continue
    end

    if not isPositionInZone(zone, hrp.Position) then
      continue
    end

    -- Skip if player is already ragdolled
    if SessionStateService:IsRagdolling(player) then
      continue
    end

    -- Skip if player is in dash i-frames
    if SessionStateService:IsDashing(player) then
      continue
    end

    -- Skip tutorial players
    if SessionStateService:IsTutorialActive(player) then
      continue
    end

    -- Skip players in harbor (safe zone)
    if SessionStateService:IsInHarbor(player) then
      continue
    end

    -- Mark as hit for this impact
    zone.hitPlayers[player] = true

    -- Apply ragdoll
    SessionStateService:StartRagdoll(player, RAGDOLL_DURATION)

    -- Calculate push velocity: inland direction * random push distance
    local pushDist = PUSH_MIN + math.random() * (PUSH_MAX - PUSH_MIN)
    -- Strong upward component and slight lateral scatter for dramatic wave effect
    local scatterX = (math.random() - 0.5) * 6
    local scatterZ = (math.random() - 0.5) * 6
    local pushVelocity = zone.inlandDirection * pushDist * 8 + Vector3.new(scatterX, 20, scatterZ)

    -- Notify the hit player for ragdoll + push
    RogueWaveService.Client.WaveHit:Fire(player, pushVelocity, RAGDOLL_DURATION)

    -- Calculate and apply loot spill
    local heldDoubloons = SessionStateService:GetHeldDoubloons(player)
    local hasBounty = SessionStateService:HasBounty(player)
    local spillAmount = GameConfig.calculateSpill(heldDoubloons, SPILL_PERCENT, hasBounty)

    if spillAmount > 0 then
      SessionStateService:AddHeldDoubloons(player, -spillAmount)

      if DoubloonService then
        DoubloonService:ScatterDoubloons(hrp.Position, spillAmount, 6)
      end
    end

    -- Fire server-side signal
    RogueWaveService.PlayerHitByWave:Fire(player, zone.id, spillAmount)

    print(
      string.format(
        "[RogueWaveService] %s hit by rogue wave %s — ragdoll %.1fs, pushed %.0f studs, spilled %d doubloons",
        player.Name,
        zone.id,
        RAGDOLL_DURATION,
        pushDist,
        spillAmount
      )
    )
  end
end

--[[
  Displaces loose doubloon pickups in the wave zone toward the inland edge.
]]
local function displaceLoosePickups(zone: ZoneEntry)
  if not DoubloonService then
    return
  end

  local inlandEdge = zone.position + zone.inlandDirection * (zone.size.Z / 2)
  local displaced = DoubloonService:DisplacePickupsInRegion(
    zone.part.CFrame,
    zone.size,
    inlandEdge,
    10 -- scatter radius at destination
  )

  if displaced and displaced > 0 then
    print(string.format("[RogueWaveService] Displaced %d pickups in zone %s", displaced, zone.id))
  end
end

--[[
  After a wave recedes, scatter 2-3 bonus containers (Crates and Barrels) in the zone.
]]
local function spawnBonusContainers(zone: ZoneEntry)
  if not ContainerService then
    return
  end

  local count = math.random(BONUS_COUNT_MIN, BONUS_COUNT_MAX)
  local halfSize = zone.size / 2
  local containerPositions = {}

  for i = 1, count do
    -- Pick container type: 50% Crate, 35% Barrel, 15% Treasure Chest
    local roll = math.random()
    local containerType
    if roll < 0.50 then
      containerType = "crate"
    elseif roll < 0.85 then
      containerType = "barrel"
    else
      containerType = "treasure_chest"
    end

    -- Random position within the zone
    local offsetX = (math.random() - 0.5) * 2 * halfSize.X * 0.8
    local offsetZ = (math.random() - 0.5) * 2 * halfSize.Z * 0.8
    local spawnPos = zone.position
      + zone.part.CFrame:VectorToWorldSpace(Vector3.new(offsetX, 0, offsetZ))
    spawnPos = Vector3.new(spawnPos.X, zone.position.Y + halfSize.Y + 1, spawnPos.Z)

    local entry = ContainerService:SpawnContainerAt(containerType, spawnPos)
    if entry then
      table.insert(containerPositions, spawnPos)
      print(
        string.format(
          "[RogueWaveService] Bonus %s washed ashore in zone %s (wave %d/%d)",
          containerType,
          zone.id,
          i,
          count
        )
      )
    end
  end

  -- Notify all clients about bonus containers
  if #containerPositions > 0 then
    RogueWaveService.Client.BonusContainersWashedAshore:FireAll(zone.id, containerPositions)
  end
end

--------------------------------------------------------------------------------
-- WAVE PHASE CYCLING
--------------------------------------------------------------------------------

--[[
  Transitions a zone through the wave lifecycle.
  idle → warning (6s) → impact (2s) → recede (3s) → idle
]]
local function advanceWavePhase(zone: ZoneEntry)
  local oldPhase = zone.phase

  if oldPhase == "idle" then
    zone.phase = "warning"
    zone.phaseTimer = WARNING_DURATION
  elseif oldPhase == "warning" then
    zone.phase = "impact"
    zone.phaseTimer = IMPACT_DURATION
    zone.hitPlayers = {}
    applyWaveImpact(zone)
    displaceLoosePickups(zone)
  elseif oldPhase == "impact" then
    zone.phase = "recede"
    zone.phaseTimer = RECEDE_DURATION
  elseif oldPhase == "recede" then
    zone.phase = "idle"
    zone.phaseTimer = math.huge -- stays idle until next night wave trigger
    zone.hitPlayers = {}
    spawnBonusContainers(zone)
  end

  -- Notify all clients of the phase change
  RogueWaveService.Client.WavePhaseChanged:FireAll(
    zone.id,
    zone.phase,
    zone.position,
    zone.size,
    zone.inlandDirection
  )
end

--[[
  Called every Heartbeat to tick active wave zone timers.
  During impact phase, continuously checks for new players entering.
]]
local function updateZones(dt: number)
  for _, zone in Zones do
    -- Only tick zones that are in an active phase (not idle)
    if zone.phase == "idle" then
      continue
    end

    zone.phaseTimer = zone.phaseTimer - dt

    -- Continuously check for players walking into an impacting wave
    if zone.phase == "impact" and zone.phaseTimer > 0 then
      applyWaveImpact(zone)
    end

    if zone.phaseTimer <= 0 then
      advanceWavePhase(zone)
    end
  end
end

--------------------------------------------------------------------------------
-- NIGHT CYCLE MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Schedules 1-2 rogue waves for the current night cycle.
  Each wave targets a random coastline zone at a random time during the night.
]]
local function scheduleNightWaves()
  if #ZoneList == 0 then
    return
  end

  local waveCount = math.random(WAVES_PER_NIGHT_MIN, WAVES_PER_NIGHT_MAX)

  -- Get the remaining night duration so we can schedule waves within it
  local nightDuration = DayNightService:GetPhaseDuration()
  local nightElapsed = DayNightService:GetPhaseElapsed()
  local remaining = nightDuration - nightElapsed

  -- Don't schedule if less than 15 seconds remaining
  if remaining < 15 then
    return
  end

  -- Schedule waves at random times, spaced at least 15s apart
  -- Leave buffer at start (5s) and end (WARNING_DURATION + IMPACT_DURATION + RECEDE_DURATION + 5s)
  local buffer = WARNING_DURATION + IMPACT_DURATION + RECEDE_DURATION + 5
  local usableWindow = remaining - buffer - 5
  if usableWindow < 5 then
    return
  end

  -- Generate random delays within the usable window
  local delays = {}
  for _ = 1, waveCount do
    table.insert(delays, 5 + math.random() * usableWindow)
  end
  table.sort(delays)

  -- Ensure minimum 15s spacing between waves
  for i = 2, #delays do
    if delays[i] - delays[i - 1] < 15 then
      delays[i] = delays[i - 1] + 15
    end
  end

  -- Remove any waves that would exceed the window
  while #delays > 0 and delays[#delays] > remaining - buffer do
    table.remove(delays)
  end

  print(
    string.format(
      "[RogueWaveService] Scheduling %d rogue wave(s) for this night (%.0fs remaining)",
      #delays,
      remaining
    )
  )

  for i, delay in delays do
    -- Pick a random zone for each wave
    local zone = ZoneList[math.random(1, #ZoneList)]

    local thread = task.delay(delay, function()
      -- Double-check we're still in night
      if not isNightActive then
        return
      end

      -- Don't trigger if zone is already active
      if zone.phase ~= "idle" then
        return
      end

      print(
        string.format(
          "[RogueWaveService] Triggering rogue wave %d/%d on zone %s",
          i,
          #delays,
          zone.id
        )
      )

      advanceWavePhase(zone) -- idle → warning
    end)

    table.insert(scheduledWaves, thread)
  end
end

--[[
  Cancels all scheduled waves (e.g., when night ends).
]]
local function cancelScheduledWaves()
  for _, thread in scheduledWaves do
    task.cancel(thread)
  end
  table.clear(scheduledWaves)
end

--[[
  Resets any active wave zones back to idle (e.g., when night ends).
]]
local function resetActiveWaves()
  for _, zone in Zones do
    if zone.phase ~= "idle" then
      zone.phase = "idle"
      zone.phaseTimer = math.huge
      zone.hitPlayers = {}

      -- Notify clients
      RogueWaveService.Client.WavePhaseChanged:FireAll(
        zone.id,
        "idle",
        zone.position,
        zone.size,
        zone.inlandDirection
      )
    end
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the current phase states of all wave zones.
  @return Array of zone state data
]]
function RogueWaveService:GetZoneStates(): {
  {
    id: string,
    phase: string,
    position: Vector3,
    size: Vector3,
    inlandDirection: Vector3,
  }
}
  local states = {}
  for _, zone in Zones do
    table.insert(states, {
      id = zone.id,
      phase = zone.phase,
      position = zone.position,
      size = zone.size,
      inlandDirection = zone.inlandDirection,
    })
  end
  return states
end

--[[
  Returns the current zone states for a client that just joined.
  @param player The requesting player
  @return Array of zone states
]]
function RogueWaveService.Client:GetZoneStates(player: Player)
  return RogueWaveService:GetZoneStates()
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function RogueWaveService:KnitInit()
  local zoneFolder = workspace:FindFirstChild("RogueWaveZones")
  if not zoneFolder then
    warn("[RogueWaveService] No RogueWaveZones folder in workspace — rogue waves disabled")
    print("[RogueWaveService] Initialized (no zones)")
    return
  end

  -- Load zone parts
  local count = 0
  for _, child in zoneFolder:GetChildren() do
    if child:IsA("BasePart") then
      local zoneId = child.Name
      local inlandDir = child.CFrame.LookVector

      local entry: ZoneEntry = {
        id = zoneId,
        part = child,
        position = child.Position,
        size = child.Size,
        inlandDirection = Vector3.new(inlandDir.X, 0, inlandDir.Z).Unit,
        phase = "idle",
        phaseTimer = math.huge, -- stays idle until night
        hitPlayers = {},
      }
      Zones[zoneId] = entry
      table.insert(ZoneList, entry)
      count = count + 1
      print("[RogueWaveService] Loaded zone:", zoneId, "at", child.Position, "size:", child.Size)
    end
  end

  print("[RogueWaveService] Initialized —", count, "zone(s) loaded")
end

function RogueWaveService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DoubloonService = Knit.GetService("DoubloonService")
  DayNightService = Knit.GetService("DayNightService")
  ContainerService = Knit.GetService("ContainerService")

  -- Clean up player references on disconnect
  Players.PlayerRemoving:Connect(function(player)
    for _, zone in Zones do
      zone.hitPlayers[player] = nil
    end
  end)

  -- Check if we have any zones
  if #ZoneList == 0 then
    print("[RogueWaveService] Started (no zones — rogue waves inactive)")
    return
  end

  -- Listen for day/night phase changes
  DayNightService.PhaseChanged:Connect(function(newPhase: string, _previousPhase: string)
    if newPhase == "Night" then
      isNightActive = true
      scheduleNightWaves()
    else
      -- Night ended: cancel pending waves and reset active ones
      isNightActive = false
      cancelScheduledWaves()
      resetActiveWaves()
    end
  end)

  -- If server starts during night, schedule immediately
  if DayNightService:IsNight() then
    isNightActive = true
    scheduleNightWaves()
  end

  -- Run zone update loop on Heartbeat
  RunService.Heartbeat:Connect(updateZones)

  print("[RogueWaveService] Started — rogue wave system active (night-only)")
end

return RogueWaveService
