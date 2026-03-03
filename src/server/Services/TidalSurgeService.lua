--[[
  TidalSurgeService.lua
  Server-authoritative tidal surge environmental hazard system.

  Handles:
    - Loading surge zone Parts from workspace.TidalSurgeZones folder
    - Independent per-zone surge timers: randomized intervals (day 90-120s, night 45-60s)
    - Surge cycle: idle → warning (4s) → flood (5s) → recede (3s) → idle
    - Server-side player detection during flood phase
    - Hit players: 1.5s ragdoll, pushed 10-15 studs inland, 10% loot spill
    - 25% chance to reveal bonus container (Barrel or Treasure Chest) after recede
    - Displaces loose doubloon pickups in the flood zone
    - Client signals for VFX/SFX at each phase transition

  Zone Parts should be BaseParts in workspace.TidalSurgeZones.
  Each Part defines the flood area (AABB). The Part's LookVector is treated as
  the "inland" direction (direction the wave pushes players). Place the Part so
  its front face points away from the water / toward land.

  Other services can call:
    - GetZoneStates() to read all zone phase states
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local TidalSurgeService = Knit.CreateService({
  Name = "TidalSurgeService",
  Client = {
    -- Fired to ALL clients when a surge zone changes phase.
    -- Args: (zoneId: string, phase: string, zonePosition: Vector3, zoneSize: Vector3, inlandDirection: Vector3)
    --   phase: "idle" | "warning" | "flood" | "recede"
    SurgePhaseChanged = Knit.CreateSignal(),

    -- Fired to a specific player when they are hit by a surge.
    -- Args: (pushVelocity: Vector3, ragdollDuration: number)
    SurgeHit = Knit.CreateSignal(),

    -- Fired to ALL clients when a bonus container is revealed after recede.
    -- Args: (zoneId: string, containerPosition: Vector3)
    BonusContainerRevealed = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
TidalSurgeService.PlayerHitBySurge = Signal.new() -- (player: Player, zoneId: string, spillAmount: number)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DoubloonService = nil
local DayNightService = nil
local ContainerService = nil

--------------------------------------------------------------------------------
-- ZONE REGISTRY
--------------------------------------------------------------------------------

type SurgePhase = "idle" | "warning" | "flood" | "recede"

type ZoneEntry = {
  id: string,
  part: BasePart,
  position: Vector3,
  size: Vector3,
  inlandDirection: Vector3, -- unit vector pointing inland (wave push direction)
  phase: SurgePhase,
  phaseTimer: number, -- time remaining in current phase (seconds)
  hitPlayers: { [Player]: boolean }, -- tracks who was already hit this flood cycle
}

-- Active zones keyed by zone ID (Part name)
local Zones: { [string]: ZoneEntry } = {}

-- Config shortcuts
local CFG = GameConfig.TidalSurge
local WARNING_DURATION = CFG.warningDuration
local FLOOD_DURATION = CFG.floodDuration
local RECEDE_DURATION = CFG.recedeDuration
local RAGDOLL_DURATION = CFG.ragdollDuration
local SPILL_PERCENT = CFG.lootSpillPercent
local PUSH_MIN = CFG.pushDistanceMin
local PUSH_MAX = CFG.pushDistanceMax
local BONUS_CONTAINER_CHANCE = CFG.bonusContainerChance

-- Vertical tolerance: players up to this many studs above the zone surface are hit
local VERTICAL_TOLERANCE = 10

--------------------------------------------------------------------------------
-- ZONE DETECTION
--------------------------------------------------------------------------------

--[[
  Checks if a world position is within a surge zone's AABB bounds.
  @param zone The zone entry
  @param position World position to check
  @return true if the position is inside the zone
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

  -- Player should be near/above the zone surface, not far below or above
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
-- SURGE INTERVAL
--------------------------------------------------------------------------------

--[[
  Returns a randomized idle duration based on current day/night phase.
  Day: 90-120s, Night: 45-60s.
]]
local function getNextIdleDuration(): number
  local isNight = DayNightService and DayNightService:IsNight()
  if isNight then
    return CFG.nightIntervalMin + math.random() * (CFG.nightIntervalMax - CFG.nightIntervalMin)
  else
    return CFG.dayIntervalMin + math.random() * (CFG.dayIntervalMax - CFG.dayIntervalMin)
  end
end

--------------------------------------------------------------------------------
-- FLOOD DAMAGE
--------------------------------------------------------------------------------

--[[
  Checks all players against a flooding zone and applies effects:
  - 1.5s ragdoll
  - Push 10-15 studs inland
  - 10% held doubloons spill
  Players who are already ragdolled, in i-frames, dead, or already hit this cycle are skipped.
]]
local function applyFloodDamage(zone: ZoneEntry)
  for _, player in Players:GetPlayers() do
    -- Skip if already hit this flood cycle
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

    -- Mark as hit for this flood cycle
    zone.hitPlayers[player] = true

    -- Apply ragdoll
    SessionStateService:StartRagdoll(player, RAGDOLL_DURATION)

    -- Calculate push velocity: inland direction * random push distance
    local pushDist = PUSH_MIN + math.random() * (PUSH_MAX - PUSH_MIN)
    -- Add slight upward component so player gets lifted, plus small random lateral scatter
    local scatterX = (math.random() - 0.5) * 4
    local scatterZ = (math.random() - 0.5) * 4
    local pushVelocity = zone.inlandDirection * pushDist * 8 -- multiply for impulse strength
      + Vector3.new(scatterX, 15, scatterZ)

    -- Notify the hit player for ragdoll + push
    TidalSurgeService.Client.SurgeHit:Fire(player, pushVelocity, RAGDOLL_DURATION)

    -- Calculate and apply loot spill
    local heldDoubloons = SessionStateService:GetHeldDoubloons(player)
    local hasBounty = SessionStateService:HasBounty(player)
    local spillAmount = GameConfig.calculateSpill(heldDoubloons, SPILL_PERCENT, hasBounty)

    if spillAmount > 0 then
      SessionStateService:AddHeldDoubloons(player, -spillAmount)

      if DoubloonService then
        DoubloonService:ScatterDoubloons(hrp.Position, spillAmount, 5)
      end
    end

    -- Fire server-side signal
    TidalSurgeService.PlayerHitBySurge:Fire(player, zone.id, spillAmount)

    print(
      string.format(
        "[TidalSurgeService] %s hit by surge %s — ragdoll %.1fs, pushed %.0f studs, spilled %d doubloons",
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
  Displaces loose doubloon pickups in the flood zone by removing and re-scattering
  them at the inland edge of the zone.
]]
local function displaceLoosePickups(zone: ZoneEntry)
  if not DoubloonService then
    return
  end

  -- Use the DoubloonService API to find and displace pickups in this zone
  -- We push them toward the inland edge
  local inlandEdge = zone.position + zone.inlandDirection * (zone.size.Z / 2)
  local displaced = DoubloonService:DisplacePickupsInRegion(
    zone.part.CFrame,
    zone.size,
    inlandEdge,
    8 -- scatter radius at destination
  )

  if displaced and displaced > 0 then
    print(string.format("[TidalSurgeService] Displaced %d pickups in zone %s", displaced, zone.id))
  end
end

--[[
  After a surge recedes, there's a 25% chance to reveal a bonus container
  (Barrel or Treasure Chest) in the wet sand area.
]]
local function trySpawnBonusContainer(zone: ZoneEntry)
  if math.random() > BONUS_CONTAINER_CHANCE then
    return
  end

  if not ContainerService then
    return
  end

  -- Pick container type: 60% Barrel, 40% Treasure Chest
  local containerType = "barrel"
  if math.random() < 0.4 then
    containerType = "treasure_chest"
  end

  -- Spawn at a random position within the zone
  local halfSize = zone.size / 2
  local offsetX = (math.random() - 0.5) * 2 * halfSize.X * 0.8
  local offsetZ = (math.random() - 0.5) * 2 * halfSize.Z * 0.8
  local spawnPos = zone.position
    + zone.part.CFrame:VectorToWorldSpace(Vector3.new(offsetX, 0, offsetZ))
  -- Ensure container spawns at ground level
  spawnPos = Vector3.new(spawnPos.X, zone.position.Y + halfSize.Y + 1, spawnPos.Z)

  local entry = ContainerService:SpawnContainerAt(containerType, spawnPos)
  if entry then
    -- Notify all clients about the bonus container
    TidalSurgeService.Client.BonusContainerRevealed:FireAll(zone.id, spawnPos)
    print(string.format("[TidalSurgeService] Bonus %s revealed in zone %s", containerType, zone.id))
  end
end

--------------------------------------------------------------------------------
-- SURGE PHASE CYCLING
--------------------------------------------------------------------------------

--[[
  Transitions a zone to the next phase in the cycle.
  idle → warning → flood → recede → idle
]]
local function advanceZonePhase(zone: ZoneEntry)
  local oldPhase = zone.phase

  if oldPhase == "idle" then
    zone.phase = "warning"
    zone.phaseTimer = WARNING_DURATION
  elseif oldPhase == "warning" then
    zone.phase = "flood"
    zone.phaseTimer = FLOOD_DURATION
    zone.hitPlayers = {} -- reset hit tracking for new flood
    -- Check for players at flood start
    applyFloodDamage(zone)
    -- Displace loose pickups
    displaceLoosePickups(zone)
  elseif oldPhase == "flood" then
    zone.phase = "recede"
    zone.phaseTimer = RECEDE_DURATION
  elseif oldPhase == "recede" then
    zone.phase = "idle"
    zone.phaseTimer = getNextIdleDuration()
    zone.hitPlayers = {}
    -- Chance to reveal bonus container
    trySpawnBonusContainer(zone)
  end

  -- Notify all clients of the phase change
  TidalSurgeService.Client.SurgePhaseChanged:FireAll(
    zone.id,
    zone.phase,
    zone.position,
    zone.size,
    zone.inlandDirection
  )
end

--[[
  Called every Heartbeat to tick all zone timers.
  During flood phase, continuously checks for new players entering.
]]
local function updateZones(dt: number)
  for _, zone in Zones do
    zone.phaseTimer = zone.phaseTimer - dt

    -- Continuously check for players walking into a flooding zone
    if zone.phase == "flood" and zone.phaseTimer > 0 then
      applyFloodDamage(zone)
    end

    if zone.phaseTimer <= 0 then
      advanceZonePhase(zone)
    end
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the current phase states of all surge zones.
  @return Array of zone state data
]]
function TidalSurgeService:GetZoneStates(): {
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
function TidalSurgeService.Client:GetZoneStates(player: Player)
  return TidalSurgeService:GetZoneStates()
end

--[[
  Checks if a world position is inside any surge zone.
  @param position World position to check
  @return boolean
]]
function TidalSurgeService:IsPositionInSurgeZone(position: Vector3): boolean
  for _, zone in Zones do
    if isPositionInZone(zone, position) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function TidalSurgeService:KnitInit()
  local zoneFolder = workspace:FindFirstChild("TidalSurgeZones")
  if not zoneFolder then
    warn("[TidalSurgeService] No TidalSurgeZones folder in workspace — surges disabled")
    print("[TidalSurgeService] Initialized (no zones)")
    return
  end

  -- Load zone parts
  local count = 0
  for _, child in zoneFolder:GetChildren() do
    if child:IsA("BasePart") then
      local zoneId = child.Name
      -- Use the Part's LookVector as the inland direction
      local inlandDir = child.CFrame.LookVector
      -- Stagger initial idle timers so zones don't all surge at once
      local initialTimer = 15 + math.random() * 30

      Zones[zoneId] = {
        id = zoneId,
        part = child,
        position = child.Position,
        size = child.Size,
        inlandDirection = Vector3.new(inlandDir.X, 0, inlandDir.Z).Unit,
        phase = "idle",
        phaseTimer = initialTimer,
        hitPlayers = {},
      }
      count = count + 1
      print(
        "[TidalSurgeService] Loaded zone:",
        zoneId,
        "at",
        child.Position,
        "size:",
        child.Size,
        "inland:",
        inlandDir
      )
    end
  end

  print("[TidalSurgeService] Initialized —", count, "zone(s) loaded")
end

function TidalSurgeService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DoubloonService = Knit.GetService("DoubloonService")
  DayNightService = Knit.GetService("DayNightService")

  ContainerService = Knit.GetService("ContainerService")

  -- Clean up player references from hitPlayers on disconnect
  Players.PlayerRemoving:Connect(function(player)
    for _, zone in Zones do
      zone.hitPlayers[player] = nil
    end
  end)

  -- Check if we have any zones
  local hasZones = false
  for _ in Zones do
    hasZones = true
    break
  end

  if not hasZones then
    print("[TidalSurgeService] Started (no zones — surges inactive)")
    return
  end

  -- Run zone update loop on Heartbeat
  RunService.Heartbeat:Connect(updateZones)

  print("[TidalSurgeService] Started — surge cycling active")
end

return TidalSurgeService
