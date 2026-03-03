--[[
  CosmeticShopController.lua
  Client-side Knit controller that manages the cosmetic shop UI panel.

  Handles:
    - Opening/closing the shop (keybind "J")
    - Fetching cosmetic catalog from CosmeticService
    - Getting treasury balance for affordability checks
    - Routing purchase/equip/unequip requests through CosmeticController
    - Tab switching between 6 cosmetic categories
    - Rebuilding the panel when cosmetic state changes

  The shop is a modal panel — the player presses J to toggle it.
  Tab changes trigger a full panel rebuild (same pattern as LeaderboardController).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))
local CosmeticConfig = require(Shared:WaitForChild("CosmeticConfig"))

local CosmeticShopPanel =
  require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("CosmeticShopPanel"))

local CosmeticShopController = Knit.CreateController({
  Name = "CosmeticShopController",
})

-- References (set in KnitStart)
local CosmeticController = nil
local DataService = nil
local CosmeticService = nil
local SoundController = nil

-- State
local FusionScope = nil
local IsVisible = nil -- Fusion.Value<boolean>
local Treasury = nil -- Fusion.Value<number>
local CatalogData = nil -- Fusion.Value<table>
local ActiveTab = "Cutlass Skins" -- current category tab
local ShopScreenGui = nil
local ShopPanel = nil
local LocalPlayer = Players.LocalPlayer
local IsLoading = false

-- Toggle key
local SHOP_KEY = Enum.KeyCode.J

--------------------------------------------------------------------------------
-- SHOP PANEL MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Destroys the current shop panel and rebuilds it with fresh catalog data.
  Called when the catalog changes (purchase, equip, etc.) or tab changes.
]]
local function rebuildPanel()
  -- Destroy existing panel if any
  if ShopPanel then
    ShopPanel:Destroy()
    ShopPanel = nil
  end

  if not FusionScope or not IsVisible or not CatalogData or not Treasury then
    return
  end

  local catalogEntries = Fusion.peek(CatalogData)
  if not catalogEntries then
    return
  end

  ShopPanel = CosmeticShopPanel.create(
    FusionScope,
    IsVisible,
    CatalogData,
    ActiveTab,
    Treasury,
    function(tabId)
      -- Tab change callback
      ActiveTab = tabId
      rebuildPanel()
    end,
    function(cosmeticId: string, action: string, equippedSlotField: string?)
      -- Handle buy/equip/unequip actions
      if action == "buy" then
        CosmeticShopController:_handlePurchase(cosmeticId)
      elseif action == "equip" then
        CosmeticShopController:_handleEquip(cosmeticId)
      elseif action == "unequip" then
        CosmeticShopController:_handleUnequip(equippedSlotField)
      end
    end,
    function()
      -- Close button
      CosmeticShopController:Close()
    end
  )

  if ShopScreenGui then
    ShopPanel.Parent = ShopScreenGui
  end
end

--[[
  Fetches fresh catalog data from the server and updates local state.
]]
local function refreshCatalog()
  if not CosmeticService or IsLoading then
    return
  end

  IsLoading = true

  CosmeticService:GetCosmeticCatalog()
    :andThen(function(catalog)
      if CatalogData then
        CatalogData:set(catalog)
      end
      rebuildPanel()
    end)
    :catch(function(err)
      warn("[CosmeticShopController] Failed to fetch cosmetic catalog:", err)
    end)
    :finally(function()
      IsLoading = false
    end)
end

--[[
  Fetches the current treasury balance from the server.
]]
local function refreshTreasury()
  if not DataService then
    return
  end

  DataService:GetTreasury()
    :andThen(function(amount)
      if Treasury then
        Treasury:set(amount or 0)
      end
    end)
    :catch(function(err)
      warn("[CosmeticShopController] Failed to fetch treasury:", err)
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Opens the cosmetic shop panel. Fetches fresh data from the server.
]]
function CosmeticShopController:Open()
  if IsVisible and Fusion.peek(IsVisible) then
    return -- Already open
  end

  if SoundController then
    SoundController:PlayButtonClickSound()
  end

  -- Refresh data before showing
  refreshTreasury()
  refreshCatalog()

  if IsVisible then
    IsVisible:set(true)
  end
end

--[[
  Closes the cosmetic shop panel.
]]
function CosmeticShopController:Close()
  if IsVisible and not Fusion.peek(IsVisible) then
    return -- Already closed
  end

  if SoundController then
    SoundController:PlayButtonClickSound()
  end

  if IsVisible then
    IsVisible:set(false)
  end
end

--[[
  Toggles the cosmetic shop open/closed.
]]
function CosmeticShopController:Toggle()
  if IsVisible and Fusion.peek(IsVisible) then
    self:Close()
  else
    self:Open()
  end
end

--[[
  Returns whether the shop is currently visible.
  @return boolean
]]
function CosmeticShopController:IsOpen(): boolean
  if IsVisible then
    return Fusion.peek(IsVisible)
  end
  return false
end

