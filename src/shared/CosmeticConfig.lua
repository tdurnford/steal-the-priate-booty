--[[
  CosmeticConfig.lua
  Configuration for all cosmetic items. Cosmetics are visual-only — no gameplay
  advantage. Purchased permanently with treasury doubloons. Organized into 6
  display categories: Cutlass Skins, Hats, Outfits, Pets, Emotes, Ship
  Customization (sail, hull, flag).
]]

local CosmeticConfig = {}

--------------------------------------------------------------------------------
-- TYPES
--------------------------------------------------------------------------------

-- The equip slot a cosmetic occupies (matches EquippedCosmetics in Types.lua)
export type CosmeticSlot =
  "cutlass_skin"
  | "hat"
  | "outfit"
  | "pet"
  | "emote"
  | "ship_sail"
  | "ship_hull"
  | "ship_flag"

-- Display category shown in the shop UI
export type CosmeticCategory =
  "Cutlass Skins"
  | "Hats"
  | "Outfits"
  | "Pets"
  | "Emotes"
  | "Ship Customization"

export type CosmeticDef = {
  id: string,
  name: string,
  description: string,
  slot: CosmeticSlot,
  category: CosmeticCategory,
  cost: number,
  assetId: string, -- placeholder until MODEL/AUDIO assets exist
  displayOrder: number, -- sort order within category
}

--------------------------------------------------------------------------------
-- COSMETIC ITEMS
--------------------------------------------------------------------------------

