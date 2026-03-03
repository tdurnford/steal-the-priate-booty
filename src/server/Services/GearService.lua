--[[
  GearService.lua
  Server-authoritative gear purchase and equip system.

  Handles:
    - Client purchase requests (validates via DataService)
    - Client equip requests (validates via DataService)
    - Visual gear tool on player characters (detailed Part-based models via WeaponModels)
    - Gear replication to all clients

  Delegates all data persistence to DataService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local Server = ServerScriptService:WaitForChild("Server")
local RateLimiter = require(Server:WaitForChild("RateLimiter"))
local WeaponModels = require(Server:WaitForChild("WeaponModels"))

local GearService = Knit.CreateService({
  Name = "GearService",
  Client = {
    -- Fired to the player when gear is purchased or equipped.
    -- Args: (gearId: string, action: string) — "purchased" or "equipped"
    GearChanged = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
GearService.GearPurchased = Signal.new() -- (player, gearId)
GearService.GearEquipped = Signal.new() -- (player, gearId)

-- Lazy-loaded service reference
local DataService = nil

-- Rate limiters for client-callable methods
local purchaseLimit = RateLimiter.new("GearService.PurchaseGear", 1.0)
local equipLimit = RateLimiter.new("GearService.EquipGear", 0.5)
local catalogLimit = RateLimiter.new("GearService.GetGearCatalog", 2.0)
local ownedLimit = RateLimiter.new("GearService.GetOwnedGear", 2.0)

-- Track active gear tools per player
local ActiveTools: { [Player]: Tool } = {}

--------------------------------------------------------------------------------
-- GEAR TOOL CREATION (detailed Part-based models via WeaponModels)
--------------------------------------------------------------------------------

--[[
  Creates a detailed cutlass Tool for the given gear ID using WeaponModels.
  Falls back to a simple single-Part tool if no builder exists.
  @param gearId The gear type ID
  @return Tool instance ready to parent to the player
]]
local function createGearTool(gearId: string): Tool
  local tool = WeaponModels.build(gearId)
  if tool then
    return tool
  end

  -- Fallback: simple box tool if WeaponModels has no builder
  local gearDef = GameConfig.GearById[gearId]
  local displayName = if gearDef then gearDef.name else "Cutlass"

  local fallback = Instance.new("Tool")
  fallback.Name = "Cutlass"
  fallback.CanBeDropped = false
  fallback.RequiresHandle = true
  fallback.ToolTip = displayName

  local handle = Instance.new("Part")
  handle.Name = "Handle"
  handle.Size = Vector3.new(0.2, 0.4, 3.5)
  handle.Color = Color3.fromRGB(130, 130, 140)
  handle.Material = Enum.Material.Metal
  handle.CanCollide = false
  handle.Massless = true
  handle.Parent = fallback

  return fallback
end

--[[
  Gives a gear tool to a player, removing any existing gear tool first.
  @param player The player to give the tool to
  @param gearId The gear type ID
]]
local function giveGearTool(player: Player, gearId: string)
  -- Remove existing tool first
  local existingTool = ActiveTools[player]
  if existingTool then
    existingTool:Destroy()
    ActiveTools[player] = nil
  end

  local character = player.Character
  if not character then
    return
  end

  -- Also remove any stale Cutlass tools from the character or backpack
  for _, child in character:GetChildren() do
    if child:IsA("Tool") and child.Name == "Cutlass" then
      child:Destroy()
    end
  end
  local backpack = player:FindFirstChildOfClass("Backpack")
  if backpack then
    for _, child in backpack:GetChildren() do
      if child:IsA("Tool") and child.Name == "Cutlass" then
        child:Destroy()
      end
    end
  end

  local tool = createGearTool(gearId)
  tool.Parent = character
  ActiveTools[player] = tool
end

--[[
  Removes a player's gear tool.
  @param player The player
]]
local function removeGearTool(player: Player)
  local tool = ActiveTools[player]
  if tool then
    tool:Destroy()
  end
  ActiveTools[player] = nil
end

--------------------------------------------------------------------------------
-- CLIENT-CALLABLE METHODS
--------------------------------------------------------------------------------

--[[
  Client requests to purchase gear.
  @param player The requesting player
  @param gearId The gear ID to purchase
  @return (success: boolean, message: string?)
]]
function GearService.Client:PurchaseGear(player: Player, gearId: string): (boolean, string?)
  if type(gearId) ~= "string" then
    return false, "Invalid gear ID"
  end
  if not purchaseLimit:check(player) then
    return false, "Too many requests"
  end

  local success, message = DataService:PurchaseGear(player, gearId)
  if success then
    -- Auto-equip the newly purchased gear
    DataService:EquipGear(player, gearId)
    giveGearTool(player, gearId)

    -- Notify client and server
    GearService.Client.GearChanged:Fire(player, gearId, "purchased")
    GearService.GearPurchased:Fire(player, gearId)
    GearService.GearEquipped:Fire(player, gearId)

    print(string.format("[GearService] %s purchased and equipped %s", player.Name, gearId))
  end
  return success, message
end

--[[
  Client requests to equip owned gear.
  @param player The requesting player
  @param gearId The gear ID to equip
  @return (success: boolean, message: string?)
]]
function GearService.Client:EquipGear(player: Player, gearId: string): (boolean, string?)
  if type(gearId) ~= "string" then
    return false, "Invalid gear ID"
  end
  if not equipLimit:check(player) then
    return false, "Too many requests"
  end

  local success, message = DataService:EquipGear(player, gearId)
  if success then
    giveGearTool(player, gearId)

    -- Notify client and server
    GearService.Client.GearChanged:Fire(player, gearId, "equipped")
    GearService.GearEquipped:Fire(player, gearId)

    print(string.format("[GearService] %s equipped %s", player.Name, gearId))
  end
  return success, message
end

--[[
  Client requests list of owned gear IDs.
  @param player The requesting player
  @return { string } Array of owned gear IDs
]]
function GearService.Client:GetOwnedGear(player: Player): { string }
  if not ownedLimit:check(player) then
    return {}
  end
  local data = DataService:GetData(player)
  if not data then
    return {}
  end
  -- Return a copy to prevent client manipulation
  local owned = {}
  for _, id in data.ownedGear do
    table.insert(owned, id)
  end
  return owned
end

--[[
  Client requests full gear catalog with ownership and equip status.
  @param player The requesting player
  @return Array of gear entries with ownership/equip info
]]
function GearService.Client:GetGearCatalog(player: Player)
  if not catalogLimit:check(player) then
    return {}
  end
  local data = DataService:GetData(player)
  local equippedGear = if data then data.equippedGear else nil

  local catalog = {}
  for _, gearDef in GameConfig.Gear do
    if not gearDef.isTutorial then -- Don't show driftwood in the shop
      local owned = if data then DataService:OwnsGear(player, gearDef.id) else false
      table.insert(catalog, {
        id = gearDef.id,
        name = gearDef.name,
        cost = gearDef.cost,
        containerDamage = gearDef.containerDamage,
        displayOrder = gearDef.displayOrder,
        owned = owned,
        equipped = equippedGear == gearDef.id,
      })
    end
  end
  return catalog
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function GearService:KnitInit()
  print("[GearService] Initializing...")
end

function GearService:KnitStart()
  DataService = Knit.GetService("DataService")

  -- Give gear tool when player data is loaded
  -- Skip for tutorial players — TutorialService handles their gear
  DataService.PlayerDataLoaded:Connect(function(player: Player, data)
    if data and data.equippedGear then
      if not data.tutorialCompleted then
        return -- tutorial player; TutorialService will handle gear
      end
      -- Wait for character to exist
      if not player.Character then
        player.CharacterAdded:Wait()
      end
      giveGearTool(player, data.equippedGear)
    end
  end)

  -- Re-give gear tool on respawn (skip for active tutorial players)
  local SessionStateService = Knit.GetService("SessionStateService")
  local function onCharacterAdded(player: Player)
    if not DataService:IsDataLoaded(player) then
      return
    end
    -- During tutorial, TutorialService handles gear
    if SessionStateService and SessionStateService:IsTutorialActive(player) then
      return
    end
    local gearId = DataService:GetEquippedGear(player)
    if gearId then
      task.defer(function()
        giveGearTool(player, gearId)
      end)
    end
  end

  Players.PlayerAdded:Connect(function(player: Player)
    player.CharacterAdded:Connect(function()
      onCharacterAdded(player)
    end)
  end)

  -- Handle players already in game (studio edge case)
  for _, player in Players:GetPlayers() do
    player.CharacterAdded:Connect(function()
      onCharacterAdded(player)
    end)
  end

  -- Clean up on player leave
  Players.PlayerRemoving:Connect(function(player: Player)
    removeGearTool(player)
  end)

  print("[GearService] Started")
end

return GearService
