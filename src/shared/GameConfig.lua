--[[
	GameConfig.lua
	Central shared configuration module containing all tunable game constants.
	Organized by system. Values match the game design spec exactly.
	Consumed by both server Services and client Controllers.
]]

local GameConfig = {}

--------------------------------------------------------------------------------
-- COMBAT
--------------------------------------------------------------------------------

export type CombatConfig = {
  lightSwingCooldown: number,
  heavySwingChargeTime: number,
  heavySwingCooldown: number,
  heavySwingRange: number,
  heavySwingArc: number,
  blockSpeedMultiplier: number,
  dashDistance: number,
  dashCooldown: number,
  dashInvulnerabilityTime: number,
  perTargetHitCooldown: number,
  recoveryWindow: number,
}

GameConfig.Combat = {
  -- Light swing (primary click)
  lightSwingCooldown = 0.4, -- seconds between swings

  -- Heavy swing (hold primary click)
  heavySwingChargeTime = 0.8, -- seconds hold before release
  heavySwingCooldown = 1.2, -- seconds after heavy swing
  heavySwingRange = 10, -- studs (wider than light swing's 8)
  heavySwingArc = 90, -- degrees half-angle (wider than light swing's 70)

  -- Block (secondary click hold)
  blockSpeedMultiplier = 0.5, -- 50% movement speed while blocking

  -- Dash
  dashDistance = 10, -- studs
  dashCooldown = 3, -- seconds
  dashInvulnerabilityTime = 0.3, -- seconds of i-frames during dash

  -- Cooldowns
  perTargetHitCooldown = 2, -- seconds before same player can be hit again
  recoveryWindow = 0.5, -- seconds after ragdoll where player can move but not attack

  -- Lunge attack (Rank 2 unlock — forward thrust)
  lungeWindup = 0.3, -- seconds (crouch telegraph before dash)
  lungeDashDistance = 6, -- studs forward dash
  lungeRange = 8, -- studs hit detection range at endpoint
  lungeArc = 70, -- degrees half-angle cone
  lungeCooldown = 4, -- seconds
  lungeRagdollDuration = 2.0, -- seconds
  lungeLootSpillPercent = 0.15, -- 15%
  lungeKnockback = 25, -- studs/s impulse

  -- Spin attack (Rank 4 unlock — 360° area attack)
  spinWindup = 0.5, -- seconds (windup animation)
  spinRange = 6, -- studs (shorter range, but full circle)
  spinArc = 180, -- degrees half-angle (= full 360°)
  spinCooldown = 5, -- seconds
  spinRagdollDuration = 1.5, -- seconds
  spinLootSpillPercent = 0.10, -- 10%
  spinKnockback = 20, -- studs/s impulse
} :: CombatConfig

--------------------------------------------------------------------------------
-- RAGDOLL
--------------------------------------------------------------------------------

export type RagdollConfig = {
  lightHitDuration: number,
  heavyHitDuration: number,
  blockedHitDuration: number,
  lightHitKnockback: number,
  heavyHitKnockback: number,
  blockedHitKnockback: number,
}

GameConfig.Ragdoll = {
  lightHitDuration = 1.5, -- seconds
  heavyHitDuration = 2.5, -- seconds (with knockback)
  blockedHitDuration = 0.5, -- seconds (no knockback)
  lightHitKnockback = 15, -- studs/s impulse (stumble)
  heavyHitKnockback = 40, -- studs/s impulse (launch)
  blockedHitKnockback = 0, -- no knockback when blocked
} :: RagdollConfig

--------------------------------------------------------------------------------
-- LOOT SPILL (PvP)
--------------------------------------------------------------------------------

export type LootSpillConfig = {
  lightHitPercent: number,
  heavyHitPercent: number,
  blockedHitPercent: number,
  minSpill: number,
  spillAllThreshold: number,
  bountySpillMultiplier: number,
}

GameConfig.LootSpill = {
  lightHitPercent = 0.10, -- 10% of held doubloons
  heavyHitPercent = 0.25, -- 25% of held doubloons
  blockedHitPercent = 0.05, -- 5% of held doubloons
  minSpill = 1, -- minimum 1 doubloon if player has any
  spillAllThreshold = 10, -- if held < this, spill all remaining
  bountySpillMultiplier = 2, -- bounty targets spill double
} :: LootSpillConfig

--------------------------------------------------------------------------------
-- CONTAINERS
--------------------------------------------------------------------------------

export type ContainerDef = {
  id: string,
  name: string,
  hp: number,
  yieldMin: number,
  yieldMax: number,
  spawnFrequency: string,
  scatterRadius: number,
  nightOnly: boolean,
}

GameConfig.Containers = {
  {
    id = "crate",
    name = "Crate",
    hp = 3,
    yieldMin = 5,
    yieldMax = 15,
    spawnFrequency = "very_common",
    scatterRadius = 3,
    nightOnly = false,
  },
  {
    id = "barrel",
    name = "Barrel",
    hp = 5,
    yieldMin = 10,
    yieldMax = 30,
    spawnFrequency = "common",
    scatterRadius = 4,
    nightOnly = false,
  },
  {
    id = "treasure_chest",
    name = "Treasure Chest",
    hp = 8,
    yieldMin = 30,
    yieldMax = 80,
    spawnFrequency = "uncommon",
    scatterRadius = 5,
    nightOnly = false,
  },
  {
    id = "reinforced_trunk",
    name = "Reinforced Trunk",
    hp = 12,
    yieldMin = 80,
    yieldMax = 200,
    spawnFrequency = "rare",
    scatterRadius = 6,
    nightOnly = false,
  },
  {
    id = "captains_vault",
    name = "Captain's Vault",
    hp = 20,
    yieldMin = 200,
    yieldMax = 500,
    spawnFrequency = "very_rare",
    scatterRadius = 8,
    nightOnly = false,
  },
  {
    id = "cursed_chest",
    name = "Cursed Chest",
    hp = 15,
    yieldMin = 200,
    yieldMax = 500,
    spawnFrequency = "night_special",
    scatterRadius = 6,
    nightOnly = true,
  },
} :: { ContainerDef }

-- Lookup by ID (built at require-time)
GameConfig.ContainerById = {} :: { [string]: ContainerDef }
for _, container in GameConfig.Containers do
  GameConfig.ContainerById[container.id] = container
end

-- Container system constants
GameConfig.ContainerSystem = {
  maxActiveContainers = 20,
  nightSpawnRateMultiplier = 1.5,
  nightYieldMultiplier = 2,
  cursedChestsPerNight = { min = 2, max = 3 },
  cursedChestAmbushChance = 0.50, -- 50% Ghost Pirate ambush on break
  cursedChestAmbushCount = { min = 1, max = 2 },
  crackingHpPercent = 0.50, -- VFX state at 50% HP
  goldLeakHpPercent = 0.25, -- VFX state at 25% HP
}

--------------------------------------------------------------------------------
-- PICKUPS
--------------------------------------------------------------------------------

GameConfig.Pickups = {
  despawnTime = 15, -- seconds before uncollected pickups vanish
  maxLoosePickups = 200, -- global cap; oldest removed first
  pickupRadius = 4, -- studs; auto-collect when player walks within this range
}

--------------------------------------------------------------------------------
-- LOOT VISIBILITY THRESHOLDS
--------------------------------------------------------------------------------

export type LootVisibilityTier = {
  minDoubloons: number,
  maxDoubloons: number,
  tier: string,
}

GameConfig.LootVisibility = {
  {
    minDoubloons = 0,
    maxDoubloons = 49,
    tier = "none", -- no visual indicator
  },
  {
    minDoubloons = 50,
    maxDoubloons = 199,
    tier = "small", -- small coin purse
  },
  {
    minDoubloons = 200,
    maxDoubloons = 499,
    tier = "medium", -- medium purse with shimmer
  },
  {
    minDoubloons = 500,
    maxDoubloons = math.huge,
    tier = "large", -- large overflowing purse with trail and sound
  },
} :: { LootVisibilityTier }

-- Night glow threshold: players with 200+ doubloons glow faintly at night
GameConfig.NightGlowThreshold = 200

--------------------------------------------------------------------------------
-- GEAR (Cutlass Tiers)
--------------------------------------------------------------------------------

export type GearDef = {
  id: string,
  name: string,
  cost: number,
  containerDamage: number,
  displayOrder: number,
  isTutorial: boolean,
}

GameConfig.Gear = {
  {
    id = "driftwood",
    name = "Driftwood",
    cost = 0,
    containerDamage = 1,
    displayOrder = 0,
    isTutorial = true,
  },
  {
    id = "rusty_cutlass",
    name = "Rusty Cutlass",
    cost = 0,
    containerDamage = 1,
    displayOrder = 1,
    isTutorial = false,
  },
  {
    id = "iron_cutlass",
    name = "Iron Cutlass",
    cost = 200,
    containerDamage = 2,
    displayOrder = 2,
    isTutorial = false,
  },
  {
    id = "steel_cutlass",
    name = "Steel Cutlass",
    cost = 1000,
    containerDamage = 3,
    displayOrder = 3,
    isTutorial = false,
  },
  {
    id = "captains_saber",
    name = "Captain's Saber",
    cost = 5000,
    containerDamage = 5,
    displayOrder = 4,
    isTutorial = false,
  },
  {
    id = "legendary_blade",
    name = "Legendary Blade",
    cost = 25000,
    containerDamage = 8,
    displayOrder = 5,
    isTutorial = false,
  },
} :: { GearDef }

-- Lookup by ID (built at require-time)
GameConfig.GearById = {} :: { [string]: GearDef }
for _, gear in GameConfig.Gear do
  GameConfig.GearById[gear.id] = gear
end

--------------------------------------------------------------------------------
-- SHIP TIERS
--------------------------------------------------------------------------------

export type ShipTierDef = {
  tier: number,
  id: string,
  name: string,
  treasuryThreshold: number,
}

GameConfig.ShipTiers = {
  { tier = 1, id = "rowboat", name = "Rowboat", treasuryThreshold = 0 },
  { tier = 2, id = "sloop", name = "Sloop", treasuryThreshold = 500 },
  { tier = 3, id = "schooner", name = "Schooner", treasuryThreshold = 2000 },
  { tier = 4, id = "brigantine", name = "Brigantine", treasuryThreshold = 10000 },
  { tier = 5, id = "galleon", name = "Galleon", treasuryThreshold = 50000 },
  { tier = 6, id = "war_galleon", name = "War Galleon", treasuryThreshold = 200000 },
  { tier = 7, id = "ghost_ship", name = "Ghost Ship", treasuryThreshold = 1000000 },
} :: { ShipTierDef }

-- Lookup by tier number (built at require-time)
GameConfig.ShipTierByNumber = {} :: { [number]: ShipTierDef }
for _, shipTier in GameConfig.ShipTiers do
  GameConfig.ShipTierByNumber[shipTier.tier] = shipTier
end

-- Ship system constants
GameConfig.ShipSystem = {
  maxDockSlots = 24,
  despawnDelay = 30, -- seconds after player leaves before ship despawns
  depositThreatReduction = 25,
  lockThreatReset = 0, -- threat resets to 0 on lock
  raidDuration = 3, -- seconds of uninterrupted interaction
  raidStealPercent = 0.25, -- steal 25% of hold (rounded up, min 1)
  raidCooldownPerShip = 30, -- seconds before same raider can raid same ship
}

--------------------------------------------------------------------------------
-- NPC — CURSED SKELETON
--------------------------------------------------------------------------------

GameConfig.CursedSkeleton = {
  hp = 20,
  speedMultiplier = 0.9, -- relative to player base speed
  aggroRange = 40, -- studs

  -- Slash attack
  slashWindup = 0.8, -- seconds
  slashRange = 8, -- studs
  slashCooldown = 2, -- seconds
  slashRagdollDuration = 2.0, -- seconds
  slashLootSpillPercent = 0.20, -- 20%

  -- Lunge attack
  lungeWindup = 0.5, -- seconds (crouch telegraph)
  lungeDashDistance = 6, -- studs
  lungeCooldown = 5, -- seconds

  -- Flinch
  flinchDuration = 0.2, -- seconds pause on hit, no ragdoll

  -- Loot
  deathBonusMin = 30,
  deathBonusMax = 80,
  respawnTime = 90, -- seconds

  -- Loot pickup behavior (NPC-002)
  lootScanRadius = 25, -- studs: how far skeleton scans for loose pickups
  lootPickupRadius = 3, -- studs: how close skeleton must be to collect a pickup
  lootScanInterval = 2, -- seconds between pickup scans during patrol
  maxCarriedDoubloons = 500, -- cap on doubloons a skeleton can carry

  -- Spawn budget (day)
  dayCountMin = 6,
  dayCountMax = 10,
  nightCountMultiplier = 1.5, -- +50% at night
}

--------------------------------------------------------------------------------
-- NPC — GHOST PIRATE
--------------------------------------------------------------------------------

GameConfig.GhostPirate = {
  hp = 10,
  speedMultiplier = 1.0,
  aggroRange = 15, -- studs (materialize and attack)

  -- Visibility distances
  fullyTransparentDistance = 20, -- fully invisible beyond this
  shimmerDistance = 10, -- faint shimmer between 10-20 studs
  visibleDistance = 10, -- mostly visible within this

  -- Spectral slash
  slashWindup = 0.6, -- seconds
  slashRange = 8, -- studs
  slashCooldown = 2.5, -- seconds
  slashRagdollDuration = 2.0, -- seconds
  slashLootSpillPercent = 0.15, -- 15%

  -- Flinch (same as skeleton)
  flinchDuration = 0.2,

  -- Loot
  deathBonusMin = 15,
  deathBonusMax = 40,
  respawnTime = 90, -- seconds (same as skeleton, night-only respawn)

  -- Spawn budget (night only)
  nightCountMin = 4,
  nightCountMax = 6,

  -- Display
  displayName = "Ghost Pirate",
}

--------------------------------------------------------------------------------
-- NPC — PHANTOM CAPTAIN (Elite)
--------------------------------------------------------------------------------

GameConfig.PhantomCaptain = {
  hp = 30,
  speedMultiplier = 1.1,
  aggroRange = 200, -- effectively unlimited: hunts specific target across map

  -- Captain's slash attack (enhanced)
  slashWindup = 0.6, -- seconds (fast, dangerous)
  slashRange = 9, -- studs (slightly longer reach)
  slashCooldown = 1.8, -- seconds (attacks faster than skeletons)
  slashRagdollDuration = 3.0, -- seconds (punishing ragdoll)
  slashLootSpillPercent = 0.30, -- 30% spill on hit

  -- Flinch (shorter than skeleton — more imposing)
  flinchDuration = 0.15, -- seconds

  -- Loot
  deathBonusMin = 100,
  deathBonusMax = 200,

  -- Spawn rules
  spawnThreatThreshold = 80, -- spawns at Doomed threat tier
  maxPerPlayer = 1,
  maxPerServer = 3,

  -- Display
  displayName = "Phantom Captain",
}

--------------------------------------------------------------------------------
-- NPC — SHARED BEHAVIOR
--------------------------------------------------------------------------------

GameConfig.NPCBehavior = {
  -- SimplePath agent parameters
  agentRadius = 2,
  agentHeight = 5,
  agentCanJump = true,

  -- Chase
  chasePathRecalcInterval = 0.3, -- seconds
  leashDistance = 80, -- studs from zone center

  -- Stuck detection
  stuckMoveThreshold = 2, -- studs
  stuckTimeRecalc = 3, -- seconds before path recalculation
  stuckTimeTeleport = 6, -- seconds before teleport to nearest waypoint
  harborReturnDelay = 5, -- seconds NPC waits at Harbor boundary

  -- Dormant mode
  dormantDistance = 150, -- studs from any player

  -- Performance budget
  maxPathRecalcsPerFrame = 3,

  -- Night modifiers (applied to ALL NPCs)
  nightSpeedBonus = 0.25, -- +25% movement speed
  nightAggroRangeBonus = 0.30, -- +30% aggro range

  -- Pack hunting (NPC-009): skeletons pair up at night
  packFormationRadius = 60, -- studs: max distance between skeletons to form a pack
  packFlankOffset = 10, -- studs: perpendicular offset for flanking skeleton
  packMaxPacks = 5, -- max simultaneous packs active at once
}

--------------------------------------------------------------------------------
-- THREAT LEVEL
--------------------------------------------------------------------------------

export type ThreatTierDef = {
  id: string,
  name: string,
  minThreat: number,
  maxThreat: number,
}

GameConfig.ThreatTiers = {
  { id = "calm", name = "Calm", minThreat = 0, maxThreat = 19 },
  { id = "uneasy", name = "Uneasy", minThreat = 20, maxThreat = 39 },
  { id = "hunted", name = "Hunted", minThreat = 40, maxThreat = 59 },
  { id = "cursed", name = "Cursed", minThreat = 60, maxThreat = 79 },
  { id = "doomed", name = "Doomed", minThreat = 80, maxThreat = 100 },
} :: { ThreatTierDef }

GameConfig.Threat = {
  maxThreat = 100,

  -- Accumulation rates
  timeRate = 5, -- +5 per minute since last lock
  heldDoubloonsRate = 1, -- +1 per 50 held doubloons
  heldDoubloonsInterval = 30, -- checked every 30 seconds
  heldDoubloonsPer = 50, -- per this many held doubloons
  containerBreakGain = 2,
  npcKillGain = 3,
  dangerZoneRate = 3, -- +3 per minute in danger zones
  nightMultiplier = 1.5, -- 1.5x all threat gains at night

  -- Reduction
  depositReduction = 25, -- depositing reduces by 25
  lockReset = 0, -- locking resets to 0

  -- Tier effects
  uneasySkeletonSpeedBonus = 0.10, -- +10% skeleton speed
  huntedBonusSkeletonCount = 1, -- 1 bonus skeleton targeting this player
  huntedAggroRange = 60, -- studs
  cursedNpcSpeedBonus = 0.20, -- +20% NPC speed
  cursedTrapContainerChance = 0.30, -- 30% trap containers
  cursedTrapRagdollDuration = 1.5, -- seconds
  cursedTrapSpillPercent = 0.10, -- 10%

  -- Doomed tier effects
  doomedDarkAuraRange = 20, -- studs: visible dark aura radius
}

--------------------------------------------------------------------------------
-- DAY/NIGHT CYCLE
--------------------------------------------------------------------------------

export type DayPhase = "Dawn" | "Day" | "Dusk" | "Night"

GameConfig.DayNight = {
  -- Phase durations in seconds
  dawnDuration = 30,
  dayDuration = 360, -- 6 minutes
  duskDuration = 30,
  nightDuration = 240, -- 4 minutes
  -- Total cycle: 660 seconds = 11 minutes

  -- Banner display
  bannerDuration = 5, -- seconds to show transition banners

  -- Night visibility
  nightViewRadius = 60, -- studs (fog limit)
}

-- Total cycle length (computed at require-time)
GameConfig.DayNight.totalCycleDuration = GameConfig.DayNight.dawnDuration
  + GameConfig.DayNight.dayDuration
  + GameConfig.DayNight.duskDuration
  + GameConfig.DayNight.nightDuration

--------------------------------------------------------------------------------
-- HAZARDS — VOLCANIC VENT
--------------------------------------------------------------------------------

GameConfig.VolcanicVent = {
  count = { min = 5, max = 7 }, -- vents on map
  dormantDuration = 20, -- seconds
  warningDuration = 5, -- seconds (steam, glow, rumble)
  eruptionDuration = 3, -- seconds (fire geyser)
  ragdollDuration = 2.0, -- seconds
  lootSpillPercent = 0.15, -- 15%
}

--------------------------------------------------------------------------------
-- HAZARDS — TIDAL SURGE
--------------------------------------------------------------------------------

GameConfig.TidalSurge = {
  dayIntervalMin = 90, -- seconds
  dayIntervalMax = 120,
  nightIntervalMin = 45,
  nightIntervalMax = 60,
  warningDuration = 4, -- seconds (water recedes)
  floodDuration = 5, -- seconds
  recedeDuration = 3, -- seconds
  ragdollDuration = 1.5, -- seconds
  pushDistanceMin = 10, -- studs inland
  pushDistanceMax = 15,
  lootSpillPercent = 0.10, -- 10%
  bonusContainerChance = 0.25, -- 25% chance to reveal hidden container
}

--------------------------------------------------------------------------------
-- HAZARDS — QUICKSAND
--------------------------------------------------------------------------------

GameConfig.Quicksand = {
  totalPatches = { min = 4, max = 6 },
  activeAtOnce = { min = 2, max = 3 },
  immobilizeDuration = 3, -- seconds (can attack, cannot move)
}

--------------------------------------------------------------------------------
-- HAZARDS — ROGUE WAVE (Night Only)
--------------------------------------------------------------------------------

GameConfig.RogueWave = {
  perNightCount = { min = 1, max = 2 },
  warningDuration = 6, -- seconds
  ragdollDuration = 3.0, -- seconds
  pushDistanceMin = 20, -- studs inland
  pushDistanceMax = 25,
  lootSpillPercent = 0.20, -- 20%
  bonusContainerCount = { min = 2, max = 3 },
}

--------------------------------------------------------------------------------
-- DANGER ZONES
--------------------------------------------------------------------------------

-- Danger zone IDs and display names. Actual boundaries are defined by Parts in
-- workspace (Folder "DangerZones", children named by zone ID).
-- Each Part's AABB is the zone boundary (same pattern as HarborZone).

export type DangerZoneDef = {
  id: string,
  name: string,
}

GameConfig.DangerZones = {
  { id = "skull_cave", name = "Skull Cave" },
  { id = "volcano", name = "Volcano" },
  { id = "deep_jungle", name = "Deep Jungle" },
} :: { DangerZoneDef }

GameConfig.DangerZoneConfig = {
  checkInterval = 0.25, -- seconds between position checks
}

-- Lookup by ID (built at require-time)
GameConfig.DangerZoneById = {} :: { [string]: DangerZoneDef }
for _, zone in GameConfig.DangerZones do
  GameConfig.DangerZoneById[zone.id] = zone
end

--------------------------------------------------------------------------------
-- BOUNTY SYSTEM
--------------------------------------------------------------------------------

GameConfig.Bounty = {
  checkInterval = 60, -- seconds between checks
  activationThreshold = 200, -- held doubloons needed
  clearThreshold = 100, -- bounty clears if held drops below
  duration = 90, -- seconds before auto-clear
}

--------------------------------------------------------------------------------
-- WORLD EVENTS
--------------------------------------------------------------------------------

GameConfig.ShipwreckEvent = {
  intervalMin = 180, -- seconds (3 min)
  intervalMax = 300, -- seconds (5 min)
  containerCount = { min = 3, max = 5 },
  duration = 60, -- seconds before despawn
}

GameConfig.LootSurgeEvent = {
  intervalMin = 300, -- seconds (5 min)
  intervalMax = 480, -- seconds (8 min)
  spawnRateMultiplier = 3,
  yieldMultiplier = 2,
  duration = 45, -- seconds
}

--------------------------------------------------------------------------------
-- NOTORIETY / RANK
--------------------------------------------------------------------------------

export type NotorietyXPReward = {
  id: string,
  description: string,
  xp: number,
}

GameConfig.NotorietyXP = {
  { id = "deposit_100", description = "Deposit 100 doubloons", xp = 10 },
  { id = "hit_player", description = "Hit a player", xp = 5 },
  { id = "pickup_spilled_loot", description = "Pick up spilled loot", xp = 3 },
  { id = "break_container", description = "Break a container", xp = 2 },
  { id = "kill_skeleton", description = "Kill a Cursed Skeleton", xp = 8 },
  { id = "kill_ghost_pirate", description = "Kill a Ghost Pirate", xp = 6 },
  { id = "kill_phantom_captain", description = "Kill a Phantom Captain", xp = 20 },
  { id = "survive_full_night", description = "Survive full night outside Harbor", xp = 15 },
  { id = "raid_ship", description = "Raid another player's ship", xp = 10 },
  { id = "hit_bounty_target", description = "Hit the bounty target", xp = 15 },
  { id = "survive_bounty", description = "Deposit while bounty is on you", xp = 25 },
} :: { NotorietyXPReward }

-- Lookup by ID (built at require-time)
GameConfig.NotorietyXPById = {} :: { [string]: NotorietyXPReward }
for _, reward in GameConfig.NotorietyXP do
  GameConfig.NotorietyXPById[reward.id] = reward
end

export type RankDef = {
  rank: number,
  id: string,
  name: string,
  xpThreshold: number,
  unlock: string?,
}

GameConfig.Ranks = {
  { rank = 1, id = "deckhand", name = "Deckhand", xpThreshold = 0, unlock = nil },
  { rank = 2, id = "buccaneer", name = "Buccaneer", xpThreshold = 500, unlock = "cutlass_lunge" },
  { rank = 3, id = "raider", name = "Raider", xpThreshold = 2000, unlock = "speed_bonus" },
  { rank = 4, id = "captain", name = "Captain", xpThreshold = 8000, unlock = "cutlass_spin" },
  {
    rank = 5,
    id = "pirate_lord",
    name = "Pirate Lord",
    xpThreshold = 25000,
    unlock = "pickup_radius",
  },
  {
    rank = 6,
    id = "dread_pirate",
    name = "Dread Pirate",
    xpThreshold = 75000,
    unlock = "title_display",
  },
} :: { RankDef }

-- Lookup by rank number (built at require-time)
GameConfig.RankByNumber = {} :: { [number]: RankDef }
for _, rankDef in GameConfig.Ranks do
  GameConfig.RankByNumber[rankDef.rank] = rankDef
end

-- Rank passive bonuses
GameConfig.RankBonuses = {
  speedBonusPercent = 0.05, -- +5% at Rank 3
  pickupRadiusBonusPercent = 0.10, -- +10% at Rank 5
}

--------------------------------------------------------------------------------
-- TUTORIAL
--------------------------------------------------------------------------------

GameConfig.Tutorial = {
  driftwoodDistance = 10, -- studs from spawn to driftwood
  crateDistance = 15, -- studs from driftwood to tutorial crate
  tutorialCrateHits = 3, -- hits to break tutorial crate with driftwood
  tutorialSkeletonHp = 5, -- weakened skeleton HP
  totalSteps = 10, -- total number of tutorial steps (1-5: beach, 6-10: harbor/shop)
  pathCrateCount = 2, -- crates spawned along beach→harbor path
  pathCrateHits = 2, -- hits to break path crates (easier than normal)
  shopProximityRadius = 15, -- studs to trigger "shop reached" during step 9
  beaconHeight = 40, -- height of the Harbor beacon in studs
}

--------------------------------------------------------------------------------
-- AUTO-SAVE
--------------------------------------------------------------------------------

GameConfig.AutoSave = {
  interval = 60, -- seconds between auto-saves
}

--------------------------------------------------------------------------------
-- ACCESSOR FUNCTIONS
--------------------------------------------------------------------------------

--[[
	Gets a container definition by its ID.
	@param id Container type ID (e.g. "crate", "cursed_chest")
	@return ContainerDef or nil if not found
]]
function GameConfig.getContainerById(id: string): ContainerDef?
  return GameConfig.ContainerById[id]
end

--[[
	Gets a gear definition by its ID.
	@param id Gear ID (e.g. "rusty_cutlass", "legendary_blade")
	@return GearDef or nil if not found
]]
function GameConfig.getGearById(id: string): GearDef?
  return GameConfig.GearById[id]
end

--[[
	Gets a ship tier definition by tier number.
	@param tier Tier number (1-7)
	@return ShipTierDef or nil if not found
]]
function GameConfig.getShipTier(tier: number): ShipTierDef?
  return GameConfig.ShipTierByNumber[tier]
end

--[[
	Calculates a player's ship tier from their treasury balance.
	@param treasury Current treasury doubloons
	@return The highest tier the player qualifies for
]]
function GameConfig.getShipTierForTreasury(treasury: number): ShipTierDef
  local bestTier = GameConfig.ShipTiers[1]
  for _, shipTier in GameConfig.ShipTiers do
    if treasury >= shipTier.treasuryThreshold then
      bestTier = shipTier
    end
  end
  return bestTier
end

--[[
	Calculates a player's rank from their notoriety XP.
	@param xp Current notoriety XP
	@return The highest rank the player qualifies for
]]
function GameConfig.getRankForXP(xp: number): RankDef
  local bestRank = GameConfig.Ranks[1]
  for _, rankDef in GameConfig.Ranks do
    if xp >= rankDef.xpThreshold then
      bestRank = rankDef
    end
  end
  return bestRank
end

--[[
	Gets the threat tier for a given threat level.
	@param threat Current threat value (0-100)
	@return ThreatTierDef for the matching tier
]]
function GameConfig.getThreatTier(threat: number): ThreatTierDef
  for i = #GameConfig.ThreatTiers, 1, -1 do
    local tier = GameConfig.ThreatTiers[i]
    if threat >= tier.minThreat then
      return tier
    end
  end
  return GameConfig.ThreatTiers[1]
end

--[[
	Gets the loot visibility tier for a given doubloon count.
	@param doubloons Number of held doubloons
	@return The tier string: "none", "small", "medium", or "large"
]]
function GameConfig.getLootVisibilityTier(doubloons: number): string
  for i = #GameConfig.LootVisibility, 1, -1 do
    local tier = GameConfig.LootVisibility[i]
    if doubloons >= tier.minDoubloons then
      return tier.tier
    end
  end
  return "none"
end

--[[
	Calculates loot spill amount for a PvP hit.
	@param heldDoubloons Victim's current held doubloons
	@param spillPercent Base spill percentage (0.10, 0.25, 0.05)
	@param hasBounty Whether the victim has a bounty
	@return Number of doubloons to spill
]]
function GameConfig.calculateSpill(
  heldDoubloons: number,
  spillPercent: number,
  hasBounty: boolean
): number
  if heldDoubloons <= 0 then
    return 0
  end

  local effectivePercent = spillPercent
  if hasBounty then
    effectivePercent = effectivePercent * GameConfig.LootSpill.bountySpillMultiplier
  end

  if heldDoubloons < GameConfig.LootSpill.spillAllThreshold then
    return heldDoubloons
  end

  local spill = math.ceil(heldDoubloons * effectivePercent)
  return math.max(spill, GameConfig.LootSpill.minSpill)
end

--[[
	Checks if a player can afford a gear purchase.
	@param gearId The gear ID to purchase
	@param treasury Player's current treasury
	@return (boolean, string?) — success and optional failure reason
]]
function GameConfig.canPurchaseGear(gearId: string, treasury: number): (boolean, string?)
  local gear = GameConfig.GearById[gearId]
  if not gear then
    return false, "Invalid gear"
  end
  if gear.isTutorial then
    return false, "Tutorial item not purchasable"
  end
  if treasury < gear.cost then
    return false, "Insufficient treasury"
  end
  return true, nil
end

--[[
	Checks if it is currently night based on a DayPhase value.
	@param phase The current day phase
	@return True if the phase is "Night"
]]
function GameConfig.isNight(phase: DayPhase): boolean
  return phase == "Night"
end

--[[
	Gets the XP reward amount for a notoriety action.
	@param actionId The action ID (e.g. "hit_player", "kill_skeleton")
	@return XP amount, or 0 if action not found
]]
function GameConfig.getNotorietyXP(actionId: string): number
  local reward = GameConfig.NotorietyXPById[actionId]
  if reward then
    return reward.xp
  end
  return 0
end

return GameConfig
