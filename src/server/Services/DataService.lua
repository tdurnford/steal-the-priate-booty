--[[
  DataService.lua
  Handles player data persistence using ProfileService.
  Manages profile loading on join and release on leave.
  Exposes getter/setter API for other services to read/write player data.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local ServerPackages = ServerScriptService:WaitForChild("ServerPackages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local ProfileService = require(ServerPackages:WaitForChild("ProfileService"))
local Types = require(Shared:WaitForChild("Types"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local PROFILE_STORE_NAME = "PlayerData_v1"
local PROFILE_KEY_PREFIX = "Player_"

local DataService = Knit.CreateService({
  Name = "DataService",
  Client = {
    -- Signal fired when player data is loaded and ready
    DataLoaded = Knit.CreateSignal(),
    -- Signal fired when data changes (for reactive UI updates)
    DataChanged = Knit.CreateSignal(),
  },
})

-- ProfileStore instance
local ProfileStore = nil

-- Cache of loaded profiles by player
local Profiles: { [Player]: any } = {}

-- Server-side signal fired when a player's data is loaded
DataService.PlayerDataLoaded = Signal.new()

--------------------------------------------------------------------------------
-- DATA ACCESSORS
--------------------------------------------------------------------------------

function DataService:GetProfile(player: Player)
  return Profiles[player]
end

function DataService:GetData(player: Player): Types.PlayerData?
  local profile = Profiles[player]
  if profile then
    return profile.Data
  end
  return nil
end

function DataService:IsDataLoaded(player: Player): boolean
  return Profiles[player] ~= nil
end

--------------------------------------------------------------------------------
-- TREASURY
--------------------------------------------------------------------------------

function DataService:GetTreasury(player: Player): number
  local data = self:GetData(player)
  return if data then data.treasury else 0
end

function DataService:UpdateTreasury(player: Player, amount: number): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  local newBalance = data.treasury + amount
  if newBalance < 0 then
    return false
  end

  data.treasury = newBalance
  self.Client.DataChanged:Fire(player, "treasury", newBalance)
  return true
end

--------------------------------------------------------------------------------
-- GEAR
--------------------------------------------------------------------------------

function DataService:GetEquippedGear(player: Player): string?
  local data = self:GetData(player)
  return if data then data.equippedGear else nil
end

function DataService:OwnsGear(player: Player, gearId: string): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end
  for _, id in data.ownedGear do
    if id == gearId then
      return true
    end
  end
  return false
end

function DataService:PurchaseGear(player: Player, gearId: string): (boolean, string?)
  local data = self:GetData(player)
  if not data then
    return false, "Data not loaded"
  end

  -- Check gear exists in config
  local gearDef = GameConfig.GearById[gearId]
  if not gearDef then
    return false, "Invalid gear ID"
  end

  -- Check not already owned
  if self:OwnsGear(player, gearId) then
    return false, "Already owned"
  end

  -- Check can afford
  if data.treasury < gearDef.cost then
    return false, "Insufficient treasury"
  end

  -- Deduct cost and add to owned
  data.treasury = data.treasury - gearDef.cost
  table.insert(data.ownedGear, gearId)

  self.Client.DataChanged:Fire(player, "treasury", data.treasury)
  self.Client.DataChanged:Fire(player, "ownedGear", data.ownedGear)
  return true, nil
end

function DataService:EquipGear(player: Player, gearId: string): (boolean, string?)
  local data = self:GetData(player)
  if not data then
    return false, "Data not loaded"
  end

  if not self:OwnsGear(player, gearId) then
    return false, "Gear not owned"
  end

  data.equippedGear = gearId
  self.Client.DataChanged:Fire(player, "equippedGear", gearId)
  return true, nil
end

--------------------------------------------------------------------------------
-- NOTORIETY / RANK
--------------------------------------------------------------------------------

function DataService:GetNotorietyXP(player: Player): number
  local data = self:GetData(player)
  return if data then data.notorietyXP else 0
end

function DataService:AddNotorietyXP(player: Player, amount: number): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  local oldRank = GameConfig.getRankForXP(data.notorietyXP)
  data.notorietyXP = data.notorietyXP + amount
  local newRank = GameConfig.getRankForXP(data.notorietyXP)

  self.Client.DataChanged:Fire(player, "notorietyXP", data.notorietyXP)

  -- Notify if rank changed
  if newRank.rank ~= oldRank.rank then
    self.Client.DataChanged:Fire(player, "notorietyRank", newRank)
  end

  return true
end

--------------------------------------------------------------------------------
-- TUTORIAL
--------------------------------------------------------------------------------

function DataService:IsTutorialCompleted(player: Player): boolean
  local data = self:GetData(player)
  return if data then data.tutorialCompleted else false
end

function DataService:CompleteTutorial(player: Player): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  data.tutorialCompleted = true
  self.Client.DataChanged:Fire(player, "tutorialCompleted", true)
  return true
end

--------------------------------------------------------------------------------
-- COSMETICS
--------------------------------------------------------------------------------

function DataService:OwnsCosmetic(player: Player, cosmeticId: string): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end
  for _, id in data.ownedCosmetics do
    if id == cosmeticId then
      return true
    end
  end
  return false
end

function DataService:AddOwnedCosmetic(player: Player, cosmeticId: string): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  if self:OwnsCosmetic(player, cosmeticId) then
    return false
  end

  table.insert(data.ownedCosmetics, cosmeticId)
  self.Client.DataChanged:Fire(player, "ownedCosmetics", data.ownedCosmetics)
  return true
end

function DataService:EquipCosmetic(
  player: Player,
  slot: string,
  cosmeticId: string?
): (boolean, string?)
  local data = self:GetData(player)
  if not data then
    return false, "Data not loaded"
  end

  -- Validate slot exists
  if data.equippedCosmetics[slot] == nil and cosmeticId ~= nil then
    -- Check if it's a valid slot name
    local validSlots = {
      cutlass_skin = true,
      hat = true,
      outfit = true,
      pet = true,
      emote_1 = true,
      emote_2 = true,
      ship_sail = true,
      ship_hull = true,
      ship_flag = true,
    }
    if not validSlots[slot] then
      return false, "Invalid cosmetic slot"
    end
  end

  -- If equipping (not unequipping), validate ownership
  if cosmeticId ~= nil and not self:OwnsCosmetic(player, cosmeticId) then
    return false, "Cosmetic not owned"
  end

  data.equippedCosmetics[slot] = cosmeticId
  self.Client.DataChanged:Fire(player, "equippedCosmetics", data.equippedCosmetics)
  return true, nil
end

--------------------------------------------------------------------------------
-- STATS
--------------------------------------------------------------------------------

function DataService:IncrementStat(player: Player, statKey: string, amount: number): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  if data.stats[statKey] == nil then
    return false
  end

  data.stats[statKey] = data.stats[statKey] + amount
  self.Client.DataChanged:Fire(player, "stats", data.stats)
  return true
end

function DataService:UpdateBiggestHaul(player: Player, haul: number): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  if haul > data.stats.biggestHaul then
    data.stats.biggestHaul = haul
    self.Client.DataChanged:Fire(player, "stats", data.stats)
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------------

function DataService:UpdateSetting(player: Player, settingKey: string, value: any): boolean
  local data = self:GetData(player)
  if not data then
    return false
  end

  if data.settings[settingKey] == nil then
    return false
  end

  data.settings[settingKey] = value
  self.Client.DataChanged:Fire(player, "settings", settingKey)
  return true
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS
--------------------------------------------------------------------------------

function DataService.Client:GetData(player: Player)
  local data = DataService:GetData(player)
  if data then
    return Types.deepCopyPlayerData(data)
  end
  return nil
end

function DataService.Client:GetTreasury(player: Player)
  return DataService:GetTreasury(player)
end

function DataService.Client:GetEquippedGear(player: Player)
  return DataService:GetEquippedGear(player)
end

function DataService.Client:UpdateSetting(player: Player, settingKey: string, value: any)
  return DataService:UpdateSetting(player, settingKey, value)
end

--------------------------------------------------------------------------------
-- PROFILE LOADING
--------------------------------------------------------------------------------

local function loadProfile(player: Player)
  local profileKey = PROFILE_KEY_PREFIX .. player.UserId
  local profile = ProfileStore:LoadProfileAsync(profileKey)

  if profile == nil then
    player:Kick("Failed to load your data. Please rejoin.")
    return
  end

  profile:AddUserId(player.UserId)
  profile:Reconcile()

  -- Handle profile release (e.g., player joins another server)
  profile:ListenToRelease(function()
    Profiles[player] = nil
    player:Kick("Your data was loaded on another server. Please rejoin.")
  end)

  -- Check if player is still in game
  if not player:IsDescendantOf(Players) then
    profile:Release()
    return
  end

  -- Apply deep copy for migration safety
  profile.Data = Types.deepCopyPlayerData(profile.Data)

  -- Update timestamps
  if profile.Data.joinedAt == 0 then
    profile.Data.joinedAt = os.time()
  end
  profile.Data.lastPlayedAt = os.time()

  -- Store profile
  Profiles[player] = profile

  -- Notify client and server
  local clientCopy = Types.deepCopyPlayerData(profile.Data)
  DataService.Client.DataLoaded:Fire(player, clientCopy)
  DataService.PlayerDataLoaded:Fire(player, profile.Data)
  print("[DataService] Profile loaded for", player.Name)
end

local function releaseProfile(player: Player)
  local profile = Profiles[player]
  if profile then
    profile.Data.lastPlayedAt = os.time()
    profile:Release()
    Profiles[player] = nil
    print("[DataService] Profile released for", player.Name)
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DataService:KnitInit()
  ProfileStore = ProfileService.GetProfileStore(PROFILE_STORE_NAME, Types.DEFAULT_PLAYER_DATA)
  print("[DataService] Initialized")
end

function DataService:KnitStart()
  Players.PlayerAdded:Connect(function(player)
    loadProfile(player)
  end)

  Players.PlayerRemoving:Connect(function(player)
    releaseProfile(player)
  end)

  -- Handle players already in game (studio edge case)
  for _, player in Players:GetPlayers() do
    task.spawn(loadProfile, player)
  end

  print("[DataService] Started")
end

return DataService
