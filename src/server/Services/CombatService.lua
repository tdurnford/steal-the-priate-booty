--[[
  CombatService.lua
  Server-authoritative combat service for light swing attacks.

  Handles:
    - Validating client attack inputs (cooldowns, state checks)
    - Server-side hit detection (raycast forward arc, short range)
    - Damage to containers (gear containerDamage value)
    - Damage to players (ragdoll + loot spill)
    - Per-target hit cooldown enforcement (2s)
    - Rate-limiting attack inputs to prevent exploit spam

  Client sends attack intent via AttackRequest.
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
    -- Args: (direction: Vector3) — the look direction of the attacker
    AttackRequest = Knit.CreateSignal(),

    -- Fired to the attacker when their swing connects.
    -- Args: (hitType: string, targetName: string?)
    --   hitType: "player" | "container" | "npc" | "miss"
    SwingResult = Knit.CreateSignal(),

    -- Fired to a player when they are hit and should ragdoll.
    -- Args: (attackerName: string, ragdollDuration: number)
    RagdollTrigger = Knit.CreateSignal(),

    -- Fired to all players near a loot spill for VFX.
    -- Args: (targetPosition: Vector3, spillAmount: number)
    LootSpillVFX = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
CombatService.PlayerHitPlayer = Signal.new() -- (attacker, target, spillAmount)
CombatService.PlayerHitContainer = Signal.new() -- (attacker, containerId, destroyed)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local ContainerService = nil
local DoubloonService = nil

-- Per-player last attack timestamp for rate limiting
local LastAttackTime: { [Player]: number } = {}

-- Light swing parameters
local LIGHT_SWING_RANGE = 8 -- studs
local LIGHT_SWING_ARC = math.rad(70) -- 70 degree half-angle cone
local LIGHT_SWING_COOLDOWN = GameConfig.Combat.lightSwingCooldown -- 0.4s

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
  Validates that a player can perform a light swing attack.
  Checks: session initialized, not ragdolling, not in recovery, cooldown elapsed.
  @param player The attacking player
  @return (canAttack: boolean, reason: string?)
]]
local function validateAttack(player: Player): (boolean, string?)
  if not SessionStateService or not SessionStateService:IsInitialized(player) then
    return false, "Session not initialized"
  end

  if SessionStateService:IsRagdolling(player) then
    return false, "Cannot attack while ragdolled"
  end

  if SessionStateService:IsInRecovery(player) then
    return false, "Cannot attack during recovery"
  end

  -- Rate limiting: enforce minimum cooldown between attacks
  local now = os.clock()
  local lastAttack = LastAttackTime[player]
  if lastAttack and (now - lastAttack) < LIGHT_SWING_COOLDOWN then
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
  @return true if target is within range and arc
]]
local function isInSwingArc(attackerCFrame: CFrame, targetPosition: Vector3): boolean
  local toTarget = targetPosition - attackerCFrame.Position
  local distance = toTarget.Magnitude

  if distance > LIGHT_SWING_RANGE then
    return false
  end

  -- Check angle from look direction
  local lookDir = attackerCFrame.LookVector
  local dirToTarget = toTarget.Unit
  local dotProduct = lookDir:Dot(dirToTarget)
  local angle = math.acos(math.clamp(dotProduct, -1, 1))

  return angle <= LIGHT_SWING_ARC
end

