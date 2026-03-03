--[[
  ThreatEffectsService.lua
  Server-authoritative threat tier effects (THREAT-003 / THREAT-004).

  Activates gameplay effects based on each player's threat tier:
    - Calm (0-19): No effects
    - Uneasy (20-39): NPCs within 60 studs of this player gain +10% speed;
      client plays eerie ambient audio
    - Hunted (40-59): Bonus Cursed Skeleton spawns targeting this player;
      aggro range extended to 60 studs; client shows fog vignette
    - Cursed (60-79): All NPCs within 60 studs gain +20% speed;
      30% chance containers near this player are traps (mini explosion on break);
      client shows ghostly green footprints visible to other players
    - Doomed (80-100): Phantom Captain elite NPC spawns to hunt this player (NPC-008);
      dark aura + ghostly particles visible to all players

  Per-player tracking:
    - Listens to SessionStateService.StateChanged for "threatLevel" changes
    - Compares old vs new tier; fires client signals on transitions
    - Spawns / despawns bonus NPCs on Hunted entry / exit

  Other services query this for per-player overrides:
    - GetSpeedBonusNearPosition(pos) — NPC speed bonus from nearby Uneasy+ players
    - GetAggroRangeForPlayer(player) — aggro range override for Hunted+ players
    - IsBonusNPC(npcId) — whether an NPC was spawned by threat effects
    - ShouldTrapContainer(player) — whether a container broken by this player is a trap
    - IsPlayerCursedOrAbove(player) — whether player is at Cursed+ tier
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local ThreatEffectsService = Knit.CreateService({
  Name = "ThreatEffectsService",
  Client = {
    -- Fired to a specific player when their threat tier changes.
    -- Args: (tierId: string, tierName: string, isUpward: boolean)
    ThreatTierChanged = Knit.CreateSignal(),
    -- Fired to ALL players when a Cursed+ player's footprints should show/hide.
    -- Args: (targetUserId: number, active: boolean)
    GhostlyFootprintsChanged = Knit.CreateSignal(),
    -- Fired to ALL players when a Doomed player's dark aura should show/hide.
    -- Args: (targetUserId: number, active: boolean)
    DarkAuraChanged = Knit.CreateSignal(),
    -- Fired to a specific player when their container explodes as a trap.
    -- Args: (containerId: string, position: Vector3)
    TrapContainerExploded = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
ThreatEffectsService.TrapTriggered = Signal.new() -- (player, containerId, position)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local NPCService = nil
local DayNightService = nil
local DoubloonService = nil

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

-- Cursed+ player tracking for footprints
local CursedPlayers: { [Player]: boolean } = {}

-- Doomed player tracking for dark aura and Phantom Captain
local DoomedPlayers: { [Player]: boolean } = {}

-- Phantom Captain tracking per player (NPC-008)
local PhantomCaptainNPCs: { [Player]: number } = {} -- player → npcId

-- Dark aura BillboardGui tracking per player
local DarkAuraGuis: { [Player]: BillboardGui } = {}

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
-- DARK AURA (DOOMED TIER)
--------------------------------------------------------------------------------

--[[
  Creates a dark aura BillboardGui on the player's character.
  The aura is a server-side BillboardGui replicated to all clients.
  Also adds a dark PointLight and particle emitter on the character.
]]
local function createDarkAura(player: Player)
  if DarkAuraGuis[player] then
    return -- already has aura
  end

  local character = player.Character
  if not character then
    return
  end
  local head = character:FindFirstChild("Head")
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not head or not hrp then
    return
  end

  -- BillboardGui: dark skull icon above head
  local billboard = Instance.new("BillboardGui")
  billboard.Name = "DoomedDarkAura"
  billboard.Size = UDim2.new(3, 0, 3, 0)
  billboard.StudsOffset = Vector3.new(0, 3.5, 0)
  billboard.AlwaysOnTop = false
  billboard.MaxDistance = 80
  billboard.ResetOnSpawn = false

  local icon = Instance.new("TextLabel")
  icon.Name = "DoomedIcon"
  icon.Size = UDim2.new(1, 0, 1, 0)
  icon.BackgroundTransparency = 1
  icon.Text = "\u{2620}" -- skull and crossbones
  icon.TextColor3 = Color3.fromRGB(180, 80, 255) -- purple
  icon.TextScaled = true
  icon.Font = Enum.Font.GothamBold
  icon.Parent = billboard

  billboard.Parent = head
  DarkAuraGuis[player] = billboard

  -- Dark PointLight on HumanoidRootPart (purple/dark glow)
  local darkLight = Instance.new("PointLight")
  darkLight.Name = "DoomedLight"
  darkLight.Color = Color3.fromRGB(100, 30, 160)
  darkLight.Brightness = 0.8
  darkLight.Range = THREAT.doomedDarkAuraRange
  darkLight.Parent = hrp

  -- Dark particle emitter on HumanoidRootPart
  local particles = Instance.new("ParticleEmitter")
  particles.Name = "DoomedParticles"
  particles.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 0, 100)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(120, 40, 180)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 0, 50)),
  })
  particles.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0),
    NumberSequenceKeypoint.new(0.3, 1.5),
    NumberSequenceKeypoint.new(1, 0),
  })
  particles.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.5),
    NumberSequenceKeypoint.new(0.5, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  particles.Lifetime = NumberRange.new(1.5, 3)
  particles.Rate = 12
  particles.Speed = NumberRange.new(0.5, 2)
  particles.SpreadAngle = Vector2.new(180, 180)
  particles.RotSpeed = NumberRange.new(-30, 30)
  particles.Parent = hrp

  print(string.format("[ThreatEffectsService] Dark aura created for %s (Doomed tier)", player.Name))
end

--[[
  Removes the dark aura from a player's character.
]]
local function removeDarkAura(player: Player)
  local billboard = DarkAuraGuis[player]
  if billboard and billboard.Parent then
    billboard:Destroy()
  end
  DarkAuraGuis[player] = nil

  local character = player.Character
  if character then
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
      local light = hrp:FindFirstChild("DoomedLight")
      if light then
        light:Destroy()
      end
      local particles = hrp:FindFirstChild("DoomedParticles")
      if particles then
        particles:Destroy()
      end
    end
  end

  print(string.format("[ThreatEffectsService] Dark aura removed for %s", player.Name))
end

--[[
  Re-attaches dark aura when a Doomed player's character respawns.
]]
local function reattachDarkAura(player: Player)
  if not DoomedPlayers[player] then
    return
  end

  -- Remove old, create new
  DarkAuraGuis[player] = nil
  createDarkAura(player)
end

--------------------------------------------------------------------------------
-- GHOSTLY FOOTPRINTS (CURSED TIER)
--------------------------------------------------------------------------------

--[[
  Enables ghostly footprints for a Cursed+ player.
  Server-side: attaches a green footprint particle emitter to the character.
  The emitter is on HumanoidRootPart and is replicated to all clients.
]]
local function enableGhostlyFootprints(player: Player)
  if CursedPlayers[player] then
    return
  end
  CursedPlayers[player] = true

  local character = player.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  -- Green footprint trail particle emitter (server-replicated)
  local footprints = Instance.new("ParticleEmitter")
  footprints.Name = "CursedFootprints"
  footprints.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 255, 80)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(40, 200, 60)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 100, 30)),
  })
  footprints.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.8),
    NumberSequenceKeypoint.new(0.2, 1.2),
    NumberSequenceKeypoint.new(1, 0),
  })
  footprints.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.5),
    NumberSequenceKeypoint.new(1, 1),
  })
  footprints.Lifetime = NumberRange.new(2, 4)
  footprints.Rate = 6
  footprints.Speed = NumberRange.new(0, 0.2)
  footprints.SpreadAngle = Vector2.new(30, 30)
  footprints.EmissionDirection = Enum.NormalId.Bottom
  -- Emit from below the character for a "footstep" look
  footprints.Parent = hrp

  -- Notify all clients for any additional client-side effects
  ThreatEffectsService.Client.GhostlyFootprintsChanged:FireAll(player.UserId, true)

  print(
    string.format(
      "[ThreatEffectsService] Ghostly footprints enabled for %s (Cursed tier)",
      player.Name
    )
  )
