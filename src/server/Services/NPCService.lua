--[[
  NPCService.lua
  Server-authoritative NPC management service.

  Handles:
    - Cursed Skeleton entity creation with Humanoid, HP, and stats
    - Ghost Pirate entity creation (NPC-007): semi-transparent, spectral slash, night-only
    - NPC AI state machine: Idle → Patrol → Chase → Attack → Flinch → Dead
    - Skeleton slash attack (0.8s windup, 8 stud range, 2s cooldown)
    - Skeleton lunge attack (0.5s crouch telegraph, 6 stud dash + slash, 5s cooldown)
    - Ghost Pirate spectral slash (0.6s windup, 8 stud range, 2.5s cooldown, 15% spill)
    - Ghost Pirate materialization (flash VFX + screech SFX on aggro)
    - NPC hit reception: flinch (0.2s pause), death (loot drop), respawn (90s)
    - Hit detection against players: ragdoll + loot spill (type-specific values)
    - SimplePath-based patrol: walk between zone waypoints using PathfindingService
    - SimplePath-based chase: 0.3s path recalculation, leash, stuck detection, Harbor boundary stop
    - Respawn management per zone

  Spawn Manager (NPC-006):
    - Budget-driven spawning: 6-10 Cursed Skeletons during day
    - Night scaling: skeleton count ×1.5, Ghost Pirates 4-6
    - Dawn cleanup: despawn Ghost Pirates (drop loot), reduce skeleton budget
    - Budget-aware respawning: only respawn if under current budget
    - Bonus threat NPCs (ThreatEffectsService) are separate from budget

  NPC spawn points are defined as Parts in workspace.NPCSpawnPoints.
  Each spawn point Part can have:
    - Attribute "Zone" (string): zone name (e.g., "jungle", "beach", "danger")
    - Attribute "NPCType" (string): which NPC type spawns here (default "skeleton")

  Patrol waypoints are read from workspace.PatrolWaypoints.
  Each child Part must have:
    - Attribute "Zone" (string): which zone this waypoint belongs to
    - Attribute "Order" (number, optional): ordering hint (lower = first)
  If no PatrolWaypoints folder exists, spawn points of the same zone are used
  as patrol destinations. If a zone has <2 waypoints, random positions around
  spawn are generated via SimplePath for obstacle avoidance.

  Other services call:
    - DamageNPC(npcId, damage, attackingPlayer) to deal damage
    - GetNPCByPart(part) to find an NPC from a hit part
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local SimplePath = require(Shared:WaitForChild("SimplePath"))

local NPCService = Knit.CreateService({
  Name = "NPCService",
  Client = {
    -- Fired to ALL players when an NPC spawns.
    -- Args: (npcId: number, npcType: string, position: Vector3)
    NPCSpawned = Knit.CreateSignal(),
    -- Fired to ALL players when an NPC takes damage.
    -- Args: (npcId: number, hpFraction: number)
    NPCDamaged = Knit.CreateSignal(),
    -- Fired to ALL players when an NPC dies.
    -- Args: (npcId: number, npcType: string, position: Vector3)
    NPCDied = Knit.CreateSignal(),
    -- Fired to ALL players when an NPC attacks (for VFX/SFX).
    -- Args: (npcId: number, attackType: string, targetPosition: Vector3?)
    NPCAttack = Knit.CreateSignal(),
    -- Fired to ALL players when an NPC flinches (for VFX).
    -- Args: (npcId: number)
    NPCFlinch = Knit.CreateSignal(),
    -- Fired to ALL players when an NPC teleports (stuck detection poof VFX).
    -- Args: (npcId: number, fromPosition: Vector3, toPosition: Vector3)
    NPCTeleported = Knit.CreateSignal(),
    -- Fired to ALL players when a Ghost Pirate materializes (enters chase).
    -- Args: (npcId: number, position: Vector3)
    GhostPirateMaterialized = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
NPCService.NPCDied = Signal.new() -- (npcEntry, killedByPlayer)
NPCService.NPCDamaged = Signal.new() -- (npcEntry, damage, attackingPlayer)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DoubloonService = nil
local ThreatService = nil
local DayNightService = nil
local HarborService = nil
local ThreatEffectsService = nil

--------------------------------------------------------------------------------
-- NPC TYPES & CONSTANTS
--------------------------------------------------------------------------------

-- AI states
local AI_STATE = {
  IDLE = "idle",
  PATROL = "patrol",
  CHASE = "chase",
  ATTACK_SLASH = "attack_slash",
  ATTACK_LUNGE = "attack_lunge",
  FLINCH = "flinch",
  DEAD = "dead",
}

-- Player base walk speed (Roblox default)
local PLAYER_BASE_SPEED = 16

-- NPC config shorthand
local SKELETON = GameConfig.CursedSkeleton
local GHOST_PIRATE = GameConfig.GhostPirate
local NPC_BEHAVIOR = GameConfig.NPCBehavior

--[[
  Returns the NPC config table for a given NPC type.
  Allows shared AI logic to read type-appropriate values.
]]
local function getNPCConfig(npcType: string)
  if npcType == "ghost_pirate" then
    return GHOST_PIRATE
  end
  return SKELETON
end

--------------------------------------------------------------------------------
-- NPC REGISTRY
--------------------------------------------------------------------------------

type NPCEntry = {
  id: number,
  npcType: string,
  hp: number,
  maxHp: number,
  model: Model,
  humanoid: Humanoid,
  rootPart: BasePart,
  position: Vector3,
  spawnPosition: Vector3,
  spawnPoint: Part?,
  zone: string,

  -- AI state
  aiState: string,
  aiStateStartTime: number,
  targetPlayer: Player?,
  lastSlashTime: number,
  lastLungeTime: number,
  lastPatrolMoveTime: number, -- timestamp of last patrol waypoint arrival
  patrolTarget: Vector3?, -- legacy fallback (unused when SimplePath is active)
  carriedDoubloons: number,

  -- SimplePath patrol (NPC-003) and chase (NPC-004)
  simplePath: any?, -- SimplePath instance for this NPC
  patrolWaypoints: { Vector3 }, -- ordered list of patrol waypoints for this NPC's zone
  patrolWaypointIndex: number, -- current index in patrolWaypoints (loops)

  -- SimplePath chase tracking (NPC-004)
  lastChaseRecalcTime: number, -- last time SimplePath:Run() was called during chase
  chaseStuckPos: Vector3?, -- position at start of stuck check window
  chaseStuckTime: number, -- time when stuck check started
  harborWaitStart: number?, -- if non-nil, NPC is waiting at Harbor boundary

  -- Flinch tracking
  flinchEndTime: number,

  -- Lunge tracking
  lungeTarget: Vector3?,
  lungeStartTime: number,

  -- Respawn
  respawnTime: number?,
  alive: boolean,

  -- Threat effects (bonus NPCs)
  forcedTarget: Player?, -- if set, this NPC always chases this player
  isBonusNPC: boolean, -- true if spawned by ThreatEffectsService (not from normal budget)
}

local ActiveNPCs: { [number]: NPCEntry } = {}
local ActiveNPCCount = 0
local nextNPCId = 1

-- Folder in workspace for NPC models
local NPCsFolder: Folder = nil

-- Spawn points folder
local SpawnPointsFolder: Folder? = nil

-- Respawn queue entries: { spawnTime, spawnPosition, zone, spawnPoint?, npcType }
local RespawnQueue = {} :: any

--------------------------------------------------------------------------------
-- SPAWN BUDGET (NPC-006)
--------------------------------------------------------------------------------

-- Current target counts per NPC type (adjusted on phase transitions)
local SkeletonBudget = 0
local GhostPirateBudget = 0

-- Cached spawn point lists by NPC type
local SkeletonSpawnPoints: { BasePart } = {}
local GhostPirateSpawnPoints: { BasePart } = {}

-- Track which spawn points are currently occupied by a living budget NPC
local OccupiedSpawnPoints: { [BasePart]: number } = {} -- spawnPoint → npcId

-- Count budget NPCs (excludes bonus NPCs from ThreatEffectsService)
local BudgetSkeletonCount = 0
local BudgetGhostPirateCount = 0

-- Track all Ghost Pirate NPC IDs for Dawn despawn
local GhostPirateNPCIds: { [number]: boolean } = {}

-- Patrol waypoints per zone (NPC-003)
-- Key: zone name, Value: ordered list of Vector3 positions
local ZonePatrolWaypoints: { [string]: { Vector3 } } = {}

-- SimplePath agent params from config
local AGENT_PARAMS = {
  AgentRadius = NPC_BEHAVIOR.agentRadius,
  AgentHeight = NPC_BEHAVIOR.agentHeight,
  AgentCanJump = NPC_BEHAVIOR.agentCanJump,
}

--[[
  Picks a random skeleton budget target for the current phase.
]]
local function rollDaySkeletonBudget(): number
  return math.random(SKELETON.dayCountMin, SKELETON.dayCountMax)
end

--[[
  Returns the night skeleton budget based on day budget.
]]
local function getNightSkeletonBudget(dayBudget: number): number
  return math.ceil(dayBudget * SKELETON.nightCountMultiplier)
end

--[[
  Picks a random ghost pirate budget for night.
]]
local function rollNightGhostPirateBudget(): number
  return math.random(GameConfig.GhostPirate.nightCountMin, GameConfig.GhostPirate.nightCountMax)
end

--[[
  Returns an available (unoccupied) spawn point from the given list,
  or nil if all are occupied. Prefers spawn points far from existing NPCs.
]]
local function pickAvailableSpawnPoint(spawnPoints: { BasePart }): BasePart?
  -- Gather unoccupied points
  local available: { BasePart } = {}
  for _, point in spawnPoints do
    if not OccupiedSpawnPoints[point] then
      table.insert(available, point)
    end
  end

  if #available == 0 then
    return nil
  end

  -- Pick a random one from available
  return available[math.random(1, #available)]
end

--[[
  Spawns skeletons to fill the current budget, using available spawn points.
  Returns the number of NPCs spawned.
]]
local function fillSkeletonBudget(): number
  local spawned = 0
  while BudgetSkeletonCount < SkeletonBudget do
    local point = pickAvailableSpawnPoint(SkeletonSpawnPoints)
    if not point then
      -- No available spawn points, spawn at a random offset from an existing point
      if #SkeletonSpawnPoints > 0 then
        local randomPoint = SkeletonSpawnPoints[math.random(1, #SkeletonSpawnPoints)]
        local zone = randomPoint:GetAttribute("Zone") or "unknown"
        local offset = randomPositionAround(randomPoint.Position, 10)
        local entry = spawnSkeleton(offset, zone, nil)
        if entry then
          spawned = spawned + 1
        end
      else
        break
      end
    else
      local zone = point:GetAttribute("Zone") or "unknown"
      local entry = spawnSkeleton(point.Position, zone, point)
      if entry then
        OccupiedSpawnPoints[point] = entry.id
        spawned = spawned + 1
      end
    end
  end
  return spawned
end

--[[
  Spawns Ghost Pirates to fill the current budget, using available spawn points.
  Returns the number of NPCs spawned.
]]
local function fillGhostPirateBudget(): number
  local spawned = 0
  while BudgetGhostPirateCount < GhostPirateBudget do
    local point = pickAvailableSpawnPoint(GhostPirateSpawnPoints)
    if not point then
      -- No available spawn points, spawn at a random offset from an existing point
      if #GhostPirateSpawnPoints > 0 then
        local randomPoint = GhostPirateSpawnPoints[math.random(1, #GhostPirateSpawnPoints)]
        local zone = randomPoint:GetAttribute("Zone") or "unknown"
        local offset = randomPositionAround(randomPoint.Position, 10)
        local entry = spawnGhostPirate(offset, zone, nil)
        if entry then
          spawned = spawned + 1
        end
      else
        break
      end
    else
      local zone = point:GetAttribute("Zone") or "unknown"
      local entry = spawnGhostPirate(point.Position, zone, point)
      if entry then
        OccupiedSpawnPoints[point] = entry.id
        spawned = spawned + 1
      end
    end
  end
  return spawned
end

--[[
  Despawns excess skeletons to bring count down to budget.
  Prefers despawning NPCs furthest from any player.
]]
local function trimSkeletonBudget()
  while BudgetSkeletonCount > SkeletonBudget do
    -- Find the budget skeleton furthest from any player
    local furthestId: number? = nil
    local furthestDist = -1

    for id, entry in ActiveNPCs do
      if entry.alive and entry.npcType == "skeleton" and not entry.isBonusNPC then
        local minPlayerDist = math.huge
        for _, player in Players:GetPlayers() do
          local hrp = getPlayerHRP(player)
          if hrp then
            local dist = (entry.position - hrp.Position).Magnitude
            if dist < minPlayerDist then
              minPlayerDist = dist
            end
          end
        end
        if minPlayerDist > furthestDist then
          furthestDist = minPlayerDist
          furthestId = id
        end
      end
    end

    if furthestId then
      local entry = ActiveNPCs[furthestId]
      if entry and entry.spawnPoint then
        OccupiedSpawnPoints[entry.spawnPoint] = nil
      end
      despawnNPC(furthestId)
    else
      break
    end
  end
end

--[[
  Despawns all Ghost Pirate NPCs (called at Dawn).
  Drops their carried doubloons at death position.
]]
local function despawnAllGhostPirates()
  local despawned = 0
  for npcId in GhostPirateNPCIds do
    local entry = ActiveNPCs[npcId]
    if entry and entry.alive then
      -- Drop carried loot
      if entry.carriedDoubloons > 0 and DoubloonService then
        DoubloonService:ScatterDoubloons(entry.position, entry.carriedDoubloons, 4)
      end

      entry.alive = false
      setState(entry, AI_STATE.DEAD)
      NPCService.Client.NPCDied:FireAll(npcId, entry.npcType, entry.position)

      if entry.spawnPoint then
        OccupiedSpawnPoints[entry.spawnPoint] = nil
      end

      task.delay(1, function()
        despawnNPC(npcId)
      end)
      despawned = despawned + 1
    end
  end
  GhostPirateNPCIds = {}
  BudgetGhostPirateCount = 0

  if despawned > 0 then
    print(string.format("[NPCService] Dawn: despawned %d Ghost Pirates", despawned))
  end
end

--[[
  Handles phase transitions for spawn budget management.
  Called by DayNightService.PhaseChanged signal.
]]
local function onPhaseChanged(newPhase: string, _previousPhase: string)
  if newPhase == "Night" or newPhase == "Dusk" then
    -- Scale up skeleton budget for night
    local dayBudget = rollDaySkeletonBudget()
    SkeletonBudget = getNightSkeletonBudget(dayBudget)
    GhostPirateBudget = rollNightGhostPirateBudget()

    local skeletonsFilled = fillSkeletonBudget()
    local ghostPiratesFilled = fillGhostPirateBudget()

    print(
      string.format(
        "[NPCService] Night budget: %d skeletons (spawned %d new), %d ghost pirates (spawned %d)",
        SkeletonBudget,
        skeletonsFilled,
        GhostPirateBudget,
        ghostPiratesFilled
      )
    )
  elseif newPhase == "Dawn" or newPhase == "Day" then
    -- Despawn all Ghost Pirates at Dawn
    despawnAllGhostPirates()

    -- Reduce skeleton budget back to day level
    SkeletonBudget = rollDaySkeletonBudget()
    GhostPirateBudget = 0

    -- Trim excess skeletons if we're over the day budget
    trimSkeletonBudget()

    print(
      string.format(
        "[NPCService] Day budget: %d skeletons (active: %d)",
        SkeletonBudget,
        BudgetSkeletonCount
      )
    )
  end
end

--------------------------------------------------------------------------------
-- NPC MODEL CREATION
--------------------------------------------------------------------------------

--[[
  Creates a Cursed Skeleton NPC model at the given position.
  Uses a Humanoid with configured HP and speed. Placeholder R15-style appearance.
  @param position World position
  @param npcId Unique NPC ID
  @return The created Model, Humanoid, and HumanoidRootPart
]]
local function createSkeletonModel(position: Vector3, npcId: number): (Model, Humanoid, BasePart)
  local model = Instance.new("Model")
  model.Name = "CursedSkeleton_" .. tostring(npcId)

  -- Create a simple NPC using a Humanoid (placeholder body)
  -- Torso/root part
  local rootPart = Instance.new("Part")
  rootPart.Name = "HumanoidRootPart"
  rootPart.Size = Vector3.new(2, 2, 1)
  rootPart.Transparency = 1
  rootPart.CanCollide = false
  rootPart.Anchored = false
  rootPart.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
  rootPart.Parent = model

  local torso = Instance.new("Part")
  torso.Name = "Torso"
  torso.Size = Vector3.new(2, 2, 1)
  torso.Color = Color3.fromRGB(180, 170, 140) -- bone color
  torso.Material = Enum.Material.SmoothPlastic
  torso.CanCollide = false
  torso.Anchored = false
  torso.CFrame = rootPart.CFrame
  torso.Parent = model

  -- Weld torso to root
  local torsoWeld = Instance.new("Weld")
  torsoWeld.Part0 = rootPart
  torsoWeld.Part1 = torso
  torsoWeld.C0 = CFrame.new()
  torsoWeld.Parent = rootPart

  -- Head
  local head = Instance.new("Part")
  head.Name = "Head"
  head.Shape = Enum.PartType.Ball
  head.Size = Vector3.new(1.2, 1.2, 1.2)
  head.Color = Color3.fromRGB(200, 190, 160) -- skull color
  head.Material = Enum.Material.SmoothPlastic
  head.CanCollide = false
  head.Anchored = false
  head.CFrame = rootPart.CFrame * CFrame.new(0, 1.6, 0)
  head.Parent = model

  local headWeld = Instance.new("Weld")
  headWeld.Part0 = torso
  headWeld.Part1 = head
  headWeld.C0 = CFrame.new(0, 1.6, 0)
  headWeld.Parent = torso

  -- Left arm
  local leftArm = Instance.new("Part")
  leftArm.Name = "Left Arm"
  leftArm.Size = Vector3.new(0.6, 2, 0.6)
  leftArm.Color = Color3.fromRGB(180, 170, 140)
  leftArm.Material = Enum.Material.SmoothPlastic
  leftArm.CanCollide = false
  leftArm.Anchored = false
  leftArm.Parent = model

  local leftArmWeld = Instance.new("Weld")
  leftArmWeld.Part0 = torso
  leftArmWeld.Part1 = leftArm
  leftArmWeld.C0 = CFrame.new(-1.3, 0, 0)
  leftArmWeld.Parent = torso

  -- Right arm (holds cutlass)
  local rightArm = Instance.new("Part")
  rightArm.Name = "Right Arm"
  rightArm.Size = Vector3.new(0.6, 2, 0.6)
  rightArm.Color = Color3.fromRGB(180, 170, 140)
  rightArm.Material = Enum.Material.SmoothPlastic
  rightArm.CanCollide = false
  rightArm.Anchored = false
  rightArm.Parent = model

  local rightArmWeld = Instance.new("Weld")
  rightArmWeld.Part0 = torso
  rightArmWeld.Part1 = rightArm
  rightArmWeld.C0 = CFrame.new(1.3, 0, 0)
  rightArmWeld.Parent = torso

  -- Left leg
  local leftLeg = Instance.new("Part")
  leftLeg.Name = "Left Leg"
  leftLeg.Size = Vector3.new(0.8, 2, 0.8)
  leftLeg.Color = Color3.fromRGB(170, 160, 130)
  leftLeg.Material = Enum.Material.SmoothPlastic
  leftLeg.CanCollide = false
  leftLeg.Anchored = false
  leftLeg.Parent = model

  local leftLegWeld = Instance.new("Weld")
  leftLegWeld.Part0 = torso
  leftLegWeld.Part1 = leftLeg
  leftLegWeld.C0 = CFrame.new(-0.5, -2, 0)
  leftLegWeld.Parent = torso

  -- Right leg
  local rightLeg = Instance.new("Part")
  rightLeg.Name = "Right Leg"
  rightLeg.Size = Vector3.new(0.8, 2, 0.8)
  rightLeg.Color = Color3.fromRGB(170, 160, 130)
  rightLeg.Material = Enum.Material.SmoothPlastic
  rightLeg.CanCollide = false
  rightLeg.Anchored = false
  rightLeg.Parent = model

  local rightLegWeld = Instance.new("Weld")
  rightLegWeld.Part0 = torso
  rightLegWeld.Part1 = rightLeg
  rightLegWeld.C0 = CFrame.new(0.5, -2, 0)
  rightLegWeld.Parent = torso

  -- Cutlass weapon (attached to right arm)
  local cutlass = Instance.new("Part")
  cutlass.Name = "Cutlass"
  cutlass.Size = Vector3.new(0.2, 3, 0.4)
  cutlass.Color = Color3.fromRGB(160, 160, 170) -- steel color
  cutlass.Material = Enum.Material.Metal
  cutlass.CanCollide = false
  cutlass.Anchored = false
  cutlass.Parent = model

  local cutlassWeld = Instance.new("Weld")
  cutlassWeld.Part0 = rightArm
  cutlassWeld.Part1 = cutlass
  cutlassWeld.C0 = CFrame.new(0, -1.5, 0) * CFrame.Angles(0, 0, math.rad(15))
  cutlassWeld.Parent = rightArm

  -- Eerie eye glow
  local eyeGlow = Instance.new("PointLight")
  eyeGlow.Color = Color3.fromRGB(120, 255, 80) -- green skeleton eyes
  eyeGlow.Brightness = 0.8
  eyeGlow.Range = 5
  eyeGlow.Parent = head

  -- Humanoid
  local humanoid = Instance.new("Humanoid")
  humanoid.MaxHealth = SKELETON.hp
  humanoid.Health = SKELETON.hp
  humanoid.WalkSpeed = PLAYER_BASE_SPEED * SKELETON.speedMultiplier
  humanoid.JumpPower = 50 -- Needed for SimplePath pathfinding (NPC-003)
  humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
  humanoid.HealthDisplayDistance = 30
  humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
  humanoid.NameDisplayDistance = 40
  humanoid.DisplayName = "Cursed Skeleton"
  humanoid.Parent = model

  model.PrimaryPart = rootPart

  -- Store metadata as attributes for hit detection
  rootPart:SetAttribute("NPCId", npcId)
  rootPart:SetAttribute("NPCType", "skeleton")
  torso:SetAttribute("NPCId", npcId)
  torso:SetAttribute("NPCType", "skeleton")
  head:SetAttribute("NPCId", npcId)
  head:SetAttribute("NPCType", "skeleton")

  model.Parent = NPCsFolder
  return model, humanoid, rootPart
end

--[[
  Creates a Ghost Pirate NPC model at the given position.
  Spectral/translucent appearance with ghostly glow. Semi-transparent by default.
  @param position World position
  @param npcId Unique NPC ID
  @return The created Model, Humanoid, and HumanoidRootPart
]]
local function createGhostPirateModel(position: Vector3, npcId: number): (Model, Humanoid, BasePart)
  local model = Instance.new("Model")
  model.Name = "GhostPirate_" .. tostring(npcId)

  -- Root part
  local rootPart = Instance.new("Part")
  rootPart.Name = "HumanoidRootPart"
  rootPart.Size = Vector3.new(2, 2, 1)
  rootPart.Transparency = 1
  rootPart.CanCollide = false
  rootPart.Anchored = false
  rootPart.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
  rootPart.Parent = model

  -- Spectral torso
  local torso = Instance.new("Part")
  torso.Name = "Torso"
  torso.Size = Vector3.new(2, 2, 1)
  torso.Color = Color3.fromRGB(100, 180, 200) -- spectral teal
  torso.Material = Enum.Material.Neon
  torso.Transparency = 0.4
  torso.CanCollide = false
  torso.Anchored = false
  torso.CFrame = rootPart.CFrame
  torso.Parent = model

  local torsoWeld = Instance.new("Weld")
  torsoWeld.Part0 = rootPart
  torsoWeld.Part1 = torso
  torsoWeld.C0 = CFrame.new()
  torsoWeld.Parent = rootPart

  -- Ghost pirate glow particle emitter on torso
  local ghostGlow = Instance.new("ParticleEmitter")
  ghostGlow.Name = "GhostGlow"
  ghostGlow.Color = ColorSequence.new(Color3.fromRGB(120, 200, 220))
  ghostGlow.Size =
    NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
  ghostGlow.Transparency =
    NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
  ghostGlow.Lifetime = NumberRange.new(0.5, 1.0)
  ghostGlow.Rate = 15
  ghostGlow.Speed = NumberRange.new(0.5, 1.5)
  ghostGlow.SpreadAngle = Vector2.new(180, 180)
  ghostGlow.LightEmission = 1
  ghostGlow.Parent = torso

  -- Spectral head
  local head = Instance.new("Part")
  head.Name = "Head"
  head.Shape = Enum.PartType.Ball
  head.Size = Vector3.new(1.2, 1.2, 1.2)
  head.Color = Color3.fromRGB(120, 200, 220) -- lighter spectral
  head.Material = Enum.Material.Neon
  head.Transparency = 0.3
  head.CanCollide = false
  head.Anchored = false
  head.CFrame = rootPart.CFrame * CFrame.new(0, 1.6, 0)
  head.Parent = model

  local headWeld = Instance.new("Weld")
  headWeld.Part0 = torso
  headWeld.Part1 = head
  headWeld.C0 = CFrame.new(0, 1.6, 0)
  headWeld.Parent = torso

  -- Left arm
  local leftArm = Instance.new("Part")
  leftArm.Name = "Left Arm"
  leftArm.Size = Vector3.new(0.6, 2, 0.6)
  leftArm.Color = Color3.fromRGB(100, 180, 200)
  leftArm.Material = Enum.Material.Neon
  leftArm.Transparency = 0.5
  leftArm.CanCollide = false
  leftArm.Anchored = false
  leftArm.Parent = model

  local leftArmWeld = Instance.new("Weld")
  leftArmWeld.Part0 = torso
  leftArmWeld.Part1 = leftArm
  leftArmWeld.C0 = CFrame.new(-1.3, 0, 0)
  leftArmWeld.Parent = torso

  -- Right arm (spectral claw)
  local rightArm = Instance.new("Part")
  rightArm.Name = "Right Arm"
  rightArm.Size = Vector3.new(0.6, 2, 0.6)
  rightArm.Color = Color3.fromRGB(100, 180, 200)
  rightArm.Material = Enum.Material.Neon
  rightArm.Transparency = 0.5
  rightArm.CanCollide = false
  rightArm.Anchored = false
  rightArm.Parent = model

  local rightArmWeld = Instance.new("Weld")
  rightArmWeld.Part0 = torso
  rightArmWeld.Part1 = rightArm
  rightArmWeld.C0 = CFrame.new(1.3, 0, 0)
  rightArmWeld.Parent = torso

  -- Left leg (fading into mist below)
  local leftLeg = Instance.new("Part")
  leftLeg.Name = "Left Leg"
  leftLeg.Size = Vector3.new(0.8, 2, 0.8)
  leftLeg.Color = Color3.fromRGB(80, 150, 170)
  leftLeg.Material = Enum.Material.Neon
  leftLeg.Transparency = 0.6
  leftLeg.CanCollide = false
  leftLeg.Anchored = false
  leftLeg.Parent = model

  local leftLegWeld = Instance.new("Weld")
  leftLegWeld.Part0 = torso
  leftLegWeld.Part1 = leftLeg
  leftLegWeld.C0 = CFrame.new(-0.5, -2, 0)
  leftLegWeld.Parent = torso

  -- Right leg
  local rightLeg = Instance.new("Part")
  rightLeg.Name = "Right Leg"
  rightLeg.Size = Vector3.new(0.8, 2, 0.8)
  rightLeg.Color = Color3.fromRGB(80, 150, 170)
  rightLeg.Material = Enum.Material.Neon
  rightLeg.Transparency = 0.6
  rightLeg.CanCollide = false
  rightLeg.Anchored = false
  rightLeg.Parent = model

  local rightLegWeld = Instance.new("Weld")
  rightLegWeld.Part0 = torso
  rightLegWeld.Part1 = rightLeg
  rightLegWeld.C0 = CFrame.new(0.5, -2, 0)
  rightLegWeld.Parent = torso

  -- Eerie ghost eye glow (cyan)
  local eyeGlow = Instance.new("PointLight")
  eyeGlow.Color = Color3.fromRGB(100, 220, 255) -- icy cyan
  eyeGlow.Brightness = 1.2
  eyeGlow.Range = 8
  eyeGlow.Parent = head

  -- Humanoid
  local humanoid = Instance.new("Humanoid")
  humanoid.MaxHealth = GHOST_PIRATE.hp
  humanoid.Health = GHOST_PIRATE.hp
  humanoid.WalkSpeed = PLAYER_BASE_SPEED * GHOST_PIRATE.speedMultiplier
  humanoid.JumpPower = 50
  humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
  humanoid.HealthDisplayDistance = 20
  humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
  humanoid.NameDisplayDistance = 15
  humanoid.DisplayName = GHOST_PIRATE.displayName
  humanoid.Parent = model

  model.PrimaryPart = rootPart

  -- Store metadata as attributes for hit detection
  for _, part in model:GetChildren() do
    if part:IsA("BasePart") then
      part:SetAttribute("NPCId", npcId)
      part:SetAttribute("NPCType", "ghost_pirate")
    end
  end

  model.Parent = NPCsFolder
  return model, humanoid, rootPart
end

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------

--[[
  Gets the HumanoidRootPart for a player, or nil if unavailable.
]]
local function getPlayerHRP(player: Player): BasePart?
  local character = player.Character
  if not character then
    return nil
  end
  return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
  Returns the closest valid player target within aggro range of an NPC.
  Excludes: dead players, ragdolling players, players in Harbor, no character.
  Uses per-player aggro range overrides from ThreatEffectsService (Hunted = 60 studs).
  @param npcEntry The NPC
  @param baseAggroRange The base aggro range in studs
  @return The closest valid player or nil, and the distance
]]
local function findClosestTarget(npcEntry: NPCEntry, baseAggroRange: number): (Player?, number)
  -- If this NPC has a forced target, only consider that player
  if npcEntry.forcedTarget then
    local target = npcEntry.forcedTarget
    if not target.Parent then
      npcEntry.forcedTarget = nil
      return nil, math.huge
    end
    if SessionStateService and SessionStateService:IsInHarbor(target) then
      return nil, math.huge
    end
    local hrp = getPlayerHRP(target)
    if not hrp then
      return nil, math.huge
    end
    local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
      return nil, math.huge
    end
    local dist = (hrp.Position - npcEntry.rootPart.Position).Magnitude
    -- Forced targets use extended range (no aggro limit, only leash)
    return target, dist
  end

  local npcPos = npcEntry.rootPart.Position
  local closest: Player? = nil
  local closestDist = math.huge

  for _, player in Players:GetPlayers() do
    -- Skip players in Harbor (safe zone)
    if SessionStateService and SessionStateService:IsInHarbor(player) then
      continue
    end

    local hrp = getPlayerHRP(player)
    if not hrp then
      continue
    end

    -- Skip dead players
    local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
      continue
    end

    -- Per-player aggro range: Hunted+ players have extended aggro range
    local playerAggroRange = baseAggroRange
    if ThreatEffectsService then
      local override = ThreatEffectsService:GetAggroRangeForPlayer(player)
      if override and override > playerAggroRange then
        playerAggroRange = override
      end
    end

    local dist = (hrp.Position - npcPos).Magnitude
    if dist <= playerAggroRange and dist < closestDist then
      closest = player
      closestDist = dist
    end
  end

  return closest, closestDist
end

--[[
  Returns a random position within a radius of the given center, on the same Y level.
]]
local function randomPositionAround(center: Vector3, radius: number): Vector3
  local angle = math.random() * math.pi * 2
  local dist = math.random() * radius
  return center + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
end

--[[
  Returns the patrol waypoints for a given zone.
  If the zone has no defined waypoints, generates 4 random positions around
  the spawn position to create a basic patrol loop.
  @param zone The zone name
  @param spawnPos Fallback center for generated waypoints
  @return Ordered list of Vector3 patrol waypoints
]]
local function getPatrolWaypointsForZone(zone: string, spawnPos: Vector3): { Vector3 }
  local waypoints = ZonePatrolWaypoints[zone]
  if waypoints and #waypoints >= 2 then
    return waypoints
  end

  -- Fallback: generate 4 patrol points in a loop around spawn position
  local generated: { Vector3 } = {}
  local patrolRadius = 15
  for i = 1, 4 do
    local angle = ((i - 1) / 4) * math.pi * 2
    local offset = Vector3.new(math.cos(angle) * patrolRadius, 0, math.sin(angle) * patrolRadius)
    table.insert(generated, spawnPos + offset)
  end
  return generated
end

--[[
  Gets the effective aggro range for an NPC, accounting for night bonus.
  @param npcType The NPC type (for config lookup)
]]
local function getEffectiveAggroRange(npcType: string): number
  local config = getNPCConfig(npcType)
  local range = config.aggroRange
  if DayNightService and DayNightService:IsNight() then
    range = range * (1 + NPC_BEHAVIOR.nightAggroRangeBonus)
  end
  return range
end

--[[
  Gets the effective walk speed for an NPC, accounting for night bonus and threat effects.
  @param npcType The NPC type (for config lookup)
  @param npcPosition Optional NPC position for threat-based speed bonus lookup
]]
local function getEffectiveSpeed(npcType: string, npcPosition: Vector3?): number
  local config = getNPCConfig(npcType)
  local speed = PLAYER_BASE_SPEED * config.speedMultiplier
  if DayNightService and DayNightService:IsNight() then
    speed = speed * (1 + NPC_BEHAVIOR.nightSpeedBonus)
  end
  -- Add threat-based speed bonus from nearby Uneasy+ players
  if npcPosition and ThreatEffectsService then
    local threatBonus = ThreatEffectsService:GetSpeedBonusNearPosition(npcPosition)
    if threatBonus > 0 then
      speed = speed * (1 + threatBonus)
    end
  end
  return speed
end

--[[
  Teleports an NPC to the nearest patrol waypoint in their zone (or spawn position
  as fallback). Used by stuck detection when an NPC is stuck for 6+ seconds.
  Fires NPCTeleported signal for client-side poof VFX.
  @param entry The NPC entry to teleport
]]
local function teleportToNearestWaypoint(entry: NPCEntry)
  local fromPos = entry.position

  -- Find the nearest waypoint in this NPC's zone
  local bestPos = entry.spawnPosition -- fallback
  local bestDist = (fromPos - bestPos).Magnitude

  for _, wp in entry.patrolWaypoints do
    local dist = (fromPos - wp).Magnitude
    if dist < bestDist then
      bestDist = dist
      bestPos = wp
    end
  end

  -- Don't teleport if already near the best waypoint
  if bestDist < NPC_BEHAVIOR.stuckMoveThreshold then
    bestPos = entry.spawnPosition
  end

  -- Teleport the NPC
  if entry.rootPart and entry.rootPart.Parent then
    entry.rootPart.CFrame = CFrame.new(bestPos + Vector3.new(0, 3, 0))
    entry.position = bestPos
  end

  -- Reset stuck tracking
  entry.chaseStuckPos = bestPos
  entry.chaseStuckTime = os.clock()
  entry.lastChaseRecalcTime = 0 -- force immediate recalc after teleport

  -- Fire VFX signal to clients
  NPCService.Client.NPCTeleported:FireAll(entry.id, fromPos, bestPos)

  print(
    string.format(
      "[NPCService] NPC #%d stuck-teleported to nearest waypoint (moved %.0f studs)",
      entry.id,
      (fromPos - bestPos).Magnitude
    )
  )
end

--------------------------------------------------------------------------------
-- NPC SPAWN / DESPAWN
--------------------------------------------------------------------------------

--[[
  Spawns a single Cursed Skeleton NPC at the given position.
  @param position World position
  @param zone Zone name
  @param spawnPoint Optional spawn point Part
  @return The NPC entry, or nil if spawn failed
]]
local function spawnSkeleton(position: Vector3, zone: string, spawnPoint: Part?): NPCEntry?
  local npcId = nextNPCId
  nextNPCId = nextNPCId + 1

  local model, humanoid, rootPart = createSkeletonModel(position, npcId)

  local entry: NPCEntry = {
    id = npcId,
    npcType = "skeleton",
    hp = SKELETON.hp,
    maxHp = SKELETON.hp,
    model = model,
    humanoid = humanoid,
    rootPart = rootPart,
    position = position,
    spawnPosition = position,
    spawnPoint = spawnPoint,
    zone = zone,

    aiState = AI_STATE.IDLE,
    aiStateStartTime = os.clock(),
    targetPlayer = nil,
    lastSlashTime = 0,
    lastLungeTime = 0,
    lastPatrolMoveTime = 0,
    patrolTarget = nil,
    carriedDoubloons = 0,

    -- SimplePath patrol (NPC-003) and chase (NPC-004)
    simplePath = nil, -- created below
    patrolWaypoints = {},
    patrolWaypointIndex = 0,

    -- SimplePath chase tracking (NPC-004)
    lastChaseRecalcTime = 0,
    chaseStuckPos = nil,
    chaseStuckTime = 0,
    harborWaitStart = nil,

    flinchEndTime = 0,

    lungeTarget = nil,
    lungeStartTime = 0,

    respawnTime = nil,
    alive = true,

    forcedTarget = nil,
    isBonusNPC = false,
  }

  -- Create SimplePath instance for pathfinding (NPC-003)
  local path = SimplePath.new(model, AGENT_PARAMS)
  entry.simplePath = path
  entry.patrolWaypoints = getPatrolWaypointsForZone(zone, position)
  entry.patrolWaypointIndex = math.random(1, math.max(1, #entry.patrolWaypoints))

  -- Wire SimplePath signals (patrol NPC-003 + chase NPC-004)
  path.Reached:Connect(function()
    if entry.aiState == AI_STATE.CHASE then
      -- During chase, reaching destination means recalculate immediately
      entry.lastChaseRecalcTime = 0
    else
      -- Patrol: mark arrival time so patrol state pauses before next waypoint
      entry.lastPatrolMoveTime = os.clock()
    end
  end)
  path.Blocked:Connect(function()
    if entry.aiState == AI_STATE.CHASE then
      -- During chase, blocked path → force immediate recalculation
      entry.lastChaseRecalcTime = 0
    else
      -- Patrol: skip to next waypoint on next tick
      entry.lastPatrolMoveTime = os.clock() - 2
    end
  end)
  path.Error:Connect(function()
    if entry.aiState == AI_STATE.CHASE then
      -- During chase, path error → force immediate recalculation
      entry.lastChaseRecalcTime = 0
    else
      -- Patrol: skip to next waypoint on next tick
      entry.lastPatrolMoveTime = os.clock() - 2
    end
  end)

  ActiveNPCs[npcId] = entry
  ActiveNPCCount = ActiveNPCCount + 1
  -- Budget count is tracked here; SpawnBonusSkeleton will decrement after marking isBonusNPC
  BudgetSkeletonCount = BudgetSkeletonCount + 1

  -- Fire signals
  NPCService.Client.NPCSpawned:FireAll(npcId, "skeleton", position)

  print(string.format("[NPCService] Spawned Cursed Skeleton #%d at zone '%s'", npcId, zone))

  return entry
end

--[[
  Spawns a single Ghost Pirate NPC at the given position.
  @param position World position
  @param zone Zone name
  @param spawnPoint Optional spawn point Part
  @return The NPC entry, or nil if spawn failed
]]
local function spawnGhostPirate(position: Vector3, zone: string, spawnPoint: Part?): NPCEntry?
  local npcId = nextNPCId
  nextNPCId = nextNPCId + 1

  local model, humanoid, rootPart = createGhostPirateModel(position, npcId)

  local entry: NPCEntry = {
    id = npcId,
    npcType = "ghost_pirate",
    hp = GHOST_PIRATE.hp,
    maxHp = GHOST_PIRATE.hp,
    model = model,
    humanoid = humanoid,
    rootPart = rootPart,
    position = position,
    spawnPosition = position,
    spawnPoint = spawnPoint,
    zone = zone,

    aiState = AI_STATE.IDLE,
    aiStateStartTime = os.clock(),
    targetPlayer = nil,
    lastSlashTime = 0,
    lastLungeTime = 0,
    lastPatrolMoveTime = 0,
    patrolTarget = nil,
    carriedDoubloons = 0,

    -- SimplePath patrol and chase
    simplePath = nil,
    patrolWaypoints = {},
    patrolWaypointIndex = 0,

    -- SimplePath chase tracking
    lastChaseRecalcTime = 0,
    chaseStuckPos = nil,
    chaseStuckTime = 0,
    harborWaitStart = nil,

    flinchEndTime = 0,

    lungeTarget = nil,
    lungeStartTime = 0,

    respawnTime = nil,
    alive = true,

    forcedTarget = nil,
    isBonusNPC = false,
  }

  -- Create SimplePath instance for pathfinding
  local path = SimplePath.new(model, AGENT_PARAMS)
  entry.simplePath = path
  entry.patrolWaypoints = getPatrolWaypointsForZone(zone, position)
  entry.patrolWaypointIndex = math.random(1, math.max(1, #entry.patrolWaypoints))

  -- Wire SimplePath signals (same as skeleton)
  path.Reached:Connect(function()
    if entry.aiState == AI_STATE.CHASE then
      entry.lastChaseRecalcTime = 0
    else
      entry.lastPatrolMoveTime = os.clock()
    end
  end)
  path.Blocked:Connect(function()
    if entry.aiState == AI_STATE.CHASE then
      entry.lastChaseRecalcTime = 0
    else
      entry.lastPatrolMoveTime = os.clock() - 2
    end
  end)
  path.Error:Connect(function()
    if entry.aiState == AI_STATE.CHASE then
      entry.lastChaseRecalcTime = 0
    else
      entry.lastPatrolMoveTime = os.clock() - 2
    end
  end)

  ActiveNPCs[npcId] = entry
  ActiveNPCCount = ActiveNPCCount + 1
  BudgetGhostPirateCount = BudgetGhostPirateCount + 1
  GhostPirateNPCIds[npcId] = true

  -- Fire signals
  NPCService.Client.NPCSpawned:FireAll(npcId, "ghost_pirate", position)

  print(string.format("[NPCService] Spawned Ghost Pirate #%d at zone '%s'", npcId, zone))

  return entry
end

--[[
  Removes an NPC from the world. Decrements budget counters and frees spawn points.
  @param npcId The NPC instance ID
]]
local function despawnNPC(npcId: number)
  local entry = ActiveNPCs[npcId]
  if not entry then
    return
  end

  -- Decrement budget counters (only for non-bonus NPCs)
  if not entry.isBonusNPC then
    if entry.npcType == "skeleton" then
      BudgetSkeletonCount = math.max(0, BudgetSkeletonCount - 1)
    elseif entry.npcType == "ghost_pirate" then
      BudgetGhostPirateCount = math.max(0, BudgetGhostPirateCount - 1)
    end
  end

  -- Free spawn point
  if entry.spawnPoint and OccupiedSpawnPoints[entry.spawnPoint] == npcId then
    OccupiedSpawnPoints[entry.spawnPoint] = nil
  end

  -- Clean up Ghost Pirate tracking
  GhostPirateNPCIds[npcId] = nil

  -- Clean up SimplePath (NPC-003)
  if entry.simplePath then
    entry.simplePath:Destroy()
    entry.simplePath = nil
  end

  if entry.model and entry.model.Parent then
    entry.model:Destroy()
  end

  ActiveNPCs[npcId] = nil
  ActiveNPCCount = ActiveNPCCount - 1
end

--------------------------------------------------------------------------------
-- NPC AI STATE MACHINE
--------------------------------------------------------------------------------

--[[
  Transitions an NPC to a new AI state.
  Stops SimplePath if leaving patrol or chase state.
  Resets chase tracking fields when entering chase.
]]
local function setState(entry: NPCEntry, newState: string)
  local oldState = entry.aiState

  -- Stop SimplePath when leaving patrol or chase (NPC-003, NPC-004)
  if (oldState == AI_STATE.PATROL or oldState == AI_STATE.CHASE) and newState ~= oldState then
    if entry.simplePath and entry.simplePath:IsRunning() then
      entry.simplePath:Stop()
    end
  end

  -- Reset chase tracking when entering chase (NPC-004)
  if newState == AI_STATE.CHASE and oldState ~= AI_STATE.CHASE then
    entry.lastChaseRecalcTime = 0
    entry.chaseStuckPos = nil
    entry.chaseStuckTime = os.clock()
    entry.harborWaitStart = nil

    -- Ghost Pirate materialization: flash VFX + screech SFX when entering chase
    if entry.npcType == "ghost_pirate" and oldState == AI_STATE.PATROL then
      NPCService.Client.GhostPirateMaterialized:FireAll(entry.id, entry.position)
    end
  end

  entry.aiState = newState
  entry.aiStateStartTime = os.clock()
end

--[[
  Handles NPC attack against a player (slash or lunge).
  Applies ragdoll and loot spill to the target.
]]
local function handleNPCHitPlayer(entry: NPCEntry, target: Player)
  if not SessionStateService then
    return
  end

  -- Cannot hit players who are ragdolling, dashing, or in Harbor
  if SessionStateService:IsRagdolling(target) then
    return
  end
  if SessionStateService:IsDashing(target) then
    return
  end
  if SessionStateService:IsInHarbor(target) then
    return
  end

  local targetHRP = getPlayerHRP(target)
  if not targetHRP then
    return
  end

  local config = getNPCConfig(entry.npcType)

  -- Check distance (must still be within range)
  local dist = (targetHRP.Position - entry.rootPart.Position).Magnitude
  if dist > config.slashRange + 2 then -- small tolerance
    return
  end

  -- Check if target is blocking
  local targetIsBlocking = SessionStateService:IsBlocking(target)

  local ragdollDuration, knockbackForce, spillPercent
  if targetIsBlocking then
    ragdollDuration = GameConfig.Ragdoll.blockedHitDuration
    knockbackForce = GameConfig.Ragdoll.blockedHitKnockback
    spillPercent = GameConfig.LootSpill.blockedHitPercent
    SessionStateService:SetBlocking(target, false)
  else
    ragdollDuration = config.slashRagdollDuration
    knockbackForce = GameConfig.Ragdoll.lightHitKnockback
    spillPercent = config.slashLootSpillPercent
  end

  -- Apply ragdoll
  SessionStateService:StartRagdoll(target, ragdollDuration)

  -- Calculate knockback direction
  local knockbackVelocity = Vector3.zero
  if knockbackForce > 0 and targetHRP then
    local knockbackDir = (targetHRP.Position - entry.rootPart.Position)
    knockbackDir = Vector3.new(knockbackDir.X, 0, knockbackDir.Z)
    if knockbackDir.Magnitude > 0.01 then
      knockbackDir = knockbackDir.Unit
    else
      knockbackDir = entry.rootPart.CFrame.LookVector
      knockbackDir = Vector3.new(knockbackDir.X, 0, knockbackDir.Z).Unit
    end
    knockbackVelocity = knockbackDir * knockbackForce
  end

  -- Send ragdoll trigger to target via CombatService client signal
  local attackerName = if entry.npcType == "ghost_pirate" then "Ghost Pirate" else "Cursed Skeleton"
  local CombatService = Knit.GetService("CombatService")
  if CombatService then
    if targetIsBlocking then
      CombatService.Client.BlockImpact:Fire(target, attackerName, ragdollDuration)
    end
    CombatService.Client.RagdollTrigger:Fire(
      target,
      attackerName,
      ragdollDuration,
      knockbackVelocity
    )
  end

  -- Calculate loot spill
  local heldDoubloons = SessionStateService:GetHeldDoubloons(target)
  local hasBounty = SessionStateService:HasBounty(target)
  local spillAmount = GameConfig.calculateSpill(heldDoubloons, spillPercent, hasBounty)

  if spillAmount > 0 then
    SessionStateService:AddHeldDoubloons(target, -spillAmount)

    local spillPos = targetHRP.Position
    if DoubloonService then
      DoubloonService:ScatterDoubloons(spillPos, spillAmount, 4)
    end

    -- Notify for VFX
    if CombatService then
      CombatService.Client.LootSpillVFX:FireAll(spillPos, spillAmount)
    end
  end

  print(
    string.format(
      "[NPCService] %s #%d hit %s — ragdoll %.1fs, spilled %d",
      attackerName,
      entry.id,
      target.Name,
      ragdollDuration,
      spillAmount
    )
  )
end

--[[
  Updates the AI for a single NPC each tick.
  @param entry The NPC entry
  @param dt Delta time
]]
local function updateNPCAI(entry: NPCEntry, dt: number)
  if not entry.alive then
    return
  end

  -- Keep position tracking in sync
  if entry.rootPart and entry.rootPart.Parent then
    entry.position = entry.rootPart.Position
  end

  -- Update humanoid speed for night bonus + threat effects
  if entry.humanoid and entry.humanoid.Parent then
    entry.humanoid.WalkSpeed = getEffectiveSpeed(entry.npcType, entry.position)
  end

  local now = os.clock()
  local config = getNPCConfig(entry.npcType)
  local aggroRange = getEffectiveAggroRange(entry.npcType)

  -- State machine
  if entry.aiState == AI_STATE.FLINCH then
    -- Wait for flinch to end
    if now >= entry.flinchEndTime then
      -- Return to chase if we have a target, otherwise patrol
      if entry.targetPlayer then
        setState(entry, AI_STATE.CHASE)
      else
        setState(entry, AI_STATE.PATROL)
      end
    end
    return
  end

  if entry.aiState == AI_STATE.IDLE then
    -- Transition to patrol after a brief idle
    if now - entry.aiStateStartTime > 1 then
      setState(entry, AI_STATE.PATROL)
    end
    return
  end

  if entry.aiState == AI_STATE.PATROL then
    -- Forced target NPCs always chase their target
    if entry.forcedTarget and entry.forcedTarget.Parent then
      entry.targetPlayer = entry.forcedTarget
      setState(entry, AI_STATE.CHASE)
      return
    end

    -- Check for players in aggro range
    local target, targetDist = findClosestTarget(entry, aggroRange)
    if target then
      entry.targetPlayer = target
      setState(entry, AI_STATE.CHASE)
      return
    end

    -- SimplePath-based patrol (NPC-003)
    if entry.simplePath and #entry.patrolWaypoints >= 1 then
      -- If SimplePath is not running, advance to next waypoint after a brief pause
      if not entry.simplePath:IsRunning() then
        -- Wait 2 seconds at each waypoint before moving on
        if now - entry.lastPatrolMoveTime < 2 then
          return
        end

        -- Advance to next patrol waypoint (loop)
        entry.patrolWaypointIndex = (entry.patrolWaypointIndex % #entry.patrolWaypoints) + 1
        local nextWaypoint = entry.patrolWaypoints[entry.patrolWaypointIndex]
        entry.simplePath:Run(nextWaypoint)
      end
      -- SimplePath handles movement via MoveToFinished — don't call Humanoid:MoveTo()

      -- Listen for SimplePath events (processed next tick via signal connections)
      -- Reached: sets lastPatrolMoveTime so we pause at the waypoint
      -- Blocked/Error: falls through to fallback below on next tick
    else
      -- Fallback: basic random wander (no SimplePath or no waypoints)
      if not entry.patrolTarget or now - entry.lastPatrolMoveTime > 5 then
        entry.patrolTarget = randomPositionAround(entry.spawnPosition, 15)
        entry.lastPatrolMoveTime = now
      end
      if entry.humanoid and entry.patrolTarget then
        entry.humanoid:MoveTo(entry.patrolTarget)
      end
      if entry.patrolTarget then
        local distToPatrol = (entry.position - entry.patrolTarget).Magnitude
        if distToPatrol < 3 then
          entry.patrolTarget = nil
          entry.lastPatrolMoveTime = now
        end
      end
    end
    return
  end

  if entry.aiState == AI_STATE.CHASE then
    -- Validate target is still valid
    local target = entry.targetPlayer
    if not target or not target.Parent then
      entry.targetPlayer = nil
      if entry.forcedTarget == target then
        entry.forcedTarget = nil
      end
      setState(entry, AI_STATE.PATROL)
      return
    end

    local targetHRP = getPlayerHRP(target)
    if not targetHRP then
      entry.targetPlayer = nil
      if entry.forcedTarget == target then
        entry.forcedTarget = nil
      end
      setState(entry, AI_STATE.PATROL)
      return
    end

    -- Harbor boundary handling (NPC-004): stop at boundary, wait 5s, then return to patrol
    if SessionStateService and SessionStateService:IsInHarbor(target) then
      if not entry.harborWaitStart then
        -- Target just entered Harbor — stop movement and start waiting
        entry.harborWaitStart = now
        if entry.simplePath and entry.simplePath:IsRunning() then
          entry.simplePath:Stop()
        end
      elseif now - entry.harborWaitStart >= NPC_BEHAVIOR.harborReturnDelay then
        -- Wait expired — return to patrol
        entry.targetPlayer = nil
        entry.harborWaitStart = nil
        setState(entry, AI_STATE.PATROL)
      end
      -- While waiting, NPC stands still at Harbor boundary
      return
    else
      -- Target left Harbor during wait — resume chase
      if entry.harborWaitStart then
        entry.harborWaitStart = nil
        entry.lastChaseRecalcTime = 0 -- force immediate recalc
      end
    end

    -- Check leash distance from spawn (skip for forced-target bonus NPCs)
    if not entry.forcedTarget then
      local distFromSpawn = (entry.position - entry.spawnPosition).Magnitude
      if distFromSpawn > NPC_BEHAVIOR.leashDistance then
        entry.targetPlayer = nil
        setState(entry, AI_STATE.PATROL)
        -- Use SimplePath to navigate back toward spawn
        if entry.simplePath then
          entry.simplePath:Run(entry.spawnPosition)
        elseif entry.humanoid then
          entry.humanoid:MoveTo(entry.spawnPosition)
        end
        return
      end
    end

    local targetPos = targetHRP.Position
    local distToTarget = (entry.position - targetPos).Magnitude

    -- Check if target moved out of aggro range (skip for forced-target bonus NPCs)
    if not entry.forcedTarget and distToTarget > aggroRange * 1.5 then
      entry.targetPlayer = nil
      setState(entry, AI_STATE.PATROL)
      return
    end

    -- Check if close enough for attack
    if distToTarget <= config.slashRange then
      -- Skeletons can lunge; Ghost Pirates only use spectral slash
      if
        entry.npcType == "skeleton"
        and distToTarget > 3
        and now - entry.lastLungeTime >= SKELETON.lungeCooldown
      then
        -- Start lunge attack
        setState(entry, AI_STATE.ATTACK_LUNGE)
        entry.lungeStartTime = now
        entry.lungeTarget = targetPos
        -- Face target
        if entry.rootPart then
          local lookDir = (targetPos - entry.rootPart.Position)
          lookDir = Vector3.new(lookDir.X, 0, lookDir.Z)
          if lookDir.Magnitude > 0.01 then
            entry.rootPart.CFrame =
              CFrame.new(entry.rootPart.Position, entry.rootPart.Position + lookDir)
          end
        end
        NPCService.Client.NPCAttack:FireAll(entry.id, "lunge", targetPos)
        return
      end

      if now - entry.lastSlashTime >= config.slashCooldown then
        -- Start slash attack
        local attackType = if entry.npcType == "ghost_pirate" then "spectral_slash" else "slash"
        setState(entry, AI_STATE.ATTACK_SLASH)
        -- Face target
        if entry.rootPart then
          local lookDir = (targetPos - entry.rootPart.Position)
          lookDir = Vector3.new(lookDir.X, 0, lookDir.Z)
          if lookDir.Magnitude > 0.01 then
            entry.rootPart.CFrame =
              CFrame.new(entry.rootPart.Position, entry.rootPart.Position + lookDir)
          end
        end
        NPCService.Client.NPCAttack:FireAll(entry.id, attackType, targetPos)
        return
      end
    end

    -- SimplePath chase movement with stuck detection (NPC-004)
    -- Stuck detection: check if NPC has moved enough since last check
    if entry.chaseStuckPos then
      local moved = (entry.position - entry.chaseStuckPos).Magnitude
      if moved < NPC_BEHAVIOR.stuckMoveThreshold then
        local stuckDuration = now - entry.chaseStuckTime
        if stuckDuration >= NPC_BEHAVIOR.stuckTimeTeleport then
          -- Stuck for 6+ seconds: teleport to nearest patrol waypoint
          teleportToNearestWaypoint(entry)
        elseif stuckDuration >= NPC_BEHAVIOR.stuckTimeRecalc then
          -- Stuck for 3+ seconds: force path recalculation
          entry.lastChaseRecalcTime = 0
        end
      else
        -- Moved enough, reset stuck detection window
        entry.chaseStuckPos = entry.position
        entry.chaseStuckTime = now
      end
    else
      -- Initialize stuck detection
      entry.chaseStuckPos = entry.position
      entry.chaseStuckTime = now
    end

    -- Recalculate path on interval (0.3s)
    if
      entry.simplePath and now - entry.lastChaseRecalcTime >= NPC_BEHAVIOR.chasePathRecalcInterval
    then
      entry.lastChaseRecalcTime = now
      entry.simplePath:Run(targetPos)
    end

    -- Re-evaluate: check if another player is closer (skip for forced-target NPCs)
    if not entry.forcedTarget then
      local closerTarget, closerDist = findClosestTarget(entry, aggroRange)
      if closerTarget and closerTarget ~= target and closerDist < distToTarget * 0.6 then
        entry.targetPlayer = closerTarget
        entry.lastChaseRecalcTime = 0 -- force immediate recalc for new target
      end
    end
    return
  end

  if entry.aiState == AI_STATE.ATTACK_SLASH then
    local elapsed = now - entry.aiStateStartTime
    local windupTime = config.slashWindup

    -- Windup phase
    if elapsed < windupTime then
      -- NPC is winding up — frozen in place
      return
    end

    -- Execute slash hit
    if elapsed >= windupTime and entry.lastSlashTime < entry.aiStateStartTime then
      entry.lastSlashTime = now

      -- Check if target is still valid and in range
      local target = entry.targetPlayer
      if target and target.Parent then
        handleNPCHitPlayer(entry, target)
      end
    end

    -- After slash, return to chase
    if elapsed > windupTime + 0.3 then
      setState(entry, AI_STATE.CHASE)
    end
    return
  end

  if entry.aiState == AI_STATE.ATTACK_LUNGE then
    local elapsed = now - entry.aiStateStartTime

    -- Telegraph phase (crouch)
    if elapsed < SKELETON.lungeWindup then
      -- NPC is crouching — telegraph to player
      return
    end

    -- Dash phase
    local dashStart = SKELETON.lungeWindup
    local dashDuration = 0.3 -- quick dash
    if elapsed >= dashStart and elapsed < dashStart + dashDuration then
      -- Move forward rapidly toward lunge target
      if entry.lungeTarget and entry.humanoid and entry.rootPart then
        local dashDir = (entry.lungeTarget - entry.rootPart.Position)
        dashDir = Vector3.new(dashDir.X, 0, dashDir.Z)
        if dashDir.Magnitude > 0.01 then
          dashDir = dashDir.Unit
        else
          dashDir = entry.rootPart.CFrame.LookVector
        end
        -- Apply lunge movement
        local dashSpeed = SKELETON.lungeDashDistance / dashDuration
        entry.humanoid:MoveTo(entry.rootPart.Position + dashDir * dashSpeed * dt)
      end
      return
    end

    -- Hit check at end of dash
    if elapsed >= dashStart + dashDuration and entry.lastLungeTime < entry.aiStateStartTime then
      entry.lastLungeTime = now

      local target = entry.targetPlayer
      if target and target.Parent then
        handleNPCHitPlayer(entry, target)
      end
    end

    -- After lunge, return to chase
    if elapsed > dashStart + dashDuration + 0.2 then
      setState(entry, AI_STATE.CHASE)
    end
    return
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Deals damage to an NPC.
  @param npcId The NPC instance ID
  @param damage The damage amount
  @param attackingPlayer The player who dealt the damage
  @return (killed: boolean, hpFraction: number?)
]]
function NPCService:DamageNPC(
  npcId: number,
  damage: number,
  attackingPlayer: Player?
): (boolean, number?)
  local entry = ActiveNPCs[npcId]
  if not entry or not entry.alive then
    return false, nil
  end

  entry.hp = math.max(0, entry.hp - damage)
  local hpFraction = entry.hp / entry.maxHp

  -- Update humanoid health display
  if entry.humanoid and entry.humanoid.Parent then
    entry.humanoid.Health = entry.hp
  end

  -- Notify clients
  NPCService.Client.NPCDamaged:FireAll(npcId, hpFraction)

  -- Fire server signal
  NPCService.NPCDamaged:Fire(entry, damage, attackingPlayer)

  if entry.hp <= 0 then
    -- NPC dies
    self:KillNPC(npcId, attackingPlayer)
    return true, 0
  end

  -- Apply flinch (0.2s pause)
  local npcConfig = getNPCConfig(entry.npcType)
  entry.flinchEndTime = os.clock() + npcConfig.flinchDuration
  setState(entry, AI_STATE.FLINCH)
  NPCService.Client.NPCFlinch:FireAll(npcId)

  return false, hpFraction
end

--[[
  Kills an NPC, drops loot, and queues respawn.
  @param npcId The NPC instance ID
  @param killedByPlayer The player who killed it (or nil)
]]
function NPCService:KillNPC(npcId: number, killedByPlayer: Player?)
  local entry = ActiveNPCs[npcId]
  if not entry or not entry.alive then
    return
  end

  entry.alive = false
  setState(entry, AI_STATE.DEAD)

  local deathPosition = entry.position
  local npcConfig = getNPCConfig(entry.npcType)

  -- Calculate loot drop: carried doubloons + bonus
  local bonusDoubloons = math.random(npcConfig.deathBonusMin, npcConfig.deathBonusMax)
  local totalDrop = entry.carriedDoubloons + bonusDoubloons

  -- Scatter doubloons at death position
  if DoubloonService and totalDrop > 0 then
    DoubloonService:ScatterDoubloons(deathPosition, totalDrop, 5)
  end

  -- Add threat for killing NPC
  if killedByPlayer and ThreatService then
    ThreatService:OnNPCKilled(killedByPlayer)
  end

  -- Notify clients
  NPCService.Client.NPCDied:FireAll(npcId, entry.npcType, deathPosition)

  -- Fire server signal
  NPCService.NPCDied:Fire(entry, killedByPlayer)

  local npcLabel = if entry.npcType == "ghost_pirate" then "Ghost Pirate" else "Skeleton"
  print(
    string.format(
      "[NPCService] %s #%d killed by %s — dropped %d doubloons (%d bonus + %d carried)",
      npcLabel,
      npcId,
      killedByPlayer and killedByPlayer.Name or "unknown",
      totalDrop,
      bonusDoubloons,
      entry.carriedDoubloons
    )
  )

  -- Queue respawn (skip for bonus NPCs — ThreatEffectsService handles their lifecycle)
  if not entry.isBonusNPC then
    table.insert(RespawnQueue, {
      spawnTime = os.clock() + npcConfig.respawnTime,
      spawnPosition = entry.spawnPosition,
      zone = entry.zone,
      spawnPoint = entry.spawnPoint,
      npcType = entry.npcType,
    })
  end

  -- Remove the NPC model after a brief delay (so death VFX can play)
  task.delay(2, function()
    despawnNPC(npcId)
  end)
end

--[[
  Finds an NPC entry by a Part that belongs to it.
  Used for hit detection (player swings at NPC's body parts).
  @param part The Part to look up
  @return NPCEntry or nil
]]
function NPCService:GetNPCByPart(part: BasePart): any
  local npcId = part:GetAttribute("NPCId")
  if npcId then
    return ActiveNPCs[npcId]
  end

  -- Check parent model's children
  local model = part.Parent
  if model and model:IsA("Model") then
    for _, child in model:GetChildren() do
      if child:IsA("BasePart") then
        local id = child:GetAttribute("NPCId")
        if id then
          return ActiveNPCs[id]
        end
      end
    end
  end

  return nil
end

--[[
  Returns the NPC entry for a given ID.
]]
function NPCService:GetNPC(npcId: number): NPCEntry?
  return ActiveNPCs[npcId]
end

--[[
  Returns the number of active NPCs.
]]
function NPCService:GetActiveNPCCount(): number
  return ActiveNPCCount
end

--[[
  Spawns an NPC at a specific position (for testing/events).
  @param npcType The NPC type (currently only "skeleton")
  @param position World position
  @return NPCEntry or nil
]]
function NPCService:SpawnNPCAt(npcType: string, position: Vector3): any
  if npcType == "skeleton" then
    return spawnSkeleton(position, "manual", nil)
  elseif npcType == "ghost_pirate" then
    return spawnGhostPirate(position, "manual", nil)
  end
  warn("[NPCService] Unknown NPC type: " .. tostring(npcType))
  return nil
end

--[[
  Spawns Ghost Pirate ambush NPCs at a position (e.g., Cursed Chest break).
  @param position World position to spawn at
  @param count Number of NPCs to spawn (1-2)
  @param zone Zone name for the spawned NPCs
]]
function NPCService:SpawnAmbushNPCs(position: Vector3, count: number, zone: string)
  for i = 1, count do
    -- Offset each NPC slightly so they don't stack on top of each other
    local angle = (i / count) * math.pi * 2
    local offset = Vector3.new(math.cos(angle) * 3, 0, math.sin(angle) * 3)
    local spawnPos = position + offset

    local entry = spawnGhostPirate(spawnPos, zone, nil)
    if entry then
      -- Ambush NPCs are bonus (don't count toward budget)
      entry.isBonusNPC = true
      BudgetGhostPirateCount = math.max(0, BudgetGhostPirateCount - 1)

      -- Fire materialization signal immediately for ambush (they appear aggressively)
      NPCService.Client.GhostPirateMaterialized:FireAll(entry.id, spawnPos)

      print(
        string.format(
          "[NPCService] Ghost Pirate ambush #%d spawned at Cursed Chest location (zone: %s)",
          entry.id,
          zone
        )
      )
    end
  end
end

--[[
  Spawns a bonus Cursed Skeleton that targets a specific player.
  Used by ThreatEffectsService for Hunted tier effect.
  Bonus NPCs do NOT count toward normal NPC budget and do NOT respawn normally.
  @param position World position to spawn at
  @param targetPlayer The player this NPC should target
  @return NPCEntry or nil
]]
function NPCService:SpawnBonusSkeleton(position: Vector3, targetPlayer: Player): any
  local entry = spawnSkeleton(position, "threat_bonus", nil)
  if entry then
    entry.forcedTarget = targetPlayer
    entry.isBonusNPC = true
    -- Correct budget count: bonus NPCs don't count toward budget
    BudgetSkeletonCount = math.max(0, BudgetSkeletonCount - 1)
    print(
      string.format(
        "[NPCService] Bonus skeleton #%d spawned targeting %s",
        entry.id,
        targetPlayer.Name
      )
    )
  end
  return entry
end

--[[
  Despawns a bonus NPC by ID. Used by ThreatEffectsService when
  a player's threat drops below Hunted tier.
  @param npcId The NPC instance ID to despawn
]]
function NPCService:DespawnBonusNPC(npcId: number)
  local entry = ActiveNPCs[npcId]
  if not entry then
    return
  end

  if entry.alive then
    entry.alive = false
    setState(entry, AI_STATE.DEAD)
    NPCService.Client.NPCDied:FireAll(npcId, entry.npcType, entry.position)
  end

  -- Remove immediately (no respawn queue for bonus NPCs)
  task.delay(1, function()
    despawnNPC(npcId)
  end)

  print(string.format("[NPCService] Bonus NPC #%d despawned", npcId))
end

--[[
  Returns the current spawn budget info.
  @return { skeletonBudget, skeletonActive, ghostPirateBudget, ghostPirateActive, bonusNPCs }
]]
function NPCService:GetBudgetInfo(): {
  skeletonBudget: number,
  skeletonActive: number,
  ghostPirateBudget: number,
  ghostPirateActive: number,
  bonusNPCs: number,
}
  local bonusCount = 0
  for _, entry in ActiveNPCs do
    if entry.alive and entry.isBonusNPC then
      bonusCount = bonusCount + 1
    end
  end

  return {
    skeletonBudget = SkeletonBudget,
    skeletonActive = BudgetSkeletonCount,
    ghostPirateBudget = GhostPirateBudget,
    ghostPirateActive = BudgetGhostPirateCount,
    bonusNPCs = bonusCount,
  }
end

--[[
  Returns whether the spawn budget has room for more NPCs of a given type.
  Used by other services to check before requesting manual spawns.
  @param npcType The NPC type to check ("skeleton" or "ghost_pirate")
  @return true if under budget
]]
function NPCService:HasBudgetRoom(npcType: string): boolean
  if npcType == "skeleton" then
    return BudgetSkeletonCount < SkeletonBudget
  elseif npcType == "ghost_pirate" then
    return BudgetGhostPirateCount < GhostPirateBudget
  end
  return false
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS
--------------------------------------------------------------------------------

function NPCService.Client:GetActiveNPCCount(_player: Player): number
  return NPCService:GetActiveNPCCount()
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function NPCService:KnitInit()
  -- Create workspace folder for NPC models
  NPCsFolder = Instance.new("Folder")
  NPCsFolder.Name = "NPCs"
  NPCsFolder.Parent = workspace

  -- Look for spawn points folder
  SpawnPointsFolder = workspace:FindFirstChild("NPCSpawnPoints")
  if not SpawnPointsFolder then
    SpawnPointsFolder = Instance.new("Folder")
    SpawnPointsFolder.Name = "NPCSpawnPoints"
    SpawnPointsFolder.Parent = workspace
    warn(
      "[NPCService] No NPCSpawnPoints folder found in workspace. "
        .. "Created an empty one. Map builders should add Parts to this folder."
    )
  end

  print("[NPCService] Initialized")
end

function NPCService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DoubloonService = Knit.GetService("DoubloonService")
  ThreatService = Knit.GetService("ThreatService")
  DayNightService = Knit.GetService("DayNightService")
  HarborService = Knit.GetService("HarborService")
  ThreatEffectsService = Knit.GetService("ThreatEffectsService")

  -- Categorize spawn points by NPC type
  local allSpawnPoints = SpawnPointsFolder and SpawnPointsFolder:GetChildren() or {}
  for _, point in allSpawnPoints do
    if point:IsA("BasePart") then
      local npcType = point:GetAttribute("NPCType") or "skeleton"
      if npcType == "skeleton" then
        table.insert(SkeletonSpawnPoints, point)
      elseif npcType == "ghost_pirate" then
        table.insert(GhostPirateSpawnPoints, point)
      end
    end
  end

  -- Discover patrol waypoints per zone (NPC-003)
  -- Filter out any waypoints inside the Harbor safe zone
  local function isInHarbor(pos: Vector3): boolean
    return HarborService and HarborService:IsPositionInHarbor(pos)
  end

  local patrolFolder = workspace:FindFirstChild("PatrolWaypoints")
  if patrolFolder then
    for _, point in patrolFolder:GetChildren() do
      if point:IsA("BasePart") and not isInHarbor(point.Position) then
        local zone = point:GetAttribute("Zone") or "unknown"
        if not ZonePatrolWaypoints[zone] then
          ZonePatrolWaypoints[zone] = {}
        end
        table.insert(ZonePatrolWaypoints[zone], {
          position = point.Position,
          order = point:GetAttribute("Order") or 999,
        })
      end
    end

    -- Sort waypoints by order within each zone, then extract positions
    for zone, waypointData in ZonePatrolWaypoints do
      table.sort(waypointData, function(a, b)
        return a.order < b.order
      end)
      local positions: { Vector3 } = {}
      for _, wp in waypointData do
        table.insert(positions, wp.position)
      end
      ZonePatrolWaypoints[zone] = positions
    end

    local totalZones = 0
    local totalWaypoints = 0
    for _, wps in ZonePatrolWaypoints do
      totalZones += 1
      totalWaypoints += #wps
    end
    print(
      string.format(
        "[NPCService] Loaded %d patrol waypoints across %d zones from PatrolWaypoints folder",
        totalWaypoints,
        totalZones
      )
    )
  else
    -- Fallback: use spawn points of each zone as patrol waypoints for that zone
    local zoneSpawnPositions: { [string]: { Vector3 } } = {}
    for _, point in allSpawnPoints do
      if point:IsA("BasePart") and not isInHarbor(point.Position) then
        local zone = point:GetAttribute("Zone") or "unknown"
        if not zoneSpawnPositions[zone] then
          zoneSpawnPositions[zone] = {}
        end
        table.insert(zoneSpawnPositions[zone], point.Position)
      end
    end

    for zone, positions in zoneSpawnPositions do
      if #positions >= 2 then
        ZonePatrolWaypoints[zone] = positions
      end
    end

    print(
      "[NPCService] No PatrolWaypoints folder found. "
        .. "Using spawn points as patrol waypoints for zones with 2+ points."
    )
  end

  -- If no skeleton spawn points exist, create test spawn points
  if #SkeletonSpawnPoints == 0 then
    warn("[NPCService] No skeleton spawn points found. Creating test spawn points near origin.")
    for i = 1, 10 do
      local angle = (i / 10) * math.pi * 2
      local testPart = Instance.new("Part")
      testPart.Name = "TestSpawn_" .. tostring(i)
      testPart.Anchored = true
      testPart.CanCollide = false
      testPart.Transparency = 1
      testPart.Size = Vector3.new(1, 1, 1)
      testPart.Position = Vector3.new(math.cos(angle) * 40, 5, math.sin(angle) * 40)
      testPart:SetAttribute("Zone", "test")
      testPart:SetAttribute("NPCType", "skeleton")
      testPart.Parent = SpawnPointsFolder
      table.insert(SkeletonSpawnPoints, testPart)
    end
  end

  -- Ghost pirate spawn points can share skeleton points if none are defined
  if #GhostPirateSpawnPoints == 0 and #SkeletonSpawnPoints > 0 then
    -- Ghost pirates can spawn at any skeleton spawn point at night
    for _, point in SkeletonSpawnPoints do
      table.insert(GhostPirateSpawnPoints, point)
    end
  end

  -- Set initial budget based on current phase
  local currentPhase = DayNightService:GetCurrentPhase()
  if currentPhase == "Night" or currentPhase == "Dusk" then
    local dayBudget = rollDaySkeletonBudget()
    SkeletonBudget = getNightSkeletonBudget(dayBudget)
    GhostPirateBudget = rollNightGhostPirateBudget()
  else
    SkeletonBudget = rollDaySkeletonBudget()
    GhostPirateBudget = 0
  end

  -- Fill initial skeleton budget
  local initialSpawns = fillSkeletonBudget()

  -- Fill Ghost Pirate budget if night is active at start
  local initialGhostPirates = 0
  if GhostPirateBudget > 0 then
    initialGhostPirates = fillGhostPirateBudget()
  end

  -- Listen for phase transitions to adjust budgets
  DayNightService.PhaseChanged:Connect(onPhaseChanged)

  -- Main AI update loop
  RunService.Heartbeat:Connect(function(dt: number)
    -- Update all active NPCs
    for _, entry in ActiveNPCs do
      if entry.alive then
        updateNPCAI(entry, dt)
      end
    end

    -- Process respawn queue (budget-aware)
    local now = os.clock()
    local i = 1
    while i <= #RespawnQueue do
      local respawn = RespawnQueue[i]
      if now >= respawn.spawnTime then
        local shouldSpawn = false
        local respawnType = respawn.npcType or "skeleton"

        -- Check if under budget before respawning
        if respawnType == "skeleton" and BudgetSkeletonCount < SkeletonBudget then
          shouldSpawn = true
        elseif respawnType == "ghost_pirate" and BudgetGhostPirateCount < GhostPirateBudget then
          -- Ghost pirate respawns only at night
          if DayNightService:IsNight() then
            shouldSpawn = true
          end
        end

        if shouldSpawn then
          if respawnType == "skeleton" then
            local entry = spawnSkeleton(respawn.spawnPosition, respawn.zone, respawn.spawnPoint)
            if entry and respawn.spawnPoint then
              OccupiedSpawnPoints[respawn.spawnPoint] = entry.id
            end
          elseif respawnType == "ghost_pirate" then
            local entry = spawnGhostPirate(respawn.spawnPosition, respawn.zone, respawn.spawnPoint)
            if entry and respawn.spawnPoint then
              OccupiedSpawnPoints[respawn.spawnPoint] = entry.id
            end
          end
        end

        table.remove(RespawnQueue, i)
      else
        i = i + 1
      end
    end
  end)

  print(
    string.format(
      "[NPCService] Started — budget: %d skeletons (spawned %d), %d ghost pirates (spawned %d), "
        .. "spawn points: %d skeleton, %d ghost pirate",
      SkeletonBudget,
      initialSpawns,
      GhostPirateBudget,
      initialGhostPirates,
      #SkeletonSpawnPoints,
      #GhostPirateSpawnPoints
    )
  )
end

return NPCService