--[[
  Performs server-side hit detection for a light swing.
  Checks for player targets and container targets in the attacker's forward arc.
  @param attacker The attacking player
  @return (hitType: string, target: any?)
    hitType: "player" | "container" | "miss"
    target: Player (for player hits) or container entry table (for container hits)
]]
local function performHitDetection(attacker: Player): (string, any?)
  local attackerHRP = getHRP(attacker)
  if not attackerHRP then
    return "miss", nil
  end

  local attackerCFrame = attackerHRP.CFrame

  -- Check player targets first (PvP priority)
  local closestPlayerDist = math.huge
  local closestPlayer: Player? = nil

  for _, otherPlayer in Players:GetPlayers() do
    if otherPlayer ~= attacker then
      local otherHRP = getHRP(otherPlayer)
      if otherHRP then
        if isInSwingArc(attackerCFrame, otherHRP.Position) then
          -- Check per-target cooldown
          if SessionStateService:CanHitTarget(attacker, otherPlayer.UserId) then
            -- Check target is not already ragdolling
            if not SessionStateService:IsRagdolling(otherPlayer) then
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

  if closestPlayer then
    return "player", closestPlayer
  end

  -- Check container targets
  -- Use a raycast to find containers in the swing arc
  local closestContainerDist = math.huge
  local closestContainerEntry = nil

  if ContainerService then
    -- Check all containers within range using their position
    -- (Iterating active containers is more reliable than raycasting for box models)
    local rayOrigin = attackerCFrame.Position
    for _, child in
      workspace:FindFirstChild("Containers") and workspace.Containers:GetChildren() or {}
    do
      if child:IsA("Model") then
        local body = child:FindFirstChild("Body")
        if body and body:IsA("BasePart") then
          if isInSwingArc(attackerCFrame, body.Position) then
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
]]
local function handlePlayerHit(attacker: Player, target: Player)
  -- Record the hit for per-target cooldown
  SessionStateService:RecordHitTarget(attacker, target.UserId)

  -- Apply ragdoll (light hit = 1.5s)
  local ragdollDuration = GameConfig.Ragdoll.lightHitDuration
  SessionStateService:StartRagdoll(target, ragdollDuration)

  -- Notify the target to ragdoll visually
  CombatService.Client.RagdollTrigger:Fire(target, attacker.Name, ragdollDuration)

  -- Calculate loot spill (light hit = 10%)
  local heldDoubloons = SessionStateService:GetHeldDoubloons(target)
  local hasBounty = SessionStateService:HasBounty(target)
  local spillAmount =
    GameConfig.calculateSpill(heldDoubloons, GameConfig.LootSpill.lightHitPercent, hasBounty)

  if spillAmount > 0 then
    -- Deduct from target
    SessionStateService:AddHeldDoubloons(target, -spillAmount)

    -- Scatter at target's position
    local targetHRP = getHRP(target)
    local spillPos = if targetHRP then targetHRP.Position else Vector3.new(0, 5, 0)

    if DoubloonService then
      DoubloonService:ScatterDoubloons(spillPos, spillAmount, 4)
    end

    -- Notify nearby clients for VFX
    CombatService.Client.LootSpillVFX:FireAll(spillPos, spillAmount)
  end

  -- Fire server-side signal
  CombatService.PlayerHitPlayer:Fire(attacker, target, spillAmount)

  print(
    string.format(
      "[CombatService] %s hit %s — ragdoll %.1fs, spilled %d doubloons",
      attacker.Name,
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

--------------------------------------------------------------------------------
-- CLIENT REQUEST HANDLER
--------------------------------------------------------------------------------

--[[
  Called when a client fires AttackRequest.
  Validates the attack, performs hit detection, and processes the result.
]]
local function onAttackRequest(player: Player)
  -- Validate the attack
  local canAttack, reason = validateAttack(player)
  if not canAttack then
    return
  end

  -- Record attack timestamp for rate limiting
  LastAttackTime[player] = os.clock()

  -- Perform hit detection
  local hitType, target = performHitDetection(player)

  if hitType == "player" and target then
    handlePlayerHit(player, target :: Player)
    CombatService.Client.SwingResult:Fire(player, "player", (target :: Player).Name)
  elseif hitType == "container" and target then
    handleContainerHit(player, target)
    CombatService.Client.SwingResult:Fire(player, "container", nil)
  else
    CombatService.Client.SwingResult:Fire(player, "miss", nil)
  end
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

  -- Listen for client attack requests
  self.Client.AttackRequest:Connect(function(player: Player)
    onAttackRequest(player)
  end)

  -- Clean up rate limiting data on player leave
  Players.PlayerRemoving:Connect(function(player: Player)
    LastAttackTime[player] = nil
  end)

  print("[CombatService] Started")
end

return CombatService
