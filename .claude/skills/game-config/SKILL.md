---
name: game-config
description: >
  Guides creation and extension of shared game configuration modules in src/shared/.
  Activate when the user asks to add new game data (items, upgrades, rarities,
  levels, powerups, prestige tiers), create a new config module, modify balancing
  numbers, or needs to understand how configs are structured and consumed by services.
---

# Shared Game Configuration Modules

All game balance data, progression tables, and item definitions live in `src/shared/`.
Config modules are required by both server Services and client Controllers, so they
must contain only pure data and deterministic helper functions -- no server APIs,
no RemoteEvents, no side effects.

## Core Pattern

Every config module follows the same structure:

```lua
--[[ Module header comment explaining purpose ]]

local MyConfig = {}

-- 1. Export types for type safety
export type MyEntry = {
  id: string,
  name: string,
  -- ...fields
}

-- 2. Data tables (the actual config values)
MyConfig.Entries = { ... }

-- 3. Lookup tables for O(1) access (built at require-time)
MyConfig.ByName = {} :: { [string]: MyEntry }
for _, entry in MyConfig.Entries do
  MyConfig.ByName[entry.name] = entry
end

-- 4. Accessor functions
function MyConfig.getByName(name: string): MyEntry?
  return MyConfig.ByName[name]
end

-- 5. Validation/business-logic helpers
function MyConfig.canAfford(cost: number, money: number): boolean
  return money >= cost
end

return MyConfig
```

The reason for this structure: export types let consuming code get autocompletion
and catch mismatches. Lookup tables built at require-time avoid repeated iteration.
Accessor functions provide a stable API so data table structure can change without
breaking callers.

## Existing Config Modules

Read the files in `src/shared/` to see all current configs. Common ones include:

| Module | Purpose |
|--------|---------|
| `RarityConfig.lua` | Rarity tiers, spawn probabilities, sell values |
| `BrainrotData.lua` | Item definitions organized by rarity |
| `UpgradeConfig.lua` | Purchasable upgrades with tiered costs/effects |
| `RebirthConfig.lua` | Prestige system levels, costs, multipliers |
| `TowerLevelConfig.lua` | Level height ranges, unlock costs |
| `PowerupConfig.lua` | Purchasable powerups and boosts |
| `LuckyBlockConfig.lua` | Loot tables with probability distributions |
| `ProductIds.lua` | Auto-generated Developer Product ID mappings (do not edit) |
| `ProductConfig.lua` | Maps product IDs to features for purchase processing |

## How Configs Use Luau Types

Configs define `export type` at the top of the module so that any file requiring
the config gets type information. This matters because Roblox's Luau type checker
validates field access and function arguments at edit time.

```lua
export type RarityDefinition = {
  name: string,
  color: Color3,
  spawnProbability: number,
  displayOrder: number,
  sellValue: number,
  -- ...
}
```

When another module does `local RarityConfig = require(...)`, it can reference
the type, and function return annotations like `: RarityDefinition?` give callers
proper autocompletion.

Use typed annotations on lookup tables too:

```lua
MyConfig.ByLevel = {} :: { [number]: LevelDef }
```

## How Configs Expose Data and Accessors

Configs expose both raw data tables and accessor functions. Raw tables allow
iteration (e.g., building UI lists), while accessors provide safe single-item
lookups with nil handling.

```lua
-- Raw data: services iterate this for validation or UI display
MyConfig.Items = {
  speed = MyConfig.SpeedUpgrade,
  capacity = MyConfig.CapacityUpgrade,
}

-- Ordered list for UI: controls display order separately from data keys
MyConfig.DisplayOrder = { "speed", "capacity" }

-- Accessor: safe lookup returning nil for invalid IDs
function MyConfig.getItem(id: string): ItemDefinition?
  return MyConfig.Items[id]
end

-- Business logic: encapsulates validation rules
function MyConfig.canPurchase(
  itemId: string,
  currentLevel: number,
  playerMoney: number
): (boolean, string?)
  -- ...checks and returns (true, nil) or (false, reason)
end
```

The pattern of returning `(boolean, string?)` for validation functions is used
consistently across configs. Follow this convention for new validation functions.

## Tiered and Leveled Data

Several configs handle progression tiers where data scales with level.

**Array of tier objects** indexed by level (used for upgrades):

```lua
MyConfig.SpeedUpgrade = {
  id = "speed",
  name = "Speed Boost",
  maxLevel = 3,
  tiers = {
    { level = 1, cost = 1000, effect = 1.25, tierName = "Basic" },
    { level = 2, cost = 5000, effect = 1.50, tierName = "Advanced" },
    { level = 3, cost = 25000, effect = 2.00, tierName = "Elite" },
  },
  effectType = "multiplier",  -- "multiplier" | "additive" | "flat"
  baseValue = 16,
}
```

**Sequential array** where index = level (used for prestige/progression):

```lua
MyConfig.ProgressionLevels = {
  { level = 1, cost = 50000, multiplier = 1.25, unlocks = "..." },
  { level = 2, cost = 200000, multiplier = 1.50, unlocks = "..." },
} :: { LevelDef }
```

