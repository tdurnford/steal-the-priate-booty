--[[
  NPCService.lua
  Server-authoritative NPC management service.

  Handles:
    - Cursed Skeleton entity creation with Humanoid, HP, and stats
    - NPC AI state machine: Idle → Patrol → Chase → Attack → Flinch → Dead
    - Slash attack (0.8s windup, 8 stud range, 2s cooldown)
    - Lunge attack (0.5s crouch telegraph, 6 stud dash + slash, 5s cooldown)
    - NPC hit reception: flinch (0.2s pause), death (loot drop), respawn (90s)
    - Hit detection against players: ragdoll 2.0s, spill 20% held doubloons
    - Basic patrol/chase movement via Humanoid:MoveTo
    - Respawn management per zone

  NPC spawn points are defined as Parts in workspace.NPCSpawnPoints.
  Each spawn point Part can have:
    - Attribute "Zone" (string): zone name (e.g., "jungle", "beach", "danger")
    - Attribute "NPCType" (string): which NPC type spawns here (default "skeleton")

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
local NPC_BEHAVIOR = GameConfig.NPCBehavior

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
  lastPatrolMoveTime: number,
  patrolTarget: Vector3?,
  carriedDoubloons: number,

  -- Flinch tracking
  flinchEndTime: number,

  -- Lunge tracking
  lungeTarget: Vector3?,
  lungeStartTime: number,

  -- Respawn
  respawnTime: number?,
  alive: boolean,
}

local ActiveNPCs: { [number]: NPCEntry } = {}
local ActiveNPCCount = 0
local nextNPCId = 1

-- Folder in workspace for NPC models
local NPCsFolder: Folder = nil

-- Spawn points folder
local SpawnPointsFolder: Folder? = nil

-- Respawn queue: { { spawnTime: number, spawnPosition: Vector3, zone: string, spawnPoint: Part? } }
local RespawnQueue: { { spawnTime: number, spawnPosition: Vector3, zone: string, spawnPoint: Part? } } =
  {}

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
  humanoid.JumpPower = 0 -- No jumping for skeletons (NPC-003 will use SimplePath)
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
  @param npcEntry The NPC
  @param aggroRange The aggro range in studs
  @return The closest valid player or nil, and the distance
]]
local function findClosestTarget(npcEntry: NPCEntry, aggroRange: number): (Player?, number)
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

    local dist = (hrp.Position - npcPos).Magnitude
    if dist <= aggroRange and dist < closestDist then
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
  Gets the effective aggro range, accounting for night bonus.
]]
local function getEffectiveAggroRange(): number
  local range = SKELETON.aggroRange
  if DayNightService and DayNightService:IsNight() then
    range = range * (1 + NPC_BEHAVIOR.nightAggroRangeBonus)
  end
  return range
end

--[[
  Gets the effective walk speed, accounting for night bonus.
]]
local function getEffectiveSpeed(): number
  local speed = PLAYER_BASE_SPEED * SKELETON.speedMultiplier
  if DayNightService and DayNightService:IsNight() then
    speed = speed * (1 + NPC_BEHAVIOR.nightSpeedBonus)
  end
  return speed
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

    flinchEndTime = 0,

    lungeTarget = nil,
    lungeStartTime = 0,

    respawnTime = nil,
    alive = true,
  }

  ActiveNPCs[npcId] = entry
  ActiveNPCCount = ActiveNPCCount + 1

  -- Fire signals
  NPCService.Client.NPCSpawned:FireAll(npcId, "skeleton", position)

  print(string.format("[NPCService] Spawned Cursed Skeleton #%d at zone '%s'", npcId, zone))

  return entry
end

