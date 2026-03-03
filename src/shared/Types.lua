--[[
  Types.lua
  Central type definitions for the pirate game.
  Contains the persistent PlayerData schema, defaults, and deep copy migration.
]]

--------------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------------

export type Settings = {
  musicEnabled: boolean,
  sfxEnabled: boolean,
  showOtherPlayers: boolean,
}

--------------------------------------------------------------------------------
-- EQUIPPED COSMETICS
--------------------------------------------------------------------------------

export type EquippedCosmetics = {
  cutlass_skin: string?,
  hat: string?,
  outfit: string?,
  pet: string?,
  emote_1: string?,
  emote_2: string?,
  ship_sail: string?,
  ship_hull: string?,
  ship_flag: string?,
}

--------------------------------------------------------------------------------
-- PLAYER STATS
--------------------------------------------------------------------------------

export type PlayerStats = {
  totalEarned: number,
  totalStolen: number,
  totalRaided: number,
  biggestHaul: number,
}

--------------------------------------------------------------------------------
-- SESSION STATE (transient, server-only, never saved to DataStore)
--------------------------------------------------------------------------------

export type SessionState = {
  -- Loot
  heldDoubloons: number,
  shipHold: number,

  -- Ship
  shipLocked: boolean,

  -- Combat
  isRagdolling: boolean,
  ragdollEndTime: number,
  recoveryEndTime: number,
  dashCooldownEnd: number,
  isDashing: boolean,
  dashInvulnEnd: number,
  isBlocking: boolean,
  lastHitTargets: { [number]: number }, -- [targetUserId] = timestamp

  -- Ship raiding
  lastRaidedShips: { [number]: number }, -- [ownerUserId] = timestamp

  -- Bounty
  hasBounty: boolean,

  -- Tutorial
  tutorialActive: boolean,
  tutorialStep: number,

  -- Threat
  threatLevel: number,
  lastLockTime: number,

  -- Zone
  inHarbor: boolean,
  inDangerZone: boolean,
  dangerZoneName: string?,

  -- NPC
  phantomCaptainActive: boolean,

  -- Quicksand
  isQuicksandTrapped: boolean,
  quicksandEndTime: number,
}

--------------------------------------------------------------------------------
-- PLAYER DATA (persistent, saved to DataStore)
--------------------------------------------------------------------------------

export type PlayerData = {
  -- Currency
  treasury: number,

  -- Gear
  equippedGear: string,
  ownedGear: { string },

  -- Notoriety / Rank
  notorietyXP: number,

  -- Tutorial
  tutorialCompleted: boolean,

  -- Cosmetics
  ownedCosmetics: { string },
  equippedCosmetics: EquippedCosmetics,

  -- Lifetime stats
  stats: PlayerStats,

  -- Settings
  settings: Settings,

  -- Timestamps
  joinedAt: number,
  lastPlayedAt: number,
}

local Types = {}

-- Default session state template for new player sessions (server-only, never saved)
Types.DEFAULT_SESSION_STATE = {
  -- Loot
  heldDoubloons = 0,
  shipHold = 0,

  -- Ship
  shipLocked = true,

  -- Combat
  isRagdolling = false,
  ragdollEndTime = 0,
  recoveryEndTime = 0,
  dashCooldownEnd = 0,
  isDashing = false,
  dashInvulnEnd = 0,
  isBlocking = false,
  lastHitTargets = {},

  -- Ship raiding
  lastRaidedShips = {},

  -- Bounty
  hasBounty = false,

  -- Tutorial
  tutorialActive = false,
  tutorialStep = 0,

  -- Threat
  threatLevel = 0,
  lastLockTime = 0,

  -- Zone
  inHarbor = false,
  inDangerZone = false,
  dangerZoneName = nil,

  -- NPC
  phantomCaptainActive = false,

  -- Quicksand
  isQuicksandTrapped = false,
  quicksandEndTime = 0,
}

-- Default data template for new players (used by ProfileService)
Types.DEFAULT_PLAYER_DATA = {
  -- Currency
  treasury = 0,

  -- Gear (new players start with rusty_cutlass after tutorial)
  equippedGear = "rusty_cutlass",
  ownedGear = { "rusty_cutlass" },

  -- Notoriety / Rank (starts at Deckhand, 0 XP)
  notorietyXP = 0,

  -- Tutorial
  tutorialCompleted = false,

  -- Cosmetics
  ownedCosmetics = {},
  equippedCosmetics = {
    cutlass_skin = nil,
    hat = nil,
    outfit = nil,
    pet = nil,
    emote_1 = nil,
    emote_2 = nil,
    ship_sail = nil,
    ship_hull = nil,
    ship_flag = nil,
  },

  -- Lifetime stats
  stats = {
    totalEarned = 0,
    totalStolen = 0,
    totalRaided = 0,
    biggestHaul = 0,
  },

  -- Settings
  settings = {
    musicEnabled = true,
    sfxEnabled = true,
    showOtherPlayers = true,
  },

  -- Timestamps
  joinedAt = 0,
  lastPlayedAt = 0,
}

