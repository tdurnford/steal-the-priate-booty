--[[
  GearService.lua
  Server-authoritative gear purchase and equip system.

  Handles:
    - Client purchase requests (validates via DataService)
    - Client equip requests (validates via DataService)
    - Visual gear tool on player characters (placeholder — MODEL-004 will replace)
    - Gear replication to all clients

  Delegates all data persistence to DataService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

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

-- Track active gear tools per player
local ActiveTools: { [Player]: Tool } = {}

--------------------------------------------------------------------------------
-- GEAR TOOL VISUALS (placeholder — MODEL-004 will replace)
--------------------------------------------------------------------------------

-- Placeholder visual properties per gear tier
local GEAR_VISUALS = {
  driftwood = {
    color = BrickColor.new("Reddish brown"),
    size = Vector3.new(0.3, 0.3, 3.5),
    material = Enum.Material.Wood,
  },
  rusty_cutlass = {
    color = BrickColor.new("Dark stone grey"),
    size = Vector3.new(0.2, 0.4, 3.5),
    material = Enum.Material.Metal,
  },
  iron_cutlass = {
    color = BrickColor.new("Medium stone grey"),
    size = Vector3.new(0.2, 0.4, 3.5),
    material = Enum.Material.Metal,
  },
  steel_cutlass = {
    color = BrickColor.new("Institutional white"),
    size = Vector3.new(0.2, 0.4, 3.8),
    material = Enum.Material.Metal,
  },
  captains_saber = {
    color = BrickColor.new("Bright yellow"),
    size = Vector3.new(0.2, 0.4, 4.0),
    material = Enum.Material.Metal,
  },
  legendary_blade = {
    color = BrickColor.new("Bright orange"),
    size = Vector3.new(0.25, 0.5, 4.5),
    material = Enum.Material.Neon,
  },
}

--[[
  Creates a placeholder cutlass Tool for the given gear ID.
  The Tool has a Handle part shaped like a sword blade.
  MODEL-004 will replace this with proper 3D models.
  @param gearId The gear type ID
  @return Tool instance ready to parent to the player
]]
local function createGearTool(gearId: string): Tool
  local visual = GEAR_VISUALS[gearId] or GEAR_VISUALS.rusty_cutlass
  local gearDef = GameConfig.GearById[gearId]
  local displayName = if gearDef then gearDef.name else "Cutlass"

  local tool = Instance.new("Tool")
  tool.Name = "Cutlass"
  tool.CanBeDropped = false
  tool.RequiresHandle = true
  tool.ToolTip = displayName

  local handle = Instance.new("Part")
  handle.Name = "Handle"
  handle.Size = visual.size
  handle.BrickColor = visual.color
  handle.Material = visual.material
  handle.CanCollide = false
  handle.Massless = true
  handle.Parent = tool

  -- Subtle glow for legendary blade
  if gearId == "legendary_blade" then
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(255, 170, 0)
    light.Brightness = 1
    light.Range = 8
    light.Parent = handle
  end

  return tool
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
