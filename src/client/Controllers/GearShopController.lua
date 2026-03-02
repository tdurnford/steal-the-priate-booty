--[[
  GearShopController.lua
  Client-side Knit controller that manages the gear shop UI panel.

  Handles:
    - Opening/closing the shop (keybind "G" or future proximity trigger)
    - Fetching gear catalog from GearService
    - Getting treasury balance for affordability checks
    - Routing purchase/equip requests through GearController
    - Rebuilding the panel when gear state changes

  The shop is a modal panel — opening it closes other modals,
  and the player cannot attack while the shop is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local GearShopPanel = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("GearShopPanel"))

local GearShopController = Knit.CreateController({
  Name = "GearShopController",
})

-- References (set in KnitStart)
local GearController = nil
local DataService = nil
local GearService = nil
local SoundController = nil

-- State
local FusionScope = nil
local IsVisible = nil -- Fusion.Value<boolean>
local Treasury = nil -- Fusion.Value<number>
local CatalogData = nil -- Fusion.Value<table>
local ShopScreenGui = nil
local ShopPanel = nil
local LocalPlayer = Players.LocalPlayer
local IsLoading = false

-- Toggle key
local SHOP_KEY = Enum.KeyCode.G

--------------------------------------------------------------------------------
-- SHOP PANEL MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Destroys the current shop panel and rebuilds it with fresh catalog data.
  Called when the catalog changes (purchase, equip, etc.).
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
  if not catalogEntries or #catalogEntries == 0 then
    return
  end

  ShopPanel = GearShopPanel.create(
    FusionScope,
    IsVisible,
    CatalogData,
    Treasury,
    function(gearId: string, action: string)
      -- Handle buy/equip actions
      if action == "buy" then
        GearShopController:_handlePurchase(gearId)
      elseif action == "equip" then
        GearShopController:_handleEquip(gearId)
      end
    end,
    function()
      -- Close button
      GearShopController:Close()
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
  if not GearService or IsLoading then
    return
  end

  IsLoading = true

  GearService:GetGearCatalog()
    :andThen(function(catalog)
      if CatalogData then
        CatalogData:set(catalog)
      end
      rebuildPanel()
    end)
    :catch(function(err)
      warn("[GearShopController] Failed to fetch gear catalog:", err)
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
      warn("[GearShopController] Failed to fetch treasury:", err)
    end)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Opens the gear shop panel. Fetches fresh data from the server.
]]
function GearShopController:Open()
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
  Closes the gear shop panel.
]]
function GearShopController:Close()
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
  Toggles the gear shop open/closed.
]]
function GearShopController:Toggle()
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
function GearShopController:IsOpen(): boolean
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
  @param gearId The gear ID to purchase
]]
function GearShopController:_handlePurchase(gearId: string)
  if not GearController then
    return
  end

  GearController:PurchaseGear(gearId)
    :andThen(function(success, message)
      if success then
        -- Refresh both treasury and catalog after successful purchase
        refreshTreasury()
        refreshCatalog()
      else
        if SoundController then
          SoundController:PlayPurchaseFailSound()
        end
        warn("[GearShopController] Purchase failed:", message or "Unknown error")
      end
    end)
    :catch(function(err)
      if SoundController then
        SoundController:PlayPurchaseFailSound()
      end
      warn("[GearShopController] Purchase error:", err)
    end)
end

--[[
  Handles an equip request from the UI.
  @param gearId The gear ID to equip
]]
function GearShopController:_handleEquip(gearId: string)
  if not GearController then
    return
  end

  GearController:EquipGear(gearId)
    :andThen(function(success, message)
      if success then
        refreshCatalog()
      else
        warn("[GearShopController] Equip failed:", message or "Unknown error")
      end
    end)
    :catch(function(err)
      warn("[GearShopController] Equip error:", err)
    end)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function GearShopController:KnitInit()
  -- Create Fusion scope and state
  FusionScope = Fusion.scoped(Fusion)
  IsVisible = FusionScope:Value(false)
  Treasury = FusionScope:Value(0)
  CatalogData = FusionScope:Value({})

  -- Create the ScreenGui
  ShopScreenGui = Instance.new("ScreenGui")
  ShopScreenGui.Name = "GearShopGui"
  ShopScreenGui.DisplayOrder = 50 -- Above HUD, below critical alerts
  ShopScreenGui.ResetOnSpawn = false
  ShopScreenGui.IgnoreGuiInset = true
  ShopScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[GearShopController] Initialized")
end

function GearShopController:KnitStart()
  GearController = Knit.GetController("GearController")
  SoundController = Knit.GetController("SoundController")
  DataService = Knit.GetService("DataService")
  GearService = Knit.GetService("GearService")

  -- Listen for gear changes to refresh the panel
  GearController.GearChanged:Connect(function(_gearId: string, _action: string)
    if IsVisible and Fusion.peek(IsVisible) then
      -- Refresh catalog when gear state changes while shop is open
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

  -- Keybind: G to toggle shop
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
      warn("[GearShopController] Failed to load initial data:", err)
    end)

  print("[GearShopController] Started — press G to open gear shop")
end

return GearShopController