end

--[[
  Disables ghostly footprints for a player.
]]
local function disableGhostlyFootprints(player: Player)
  if not CursedPlayers[player] then
    return
  end
  CursedPlayers[player] = nil

  local character = player.Character
  if character then
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
      local footprints = hrp:FindFirstChild("CursedFootprints")
      if footprints then
        footprints:Destroy()
      end
    end
  end

  ThreatEffectsService.Client.GhostlyFootprintsChanged:FireAll(player.UserId, false)

  print(string.format("[ThreatEffectsService] Ghostly footprints disabled for %s", player.Name))
end

--[[
  Re-attaches ghostly footprints when a Cursed+ player's character respawns.
]]
local function reattachGhostlyFootprints(player: Player)
  if not CursedPlayers[player] then
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

  -- Remove existing if any
  local existing = hrp:FindFirstChild("CursedFootprints")
  if existing then
    existing:Destroy()
  end

  -- Re-create
  local footprints = Instance.new("ParticleEmitter")
  footprints.Name = "CursedFootprints"
  footprints.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 255, 80)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(40, 200, 60)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 100, 30)),
  })
  footprints.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.8),
    NumberSequenceKeypoint.new(0.2, 1.2),
    NumberSequenceKeypoint.new(1, 0),
  })
  footprints.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.5),
    NumberSequenceKeypoint.new(1, 1),
  })
  footprints.Lifetime = NumberRange.new(2, 4)
  footprints.Rate = 6
  footprints.Speed = NumberRange.new(0, 0.2)
  footprints.SpreadAngle = Vector2.new(30, 30)
  footprints.EmissionDirection = Enum.NormalId.Bottom
  footprints.Parent = hrp