--[[
  Deep copies player data for safe manipulation.
  Also handles migration from older schema versions.
  @param data Source player data (may have missing fields from older saves)
  @return Deep copy of the data
]]
function Types.deepCopyPlayerData(data: PlayerData): PlayerData
  -- Migration fallbacks for each field
  local sourceTreasury = data.treasury or data.money or 0
  local sourceEquippedGear = data.equippedGear or "rusty_cutlass"
  local sourceOwnedGear = data.ownedGear or { "rusty_cutlass" }
  local sourceNotorietyXP = data.notorietyXP or 0
  local sourceTutorialCompleted = if data.tutorialCompleted ~= nil
    then data.tutorialCompleted
    else false
  local sourceOwnedCosmetics = data.ownedCosmetics or {}
  local sourceEquippedCosmetics = data.equippedCosmetics or {}
  local sourceStats = data.stats or {}
  local sourceSettings = data.settings or {}

  local copy: PlayerData = {
    treasury = sourceTreasury,
    equippedGear = sourceEquippedGear,
    ownedGear = {},
    notorietyXP = sourceNotorietyXP,
    tutorialCompleted = sourceTutorialCompleted,
    ownedCosmetics = {},
    equippedCosmetics = {
      cutlass_skin = sourceEquippedCosmetics.cutlass_skin,
      hat = sourceEquippedCosmetics.hat,
      outfit = sourceEquippedCosmetics.outfit,
      pet = sourceEquippedCosmetics.pet,
      emote_1 = sourceEquippedCosmetics.emote_1,
      emote_2 = sourceEquippedCosmetics.emote_2,
      ship_sail = sourceEquippedCosmetics.ship_sail,
      ship_hull = sourceEquippedCosmetics.ship_hull,
      ship_flag = sourceEquippedCosmetics.ship_flag,
    },
    stats = {
      totalEarned = sourceStats.totalEarned or 0,
      totalStolen = sourceStats.totalStolen or 0,
      totalRaided = sourceStats.totalRaided or 0,
      biggestHaul = sourceStats.biggestHaul or 0,
    },
    settings = {
      musicEnabled = if sourceSettings.musicEnabled ~= nil
        then sourceSettings.musicEnabled
        else true,
      sfxEnabled = if sourceSettings.sfxEnabled ~= nil then sourceSettings.sfxEnabled else true,
      showOtherPlayers = if sourceSettings.showOtherPlayers ~= nil
        then sourceSettings.showOtherPlayers
        else true,
    },
    joinedAt = data.joinedAt or 0,
    lastPlayedAt = data.lastPlayedAt or 0,
  }

  -- Copy array fields
  for _, gearId in sourceOwnedGear do
    table.insert(copy.ownedGear, gearId)
  end

  for _, cosmeticId in sourceOwnedCosmetics do
    table.insert(copy.ownedCosmetics, cosmeticId)
  end

  return copy
end

--[[
  Creates a fresh session state for a player.
  Optionally sets tutorialActive based on whether the player has completed the tutorial.
  @param tutorialCompleted Whether the player has already completed the tutorial
  @return A new SessionState with correct defaults
]]
function Types.createSessionState(tutorialCompleted: boolean): SessionState
  local state: SessionState = {
    heldDoubloons = 0,
    shipHold = 0,
    shipLocked = true,
    isRagdolling = false,
    ragdollEndTime = 0,
    recoveryEndTime = 0,
    dashCooldownEnd = 0,
    isDashing = false,
    dashInvulnEnd = 0,
    isBlocking = false,
    lastHitTargets = {},
    lastRaidedShips = {},
    hasBounty = false,
    tutorialActive = not tutorialCompleted,
    tutorialStep = if tutorialCompleted then 0 else 1,
    threatLevel = 0,
    lastLockTime = os.clock(),
    inHarbor = false,
    inDangerZone = false,
    dangerZoneName = nil,
    phantomCaptainActive = false,
  }
  return state
end

return Types