Both use a companion lookup table for O(1) access by level:

```lua
MyConfig.ByLevel = {} :: { [number]: LevelDef }
for _, levelData in MyConfig.ProgressionLevels do
  MyConfig.ByLevel[levelData.level] = levelData
end
```

**Grouped by category** with flat lookups built at require-time (used for item catalogs):

```lua
MyConfig.ByCategory = {
  Common = { { id = "...", name = "..." }, ... },
  Rare = { { id = "...", name = "..." }, ... },
}

-- Built at require-time:
MyConfig.All = {}       -- flat array of all entries
MyConfig.ByName = {}    -- name -> entry
MyConfig.ById = {}      -- id -> entry

for category, entries in MyConfig.ByCategory do
  for _, entry in entries do
    table.insert(MyConfig.All, entry)
    MyConfig.ByName[entry.name] = entry
    MyConfig.ById[entry.id] = entry
  end
end
```

## Relationship Between Configs and Services

Configs live in `src/shared/` and are consumed by:
- **Server Services** (`src/server/Services/`) for authoritative validation and game logic
- **Client Controllers** (`src/client/Controllers/`) for UI display and predictions

Configs require other configs when there are cross-cutting concerns. Use
`require(script.Parent.ModuleName)` for sibling config requires within `src/shared/`.

When a config needs to reference another config but risks circular dependencies,
use `pcall(require(...))`:

```lua
local ok, OtherConfig = pcall(function()
  return require(script.Parent.OtherConfig)
end)
if ok and OtherConfig then
  -- use OtherConfig
end
```

## Adding a New Entry to an Existing Config

### General pattern

1. Find the relevant data table in the config module
2. Add the entry following the existing `export type` definition
3. If the config has a lookup table built at require-time, the entry is auto-indexed
4. If the config has validation (e.g., probability sums), check invariants

### Adding to a tiered config

When adding a new tier to an existing upgrade:
1. Append to the `tiers` array
2. Update `maxLevel` to match the new tier count
3. Costs should increase with level (check neighboring tiers for progression curve)

### Adding to a categorized config

When adding a new item to a category:
1. Add the entry to the correct category in the grouped table
2. The require-time loop handles `All`, `ByName`, `ById` automatically
3. The id should follow the pattern `{category}_{snake_case_name}`

## Creating a New Config Module From Scratch

Place the file in `src/shared/`. Follow this template:

```lua
--[[
  NewFeatureConfig.lua
  Configuration for [feature description].
]]

local NewFeatureConfig = {}

-- Export types
export type FeatureEntry = {
  id: string,
  name: string,
  cost: number,
}

-- Data tables
NewFeatureConfig.Entries = {
  {
    id = "entry_one",
    name = "Entry One",
    cost = 1000,
  },
} :: { FeatureEntry }

-- Lookup tables (built at require-time)
NewFeatureConfig.ById = {} :: { [string]: FeatureEntry }
for _, entry in NewFeatureConfig.Entries do
  NewFeatureConfig.ById[entry.id] = entry
end

-- Accessor functions
function NewFeatureConfig.getById(id: string): FeatureEntry?
  return NewFeatureConfig.ById[id]
end

-- Validation helpers (return boolean, string? pattern)
function NewFeatureConfig.canUse(id: string, playerMoney: number): (boolean, string?)
  local entry = NewFeatureConfig.ById[id]
  if not entry then
    return false, "Invalid entry"
  end
  if playerMoney < entry.cost then
    return false, "Insufficient funds"
  end
  return true, nil
end

return NewFeatureConfig
```

Key points:
- Name the file `{Feature}Config.lua` in `src/shared/`
- Start with `local X = {}` and end with `return X`
- Define `export type` before data tables
- Build lookup tables at require-time, not inside functions
- Use `:: { Type }` annotations on tables for type checker support
- Follow the `(boolean, string?)` return pattern for validation
- If you need product IDs, require `ProductIds` (do not hardcode IDs)
- If you need cross-config data, require the sibling via `script.Parent`
- Add a `validate()` function when the config has invariants (probability sums, continuity)

## Module Comments and Documentation

Use `--[[ ]]` block comments for the module header and function documentation:

```lua
--[[
  Gets the cost for the next level of an entry.
  @param id The entry ID
  @param currentLevel Current level
  @return Cost in currency, or nil if at max level
]]
function MyConfig.getNextCost(id: string, currentLevel: number): number?
```

Inline comments explain constants and design decisions:

```lua
local BASE_WALK_SPEED = 16 -- studs per second (Roblox default)
```

## ProductIds.lua Is Auto-Generated

`ProductIds.lua` is generated by `scripts/generate-product-ids.sh` from the
Mantle deployment state file. Do not edit it manually. When you need a new
Developer Product, add it to the Mantle configuration and regenerate.

Other configs reference ProductIds like this:

```lua
local ProductIds = require(script.Parent.ProductIds)
productId = ProductIds["my-product-name"],
```