--[[
  Removes an NPC from the world.
  @param npcId The NPC instance ID
]]
local function despawnNPC(npcId: number)
  local entry = ActiveNPCs[npcId]
  if not entry then
    return
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
]]
local function setState(entry: NPCEntry, newState: string)
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

  -- Check distance (must still be within range)
  local dist = (targetHRP.Position - entry.rootPart.Position).Magnitude
  if dist > SKELETON.slashRange + 2 then -- small tolerance
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
    ragdollDuration = SKELETON.slashRagdollDuration
    knockbackForce = GameConfig.Ragdoll.lightHitKnockback -- NPC hits use light knockback
    spillPercent = SKELETON.slashLootSpillPercent
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
  local CombatService = Knit.GetService("CombatService")
  if CombatService then
    if targetIsBlocking then
      CombatService.Client.BlockImpact:Fire(target, "Cursed Skeleton", ragdollDuration)
    end
    CombatService.Client.RagdollTrigger:Fire(
      target,
      "Cursed Skeleton",
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
      "[NPCService] Skeleton #%d hit %s — ragdoll %.1fs, spilled %d",
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

  -- Update humanoid speed for night bonus
  if entry.humanoid and entry.humanoid.Parent then
    entry.humanoid.WalkSpeed = getEffectiveSpeed()
  end

  local now = os.clock()
  local aggroRange = getEffectiveAggroRange()

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
    -- Check for players in aggro range
    local target, targetDist = findClosestTarget(entry, aggroRange)
    if target then
      entry.targetPlayer = target
      setState(entry, AI_STATE.CHASE)
      return
    end

    -- Patrol: wander around spawn point
    if not entry.patrolTarget or now - entry.lastPatrolMoveTime > 5 then
      -- Pick a new random patrol point within 15 studs of spawn
      entry.patrolTarget = randomPositionAround(entry.spawnPosition, 15)
      entry.lastPatrolMoveTime = now
    end

    -- Move toward patrol target
    if entry.humanoid and entry.patrolTarget then
      entry.humanoid:MoveTo(entry.patrolTarget)
    end

    -- Check if reached patrol target
    if entry.patrolTarget then
      local distToPatrol = (entry.position - entry.patrolTarget).Magnitude
      if distToPatrol < 3 then
        -- Wait briefly at the waypoint
        entry.patrolTarget = nil
        entry.lastPatrolMoveTime = now
      end
    end
    return
  end

  if entry.aiState == AI_STATE.CHASE then
    -- Validate target is still valid
    local target = entry.targetPlayer
    if not target or not target.Parent then
      entry.targetPlayer = nil
      setState(entry, AI_STATE.PATROL)
      return
    end

    local targetHRP = getPlayerHRP(target)
    if not targetHRP then
      entry.targetPlayer = nil
      setState(entry, AI_STATE.PATROL)
      return
    end

    -- Check if target entered Harbor
    if SessionStateService and SessionStateService:IsInHarbor(target) then
      entry.targetPlayer = nil
      setState(entry, AI_STATE.PATROL)
      return
    end

    -- Check leash distance from spawn
    local distFromSpawn = (entry.position - entry.spawnPosition).Magnitude
    if distFromSpawn > NPC_BEHAVIOR.leashDistance then
      entry.targetPlayer = nil
      setState(entry, AI_STATE.PATROL)
      -- Move back toward spawn
      if entry.humanoid then
        entry.humanoid:MoveTo(entry.spawnPosition)
      end
      return
    end

    local targetPos = targetHRP.Position
    local distToTarget = (entry.position - targetPos).Magnitude

    -- Check if target moved out of aggro range (with some hysteresis)
    if distToTarget > aggroRange * 1.5 then
      entry.targetPlayer = nil
      setState(entry, AI_STATE.PATROL)
      return
    end

    -- Check if close enough for attack
    if distToTarget <= SKELETON.slashRange then
      -- Decide attack type: prefer lunge if cooldown is up and distance is right
      if distToTarget > 3 and now - entry.lastLungeTime >= SKELETON.lungeCooldown then
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

      if now - entry.lastSlashTime >= SKELETON.slashCooldown then
        -- Start slash attack
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
        NPCService.Client.NPCAttack:FireAll(entry.id, "slash", targetPos)
        return
      end
    end

    -- Move toward target
    if entry.humanoid then
      entry.humanoid:MoveTo(targetPos)
    end

    -- Re-evaluate: check if another player is closer
    local closerTarget, closerDist = findClosestTarget(entry, aggroRange)
    if closerTarget and closerTarget ~= target and closerDist < distToTarget * 0.6 then
      entry.targetPlayer = closerTarget
    end
    return
  end

  if entry.aiState == AI_STATE.ATTACK_SLASH then
    local elapsed = now - entry.aiStateStartTime

    -- Windup phase
    if elapsed < SKELETON.slashWindup then
      -- NPC is winding up — frozen in place
      return
    end

    -- Execute slash hit
    if elapsed >= SKELETON.slashWindup and entry.lastSlashTime < entry.aiStateStartTime then
      entry.lastSlashTime = now

      -- Check if target is still valid and in range
      local target = entry.targetPlayer
      if target and target.Parent then
        handleNPCHitPlayer(entry, target)
      end
    end

    -- After slash, return to chase
    if elapsed > SKELETON.slashWindup + 0.3 then
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
  entry.flinchEndTime = os.clock() + SKELETON.flinchDuration
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

  -- Calculate loot drop: carried doubloons + bonus
  local bonusDoubloons = math.random(SKELETON.deathBonusMin, SKELETON.deathBonusMax)
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

  print(
    string.format(
      "[NPCService] Skeleton #%d killed by %s — dropped %d doubloons (%d bonus + %d carried)",
      npcId,
      killedByPlayer and killedByPlayer.Name or "unknown",
      totalDrop,
      bonusDoubloons,
      entry.carriedDoubloons
    )
  )

  -- Queue respawn
  table.insert(RespawnQueue, {
    spawnTime = os.clock() + SKELETON.respawnTime,
    spawnPosition = entry.spawnPosition,
    zone = entry.zone,
    spawnPoint = entry.spawnPoint,
  })

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
  end
  warn("[NPCService] Unknown NPC type: " .. tostring(npcType))
  return nil
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

  -- Spawn initial NPCs at spawn points
  local spawnPoints = SpawnPointsFolder and SpawnPointsFolder:GetChildren() or {}
  local spawnedCount = 0
  for _, point in spawnPoints do
    if point:IsA("BasePart") then
      local npcType = point:GetAttribute("NPCType") or "skeleton"
      if npcType == "skeleton" then
        local zone = point:GetAttribute("Zone") or "unknown"
        spawnSkeleton(point.Position, zone, point)
        spawnedCount = spawnedCount + 1
      end
    end
  end

  -- If no spawn points exist, spawn a few at default positions for testing
  if spawnedCount == 0 then
    warn("[NPCService] No NPC spawn points found. Spawning test skeletons near origin.")
    for i = 1, 3 do
      local angle = (i / 3) * math.pi * 2
      local pos = Vector3.new(math.cos(angle) * 40, 5, math.sin(angle) * 40)
      spawnSkeleton(pos, "test", nil)
    end
  end

  -- Main AI update loop
  RunService.Heartbeat:Connect(function(dt: number)
    -- Update all active NPCs
    for _, entry in ActiveNPCs do
      if entry.alive then
        updateNPCAI(entry, dt)
      end
    end

    -- Process respawn queue
    local now = os.clock()
    local i = 1
    while i <= #RespawnQueue do
      local respawn = RespawnQueue[i]
      if now >= respawn.spawnTime then
        -- Respawn the NPC
        spawnSkeleton(respawn.spawnPosition, respawn.zone, respawn.spawnPoint)
        table.remove(RespawnQueue, i)
      else
        i = i + 1
      end
    end
  end)

  print(
    string.format(
      "[NPCService] Started — %d NPCs spawned, %d spawn points found",
      ActiveNPCCount,
      #spawnPoints
    )
  )
end

return NPCService