CosmeticConfig.Items = {
  -- Cutlass Skins
  {
    id = "skin_barnacle_blade",
    name = "Barnacle Blade",
    description = "A seaweed-wrapped cutlass from the ocean floor.",
    slot = "cutlass_skin",
    category = "Cutlass Skins",
    cost = 500,
    assetId = "rbxassetid://0", -- placeholder
    displayOrder = 1,
  },
  {
    id = "skin_crimson_cutlass",
    name = "Crimson Cutlass",
    description = "A blood-red blade feared across the seven seas.",
    slot = "cutlass_skin",
    category = "Cutlass Skins",
    cost = 2000,
    assetId = "rbxassetid://0",
    displayOrder = 2,
  },
  {
    id = "skin_golden_saber",
    name = "Golden Saber",
    description = "A gold-plated saber fit for a pirate king.",
    slot = "cutlass_skin",
    category = "Cutlass Skins",
    cost = 8000,
    assetId = "rbxassetid://0",
    displayOrder = 3,
  },

  -- Hats
  {
    id = "hat_sailors_bandana",
    name = "Sailor's Bandana",
    description = "A weathered red bandana tied tight.",
    slot = "hat",
    category = "Hats",
    cost = 300,
    assetId = "rbxassetid://0",
    displayOrder = 1,
  },
  {
    id = "hat_tricorn",
    name = "Tricorn Hat",
    description = "The classic three-cornered pirate hat.",
    slot = "hat",
    category = "Hats",
    cost = 1500,
    assetId = "rbxassetid://0",
    displayOrder = 2,
  },
  {
    id = "hat_captains_plume",
    name = "Captain's Plume",
    description = "A grand feathered hat worn by legendary captains.",
    slot = "hat",
    category = "Hats",
    cost = 5000,
    assetId = "rbxassetid://0",
    displayOrder = 3,
  },

  -- Outfits
  {
    id = "outfit_deckhand_garb",
    name = "Deckhand Garb",
    description = "Simple sailor clothes stained with salt and sweat.",
    slot = "outfit",
    category = "Outfits",
    cost = 1000,
    assetId = "rbxassetid://0",
    displayOrder = 1,
  },
  {
    id = "outfit_buccaneer_coat",
    name = "Buccaneer Coat",
    description = "A rugged leather longcoat favored by raiders.",
    slot = "outfit",
    category = "Outfits",
    cost = 4000,
    assetId = "rbxassetid://0",
    displayOrder = 2,
  },
  {
    id = "outfit_admirals_regalia",
    name = "Admiral's Regalia",
    description = "Gold-trimmed naval uniform of imposing authority.",
    slot = "outfit",
    category = "Outfits",
    cost = 15000,
    assetId = "rbxassetid://0",
    displayOrder = 3,
  },

  -- Pets
  {
    id = "pet_parrot",
    name = "Parrot",
    description = "A colorful parrot perched on your shoulder.",
    slot = "pet",
    category = "Pets",
    cost = 2000,
    assetId = "rbxassetid://0",
    displayOrder = 1,
  },
  {
    id = "pet_monkey",
    name = "Monkey",
    description = "A mischievous little monkey that follows you around.",
    slot = "pet",
    category = "Pets",
    cost = 8000,
    assetId = "rbxassetid://0",
    displayOrder = 2,
  },
  {
    id = "pet_ghost_crab",
    name = "Ghost Crab",
    description = "A spectral crab companion from beyond the grave.",
    slot = "pet",
    category = "Pets",
    cost = 25000,
    assetId = "rbxassetid://0",
    displayOrder = 3,
  },

  -- Emotes
  {
    id = "emote_pirate_dance",
    name = "Pirate Dance",
    description = "Do a jolly jig on the spot.",
    slot = "emote",
    category = "Emotes",
    cost = 200,
    assetId = "rbxassetid://0",
    displayOrder = 1,
  },
  {
    id = "emote_laugh_taunt",
    name = "Laugh Taunt",
    description = "Let out a mocking pirate laugh.",
    slot = "emote",
    category = "Emotes",
    cost = 800,
    assetId = "rbxassetid://0",
    displayOrder = 2,
  },
  {
    id = "emote_coin_flip",
    name = "Coin Flip",
    description = "Casually flip a golden doubloon.",
    slot = "emote",
    category = "Emotes",
    cost = 2500,
    assetId = "rbxassetid://0",
    displayOrder = 3,
  },
  {
    id = "emote_telescope_pose",
    name = "Telescope Pose",
    description = "Strike a dramatic lookout pose.",
    slot = "emote",
    category = "Emotes",
    cost = 1500,
    assetId = "rbxassetid://0",
    displayOrder = 4,
  },

  -- Ship Customization — Sails
  {
    id = "sail_tattered",
    name = "Tattered Sails",
    description = "Weathered canvas with a haunted look.",
    slot = "ship_sail",
    category = "Ship Customization",
    cost = 1000,
    assetId = "rbxassetid://0",
    displayOrder = 1,
  },
  {
    id = "sail_crimson",
    name = "Crimson Sails",
    description = "Blood-red sails visible from any shore.",
    slot = "ship_sail",
    category = "Ship Customization",
    cost = 5000,
    assetId = "rbxassetid://0",
    displayOrder = 2,
  },
  {
    id = "sail_phantom",
    name = "Phantom Sails",
    description = "Translucent ghostly sails that shimmer in the wind.",
    slot = "ship_sail",
    category = "Ship Customization",
    cost = 20000,
    assetId = "rbxassetid://0",
    displayOrder = 3,
  },

  -- Ship Customization — Hulls
  {
    id = "hull_driftwood",
    name = "Driftwood Finish",
    description = "Rough aged planks from a sunken vessel.",
    slot = "ship_hull",
    category = "Ship Customization",
    cost = 1500,
    assetId = "rbxassetid://0",
    displayOrder = 4,
  },
  {
    id = "hull_ironclad",
    name = "Ironclad Hull",
    description = "Iron-banded dark timber, built to last.",
    slot = "ship_hull",
    category = "Ship Customization",
    cost = 6000,
    assetId = "rbxassetid://0",
    displayOrder = 5,
  },
  {
    id = "hull_gilded",
    name = "Gilded Hull",
    description = "Gold leaf coating that gleams in the sun.",
    slot = "ship_hull",
    category = "Ship Customization",
    cost = 25000,
    assetId = "rbxassetid://0",
    displayOrder = 6,
  },

  -- Ship Customization — Flags
  {
    id = "flag_jolly_roger",
    name = "Jolly Roger",
    description = "The classic skull and crossbones.",
    slot = "ship_flag",
    category = "Ship Customization",
    cost = 500,
    assetId = "rbxassetid://0",
    displayOrder = 7,
  },
  {
    id = "flag_blood",
    name = "Blood Flag",
    description = "A crimson banner with crossed cutlasses.",
    slot = "ship_flag",
    category = "Ship Customization",
    cost = 2000,
    assetId = "rbxassetid://0",
    displayOrder = 8,
  },
  {
    id = "flag_phantom_standard",
    name = "Phantom Standard",
    description = "A ghostly flag that glows faintly at night.",
    slot = "ship_flag",
    category = "Ship Customization",
    cost = 8000,
    assetId = "rbxassetid://0",
    displayOrder = 9,
  },
} :: { CosmeticDef }

--------------------------------------------------------------------------------
-- DISPLAY CATEGORIES (ordered for shop UI)
--------------------------------------------------------------------------------

CosmeticConfig.Categories = {
  "Cutlass Skins",
  "Hats",
  "Outfits",
  "Pets",
  "Emotes",
  "Ship Customization",
} :: { CosmeticCategory }

-- Maps a CosmeticSlot to its display category
CosmeticConfig.SlotToCategory = {
  cutlass_skin = "Cutlass Skins",
  hat = "Hats",
  outfit = "Outfits",
  pet = "Pets",
  emote = "Emotes",
  ship_sail = "Ship Customization",
  ship_hull = "Ship Customization",
  ship_flag = "Ship Customization",
} :: { [CosmeticSlot]: CosmeticCategory }