--------------------------------------------------------------------------------
-- INTERNAL HANDLERS
--------------------------------------------------------------------------------

--[[
  Handles a purchase request from the UI.
  @param cosmeticId The cosmetic ID to purchase
]]
function CosmeticShopController:_handlePurchase(cosmeticId: string)
  if not CosmeticController then
    return
  end

  CosmeticController:PurchaseCosmetic(cosmeticId)
    :andThen(function(success, message)
      if success then
        -- Refresh both treasury and catalog after successful purchase
        refreshTreasury()
        refreshCatalog()
      else
        if SoundController then
          SoundController:PlayPurchaseFailSound()
        end
        warn("[CosmeticShopController] Purchase failed:", message or "Unknown error")
      end
    end)
    :catch(function(err)
      if SoundController then
        SoundController:PlayPurchaseFailSound()
      end
      warn("[CosmeticShopController] Purchase error:", err)
    end)
end

--[[
  Handles an equip request from the UI.
  Determines the correct slot field based on the cosmetic's slot type.
  For emotes (which have two possible slots), picks the first empty slot.
  @param cosmeticId The cosmetic ID to equip
]]
function CosmeticShopController:_handleEquip(cosmeticId: string)
  if not CosmeticController then
    return
  end

  local cosmeticDef = CosmeticConfig.getById(cosmeticId)
  if not cosmeticDef then
    return
  end

  -- Determine the slot field to equip into
  local validFields = CosmeticConfig.SlotEquipFields[cosmeticDef.slot]
  if not validFields or #validFields == 0 then
    return
  end

  local slotField
  if #validFields == 1 then
    -- Single slot (hat, outfit, pet, cutlass_skin, ship_sail/hull/flag)
    slotField = validFields[1]
  else
    -- Multiple slots (emotes: emote_1, emote_2)
    -- Prefer the first empty slot; default to first slot if both occupied
    slotField = validFields[1]
    local equipped = CosmeticController:GetEquippedCosmetics()
    for _, field in validFields do
      if not equipped[field] then
        slotField = field
        break
      end
    end
  end

  CosmeticController:EquipCosmetic(cosmeticId, slotField)
    :andThen(function(success, message)
      if success then
        refreshCatalog()
      else
        warn("[CosmeticShopController] Equip failed:", message or "Unknown error")
      end
    end)
    :catch(function(err)
      warn("[CosmeticShopController] Equip error:", err)
    end)
end

--[[
  Handles an unequip request from the UI.
  @param slotField The EquippedCosmetics field to clear
]]
function CosmeticShopController:_handleUnequip(slotField: string?)
  if not CosmeticController or not slotField then
    return
  end

  CosmeticController:UnequipCosmetic(slotField)
    :andThen(function(success, message)
      if success then
        refreshCatalog()
      else
        warn("[CosmeticShopController] Unequip failed:", message or "Unknown error")
      end
    end)
    :catch(function(err)
      warn("[CosmeticShopController] Unequip error:", err)
    end)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function CosmeticShopController:KnitInit()
  -- Create Fusion scope and state
  FusionScope = Fusion.scoped(Fusion)
  IsVisible = FusionScope:Value(false)
  Treasury = FusionScope:Value(0)
  CatalogData = FusionScope:Value({})

  -- Create the ScreenGui
  ShopScreenGui = Instance.new("ScreenGui")
  ShopScreenGui.Name = "CosmeticShopGui"
  ShopScreenGui.DisplayOrder = 51 -- Above gear shop (50), below critical alerts
  ShopScreenGui.ResetOnSpawn = false
  ShopScreenGui.IgnoreGuiInset = true
  ShopScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[CosmeticShopController] Initialized")
end

function CosmeticShopController:KnitStart()
  CosmeticController = Knit.GetController("CosmeticController")
  SoundController = Knit.GetController("SoundController")
  DataService = Knit.GetService("DataService")
  CosmeticService = Knit.GetService("CosmeticService")

  -- Listen for cosmetic changes to refresh the panel
  CosmeticController.CosmeticChanged:Connect(function(_cosmeticId, _slotField, _action)
    if IsVisible and Fusion.peek(IsVisible) then
      -- Refresh catalog when cosmetic state changes while shop is open
      refreshTreasury()
      refreshCatalog()
    end
  end)

  -- Listen for treasury changes via DataService
  DataService.DataChanged:Connect(function(key: string, value: any)
    if key == "treasury" and type(value) == "number" then
      if Treasury then
        Treasury:set(value)
      end
    end
  end)

  -- Keybind: J to toggle shop
  UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
      return
    end
    if input.KeyCode == SHOP_KEY then
      self:Toggle()
    end
  end)

  -- Load initial treasury
  DataService:GetData()
    :andThen(function(data)
      if data and data.treasury and Treasury then
        Treasury:set(data.treasury)
      end
    end)
    :catch(function(err)
      warn("[CosmeticShopController] Failed to load initial data:", err)
    end)

  print("[CosmeticShopController] Started — press J to open cosmetic shop")
end

return CosmeticShopController
