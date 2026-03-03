--[[
  CosmeticVisualService.lua
  Server-authoritative cosmetic visual application.

  Handles:
    - Applying/removing hat, outfit, cutlass skin, and pet visuals on player characters
    - Applying/removing sail, hull, and flag visuals on player ships
    - Re-applying character cosmetics on respawn (CharacterAdded)
    - Re-applying ship cosmetics when ship tier changes (model recreated)
    - Loading initial cosmetics when player data is ready
    - Cleanup on player disconnect

  All visuals are server-created instances parented to character/ship models,
  so they auto-replicate to all clients via standard Roblox replication.
  No client controller is needed.

  Uses placeholder Part-based visuals until MODEL assets exist.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local CosmeticConfig = require(Shared:WaitForChild("CosmeticConfig"))

local CosmeticVisualService = Knit.CreateService({
  Name = "CosmeticVisualService",
  Client = {},
})

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil
local CosmeticService = nil
local ShipService = nil

-- Per-player pet Heartbeat connections
local PetConnections: { [Player]: RBXScriptConnection } = {}

--------------------------------------------------------------------------------
-- PLACEHOLDER VISUAL DATA
--------------------------------------------------------------------------------

local HAT_VISUALS = {
  hat_sailors_bandana = {
    size = Vector3.new(1.2, 0.15, 1.2),
    color = Color3.fromRGB(180, 40, 40),
    material = Enum.Material.Fabric,
    offset = CFrame.new(0, 0.7, 0),
  },
  hat_tricorn = {
    size = Vector3.new(1.8, 0.3, 1.6),
    color = Color3.fromRGB(50, 35, 20),
    material = Enum.Material.SmoothPlastic,
    offset = CFrame.new(0, 0.75, 0),
  },
  hat_captains_plume = {
    size = Vector3.new(2.0, 0.4, 1.8),
    color = Color3.fromRGB(40, 25, 60),
    material = Enum.Material.SmoothPlastic,
    offset = CFrame.new(0, 0.8, 0),
    glow = { color = Color3.fromRGB(255, 215, 0), brightness = 0.5, range = 6 },
  },
}

local OUTFIT_COLORS = {
  outfit_deckhand_garb = {
    torso = Color3.fromRGB(139, 90, 43),
    limbs = Color3.fromRGB(180, 130, 80),
  },
  outfit_buccaneer_coat = {
    torso = Color3.fromRGB(45, 30, 20),
    limbs = Color3.fromRGB(70, 50, 35),
  },
  outfit_admirals_regalia = {
    torso = Color3.fromRGB(25, 25, 80),
    limbs = Color3.fromRGB(35, 35, 100),
    glow = { color = Color3.fromRGB(255, 215, 0), brightness = 0.3, range = 4 },
  },
}

local CUTLASS_SKIN_VISUALS = {
  skin_barnacle_blade = {
    color = Color3.fromRGB(50, 100, 80),
    material = Enum.Material.Slate,
  },
  skin_crimson_cutlass = {
    color = Color3.fromRGB(150, 20, 20),
    material = Enum.Material.Metal,
    glow = { color = Color3.fromRGB(200, 30, 30), brightness = 0.4, range = 4 },
  },
  skin_golden_saber = {
    color = Color3.fromRGB(255, 200, 50),
    material = Enum.Material.Metal,
    glow = { color = Color3.fromRGB(255, 215, 0), brightness = 1, range = 8 },
  },
}

local PET_VISUALS = {
  pet_parrot = {
    size = Vector3.new(0.6, 0.5, 0.8),
    color = Color3.fromRGB(200, 50, 30),
    material = Enum.Material.SmoothPlastic,
    offset = Vector3.new(1.2, 1.8, 0), -- Right shoulder
  },
  pet_monkey = {
    size = Vector3.new(0.7, 0.7, 0.6),
    color = Color3.fromRGB(120, 80, 40),
    material = Enum.Material.SmoothPlastic,
    offset = Vector3.new(-1.0, 0.5, -0.8), -- Behind left side
  },
  pet_ghost_crab = {
    size = Vector3.new(0.6, 0.3, 0.8),
    color = Color3.fromRGB(150, 200, 255),
    material = Enum.Material.Neon,
    offset = Vector3.new(1.0, 0.2, 0.5), -- Near feet, right side
    glow = { color = Color3.fromRGB(150, 200, 255), brightness = 0.5, range = 5 },
  },
}

local SAIL_VISUALS = {
  sail_tattered = {
    color = Color3.fromRGB(160, 150, 130),
    material = Enum.Material.Fabric,
    transparency = 0.15,
  },
  sail_crimson = {
    color = Color3.fromRGB(160, 20, 20),
    material = Enum.Material.Fabric,
    transparency = 0,
  },
  sail_phantom = {
    color = Color3.fromRGB(150, 200, 255),
    material = Enum.Material.Neon,
    transparency = 0.4,
    glow = { color = Color3.fromRGB(150, 200, 255), brightness = 0.8, range = 15 },
  },
}

local HULL_VISUALS = {
  hull_driftwood = {
    color = Color3.fromRGB(110, 80, 50),
    material = Enum.Material.Wood,
  },
  hull_ironclad = {
    color = Color3.fromRGB(60, 60, 70),
    material = Enum.Material.DiamondPlate,
  },
  hull_gilded = {
    color = Color3.fromRGB(255, 200, 50),
    material = Enum.Material.Metal,
    glow = { color = Color3.fromRGB(255, 215, 0), brightness = 0.6, range = 12 },
  },
}

local FLAG_VISUALS = {
  flag_jolly_roger = {
    color = Color3.fromRGB(20, 20, 20),
    material = Enum.Material.Fabric,
  },
  flag_blood = {
    color = Color3.fromRGB(140, 15, 15),
    material = Enum.Material.Fabric,
  },
  flag_phantom_standard = {
    color = Color3.fromRGB(130, 180, 230),
    material = Enum.Material.Neon,
    glow = { color = Color3.fromRGB(130, 180, 230), brightness = 0.5, range = 8 },
  },
}

--------------------------------------------------------------------------------
-- CHARACTER COSMETICS: HAT
--------------------------------------------------------------------------------

local COSMETIC_HAT_TAG = "CosmeticHat"

--[[
  Removes any existing cosmetic hat from the character.
  @param character The player's character model
]]
local function removeHat(character: Model)
  for _, child in character:GetChildren() do
    if child.Name == COSMETIC_HAT_TAG then
      child:Destroy()
    end
  end
end

--[[
  Applies a cosmetic hat to the character.
  @param character The player's character model
  @param cosmeticId The hat cosmetic ID
]]
local function applyHat(character: Model, cosmeticId: string)
  removeHat(character)

  local visual = HAT_VISUALS[cosmeticId]
  if not visual then
    return
  end

  local head = character:FindFirstChild("Head")
  if not head or not head:IsA("BasePart") then
    return
  end

  local hat = Instance.new("Part")
  hat.Name = COSMETIC_HAT_TAG
  hat.Size = visual.size
  hat.Color = visual.color
  hat.Material = visual.material
  hat.CanCollide = false
  hat.CanQuery = false
  hat.CanTouch = false
  hat.Massless = true
  hat.CastShadow = true

  local weld = Instance.new("Weld")
  weld.Part0 = head
  weld.Part1 = hat
  weld.C0 = visual.offset
  weld.Parent = hat

  if visual.glow then
    local light = Instance.new("PointLight")
    light.Color = visual.glow.color
    light.Brightness = visual.glow.brightness
    light.Range = visual.glow.range
    light.Parent = hat
  end

  hat.Parent = character
end

--------------------------------------------------------------------------------
-- CHARACTER COSMETICS: OUTFIT
--------------------------------------------------------------------------------

local COSMETIC_OUTFIT_TAG = "CosmeticOutfit"

--[[
  Removes cosmetic outfit coloring from the character, restoring defaults.
  @param character The player's character model
]]
local function removeOutfit(character: Model)
  -- Remove marker and glow
  local marker = character:FindFirstChild(COSMETIC_OUTFIT_TAG)
  if marker then
    marker:Destroy()
  end

  -- Restore default body colors
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if not humanoid then
    return
  end

  local bodyColors = character:FindFirstChildOfClass("BodyColors")
  if bodyColors then
    -- Reset to Roblox default character colors
    local default = BrickColor.new("Bright yellow")
    bodyColors.TorsoColor = default
    bodyColors.LeftArmColor = default
    bodyColors.RightArmColor = default
    bodyColors.LeftLegColor = default
    bodyColors.RightLegColor = default
  end

  -- Remove outfit glow
  local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
  if torso then
    local glow = torso:FindFirstChild("OutfitGlow")
    if glow then
      glow:Destroy()
    end
  end
end

--[[
  Applies cosmetic outfit coloring to the character.
  @param character The player's character model
  @param cosmeticId The outfit cosmetic ID
]]
local function applyOutfit(character: Model, cosmeticId: string)
  removeOutfit(character)

  local visual = OUTFIT_COLORS[cosmeticId]
  if not visual then
    return
  end

  local bodyColors = character:FindFirstChildOfClass("BodyColors")
  if not bodyColors then
    bodyColors = Instance.new("BodyColors")
    bodyColors.Parent = character
  end

  bodyColors.TorsoColor = BrickColor.new(visual.torso)
  bodyColors.LeftArmColor = BrickColor.new(visual.limbs)
  bodyColors.RightArmColor = BrickColor.new(visual.limbs)
  bodyColors.LeftLegColor = BrickColor.new(visual.limbs)
  bodyColors.RightLegColor = BrickColor.new(visual.limbs)

  -- Add marker so we know an outfit is applied
  local marker = Instance.new("BoolValue")
  marker.Name = COSMETIC_OUTFIT_TAG
  marker.Value = true
  marker.Parent = character

  -- Optional glow for premium outfits
  if visual.glow then
    local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    if torso then
      local light = Instance.new("PointLight")
      light.Name = "OutfitGlow"
      light.Color = visual.glow.color
      light.Brightness = visual.glow.brightness
      light.Range = visual.glow.range
      light.Parent = torso
    end
  end
end

--------------------------------------------------------------------------------
-- CHARACTER COSMETICS: CUTLASS SKIN
--------------------------------------------------------------------------------

--[[
  Applies a cutlass skin to the player's equipped gear tool handle.
  @param character The player's character model
  @param cosmeticId The cutlass skin cosmetic ID
]]
local function applyCutlassSkin(character: Model, cosmeticId: string)
  local visual = CUTLASS_SKIN_VISUALS[cosmeticId]
  if not visual then
    return
  end

  -- Find the Cutlass tool on the character or in backpack
  local tool = nil
  for _, child in character:GetChildren() do
    if child:IsA("Tool") and child.Name == "Cutlass" then
      tool = child
      break
    end
  end

  if not tool then
    local player = Players:GetPlayerFromCharacter(character)
    if player then
      local backpack = player:FindFirstChildOfClass("Backpack")
      if backpack then
        for _, child in backpack:GetChildren() do
          if child:IsA("Tool") and child.Name == "Cutlass" then
            tool = child
            break
          end
        end
      end
    end
  end

  if not tool then
    return
  end

  local handle = tool:FindFirstChild("Handle")
  if not handle or not handle:IsA("BasePart") then
    return
  end

  -- Apply skin visuals to the blade handle
  handle.Color = visual.color
  handle.Material = visual.material

  -- Also recolor blade-related child parts for visual consistency
  local BLADE_PARTS = {
    BladeEdge = true,
    BladeCore = true,
    BladeTip = true,
    BladeEdgeGlow = true,
    BladeSpineGlow = true,
  }
  for _, child in tool:GetChildren() do
    if child:IsA("BasePart") and BLADE_PARTS[child.Name] then
      child.Color = visual.color
      child.Material = visual.material
    end
  end

  -- Remove old skin glow, add new one if applicable
  local oldGlow = handle:FindFirstChild("SkinGlow")
  if oldGlow then
    oldGlow:Destroy()
  end

  if visual.glow then
    local light = Instance.new("PointLight")
    light.Name = "SkinGlow"
    light.Color = visual.glow.color
    light.Brightness = visual.glow.brightness
    light.Range = visual.glow.range
    light.Parent = handle
  end
end

--[[
  Removes cutlass skin, restoring the default gear appearance.
  @param character The player's character model
  @param player The player (to look up equipped gear for default visuals)
]]
local function removeCutlassSkin(character: Model, player: Player)
  -- We can't easily restore the original color since GearService created it.
  -- Instead, just remove the skin glow — the gear tool will be recreated
  -- on next respawn or gear change with its default appearance.
  local tool = nil
  for _, child in character:GetChildren() do
    if child:IsA("Tool") and child.Name == "Cutlass" then
      tool = child
      break
    end
  end

  if not tool then
    local backpack = player:FindFirstChildOfClass("Backpack")
    if backpack then
      for _, child in backpack:GetChildren() do
        if child:IsA("Tool") and child.Name == "Cutlass" then
          tool = child
          break
        end
      end
    end
  end

  if not tool then
    return
  end

  local handle = tool:FindFirstChild("Handle")
  if not handle then
    return
  end

  local glow = handle:FindFirstChild("SkinGlow")
  if glow then
    glow:Destroy()
  end
end

--------------------------------------------------------------------------------
-- CHARACTER COSMETICS: PET
--------------------------------------------------------------------------------

local COSMETIC_PET_TAG = "CosmeticPet"

--[[
  Removes the cosmetic pet from the character and disconnects its follow loop.
  @param player The player (for cleanup of Heartbeat connection)
  @param character The player's character model
]]
local function removePet(player: Player, character: Model)
  -- Disconnect Heartbeat follow loop
  local conn = PetConnections[player]
  if conn then
    conn:Disconnect()
    PetConnections[player] = nil
  end

  for _, child in character:GetChildren() do
    if child.Name == COSMETIC_PET_TAG then
      child:Destroy()
    end
  end
end

--[[
  Applies a cosmetic pet that follows the player's character.
  @param player The player
  @param character The player's character model
  @param cosmeticId The pet cosmetic ID
]]
local function applyPet(player: Player, character: Model, cosmeticId: string)
  removePet(player, character)

  local visual = PET_VISUALS[cosmeticId]
  if not visual then
    return
  end

  local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
  if not humanoidRootPart then
    return
  end

  local pet = Instance.new("Part")
  pet.Name = COSMETIC_PET_TAG
  pet.Size = visual.size
  pet.Color = visual.color
  pet.Material = visual.material
  pet.CanCollide = false
  pet.CanQuery = false
  pet.CanTouch = false
  pet.Massless = true
  pet.Anchored = true
  pet.CastShadow = true
  pet.Parent = character

  if visual.glow then
    local light = Instance.new("PointLight")
    light.Color = visual.glow.color
    light.Brightness = visual.glow.brightness
    light.Range = visual.glow.range
    light.Parent = pet
  end

  -- Follow loop: update pet position each frame relative to HumanoidRootPart
  local offset = visual.offset
  local bobPhase = math.random() * math.pi * 2 -- Random start phase for bob

  PetConnections[player] = RunService.Heartbeat:Connect(function()
    if not character.Parent or not humanoidRootPart.Parent then
      removePet(player, character)
      return
    end

    if not pet.Parent then
      return
    end

    -- Bob up and down gently
    local bob = math.sin(os.clock() * 2 + bobPhase) * 0.15
    local targetPos = humanoidRootPart.CFrame * CFrame.new(offset + Vector3.new(0, bob, 0))
    -- Smooth lerp for natural following
    pet.CFrame = pet.CFrame:Lerp(targetPos, 0.15)
  end)
end

--------------------------------------------------------------------------------
-- SHIP COSMETICS: SAIL
--------------------------------------------------------------------------------

local COSMETIC_SAIL_TAG = "CosmeticSail"

--[[
  Removes cosmetic sail from a ship model.
  @param shipModel The ship Model
]]
local function removeSail(shipModel: Model)
  local existing = shipModel:FindFirstChild(COSMETIC_SAIL_TAG)
  if existing then
    existing:Destroy()
  end
end

--[[
  Applies a cosmetic sail to a ship model.
  @param shipModel The ship Model
  @param cosmeticId The sail cosmetic ID
]]
local function applySail(shipModel: Model, cosmeticId: string)
  removeSail(shipModel)

  local visual = SAIL_VISUALS[cosmeticId]
  if not visual then
    return
  end

  local mast = shipModel:FindFirstChild("Mast")
  if not mast or not mast:IsA("BasePart") then
    return -- No mast (rowboat tier), skip
  end

  local hull = shipModel:FindFirstChild("Hull")
  if not hull then
    return
  end

  -- Create sail as a wide thin Part attached to the mast
  local sailWidth = hull.Size.X * 0.8
  local sailHeight = mast.Size.Y * 0.6

  local sail = Instance.new("Part")
  sail.Name = COSMETIC_SAIL_TAG
  sail.Size = Vector3.new(sailWidth, sailHeight, 0.15)
  sail.Color = visual.color
  sail.Material = visual.material
  sail.Transparency = visual.transparency or 0
  sail.Anchored = true
  sail.CanCollide = false
  sail.CanQuery = false
  sail.CanTouch = false
  sail.CastShadow = true
  sail.CFrame = mast.CFrame * CFrame.new(0, mast.Size.Y * 0.1, 0)
  sail.Parent = shipModel

  if visual.glow then
    local light = Instance.new("PointLight")
    light.Color = visual.glow.color
    light.Brightness = visual.glow.brightness
    light.Range = visual.glow.range
    light.Parent = sail
  end
end

--------------------------------------------------------------------------------
-- SHIP COSMETICS: HULL
--------------------------------------------------------------------------------

--[[
  Applies cosmetic hull color/material to the ship's Hull part.
  @param shipModel The ship Model
  @param cosmeticId The hull cosmetic ID
]]
local function applyHullCosmetic(shipModel: Model, cosmeticId: string)
  local visual = HULL_VISUALS[cosmeticId]
  if not visual then
    return
  end

  local hull = shipModel:FindFirstChild("Hull")
  if not hull or not hull:IsA("BasePart") then
    return
  end

  hull.Color = visual.color
  hull.Material = visual.material

  -- Remove old cosmetic glow, add new one if applicable
  local oldGlow = hull:FindFirstChild("CosmeticHullGlow")
  if oldGlow then
    oldGlow:Destroy()
  end

  if visual.glow then
    local light = Instance.new("PointLight")
    light.Name = "CosmeticHullGlow"
    light.Color = visual.glow.color
    light.Brightness = visual.glow.brightness
    light.Range = visual.glow.range
    light.Parent = hull
  end
end

--[[
  Removes cosmetic hull modifications. Since the hull part's original
  appearance was set by ShipService and we can't easily restore it,
  this is a best-effort reset. The ship model gets recreated on tier change.
  @param shipModel The ship Model
]]
local function removeHullCosmetic(shipModel: Model)
  local hull = shipModel:FindFirstChild("Hull")
  if not hull then
    return
  end

  local glow = hull:FindFirstChild("CosmeticHullGlow")
  if glow then
    glow:Destroy()
  end
end

--------------------------------------------------------------------------------
-- SHIP COSMETICS: FLAG
--------------------------------------------------------------------------------

local COSMETIC_FLAG_TAG = "CosmeticFlag"

--[[
  Removes cosmetic flag from a ship model.
  @param shipModel The ship Model
]]
local function removeFlag(shipModel: Model)
  local existing = shipModel:FindFirstChild(COSMETIC_FLAG_TAG)
  if existing then
    existing:Destroy()
  end
end

--[[
  Applies a cosmetic flag to a ship model.
  @param shipModel The ship Model
  @param cosmeticId The flag cosmetic ID
]]
local function applyFlag(shipModel: Model, cosmeticId: string)
  removeFlag(shipModel)

  local visual = FLAG_VISUALS[cosmeticId]
  if not visual then
    return
  end

  local mast = shipModel:FindFirstChild("Mast")
  if not mast or not mast:IsA("BasePart") then
    return -- No mast (rowboat), skip
  end

  local flag = Instance.new("Part")
  flag.Name = COSMETIC_FLAG_TAG
  flag.Size = Vector3.new(1.5, 1.0, 0.1)
  flag.Color = visual.color
  flag.Material = visual.material
  flag.Anchored = true
  flag.CanCollide = false
  flag.CanQuery = false
  flag.CanTouch = false
  flag.CastShadow = true
  -- Position at top of mast, offset to one side
  flag.CFrame = mast.CFrame * CFrame.new(1.0, mast.Size.Y / 2, 0)
  flag.Parent = shipModel

  if visual.glow then
    local light = Instance.new("PointLight")
    light.Color = visual.glow.color
    light.Brightness = visual.glow.brightness
    light.Range = visual.glow.range
    light.Parent = flag
  end
end

--------------------------------------------------------------------------------
-- COMPOSITE APPLY/REMOVE FUNCTIONS
--------------------------------------------------------------------------------

--[[
  Applies all equipped character cosmetics (hat, outfit, cutlass_skin, pet)
  for a player to their current character.
  @param player The player
]]
local function applyAllCharacterCosmetics(player: Player)
  local character = player.Character
  if not character then
    return
  end

  local data = DataService:GetData(player)
  if not data then
    return
  end

  local equipped = data.equippedCosmetics

  -- Hat
  if equipped.hat then
    applyHat(character, equipped.hat)
  end

  -- Outfit
  if equipped.outfit then
    applyOutfit(character, equipped.outfit)
  end

  -- Cutlass skin (deferred to let GearService create tool first)
  if equipped.cutlass_skin then
    task.defer(function()
      if character.Parent then
        applyCutlassSkin(character, equipped.cutlass_skin)
      end
    end)
  end

  -- Pet
  if equipped.pet then
    applyPet(player, character, equipped.pet)
  end
end

--[[
  Applies all equipped ship cosmetics (sail, hull, flag)
  for a player to their docked ship.
  @param player The player
]]
local function applyAllShipCosmetics(player: Player)
  if not ShipService then
    return
  end

  local entry = ShipService:GetDockedShip(player)
  if not entry or not entry.model or not entry.model.Parent then
    return
  end

  local data = DataService:GetData(player)
  if not data then
    return
  end

  local equipped = data.equippedCosmetics

  if equipped.ship_sail then
    applySail(entry.model, equipped.ship_sail)
  end

  if equipped.ship_hull then
    applyHullCosmetic(entry.model, equipped.ship_hull)
  end

  if equipped.ship_flag then
    applyFlag(entry.model, equipped.ship_flag)
  end
end

--------------------------------------------------------------------------------
-- EVENT HANDLERS
--------------------------------------------------------------------------------

--[[
  Handles a cosmetic being equipped. Applies the visual immediately.
  @param player The player who equipped the cosmetic
  @param cosmeticId The cosmetic ID that was equipped
  @param slotField The EquippedCosmetics field (e.g. "hat", "ship_sail")
]]
local function onCosmeticEquipped(player: Player, cosmeticId: string, slotField: string)
  local cosmeticDef = CosmeticConfig.getById(cosmeticId)
  if not cosmeticDef then
    return
  end

  local character = player.Character

  if slotField == "hat" and character then
    applyHat(character, cosmeticId)
  elseif slotField == "outfit" and character then
    applyOutfit(character, cosmeticId)
  elseif slotField == "cutlass_skin" and character then
    applyCutlassSkin(character, cosmeticId)
  elseif slotField == "pet" and character then
    applyPet(player, character, cosmeticId)
  elseif slotField == "ship_sail" or slotField == "ship_hull" or slotField == "ship_flag" then
    if ShipService then
      local entry = ShipService:GetDockedShip(player)
      if entry and entry.model and entry.model.Parent then
        if slotField == "ship_sail" then
          applySail(entry.model, cosmeticId)
        elseif slotField == "ship_hull" then
          applyHullCosmetic(entry.model, cosmeticId)
        elseif slotField == "ship_flag" then
          applyFlag(entry.model, cosmeticId)
        end
      end
    end
  end
end

--[[
  Handles a cosmetic being unequipped. Removes the visual immediately.
  @param player The player who unequipped the cosmetic
  @param slotField The EquippedCosmetics field that was cleared
]]
local function onCosmeticUnequipped(player: Player, slotField: string)
  local character = player.Character

  if slotField == "hat" and character then
    removeHat(character)
  elseif slotField == "outfit" and character then
    removeOutfit(character)
  elseif slotField == "cutlass_skin" and character then
    removeCutlassSkin(character, player)
  elseif slotField == "pet" and character then
    removePet(player, character)
  elseif slotField == "ship_sail" or slotField == "ship_hull" or slotField == "ship_flag" then
    if ShipService then
      local entry = ShipService:GetDockedShip(player)
      if entry and entry.model and entry.model.Parent then
        if slotField == "ship_sail" then
          removeSail(entry.model)
        elseif slotField == "ship_hull" then
          removeHullCosmetic(entry.model)
        elseif slotField == "ship_flag" then
          removeFlag(entry.model)
        end
      end
    end
  end
end

--[[
  Cleans up all cosmetic visuals and connections for a disconnecting player.
  @param player The disconnecting player
]]
local function cleanupPlayer(player: Player)
  -- Clean up pet Heartbeat connection
  local conn = PetConnections[player]
  if conn then
    conn:Disconnect()
    PetConnections[player] = nil
  end
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function CosmeticVisualService:KnitInit()
  print("[CosmeticVisualService] Initializing...")
end

function CosmeticVisualService:KnitStart()
  DataService = Knit.GetService("DataService")
  CosmeticService = Knit.GetService("CosmeticService")

  local ok, svc = pcall(function()
    return Knit.GetService("ShipService")
  end)
  if ok then
    ShipService = svc
  end

  -- Listen for cosmetic equip/unequip events
  CosmeticService.CosmeticEquipped:Connect(onCosmeticEquipped)
  CosmeticService.CosmeticUnequipped:Connect(onCosmeticUnequipped)

  -- Re-apply character cosmetics on respawn
  local function onCharacterAdded(player: Player)
    -- Defer to let GearService give the tool first
    task.defer(function()
      if player.Parent and DataService:IsDataLoaded(player) then
        applyAllCharacterCosmetics(player)
      end
    end)
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

  -- Apply ship cosmetics when a ship spawns
  if ShipService then
    ShipService.ShipSpawned:Connect(function(entry)
      if entry.owner and entry.owner.Parent then
        task.defer(function()
          applyAllShipCosmetics(entry.owner)
        end)
      end
    end)

    -- Re-apply ship cosmetics when ship tier changes (model is recreated)
    ShipService.ShipTierChanged:Connect(function(entry)
      if entry.owner and entry.owner.Parent then
        task.defer(function()
          applyAllShipCosmetics(entry.owner)
        end)
      end
    end)
  end

  -- Cleanup on disconnect
  Players.PlayerRemoving:Connect(cleanupPlayer)

  -- Apply initial cosmetics for players whose data is already loaded
  for _, player in Players:GetPlayers() do
    if DataService:IsDataLoaded(player) then
      task.defer(function()
        applyAllCharacterCosmetics(player)
        applyAllShipCosmetics(player)
      end)
    end
  end

  print("[CosmeticVisualService] Started")
end

return CosmeticVisualService