end

--------------------------------------------------------------------------------
-- DOOMED TIER — PHANTOM CAPTAIN (NPC-008)
--------------------------------------------------------------------------------

--[[
  Handles entering Doomed tier for a player.
  Spawns a Phantom Captain elite NPC to hunt this player.
  Also creates dark aura visual effect.
]]
local function onDoomedEnter(player: Player)
  DoomedPlayers[player] = true

  -- Set session state for Phantom Captain tracking
  if SessionStateService then
    SessionStateService:SetPhantomCaptainActive(player, true)
  end

  -- Create dark aura (visible to all players)
  createDarkAura(player)

  -- Notify all clients
  ThreatEffectsService.Client.DarkAuraChanged:FireAll(player.UserId, true)

  -- Spawn Phantom Captain (NPC-008)
  if NPCService then
    local captainEntry = NPCService:SpawnPhantomCaptain(player)
    if captainEntry then
      PhantomCaptainNPCs[player] = captainEntry.id
      print(
        string.format(
          "[ThreatEffectsService] %s reached Doomed tier — Phantom Captain #%d spawned",
          player.Name,
          captainEntry.id
        )
      )
    else
      warn(
        string.format(
          "[ThreatEffectsService] %s reached Doomed tier — Phantom Captain spawn failed (server cap?)",
          player.Name
        )
      )
    end
  end
end

--[[
  Handles leaving Doomed tier for a player.
  Despawns the Phantom Captain and removes dark aura.
]]
local function onDoomedExit(player: Player)
  DoomedPlayers[player] = nil

  -- Clear session state
  if SessionStateService then
    SessionStateService:SetPhantomCaptainActive(player, false)
  end

  -- Remove dark aura
  removeDarkAura(player)

  -- Notify all clients
  ThreatEffectsService.Client.DarkAuraChanged:FireAll(player.UserId, false)

  -- Despawn Phantom Captain (NPC-008)
  if NPCService and PhantomCaptainNPCs[player] then
    NPCService:DespawnPhantomCaptain(player)
    PhantomCaptainNPCs[player] = nil
  end
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

  -- Handle Cursed ghostly footprints
  if newOrder >= TIER_ORDER.cursed and oldOrder < TIER_ORDER.cursed then
    enableGhostlyFootprints(player)
  elseif newOrder < TIER_ORDER.cursed and oldOrder >= TIER_ORDER.cursed then
    disableGhostlyFootprints(player)
  end

  -- Handle Doomed dark aura + Phantom Captain
  if newOrder >= TIER_ORDER.doomed and oldOrder < TIER_ORDER.doomed then
    onDoomedEnter(player)
  elseif newOrder < TIER_ORDER.doomed and oldOrder >= TIER_ORDER.doomed then
    onDoomedExit(player)
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
      -- Cursed/Doomed: +20% NPC speed
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

--[[
  Checks if a player is at Cursed tier or above.
  @param player The player to check
  @return true if the player is at Cursed (60-79) or Doomed (80-100)
]]
function ThreatEffectsService:IsPlayerCursedOrAbove(player: Player): boolean
  local tierId = PlayerThreatTiers[player] or "calm"
  return (TIER_ORDER[tierId] or 1) >= TIER_ORDER.cursed
end

--[[
  Rolls whether a container broken by this player should be a trap.
  Only applies to Cursed+ players. 30% chance per GameConfig.
  @param player The player who broke the container
  @return true if the container should explode as a trap
]]
function ThreatEffectsService:ShouldTrapContainer(player: Player): boolean
  if not self:IsPlayerCursedOrAbove(player) then
    return false
  end
  return math.random() < THREAT.cursedTrapContainerChance
end

