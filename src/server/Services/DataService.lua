--[[
	DataService.lua
	Handles player data persistence using ProfileService.
	Manages profile loading on join and release on leave.
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

--[[
  Gets the profile for a player.
  @param player The player to get profile for
  @return Profile object or nil if not loaded
]]
function DataService:GetProfile(player: Player)
  return Profiles[player]
end

--[[
  Gets the player data for a player.
  @param player The player to get data for
  @return PlayerData table or nil if not loaded
]]
function DataService:GetData(player: Player): Types.PlayerData?
  local profile = Profiles[player]
  if profile then
    return profile.Data
  end
  return nil
end

--[[
  Checks if a player's data is loaded and ready.
  @param player The player to check
  @return True if data is loaded
]]
function DataService:IsDataLoaded(player: Player): boolean
  return Profiles[player] ~= nil
end

--[[
  Updates the player's money balance.
  @param player The player to update
  @param amount Amount to add (positive) or subtract (negative)
  @return True if successful, false if insufficient funds or data not loaded
]]
function DataService:UpdateMoney(player: Player, amount: number): boolean
  local profile = Profiles[player]
  if not profile then
    return false
  end

  local newBalance = profile.Data.money + amount
  if newBalance < 0 then
    return false
  end

  profile.Data.money = newBalance
  self.Client.DataChanged:Fire(player, "money", newBalance)
  return true
end

--[[
  Updates a player setting.
  @param player The player to update
  @param settingKey The setting key to update
  @param value The new value
  @return True if successful
]]
function DataService:UpdateSetting(player: Player, settingKey: string, value: any): boolean
  local profile = Profiles[player]
  if not profile then
    return false
  end

  if profile.Data.settings[settingKey] == nil then
    return false
  end

  profile.Data.settings[settingKey] = value
  self.Client.DataChanged:Fire(player, "settings", settingKey)
  return true
end

-- Client-exposed methods
function DataService.Client:GetData(player: Player)
  return DataService:GetData(player)
end

function DataService.Client:GetMoney(player: Player)
  local data = DataService:GetData(player)
  return if data then data.money else 0
end

function DataService.Client:UpdateSetting(player: Player, settingKey: string, value: any)
  return DataService:UpdateSetting(player, settingKey, value)
end

--[[
  Loads a player's profile from ProfileService.
]]
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

  -- Apply deep copy to ensure data integrity
  profile.Data = Types.deepCopyPlayerData(profile.Data)

  -- Store profile
  Profiles[player] = profile

  -- Notify client and server
  DataService.Client.DataLoaded:Fire(player, profile.Data)
  DataService.PlayerDataLoaded:Fire(player, profile.Data)
  print("[DataService] Profile loaded for", player.Name)
end

--[[
  Releases a player's profile when they leave.
]]
local function releaseProfile(player: Player)
  local profile = Profiles[player]
  if profile then
    profile:Release()
    Profiles[player] = nil
    print("[DataService] Profile released for", player.Name)
  end
end

function DataService:KnitInit()
  ProfileStore = ProfileService.GetProfileStore(PROFILE_STORE_NAME, Types.DEFAULT_PLAYER_DATA)
  print("[DataService] Initialized")
end

function DataService:KnitStart()
  -- Load profiles for players who join
  Players.PlayerAdded:Connect(function(player)
    loadProfile(player)
  end)

  -- Release profiles when players leave
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
