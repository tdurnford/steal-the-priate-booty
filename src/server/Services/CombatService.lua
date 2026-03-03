--[[
  CombatService.lua
  Server-authoritative combat service for light swing, heavy swing, block, and dash.

  Handles:
    - Validating client attack inputs (cooldowns, state checks)
    - Server-side hit detection (forward arc, short/medium range)
    - Light swing: fast 0.4s cooldown, 8 stud range, 70° arc
    - Heavy swing: 0.8s charge, 1.2s cooldown, 10 stud range, 90° arc
    - Block: secondary click hold, 50% speed, reduced ragdoll/spill on hit
    - Dash: directional 10-stud dash, 3s cooldown, 0.3s invulnerability frames
    - Damage to containers (gear containerDamage value)
    - Damage to players (ragdoll + loot spill, reduced when blocking)
    - Per-target hit cooldown enforcement (2s)
    - Rate-limiting attack inputs to prevent exploit spam

  Client sends attack intent via AttackRequest (light) or HeavyAttackRequest (heavy).
  Client sends block state via BlockStateChanged.
  Client sends dash intent via DashRequest.
  Server validates, performs hit detection, and fires results back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local CombatService = Knit.CreateService({
  Name = "CombatService",
  Client = {
    -- Client fires this to request a light swing attack.
    AttackRequest = Knit.CreateSignal(),

    -- Client fires this to request a heavy swing attack.
    -- Args: (chargeTime: number) — how long the client held the button
    HeavyAttackRequest = Knit.CreateSignal(),

    -- Client fires this to notify the server of block state changes.
    -- Args: (blocking: boolean)
    BlockStateChanged = Knit.CreateSignal(),

    -- Client fires this to request a dash in a direction.
    -- Args: (direction: Vector3) — unit vector in world space
    DashRequest = Knit.CreateSignal(),

    -- Fired to the dashing player to confirm dash (for VFX/movement).
    -- Args: (direction: Vector3)
    DashConfirm = Knit.CreateSignal(),

    -- Fired to the attacker when their swing connects.
    -- Args: (hitType: string, targetName: string?, attackType: string?)
    --   hitType: "player" | "container" | "npc" | "miss"
    --   attackType: "light" | "heavy"
    SwingResult = Knit.CreateSignal(),

    -- Fired to a player when they are hit and should ragdoll.
    -- Args: (attackerName: string, ragdollDuration: number, knockbackVelocity: Vector3)
    RagdollTrigger = Knit.CreateSignal(),

    -- Fired to a player when they successfully block an incoming hit.
    -- Args: (attackerName: string, ragdollDuration: number)
    BlockImpact = Knit.CreateSignal(),

    -- Fired to all players near a loot spill for VFX.
    -- Args: (targetPosition: Vector3, spillAmount: number)
    LootSpillVFX = Knit.CreateSignal(),

    -- Client fires this to request a lunge attack (Rank 2 unlock).
    LungeRequest = Knit.CreateSignal(),

    -- Fired to the lunging player to confirm lunge (for VFX/movement).
    -- Args: (direction: Vector3)
    LungeConfirm = Knit.CreateSignal(),

    -- Client fires this to request a spin attack (Rank 4 unlock).
    SpinRequest = Knit.CreateSignal(),

    -- Fired to the spinning player to confirm spin (for VFX).
    SpinConfirm = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
CombatService.PlayerHitPlayer = Signal.new() -- (attacker, target, spillAmount)
CombatService.PlayerHitContainer = Signal.new() -- (attacker, containerId, destroyed)
CombatService.PlayerHitNPC = Signal.new() -- (attacker, npcId, killed)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local ContainerService = nil
local DoubloonService = nil
local HarborService = nil
local NPCService = nil
local RankEffectsService = nil

-- Per-player last attack timestamp for rate limiting
local LastAttackTime: { [Player]: number } = {}

-- Light swing parameters
local LIGHT_SWING_RANGE = 8 -- studs
local LIGHT_SWING_ARC = math.rad(70) -- 70 degree half-angle cone
local LIGHT_SWING_COOLDOWN = GameConfig.Combat.lightSwingCooldown -- 0.4s

-- Heavy swing parameters
local HEAVY_SWING_RANGE = GameConfig.Combat.heavySwingRange -- 10 studs
local HEAVY_SWING_ARC = math.rad(GameConfig.Combat.heavySwingArc) -- 90 degree half-angle cone
local HEAVY_SWING_COOLDOWN = GameConfig.Combat.heavySwingCooldown -- 1.2s
local HEAVY_SWING_CHARGE_TIME = GameConfig.Combat.heavySwingChargeTime -- 0.8s

-- Block parameters
local BLOCK_SPEED_MULTIPLIER = GameConfig.Combat.blockSpeedMultiplier -- 0.5

-- Dash parameters
local DASH_DISTANCE = GameConfig.Combat.dashDistance -- 10 studs
local DASH_COOLDOWN = GameConfig.Combat.dashCooldown -- 3s
local DASH_INVULN_TIME = GameConfig.Combat.dashInvulnerabilityTime -- 0.3s

-- Lunge parameters (Rank 2 unlock)
local LUNGE_WINDUP = GameConfig.Combat.lungeWindup -- 0.3s
local LUNGE_DASH_DISTANCE = GameConfig.Combat.lungeDashDistance -- 6 studs
local LUNGE_RANGE = GameConfig.Combat.lungeRange -- 8 studs
local LUNGE_ARC = math.rad(GameConfig.Combat.lungeArc) -- 70 degrees
local LUNGE_COOLDOWN = GameConfig.Combat.lungeCooldown -- 4s
local LUNGE_RAGDOLL = GameConfig.Combat.lungeRagdollDuration -- 2.0s
local LUNGE_SPILL = GameConfig.Combat.lungeLootSpillPercent -- 0.15
local LUNGE_KNOCKBACK = GameConfig.Combat.lungeKnockback -- 25

-- Spin parameters (Rank 4 unlock)
local SPIN_WINDUP = GameConfig.Combat.spinWindup -- 0.5s
local SPIN_RANGE = GameConfig.Combat.spinRange -- 6 studs
local SPIN_ARC = math.rad(GameConfig.Combat.spinArc) -- 180 degrees (= full 360)
local SPIN_COOLDOWN = GameConfig.Combat.spinCooldown -- 5s
local SPIN_RAGDOLL = GameConfig.Combat.spinRagdollDuration -- 1.5s
local SPIN_SPILL = GameConfig.Combat.spinLootSpillPercent -- 0.10
local SPIN_KNOCKBACK = GameConfig.Combat.spinKnockback -- 20

-- Per-player lunge/spin cooldown timestamps
local LastLungeTime: { [Player]: number } = {}
local LastSpinTime: { [Player]: number } = {}

-- Per-player default walk speed (stored on first block for restoration)
local PlayerDefaultWalkSpeed: { [Player]: number } = {}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Gets the gear damage value for a player's currently equipped gear.
  @param player The attacking player
  @return containerDamage number (defaults to 1)
]]
local function getGearDamage(player: Player): number
  if not DataService then
    return 1
  end
  local gearId = DataService:GetEquippedGear(player)
  if not gearId then
    return 1
  end
  local gearDef = GameConfig.GearById[gearId]
  if not gearDef then
    return 1
  end
  return gearDef.containerDamage
end

--[[
  Validates that a player can perform an attack.
  Checks: session initialized, not ragdolling, not in recovery, cooldown elapsed.
  @param player The attacking player
  @param cooldown The cooldown duration for this attack type
  @return (canAttack: boolean, reason: string?)
]]
local function validateAttack(player: Player, cooldown: number): (boolean, string?)
  if not SessionStateService or not SessionStateService:IsInitialized(player) then
    return false, "Session not initialized"
  end

  if SessionStateService:IsRagdolling(player) then
    return false, "Cannot attack while ragdolled"
  end

  if SessionStateService:IsInRecovery(player) then
    return false, "Cannot attack during recovery"
  end

  if SessionStateService:IsBlocking(player) then
    return false, "Cannot attack while blocking"
  end

  if SessionStateService:IsDashing(player) then
    return false, "Cannot attack while dashing"
  end

  -- Rate limiting: enforce minimum cooldown between attacks
  local now = os.clock()
  local lastAttack = LastAttackTime[player]
  if lastAttack and (now - lastAttack) < cooldown then
    return false, "Attack on cooldown"
  end

  return true, nil
end

--[[
  Gets the HumanoidRootPart for a player, or nil if unavailable.
]]
local function getHRP(player: Player): BasePart?
  local character = player.Character
  if not character then
    return nil
  end
  return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
  Checks if a target position is within the attacker's forward arc.
  @param attackerCFrame The attacker's CFrame (position + facing)
  @param targetPosition The target's world position
  @param range The max range in studs
  @param arc The max half-angle in radians
  @return true if target is within range and arc
]]
local function isInSwingArc(
  attackerCFrame: CFrame,
  targetPosition: Vector3,
  range: number,
  arc: number
): boolean
  local toTarget = targetPosition - attackerCFrame.Position
  local distance = toTarget.Magnitude

  if distance > range then
    return false
  end

  -- Check angle from look direction
  local lookDir = attackerCFrame.LookVector
  local dirToTarget = toTarget.Unit
  local dotProduct = lookDir:Dot(dirToTarget)
  local angle = math.acos(math.clamp(dotProduct, -1, 1))

  return angle <= arc
end

--[[
  Performs server-side hit detection for a swing attack.
  Checks for player targets, NPC targets, and container targets in the attacker's forward arc.
  Priority: players > NPCs > containers.
  @param attacker The attacking player
  @param range The max range in studs
  @param arc The max half-angle in radians
  @return (hitType: string, target: any?)
    hitType: "player" | "npc" | "container" | "miss"
    target: Player (for player hits), NPC entry (for NPC hits), or container entry (for container hits)
]]
local function performHitDetection(attacker: Player, range: number, arc: number): (string, any?)
  local attackerHRP = getHRP(attacker)
  if not attackerHRP then
    return "miss", nil
  end

  local attackerCFrame = attackerHRP.CFrame

  -- Check player targets first (PvP priority)
  -- Harbor safe zone: skip PvP if attacker is in harbor
  local attackerInHarbor = SessionStateService and SessionStateService:IsInHarbor(attacker)
  local closestPlayerDist = math.huge
  local closestPlayer: Player? = nil

  if not attackerInHarbor then
    for _, otherPlayer in Players:GetPlayers() do
      if otherPlayer ~= attacker then
        -- Skip targets that are in the Harbor safe zone
        if SessionStateService:IsInHarbor(otherPlayer) then
          continue
        end
        local otherHRP = getHRP(otherPlayer)
        if otherHRP then
          if isInSwingArc(attackerCFrame, otherHRP.Position, range, arc) then
            -- Check per-target cooldown
            if SessionStateService:CanHitTarget(attacker, otherPlayer.UserId) then
              -- Check target is not already ragdolling or dashing (i-frames)
              if
                not SessionStateService:IsRagdolling(otherPlayer)
                and not SessionStateService:IsDashing(otherPlayer)
              then
                local dist = (otherHRP.Position - attackerCFrame.Position).Magnitude
                if dist < closestPlayerDist then
                  closestPlayerDist = dist
                  closestPlayer = otherPlayer
                end
              end
            end
          end
        end
      end
    end
  end

  if closestPlayer then
    return "player", closestPlayer
  end

  -- Check NPC targets (priority over containers)
  local closestNPCDist = math.huge
  local closestNPCEntry = nil

  if NPCService then
    local npcsFolder = workspace:FindFirstChild("NPCs")
    if npcsFolder then
      for _, child in npcsFolder:GetChildren() do
        if child:IsA("Model") then
          local rootPart = child:FindFirstChild("HumanoidRootPart") or child:FindFirstChild("Torso")
          if rootPart and rootPart:IsA("BasePart") then
            if isInSwingArc(attackerCFrame, rootPart.Position, range, arc) then
              local dist = (rootPart.Position - attackerCFrame.Position).Magnitude
              if dist < closestNPCDist then
                local npcEntry = NPCService:GetNPCByPart(rootPart)
                if npcEntry and npcEntry.alive then
                  closestNPCDist = dist
                  closestNPCEntry = npcEntry
                end
              end
            end
          end
        end
      end
    end
  end

  if closestNPCEntry then
    return "npc", closestNPCEntry
  end

  -- Check container targets
  local closestContainerDist = math.huge
  local closestContainerEntry = nil

  if ContainerService then
    local rayOrigin = attackerCFrame.Position
    for _, child in
      workspace:FindFirstChild("Containers") and workspace.Containers:GetChildren() or {}
    do
      if child:IsA("Model") then
        local body = child:FindFirstChild("Body")
        if body and body:IsA("BasePart") then
          if isInSwingArc(attackerCFrame, body.Position, range, arc) then
            local dist = (body.Position - rayOrigin).Magnitude
            if dist < closestContainerDist then
              local entry = ContainerService:GetContainerByPart(body)
              if entry then
                closestContainerDist = dist
                closestContainerEntry = entry
              end
            end
          end
        end
      end
    end
  end

  if closestContainerEntry then
    return "container", closestContainerEntry
  end

  return "miss", nil
end

--[[
  Handles a player hitting another player.
  Applies ragdoll, calculates loot spill, scatters doubloons.
  @param attacker The attacking player
  @param target The hit player
  @param attackType "light" | "heavy" — determines ragdoll/knockback/spill values
]]
local function handlePlayerHit(attacker: Player, target: Player, attackType: string)
  -- Record the hit for per-target cooldown
  SessionStateService:RecordHitTarget(attacker, target.UserId)

  -- Check if the target is blocking
  local targetIsBlocking = SessionStateService:IsBlocking(target)

  -- Select ragdoll/knockback/spill values based on attack type and block state
  local ragdollDuration, knockbackForce, spillPercent
  if targetIsBlocking then
    -- Blocked hit: reduced ragdoll, no knockback, 5% spill
    ragdollDuration = GameConfig.Ragdoll.blockedHitDuration
    knockbackForce = GameConfig.Ragdoll.blockedHitKnockback
    spillPercent = GameConfig.LootSpill.blockedHitPercent
    -- End block state since player is ragdolled
    SessionStateService:SetBlocking(target, false)
    -- Restore walk speed on the target since block is ending via ragdoll
    local targetHumanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
    if targetHumanoid and PlayerDefaultWalkSpeed[target] then
      targetHumanoid.WalkSpeed = PlayerDefaultWalkSpeed[target]
    end
  else
    local isHeavy = attackType == "heavy"
    ragdollDuration = if isHeavy
      then GameConfig.Ragdoll.heavyHitDuration
      else GameConfig.Ragdoll.lightHitDuration
    knockbackForce = if isHeavy
      then GameConfig.Ragdoll.heavyHitKnockback
      else GameConfig.Ragdoll.lightHitKnockback
    spillPercent = if isHeavy
      then GameConfig.LootSpill.heavyHitPercent
      else GameConfig.LootSpill.lightHitPercent
  end

  SessionStateService:StartRagdoll(target, ragdollDuration)

  -- Calculate knockback velocity: push target away from attacker
  local attackerHRP = getHRP(attacker)
  local targetHRP = getHRP(target)
  local knockbackVelocity = Vector3.zero
  if knockbackForce > 0 and attackerHRP and targetHRP then
    local knockbackDir = (targetHRP.Position - attackerHRP.Position)
    -- Use XZ direction only, normalize
    knockbackDir = Vector3.new(knockbackDir.X, 0, knockbackDir.Z)
    if knockbackDir.Magnitude > 0.01 then
      knockbackDir = knockbackDir.Unit
    else
      -- Fallback to attacker's look direction
      knockbackDir = attackerHRP.CFrame.LookVector
      knockbackDir = Vector3.new(knockbackDir.X, 0, knockbackDir.Z).Unit
    end
    knockbackVelocity = knockbackDir * knockbackForce
  end

  if targetIsBlocking then
    -- Send block impact to the target (different visual than full ragdoll)
    CombatService.Client.BlockImpact:Fire(target, attacker.Name, ragdollDuration)
  end

  -- Notify the target to ragdoll visually (with knockback)
  CombatService.Client.RagdollTrigger:Fire(
    target,
    attacker.Name,
    ragdollDuration,
    knockbackVelocity
  )

  -- Calculate loot spill
  local heldDoubloons = SessionStateService:GetHeldDoubloons(target)
  local hasBounty = SessionStateService:HasBounty(target)
  local spillAmount = GameConfig.calculateSpill(heldDoubloons, spillPercent, hasBounty)

  if spillAmount > 0 then
    -- Deduct from target
    SessionStateService:AddHeldDoubloons(target, -spillAmount)

    -- Scatter at target's position
    local spillHRP = getHRP(target)
    local spillPos = if spillHRP then spillHRP.Position else Vector3.new(0, 5, 0)

    if DoubloonService then
      local isHeavy = attackType == "heavy"
      DoubloonService:ScatterDoubloons(spillPos, spillAmount, if isHeavy then 6 else 4)
    end

    -- Notify nearby clients for VFX
    CombatService.Client.LootSpillVFX:FireAll(spillPos, spillAmount)
  end

  -- Fire server-side signal
  CombatService.PlayerHitPlayer:Fire(attacker, target, spillAmount)

  local hitLabel = if targetIsBlocking then "blocked" else attackType
  print(
    string.format(
      "[CombatService] %s %s-hit %s — ragdoll %.1fs, spilled %d doubloons",
      attacker.Name,
      hitLabel,
      target.Name,
      ragdollDuration,
      spillAmount
    )
  )
end

--[[
  Handles a player hitting a container.
  Applies gear damage to the container.
]]
local function handleContainerHit(attacker: Player, containerEntry: any)
  local damage = getGearDamage(attacker)
  local destroyed, hpFraction =
    ContainerService:DamageContainer(containerEntry.id, damage, attacker)

  -- Fire server-side signal
  CombatService.PlayerHitContainer:Fire(attacker, containerEntry.id, destroyed)

  if destroyed then
    print(
      string.format(
        "[CombatService] %s destroyed %s with %d damage",
        attacker.Name,
        containerEntry.def.name,
        damage
      )
    )
  end
end

--[[
  Handles a player hitting an NPC.
  Applies gear damage to the NPC via NPCService.
]]
local function handleNPCHit(attacker: Player, npcEntry: any)
  local damage = getGearDamage(attacker)
  local killed, _hpFraction = NPCService:DamageNPC(npcEntry.id, damage, attacker)

  -- Fire server-side signal
  CombatService.PlayerHitNPC:Fire(attacker, npcEntry.id, killed)

  if killed then
    print(
      string.format(
        "[CombatService] %s killed %s #%d with %d damage",
        attacker.Name,
        npcEntry.npcType,
        npcEntry.id,
        damage
      )
    )
  end
end

--[[
  Performs server-side hit detection that returns ALL targets in arc (for spin attack).
  Returns separate lists for players, NPCs, and containers.
]]
local function performMultiHitDetection(
  attacker: Player,
  range: number,
  arc: number
): ({ Player }, { any }, { any })
  local attackerHRP = getHRP(attacker)
  if not attackerHRP then
    return {}, {}, {}
  end

  local attackerCFrame = attackerHRP.CFrame
  local hitPlayers: { Player } = {}
  local hitNPCs: { any } = {}
  local hitContainers: { any } = {}

  -- Check player targets
  local attackerInHarbor = SessionStateService and SessionStateService:IsInHarbor(attacker)
  if not attackerInHarbor then
    for _, otherPlayer in Players:GetPlayers() do
      if otherPlayer ~= attacker then
        if SessionStateService:IsInHarbor(otherPlayer) then
          continue
        end
        local otherHRP = getHRP(otherPlayer)
        if otherHRP then
          if isInSwingArc(attackerCFrame, otherHRP.Position, range, arc) then
            if SessionStateService:CanHitTarget(attacker, otherPlayer.UserId) then
              if
                not SessionStateService:IsRagdolling(otherPlayer)
                and not SessionStateService:IsDashing(otherPlayer)
              then
                table.insert(hitPlayers, otherPlayer)
              end
            end
          end
        end
      end
    end
  end

  -- Check NPC targets
  if NPCService then
    local npcsFolder = workspace:FindFirstChild("NPCs")
    if npcsFolder then
      for _, child in npcsFolder:GetChildren() do
        if child:IsA("Model") then
          local rootPart = child:FindFirstChild("HumanoidRootPart") or child:FindFirstChild("Torso")
          if rootPart and rootPart:IsA("BasePart") then
            if isInSwingArc(attackerCFrame, rootPart.Position, range, arc) then
              local npcEntry = NPCService:GetNPCByPart(rootPart)
              if npcEntry and npcEntry.alive then
                table.insert(hitNPCs, npcEntry)
              end
            end
          end
        end
      end
    end
  end

  -- Check container targets
  if ContainerService then
    for _, child in
      workspace:FindFirstChild("Containers") and workspace.Containers:GetChildren() or {}
    do
      if child:IsA("Model") then
        local body = child:FindFirstChild("Body")
        if body and body:IsA("BasePart") then
          if isInSwingArc(attackerCFrame, body.Position, range, arc) then
            local entry = ContainerService:GetContainerByPart(body)
            if entry then
              table.insert(hitContainers, entry)
            end
          end
        end
      end
    end
  end

  return hitPlayers, hitNPCs, hitContainers
end

--[[
  Handles a player hit with custom ragdoll/knockback/spill parameters (for lunge/spin).
  @param attacker The attacking player
  @param target The hit player
  @param ragdollDuration Custom ragdoll duration
  @param spillPercent Custom loot spill percentage
  @param knockbackForce Custom knockback force
  @param attackType Label for logging ("lunge" or "spin")
]]
local function handlePlayerHitCustom(
  attacker: Player,
  target: Player,
  ragdollDuration: number,
  spillPercent: number,
  knockbackForce: number,
  attackType: string
)
  -- Record the hit for per-target cooldown
  SessionStateService:RecordHitTarget(attacker, target.UserId)

  -- Check if the target is blocking
  local targetIsBlocking = SessionStateService:IsBlocking(target)

  if targetIsBlocking then
    ragdollDuration = GameConfig.Ragdoll.blockedHitDuration
    knockbackForce = GameConfig.Ragdoll.blockedHitKnockback
    spillPercent = GameConfig.LootSpill.blockedHitPercent
    SessionStateService:SetBlocking(target, false)
    local targetHumanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
    if targetHumanoid and PlayerDefaultWalkSpeed[target] then
      targetHumanoid.WalkSpeed = PlayerDefaultWalkSpeed[target]
    end
  end

  SessionStateService:StartRagdoll(target, ragdollDuration)

  -- Calculate knockback velocity
  local attackerHRP = getHRP(attacker)
  local targetHRP = getHRP(target)
  local knockbackVelocity = Vector3.zero
  if knockbackForce > 0 and attackerHRP and targetHRP then
    local knockbackDir = (targetHRP.Position - attackerHRP.Position)
    knockbackDir = Vector3.new(knockbackDir.X, 0, knockbackDir.Z)
    if knockbackDir.Magnitude > 0.01 then
      knockbackDir = knockbackDir.Unit
    else
      knockbackDir = attackerHRP.CFrame.LookVector
      knockbackDir = Vector3.new(knockbackDir.X, 0, knockbackDir.Z).Unit
    end
    knockbackVelocity = knockbackDir * knockbackForce
  end

  if targetIsBlocking then
    CombatService.Client.BlockImpact:Fire(target, attacker.Name, ragdollDuration)
  end

  CombatService.Client.RagdollTrigger:Fire(
    target,
    attacker.Name,
    ragdollDuration,
    knockbackVelocity
  )

  -- Calculate loot spill
  local heldDoubloons = SessionStateService:GetHeldDoubloons(target)
  local hasBounty = SessionStateService:HasBounty(target)
  local spillAmount = GameConfig.calculateSpill(heldDoubloons, spillPercent, hasBounty)

  if spillAmount > 0 then
    SessionStateService:AddHeldDoubloons(target, -spillAmount)
    local spillHRP = getHRP(target)
    local spillPos = if spillHRP then spillHRP.Position else Vector3.new(0, 5, 0)
    if DoubloonService then
      DoubloonService:ScatterDoubloons(spillPos, spillAmount, 5)
    end
    CombatService.Client.LootSpillVFX:FireAll(spillPos, spillAmount)
  end

  CombatService.PlayerHitPlayer:Fire(attacker, target, spillAmount)

  local hitLabel = if targetIsBlocking then "blocked" else attackType
  print(
    string.format(
      "[CombatService] %s %s-hit %s — ragdoll %.1fs, spilled %d doubloons",
      attacker.Name,
      hitLabel,
      target.Name,
      ragdollDuration,
      spillAmount
    )
  )
end

--------------------------------------------------------------------------------
-- CLIENT REQUEST HANDLERS
--------------------------------------------------------------------------------

--[[
  Called when a client fires AttackRequest (light swing).
  Validates the attack, performs hit detection, and processes the result.
]]
local function onAttackRequest(player: Player)
  -- Validate the attack (use the larger of light/heavy cooldown for rate limit)
  local canAttack, reason = validateAttack(player, LIGHT_SWING_COOLDOWN)
  if not canAttack then
    return
  end

  -- Record attack timestamp for rate limiting
  LastAttackTime[player] = os.clock()

  -- Perform hit detection with light swing range/arc
  local hitType, target = performHitDetection(player, LIGHT_SWING_RANGE, LIGHT_SWING_ARC)

  if hitType == "player" and target then
    handlePlayerHit(player, target :: Player, "light")
    CombatService.Client.SwingResult:Fire(player, "player", (target :: Player).Name, "light")
  elseif hitType == "npc" and target then
    handleNPCHit(player, target)
    CombatService.Client.SwingResult:Fire(player, "npc", target.npcType, "light")
  elseif hitType == "container" and target then
    handleContainerHit(player, target)
    CombatService.Client.SwingResult:Fire(player, "container", nil, "light")
  else
    CombatService.Client.SwingResult:Fire(player, "miss", nil, "light")
  end
end

--[[
  Called when a client fires HeavyAttackRequest (heavy swing).
  Validates charge time, cooldown, performs wide-arc hit detection.
  @param player The attacking player
  @param chargeTime How long the client claims to have charged (sanity checked)
]]
local function onHeavyAttackRequest(player: Player, chargeTime: number)
  -- Sanity check chargeTime is a number
  if type(chargeTime) ~= "number" then
    return
  end

  -- Validate the attack with heavy cooldown
  local canAttack, reason = validateAttack(player, HEAVY_SWING_COOLDOWN)
  if not canAttack then
    return
  end

  -- Validate charge time was sufficient (with small tolerance for network latency)
  if chargeTime < (HEAVY_SWING_CHARGE_TIME - 0.1) then
    return
  end

  -- Record attack timestamp for rate limiting
  LastAttackTime[player] = os.clock()

  -- Perform hit detection with heavy swing range/arc (wider + longer)
  local hitType, target = performHitDetection(player, HEAVY_SWING_RANGE, HEAVY_SWING_ARC)

  if hitType == "player" and target then
    handlePlayerHit(player, target :: Player, "heavy")
    CombatService.Client.SwingResult:Fire(player, "player", (target :: Player).Name, "heavy")
  elseif hitType == "npc" and target then
    handleNPCHit(player, target)
    CombatService.Client.SwingResult:Fire(player, "npc", target.npcType, "heavy")
  elseif hitType == "container" and target then
    -- Heavy swing deals 2x gear damage to containers
    handleContainerHit(player, target)
    CombatService.Client.SwingResult:Fire(player, "container", nil, "heavy")
  else
    CombatService.Client.SwingResult:Fire(player, "miss", nil, "heavy")
  end
end

--[[
  Called when a client fires LungeRequest (Rank 2 unlock).
  Forward dash + slash at endpoint.
]]
local function onLungeRequest(player: Player)
  -- Check rank unlock
  if not RankEffectsService or not RankEffectsService:HasLunge(player) then
    return
  end

  -- Validate basic attack state
  local canAttack, _ = validateAttack(player, LUNGE_COOLDOWN)
  if not canAttack then
    return
  end

  -- Check lunge-specific cooldown
  local now = os.clock()
  local lastLunge = LastLungeTime[player]
  if lastLunge and (now - lastLunge) < LUNGE_COOLDOWN then
    return
  end

  LastLungeTime[player] = now
  LastAttackTime[player] = now

  -- Get lunge direction (player's facing direction)
  local hrp = getHRP(player)
  if not hrp then
    return
  end
  local lookDir = hrp.CFrame.LookVector
  local lungeDir = Vector3.new(lookDir.X, 0, lookDir.Z)
  if lungeDir.Magnitude > 0.01 then
    lungeDir = lungeDir.Unit
  else
    return
  end

  -- Confirm lunge to client (triggers VFX and movement)
  CombatService.Client.LungeConfirm:Fire(player, lungeDir)

  -- Schedule hit detection after windup delay (player dashes then hits at endpoint)
  task.delay(LUNGE_WINDUP, function()
    -- Re-check state (could have been ragdolled during windup)
    if SessionStateService:IsRagdolling(player) then
      return
    end

    -- Hit detection at endpoint (standard single-target)
    local hitType, target = performHitDetection(player, LUNGE_RANGE, LUNGE_ARC)

    if hitType == "player" and target then
      handlePlayerHitCustom(
        player,
        target :: Player,
        LUNGE_RAGDOLL,
        LUNGE_SPILL,
        LUNGE_KNOCKBACK,
        "lunge"
      )
      CombatService.Client.SwingResult:Fire(player, "player", (target :: Player).Name, "lunge")
    elseif hitType == "npc" and target then
      handleNPCHit(player, target)
      CombatService.Client.SwingResult:Fire(player, "npc", target.npcType, "lunge")
    elseif hitType == "container" and target then
      handleContainerHit(player, target)
      CombatService.Client.SwingResult:Fire(player, "container", nil, "lunge")
    else
      CombatService.Client.SwingResult:Fire(player, "miss", nil, "lunge")
    end
  end)
end

--[[
  Called when a client fires SpinRequest (Rank 4 unlock).
  360° area attack hitting all targets in range.
]]
local function onSpinRequest(player: Player)
  -- Check rank unlock
  if not RankEffectsService or not RankEffectsService:HasSpin(player) then
    return
  end

  -- Validate basic attack state
  local canAttack, _ = validateAttack(player, SPIN_COOLDOWN)
  if not canAttack then
    return
  end

  -- Check spin-specific cooldown
  local now = os.clock()
  local lastSpin = LastSpinTime[player]
  if lastSpin and (now - lastSpin) < SPIN_COOLDOWN then
    return
  end

  LastSpinTime[player] = now
  LastAttackTime[player] = now

  -- Confirm spin to client (triggers VFX)
  CombatService.Client.SpinConfirm:Fire(player)

  -- Schedule hit detection after windup
  task.delay(SPIN_WINDUP, function()
    if SessionStateService:IsRagdolling(player) then
      return
    end

    -- Multi-hit detection: hits ALL targets in 360° arc
    local hitPlayers, hitNPCs, hitContainers =
      performMultiHitDetection(player, SPIN_RANGE, SPIN_ARC)

    local hitAnything = false

    -- Hit all players in range
    for _, target in hitPlayers do
      handlePlayerHitCustom(player, target, SPIN_RAGDOLL, SPIN_SPILL, SPIN_KNOCKBACK, "spin")
      hitAnything = true
    end

    -- Hit all NPCs in range
    for _, npcEntry in hitNPCs do
      handleNPCHit(player, npcEntry)
      hitAnything = true
    end

    -- Hit all containers in range
    for _, containerEntry in hitContainers do
      handleContainerHit(player, containerEntry)
      hitAnything = true
    end

    if hitAnything then
      local hitCount = #hitPlayers + #hitNPCs + #hitContainers
      CombatService.Client.SwingResult:Fire(player, "multi", tostring(hitCount), "spin")
      print(
        string.format(
          "[CombatService] %s spin hit %d targets (%d players, %d NPCs, %d containers)",
          player.Name,
          hitCount,
          #hitPlayers,
          #hitNPCs,
          #hitContainers
        )
      )
    else
      CombatService.Client.SwingResult:Fire(player, "miss", nil, "spin")
    end
  end)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function CombatService:KnitInit()
  -- Nothing to initialize before services are available
end

function CombatService:KnitStart()
  -- Get references to other services
  SessionStateService = Knit.GetService("SessionStateService")
  DataService = Knit.GetService("DataService")
  ContainerService = Knit.GetService("ContainerService")
  DoubloonService = Knit.GetService("DoubloonService")
  HarborService = Knit.GetService("HarborService")
  NPCService = Knit.GetService("NPCService")
  RankEffectsService = Knit.GetService("RankEffectsService")

  -- Listen for client attack requests
  self.Client.AttackRequest:Connect(function(player: Player)
    onAttackRequest(player)
  end)

  self.Client.HeavyAttackRequest:Connect(function(player: Player, chargeTime: number)
    onHeavyAttackRequest(player, chargeTime)
  end)

  -- Listen for block state changes from client
  self.Client.BlockStateChanged:Connect(function(player: Player, blocking: any)
    -- Sanity check the value is boolean
    if type(blocking) ~= "boolean" then
      return
    end

    if not SessionStateService or not SessionStateService:IsInitialized(player) then
      return
    end

    -- Cannot block while ragdolled or in recovery
    if blocking then
      if SessionStateService:IsRagdolling(player) then
        return
      end
      if SessionStateService:IsInRecovery(player) then
        return
      end
    end

    SessionStateService:SetBlocking(player, blocking)

    -- Apply or restore movement speed (use rank-aware walk speed)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
      if blocking then
        -- Get the correct default walk speed from RankEffectsService
        local defaultSpeed = if RankEffectsService
          then RankEffectsService:GetWalkSpeed(player)
          else humanoid.WalkSpeed
        PlayerDefaultWalkSpeed[player] = defaultSpeed
        humanoid.WalkSpeed = defaultSpeed * BLOCK_SPEED_MULTIPLIER
      else
        -- Restore default walk speed
        local restoreSpeed = if RankEffectsService
          then RankEffectsService:GetWalkSpeed(player)
          else PlayerDefaultWalkSpeed[player] or humanoid.WalkSpeed
        humanoid.WalkSpeed = restoreSpeed
      end
    end
  end)

  -- Listen for dash requests from client
  self.Client.DashRequest:Connect(function(player: Player, direction: any)
    -- Validate direction is a Vector3
    if typeof(direction) ~= "Vector3" then
      return
    end

    if not SessionStateService or not SessionStateService:IsInitialized(player) then
      return
    end

    -- Cannot dash while ragdolled
    if SessionStateService:IsRagdolling(player) then
      return
    end

    -- Cannot dash while in recovery
    if SessionStateService:IsInRecovery(player) then
      return
    end

    -- Cannot dash while blocking
    if SessionStateService:IsBlocking(player) then
      return
    end

    -- Cannot dash while already dashing
    if SessionStateService:IsDashing(player) then
      return
    end

    -- Check cooldown
    if SessionStateService:IsDashOnCooldown(player) then
      return
    end

    -- Normalize direction (XZ only, ignore vertical)
    local dashDir = Vector3.new(direction.X, 0, direction.Z)
    if dashDir.Magnitude < 0.01 then
      -- Fallback to player's look direction
      local hrp = getHRP(player)
      if not hrp then
        return
      end
      local look = hrp.CFrame.LookVector
      dashDir = Vector3.new(look.X, 0, look.Z).Unit
    else
      dashDir = dashDir.Unit
    end

    -- Start dash (sets isDashing, invulnerability, and cooldown)
    SessionStateService:StartDash(player, DASH_INVULN_TIME, DASH_COOLDOWN)

    -- Cancel block state if somehow still active
    if SessionStateService:IsBlocking(player) then
      SessionStateService:SetBlocking(player, false)
      local character = player.Character
      local humanoid = character and character:FindFirstChildOfClass("Humanoid")
      if humanoid and PlayerDefaultWalkSpeed[player] then
        humanoid.WalkSpeed = PlayerDefaultWalkSpeed[player]
      end
    end

    -- Confirm dash to client (triggers VFX and movement)
    CombatService.Client.DashConfirm:Fire(player, dashDir)
  end)

  -- Listen for lunge requests from client (Rank 2 unlock)
  self.Client.LungeRequest:Connect(function(player: Player)
    onLungeRequest(player)
  end)

  -- Listen for spin requests from client (Rank 4 unlock)
  self.Client.SpinRequest:Connect(function(player: Player)
    onSpinRequest(player)
  end)

  -- Clean up rate limiting data on player leave
  Players.PlayerRemoving:Connect(function(player: Player)
    LastAttackTime[player] = nil
    LastLungeTime[player] = nil
    LastSpinTime[player] = nil
    PlayerDefaultWalkSpeed[player] = nil
  end)

  print("[CombatService] Started")
end

return CombatService