--[[
  Executes the trap container explosion on a player.
  Called by ContainerService when a trap triggers.
  Applies ragdoll and loot spill.
  @param player The player hit by the trap
  @param position The container's position (for VFX)
  @param containerId The container's ID (for client notification)
]]
function ThreatEffectsService:ExecuteTrap(player: Player, position: Vector3, containerId: string)
  -- Ragdoll the player
  if SessionStateService and not SessionStateService:IsRagdolling(player) then
    SessionStateService:StartRagdoll(player, THREAT.cursedTrapRagdollDuration)
  end

  -- Spill loot
  local heldDoubloons = SessionStateService and SessionStateService:GetHeldDoubloons(player) or 0
  if heldDoubloons > 0 then
    local spillAmount = math.max(1, math.floor(heldDoubloons * THREAT.cursedTrapSpillPercent))
    SessionStateService:AddHeldDoubloons(player, -spillAmount)

    -- Scatter the spilled doubloons
    if DoubloonService then
      DoubloonService:ScatterDoubloons(position, spillAmount, 5)
    end
  end

  -- Notify the player for client-side VFX
  ThreatEffectsService.Client.TrapContainerExploded:Fire(player, containerId, position)

  -- Fire server-side signal
  ThreatEffectsService.TrapTriggered:Fire(player, containerId, position)

  print(
    string.format(
      "[ThreatEffectsService] Trap container triggered on %s — ragdoll %.1fs, %.0f%% loot spill",
      player.Name,
      THREAT.cursedTrapRagdollDuration,
      THREAT.cursedTrapSpillPercent * 100
    )
  )
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

--[[
  Returns info about all players with active Cursed/Doomed effects (for late-join sync).
  @return { cursedPlayerIds: {number}, doomedPlayerIds: {number} }
]]
function ThreatEffectsService.Client:GetActiveEffects(_player: Player): { [string]: { number } }
  local cursedIds = {}
  local doomedIds = {}

  for p, _ in CursedPlayers do
    if p.Parent then
      table.insert(cursedIds, p.UserId)
    end
  end
  for p, _ in DoomedPlayers do
    if p.Parent then
      table.insert(doomedIds, p.UserId)
    end
  end

  return {
    cursedPlayerIds = cursedIds,
    doomedPlayerIds = doomedIds,
  }
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
  -- Clean up Doomed effects and Phantom Captain (NPC-008)
  if DoomedPlayers[player] then
    removeDarkAura(player)
    ThreatEffectsService.Client.DarkAuraChanged:FireAll(player.UserId, false)
    DoomedPlayers[player] = nil

    -- Despawn Phantom Captain
    if NPCService and PhantomCaptainNPCs[player] then
      NPCService:DespawnPhantomCaptain(player)
      PhantomCaptainNPCs[player] = nil
    end
  end

  -- Clean up Cursed effects
  if CursedPlayers[player] then
    disableGhostlyFootprints(player)
  end

  -- Despawn any bonus NPCs for this player
  despawnBonusSkeleton(player)

  -- Clean up tracking
  PlayerThreatTiers[player] = nil
  UneasyPlayers[player] = nil
end

--------------------------------------------------------------------------------
-- CHARACTER RESPAWN HANDLING
--------------------------------------------------------------------------------

local function onCharacterAdded(player: Player)
  -- Re-attach Cursed footprints if player is Cursed+
  task.delay(0.5, function()
    if not player.Parent then
      return
    end
    reattachGhostlyFootprints(player)
    reattachDarkAura(player)
  end)
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
  DoubloonService = Knit.GetService("DoubloonService")

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
      local tierOrder = TIER_ORDER[tier.id]
      if tierOrder >= TIER_ORDER.uneasy then
        UneasyPlayers[player] = true
      end
      if tierOrder >= TIER_ORDER.cursed then
        enableGhostlyFootprints(player)
      end
      if tierOrder >= TIER_ORDER.doomed then
        onDoomedEnter(player)
      end
    end
  end

  -- Handle character respawns for re-attaching effects
  Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function()
      onCharacterAdded(player)
    end)
  end)
  -- Also connect for existing players
  for _, player in Players:GetPlayers() do
    player.CharacterAdded:Connect(function()
      onCharacterAdded(player)
    end)
  end

  -- Clean up on player leave
  Players.PlayerRemoving:Connect(onPlayerRemoving)

  -- Listen for bonus NPC deaths — respawn if player still Hunted
  NPCService.NPCDied:Connect(function(npcEntry, _killedByPlayer)
    -- Check if this is a bonus skeleton death
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

    -- Check if this is a Phantom Captain death (NPC-008)
    -- Phantom Captains do NOT respawn — they are one-time spawns per Doomed entry
    if npcEntry.npcType == "phantom_captain" then
      for player, captainId in PhantomCaptainNPCs do
        if captainId == npcEntry.id then
          PhantomCaptainNPCs[player] = nil
          print(
            string.format(
              "[ThreatEffectsService] Phantom Captain #%d (targeting %s) was killed — no respawn",
              npcEntry.id,
              player.Name
            )
          )
          break
        end
      end
    end
  end)

  print(
    "[ThreatEffectsService] Started — listening for threat tier transitions (tiers 1-5, Phantom Captain NPC-008)"
  )
end

return ThreatEffectsService
