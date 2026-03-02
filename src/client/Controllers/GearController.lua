--[[
  GearController.lua
  Client-side gear management controller.

  Handles:
    - Tracking the local player's equipped gear for other controllers
    - Listening to GearChanged signals for visual/audio feedback
    - Providing API for shop UI (UI-010) and other controllers

  Does NOT render the gear tool on the character — that is handled
  server-side by GearService for proper replication to all clients.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local GearController = Knit.CreateController({
  Name = "GearController",
})

-- Public signal for other controllers (fires on any gear change)
-- Args: (gearId: string, action: string) — "purchased" or "equipped"
GearController.GearChanged = Signal.new()

-- Lazy-loaded references
local GearService = nil
local DataService = nil
local SoundController = nil

-- Local state
local EquippedGear: string? = nil
local OwnedGear: { string } = {}

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the currently equipped gear ID.
  @return string? The gear ID or nil
]]
function GearController:GetEquippedGear(): string?
  return EquippedGear
end

--[[
  Returns the gear definition for the equipped gear.
  @return GearDef? The gear config entry or nil
]]
function GearController:GetEquippedGearDef()
  if not EquippedGear then
    return nil
  end
  return GameConfig.GearById[EquippedGear]
end

--[[
  Checks if the local player owns a gear item.
  @param gearId The gear ID to check
  @return boolean
]]
function GearController:OwnsGear(gearId: string): boolean
  for _, id in OwnedGear do
    if id == gearId then
      return true
    end
  end
  return false
end

--[[
  Requests the server to purchase gear.
  @param gearId The gear ID to purchase
  @return Promise<boolean, string?> success and optional error message
]]
function GearController:PurchaseGear(gearId: string)
  if not GearService then
    return
  end
  return GearService:PurchaseGear(gearId)
end

--[[
  Requests the server to equip gear.
  @param gearId The gear ID to equip
  @return Promise<boolean, string?> success and optional error message
]]
function GearController:EquipGear(gearId: string)
  if not GearService then
    return
  end
  return GearService:EquipGear(gearId)
end

--[[
  Requests the full gear catalog from the server.
  @return Promise<table> Array of catalog entries with ownership/equip info
]]
function GearController:GetGearCatalog()
  if not GearService then
    return
  end
  return GearService:GetGearCatalog()
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function GearController:KnitInit()
  print("[GearController] Initializing...")
end

function GearController:KnitStart()
  GearService = Knit.GetService("GearService")
  DataService = Knit.GetService("DataService")
  SoundController = Knit.GetController("SoundController")

  -- Load initial gear state from player data
  DataService:GetData()
    :andThen(function(data)
      if data then
        EquippedGear = data.equippedGear
        OwnedGear = data.ownedGear or {}
      end
    end)
    :catch(function(err)
      warn("[GearController] Failed to load initial gear state:", err)
    end)

  -- Listen for gear changes from server
  GearService.GearChanged:Connect(function(gearId: string, action: string)
    EquippedGear = gearId

    -- Update owned list if purchased
    if action == "purchased" then
      table.insert(OwnedGear, gearId)
      if SoundController then
        SoundController:PlayPurchaseSound()
      end
    end

    -- Fire local signal for other controllers
    GearController.GearChanged:Fire(gearId, action)
    print(string.format("[GearController] Gear %s: %s", action, gearId))
  end)

  -- Listen for data changes (e.g., from reconnection or other sources)
  DataService.DataChanged:Connect(function(key: string, value: any)
    if key == "equippedGear" and type(value) == "string" then
      EquippedGear = value
    elseif key == "ownedGear" and type(value) == "table" then
      OwnedGear = value
    end
  end)

  print("[GearController] Started")
end

return GearController