-- Maps a CosmeticSlot to the EquippedCosmetics field(s) it occupies.
-- Emotes have two equip slots (emote_1, emote_2); all others have one.
CosmeticConfig.SlotEquipFields = {
  cutlass_skin = { "cutlass_skin" },
  hat = { "hat" },
  outfit = { "outfit" },
  pet = { "pet" },
  emote = { "emote_1", "emote_2" },
  ship_sail = { "ship_sail" },
  ship_hull = { "ship_hull" },
  ship_flag = { "ship_flag" },
} :: { [CosmeticSlot]: { string } }

--------------------------------------------------------------------------------
-- LOOKUP TABLES (built at require-time)
--------------------------------------------------------------------------------

-- O(1) lookup by cosmetic ID
CosmeticConfig.ById = {} :: { [string]: CosmeticDef }
for _, item in CosmeticConfig.Items do
  CosmeticConfig.ById[item.id] = item
end

-- Items grouped by display category (for shop tabs)
CosmeticConfig.ByCategory = {} :: { [CosmeticCategory]: { CosmeticDef } }
for _, cat in CosmeticConfig.Categories do
  CosmeticConfig.ByCategory[cat] = {}
end
for _, item in CosmeticConfig.Items do
  table.insert(CosmeticConfig.ByCategory[item.category], item)
end

-- Items grouped by equip slot
CosmeticConfig.BySlot = {} :: { [CosmeticSlot]: { CosmeticDef } }
for _, item in CosmeticConfig.Items do
  if not CosmeticConfig.BySlot[item.slot] then
    CosmeticConfig.BySlot[item.slot] = {}
  end
  table.insert(CosmeticConfig.BySlot[item.slot], item)
end

--------------------------------------------------------------------------------
-- ACCESSOR FUNCTIONS
--------------------------------------------------------------------------------

--[[
  Gets a cosmetic definition by its ID.
  @param id Cosmetic ID (e.g. "hat_tricorn", "skin_golden_saber")
  @return CosmeticDef or nil if not found
]]
function CosmeticConfig.getById(id: string): CosmeticDef?
  return CosmeticConfig.ById[id]
end

--[[
  Gets all cosmetics in a display category, sorted by displayOrder.
  @param category Display category name
  @return Array of CosmeticDef (empty if category invalid)
]]
function CosmeticConfig.getByCategory(category: CosmeticCategory): { CosmeticDef }
  return CosmeticConfig.ByCategory[category] or {}
end

--[[
  Gets all cosmetics for a given equip slot.
  @param slot The equip slot
  @return Array of CosmeticDef (empty if slot invalid)
]]
function CosmeticConfig.getBySlot(slot: CosmeticSlot): { CosmeticDef }
  return CosmeticConfig.BySlot[slot] or {}
end

--[[
  Checks if a player can purchase a cosmetic.
  @param cosmeticId The cosmetic ID to purchase
  @param treasury Player's current treasury balance
  @param ownedCosmetics Array of cosmetic IDs the player owns
  @return (boolean, string?) — success and optional failure reason
]]
function CosmeticConfig.canPurchase(
  cosmeticId: string,
  treasury: number,
  ownedCosmetics: { string }
): (boolean, string?)
  local cosmetic = CosmeticConfig.ById[cosmeticId]
  if not cosmetic then
    return false, "Invalid cosmetic"
  end

  -- Check if already owned
  for _, ownedId in ownedCosmetics do
    if ownedId == cosmeticId then
      return false, "Already owned"
    end
  end

  if treasury < cosmetic.cost then
    return false, "Insufficient treasury"
  end

  return true, nil
end

--[[
  Checks if a cosmetic can be equipped to a given slot field.
  @param cosmeticId The cosmetic ID to equip
  @param slotField The EquippedCosmetics field (e.g. "hat", "emote_1", "ship_sail")
  @param ownedCosmetics Array of cosmetic IDs the player owns
  @return (boolean, string?) — success and optional failure reason
]]
function CosmeticConfig.canEquip(
  cosmeticId: string,
  slotField: string,
  ownedCosmetics: { string }
): (boolean, string?)
  local cosmetic = CosmeticConfig.ById[cosmeticId]
  if not cosmetic then
    return false, "Invalid cosmetic"
  end

  -- Check ownership
  local owned = false
  for _, ownedId in ownedCosmetics do
    if ownedId == cosmeticId then
      owned = true
      break
    end
  end
  if not owned then
    return false, "Not owned"
  end

  -- Check slot compatibility: the slotField must be in the cosmetic's valid equip fields
  local validFields = CosmeticConfig.SlotEquipFields[cosmetic.slot]
  if not validFields then
    return false, "Invalid slot"
  end
  local fieldValid = false
  for _, field in validFields do
    if field == slotField then
      fieldValid = true
      break
    end
  end
  if not fieldValid then
    return false, "Wrong slot"
  end

  return true, nil
end

return CosmeticConfig
