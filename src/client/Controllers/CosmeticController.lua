--[[
  CosmeticController.lua
  Client-side cosmetic state tracking controller.

  Handles:
    - Tracking the local player's owned and equipped cosmetics
    - Listening to CosmeticChanged signals for state updates
    - Providing API for cosmetic shop UI (UI-011) and other controllers
    - Purchase, equip, and unequip RPC wrappers

  Does NOT apply cosmetic visuals — COSMETIC-003 will handle that.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local CosmeticConfig = require(Shared:WaitForChild("CosmeticConfig"))

local CosmeticController = Knit.CreateController({
  Name = "CosmeticController",
})

-- Public signals for other controllers
-- Args: (cosmeticId: string?, slotField: string, action: string)
CosmeticController.CosmeticChanged = Signal.new()

-- Lazy-loaded references
local CosmeticService = nil
local DataService = nil
local SoundController = nil

-- Local state
local OwnedCosmetics: { string } = {}
local EquippedCosmetics: { [string]: string? } = {}

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Checks if the local player owns a cosmetic item.
  @param cosmeticId The cosmetic ID to check
  @return boolean
]]
function CosmeticController:OwnsCosmetic(cosmeticId: string): boolean
  for _, id in OwnedCosmetics do
    if id == cosmeticId then
      return true
    end
  end
  return false
end

--[[
  Gets the cosmetic ID equipped in a given slot field.
  @param slotField The EquippedCosmetics field (e.g. "hat", "emote_1")
  @return string? The cosmetic ID or nil
]]
function CosmeticController:GetEquippedInSlot(slotField: string): string?
  return EquippedCosmetics[slotField]
end

--[[
  Gets the full equipped cosmetics map.
  @return { [string]: string? }
]]
function CosmeticController:GetEquippedCosmetics(): { [string]: string? }
  local copy = {}
  for slot, id in EquippedCosmetics do
    copy[slot] = id
  end
  return copy
end

--[[
  Gets the list of owned cosmetic IDs.
  @return { string }
]]
function CosmeticController:GetOwnedCosmetics(): { string }
  local copy = {}
  for _, id in OwnedCosmetics do
    table.insert(copy, id)
  end
  return copy
end

--[[
  Requests the server to purchase a cosmetic.
  @param cosmeticId The cosmetic ID to purchase
  @return Promise<boolean, string?> success and optional error message
]]
function CosmeticController:PurchaseCosmetic(cosmeticId: string)
  if not CosmeticService then
    return
  end
  return CosmeticService:PurchaseCosmetic(cosmeticId)
end

--[[
  Requests the server to equip a cosmetic to a slot.
  @param cosmeticId The cosmetic ID to equip
  @param slotField The EquippedCosmetics field to equip into
  @return Promise<boolean, string?> success and optional error message
]]
function CosmeticController:EquipCosmetic(cosmeticId: string, slotField: string)
  if not CosmeticService then
    return
  end
  return CosmeticService:EquipCosmetic(cosmeticId, slotField)
end

--[[
  Requests the server to unequip a cosmetic slot.
  @param slotField The EquippedCosmetics field to clear
  @return Promise<boolean, string?> success and optional error message
]]
function CosmeticController:UnequipCosmetic(slotField: string)
  if not CosmeticService then
    return
  end
  return CosmeticService:UnequipCosmetic(slotField)
end

--[[
  Requests the full cosmetic catalog from the server.
  @return Promise<table> Array of catalog entries with ownership/equip info
]]
function CosmeticController:GetCosmeticCatalog()
  if not CosmeticService then
    return
  end
  return CosmeticService:GetCosmeticCatalog()
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function CosmeticController:KnitInit()
  print("[CosmeticController] Initializing...")
end

function CosmeticController:KnitStart()
  CosmeticService = Knit.GetService("CosmeticService")
  DataService = Knit.GetService("DataService")

  local ok, ctrl = pcall(function()
    return Knit.GetController("SoundController")
  end)
  if ok then
    SoundController = ctrl
  end

  -- Load initial cosmetic state from player data
  DataService:GetData()
    :andThen(function(data)
      if data then
        OwnedCosmetics = data.ownedCosmetics or {}
        EquippedCosmetics = data.equippedCosmetics or {}
      end
    end)
    :catch(function(err)
      warn("[CosmeticController] Failed to load initial cosmetic state:", err)
    end)

  -- Listen for cosmetic changes from server
  CosmeticService.CosmeticChanged:Connect(
    function(cosmeticId: string?, slotField: string, action: string)
      if action == "purchased" and cosmeticId then
        table.insert(OwnedCosmetics, cosmeticId)
        if SoundController then
          SoundController:PlayPurchaseSound()
        end
      elseif action == "equipped" then
        EquippedCosmetics[slotField] = cosmeticId
      elseif action == "unequipped" then
        EquippedCosmetics[slotField] = nil
      end

      -- Fire local signal for other controllers
      CosmeticController.CosmeticChanged:Fire(cosmeticId, slotField, action)
      print(
        string.format(
          "[CosmeticController] Cosmetic %s: %s in %s",
          action,
          tostring(cosmeticId),
          slotField
        )
      )
    end
  )

  -- Listen for data changes (e.g. from reconnection)
  DataService.DataChanged:Connect(function(key: string, value: any)
    if key == "ownedCosmetics" and type(value) == "table" then
      OwnedCosmetics = value
    elseif key == "equippedCosmetics" and type(value) == "table" then
      EquippedCosmetics = value
    end
  end)

  print("[CosmeticController] Started")
end

return CosmeticController
