--[[
  CosmeticService.lua
  Server-authoritative cosmetic purchase, equip, and unequip system.

  Handles:
    - Client purchase requests (validates via CosmeticConfig + DataService)
    - Client equip requests (validates slot compatibility + ownership)
    - Client unequip requests (clears a cosmetic slot)
    - Spending treasury on cosmetics triggers ship tier recalculation
    - Purchased cosmetics are permanent — never lost

  Delegates all data persistence to DataService.
  COSMETIC-003 will handle visual application of equipped cosmetics.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local CosmeticConfig = require(Shared:WaitForChild("CosmeticConfig"))

local Server = ServerScriptService:WaitForChild("Server")
local RateLimiter = require(Server:WaitForChild("RateLimiter"))

local CosmeticService = Knit.CreateService({
  Name = "CosmeticService",
  Client = {
    -- Fired to the player when a cosmetic is purchased, equipped, or unequipped.
    -- Args: (cosmeticId: string?, slotField: string, action: string)
    -- action is "purchased", "equipped", or "unequipped"
    CosmeticChanged = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
CosmeticService.CosmeticPurchased = Signal.new() -- (player, cosmeticId)
CosmeticService.CosmeticEquipped = Signal.new() -- (player, cosmeticId, slotField)
CosmeticService.CosmeticUnequipped = Signal.new() -- (player, slotField)

-- Rate limiters for client-callable methods
local purchaseLimit = RateLimiter.new("CosmeticService.PurchaseCosmetic", 1.0)
local equipLimit = RateLimiter.new("CosmeticService.EquipCosmetic", 0.5)
local unequipLimit = RateLimiter.new("CosmeticService.UnequipCosmetic", 0.5)
local catalogLimit = RateLimiter.new("CosmeticService.GetCosmeticCatalog", 2.0)
local equippedLimit = RateLimiter.new("CosmeticService.GetEquippedCosmetics", 2.0)

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil
local ShipService = nil

--------------------------------------------------------------------------------
-- CLIENT-CALLABLE METHODS
--------------------------------------------------------------------------------

--[[
  Client requests to purchase a cosmetic item.
  Deducts treasury, adds to owned cosmetics, triggers ship tier recalculation.
  @param player The requesting player
  @param cosmeticId The cosmetic ID to purchase
  @return (success: boolean, message: string?)
]]
function CosmeticService.Client:PurchaseCosmetic(
  player: Player,
  cosmeticId: string
): (boolean, string?)
  if type(cosmeticId) ~= "string" then
    return false, "Invalid cosmetic ID"
  end
  if not purchaseLimit:check(player) then
    return false, "Too many requests"
  end

  local data = DataService:GetData(player)
  if not data then
    return false, "Data not loaded"
  end

  -- Validate via CosmeticConfig
  local canBuy, reason = CosmeticConfig.canPurchase(cosmeticId, data.treasury, data.ownedCosmetics)
  if not canBuy then
    return false, reason
  end

  local cosmeticDef = CosmeticConfig.getById(cosmeticId)

  -- Deduct treasury
  local deducted = DataService:UpdateTreasury(player, -cosmeticDef.cost)
  if not deducted then
    return false, "Treasury deduction failed"
  end

  -- Add to owned cosmetics
  DataService:AddOwnedCosmetic(player, cosmeticId)

  -- Recalculate ship tier (spending treasury may cause downgrade)
  if ShipService then
    ShipService:RecalculateShipTier(player)
  end

  -- Notify client and server
  CosmeticService.Client.CosmeticChanged:Fire(player, cosmeticId, cosmeticDef.slot, "purchased")
  CosmeticService.CosmeticPurchased:Fire(player, cosmeticId)

  print(string.format("[CosmeticService] %s purchased %s", player.Name, cosmeticId))
  return true, nil
end

--[[
  Client requests to equip a cosmetic to a slot.
  @param player The requesting player
  @param cosmeticId The cosmetic ID to equip
  @param slotField The EquippedCosmetics field to equip into (e.g. "hat", "emote_1")
  @return (success: boolean, message: string?)
]]
function CosmeticService.Client:EquipCosmetic(
  player: Player,
  cosmeticId: string,
  slotField: string
): (boolean, string?)
  if type(cosmeticId) ~= "string" or type(slotField) ~= "string" then
    return false, "Invalid arguments"
  end
  if not equipLimit:check(player) then
    return false, "Too many requests"
  end

  local data = DataService:GetData(player)
  if not data then
    return false, "Data not loaded"
  end

  -- Validate via CosmeticConfig
  local canEquip, reason = CosmeticConfig.canEquip(cosmeticId, slotField, data.ownedCosmetics)
  if not canEquip then
    return false, reason
  end

  -- Set the cosmetic in the slot
  local success, err = DataService:EquipCosmetic(player, slotField, cosmeticId)
  if not success then
    return false, err
  end

  -- Notify client and server
  CosmeticService.Client.CosmeticChanged:Fire(player, cosmeticId, slotField, "equipped")
  CosmeticService.CosmeticEquipped:Fire(player, cosmeticId, slotField)

  print(string.format("[CosmeticService] %s equipped %s to %s", player.Name, cosmeticId, slotField))
  return true, nil
end

--[[
  Client requests to unequip a cosmetic slot.
  @param player The requesting player
  @param slotField The EquippedCosmetics field to clear (e.g. "hat", "emote_1")
  @return (success: boolean, message: string?)
]]
function CosmeticService.Client:UnequipCosmetic(
  player: Player,
  slotField: string
): (boolean, string?)
  if type(slotField) ~= "string" then
    return false, "Invalid slot"
  end
  if not unequipLimit:check(player) then
    return false, "Too many requests"
  end

  local data = DataService:GetData(player)
  if not data then
    return false, "Data not loaded"
  end

  -- Check the slot is currently occupied
  if data.equippedCosmetics[slotField] == nil then
    return false, "Slot is empty"
  end

  -- Clear the slot
  local success, err = DataService:EquipCosmetic(player, slotField, nil)
  if not success then
    return false, err
  end

  -- Notify client and server
  CosmeticService.Client.CosmeticChanged:Fire(player, nil, slotField, "unequipped")
  CosmeticService.CosmeticUnequipped:Fire(player, slotField)

  print(string.format("[CosmeticService] %s unequipped slot %s", player.Name, slotField))
  return true, nil
end

--[[
  Client requests the full cosmetic catalog with ownership and equip status.
  @param player The requesting player
  @return Array of cosmetic entries with ownership/equip info
]]
function CosmeticService.Client:GetCosmeticCatalog(player: Player)
  if not catalogLimit:check(player) then
    return {}
  end
  local data = DataService:GetData(player)

  local catalog = {}
  for _, category in CosmeticConfig.Categories do
    local items = CosmeticConfig.getByCategory(category)
    for _, cosmeticDef in items do
      local owned = if data then DataService:OwnsCosmetic(player, cosmeticDef.id) else false

      -- Check if currently equipped in any valid slot
      local equippedInSlot: string? = nil
      if data then
        local validFields = CosmeticConfig.SlotEquipFields[cosmeticDef.slot]
        if validFields then
          for _, field in validFields do
            if data.equippedCosmetics[field] == cosmeticDef.id then
              equippedInSlot = field
              break
            end
          end
        end
      end

      table.insert(catalog, {
        id = cosmeticDef.id,
        name = cosmeticDef.name,
        description = cosmeticDef.description,
        slot = cosmeticDef.slot,
        category = cosmeticDef.category,
        cost = cosmeticDef.cost,
        displayOrder = cosmeticDef.displayOrder,
        owned = owned,
        equippedInSlot = equippedInSlot,
      })
    end
  end
  return catalog
end

--[[
  Client requests the current equipped cosmetics map.
  @param player The requesting player
  @return EquippedCosmetics table (copy)
]]
function CosmeticService.Client:GetEquippedCosmetics(player: Player)
  if not equippedLimit:check(player) then
    return {}
  end
  local data = DataService:GetData(player)
  if not data then
    return {}
  end

  -- Return a copy
  local equipped = {}
  for slot, cosmeticId in data.equippedCosmetics do
    equipped[slot] = cosmeticId
  end
  return equipped
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function CosmeticService:KnitInit()
  print("[CosmeticService] Initializing...")
end

function CosmeticService:KnitStart()
  DataService = Knit.GetService("DataService")

  local ok, svc = pcall(function()
    return Knit.GetService("ShipService")
  end)
  if ok then
    ShipService = svc
  end

  print("[CosmeticService] Started")
end

return CosmeticService
