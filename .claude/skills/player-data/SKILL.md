---
name: player-data
description: >
  Guide for working with the player data persistence system (ProfileService, Types, DataService).
  Activate when adding new player data fields, modifying saved data, reading/writing player state,
  creating new data-driven features, or debugging data migration issues. Also relevant for
  understanding how inventory, currency, upgrades, and settings are stored and synced.
---

# Player Data System

This project persists player data using **ProfileService** (a Roblox DataStore wrapper) integrated through a central **DataService** Knit service. The data schema is defined in `src/shared/Types.lua`, and all reads/writes flow through `src/server/Services/DataService.lua`.

## Architecture Overview

```
Types.lua (schema + defaults + deepCopy migration)
    |
    v
DataService.lua (server Knit service)
    |
    +--> ProfileService (Roblox DataStore wrapper, wally dependency)
    |      key format: "Player_{UserId}"
    |      store name: "PlayerData_v1"
    |
    +--> Client signals (DataChanged, DataLoaded, MoneyGained, etc.)
    +--> Server signals (PlayerDataLoaded, AccumulationUpdated)
```

## The PlayerData Type

Defined in `src/shared/Types.lua`. Every field persisted for a player lives in the `PlayerData` export type. Read the current definition there for the full list of fields.

The type uses Luau `export type` so any module that requires Types gets autocomplete and type checking.

## DEFAULT_PLAYER_DATA

Also in `src/shared/Types.lua`. This is the template ProfileService uses for new players and for its `Reconcile()` call (which fills in missing fields from the template).

Read the current defaults in Types.lua to understand what new players start with.

## How to Add a New Data Field

Follow these three steps in order. Missing any step will cause data loss or crashes for existing players.

### Step 1: Add to the type definition

In `src/shared/Types.lua`, add the field to the `PlayerData` type:

```lua
export type PlayerData = {
  -- ... existing fields ...
  myNewField: number,  -- Description of what it tracks
}
```

### Step 2: Add to DEFAULT_PLAYER_DATA

In the same file, add a sensible default:

```lua
Types.DEFAULT_PLAYER_DATA = {
  -- ... existing fields ...
  myNewField = 0,  -- Default for new players
}
```

ProfileService's `Reconcile()` uses this template to fill in missing keys on existing profiles. Existing players who load their data will automatically get the default value.

### Step 3: Add migration logic in deepCopyPlayerData

In `Types.deepCopyPlayerData()`, add a migration line that handles existing saves where the field does not exist:

```lua
-- Migration for myNewField (existing players get 0)
local sourceMyNewField = data.myNewField or 0
```

Then include it in the copy table:

```lua
local copy: PlayerData = {
  -- ... existing fields ...
  myNewField = sourceMyNewField,
}
```

The `or` fallback is the critical piece: it ensures that profiles saved before this field existed will not break when deep-copied.

**Why deepCopy needs migration separately from Reconcile:** `deepCopyPlayerData` is called on raw profile data before clients receive it. If a field is nil in the saved data and you access it without the `or` fallback, the copy will have nil for that field, which can cause downstream errors. Reconcile fills in missing top-level keys, but deepCopy must also handle it because the copy is constructed field-by-field.

For dictionary fields, also add a copy loop:

```lua
local sourceMyDict = data.myDict or {}
-- ... in the copy table:
myDict = {},
-- ... after the copy table:
for key, value in sourceMyDict do
  copy.myDict[key] = value
end
```

## Factory Functions

Types.lua contains factory functions for creating complex nested data structures (e.g., `Types.createBrainrot`). These look up shared config data and set sensible defaults. Check Types.lua for the current factory functions available.

When adding a new entity type that gets stored in PlayerData, create a factory function following the same pattern:

```lua
function Types.createMyEntity(id: string, typeId: string?): MyEntity
  local config = MyConfig.getById(typeId)
  return {
    id = id,
    typeId = typeId or "unknown",
    name = if config then config.name else "Unknown",
    -- ... other fields with defaults
  }
end
```

## deepCopyPlayerData and Migration

`Types.deepCopyPlayerData(data)` does two things:

1. **Creates a safe deep copy** of the profile data (so mutations don't affect the original reference stored in ProfileService)
2. **Migrates legacy data** from older schema versions

Read the function in Types.lua to see all current migrations. The pattern is consistent: use `or` fallbacks for missing fields, clamp/transform fields that changed format, and copy nested tables with explicit loops.

## DataService Overview

`src/server/Services/DataService.lua` is the Knit service that owns all profile loading, saving, and data manipulation.

### Profile Loading Flow

1. `PlayerAdded` triggers `_loadProfile(player)`
2. `ProfileStore:LoadProfileAsync(key, "ForceLoad")` loads the profile
3. `profile:Reconcile()` fills in missing fields from `DEFAULT_PLAYER_DATA`
4. Stores profile in `Profiles[player]` cache
5. Fires `Client.DataLoaded` with a deep copy, and `PlayerDataLoaded` (server signal) with the raw data

### Profile Release Flow

On `PlayerRemoving`:
1. Updates `lastPlayedAt` to current timestamp
2. Calls `profile:Release()` and removes from cache

### Reading Data

From **server** code:

```lua
local DataService = Knit.GetService("DataService")

-- Get the full PlayerData table (direct reference to profile.Data)
local data = DataService:GetData(player)

-- Get the raw profile object (needed for direct mutations)
local profile = DataService:GetProfile(player)

-- Check if data is loaded
if DataService:IsDataLoaded(player) then ... end
```

From **client** code:

```lua
local DataService = Knit.GetService("DataService")

-- Gets a deep copy (safe for client, no direct mutation)
local data = DataService:GetData()
```

### Modifying Data

Modify data through DataService methods, not by directly writing to `profile.Data`. The methods handle:
- Validation (sufficient funds, valid types, valid indices)
- Leaderboard sync (updating `leaderstats` folder on the Player instance)
- Signal firing (`DataChanged`, `MoneyGained`, etc.)
- Lifetime stat tracking

Read DataService.lua for the full list of available mutation methods. The pattern is consistent:

```lua
function DataService:UpdateSomething(player: Player, ...)
  local data = self:GetData(player)
  if not data then return false end

  -- Validate
  -- Mutate
  -- Fire signals
  self.Client.DataChanged:Fire(player, "fieldName", newValue)
  return true
end
```

When you need to modify a field that has no dedicated method, access the profile directly and fire `DataChanged`:

```lua
local profile = DataService:GetProfile(player)
if not profile then return end

profile.Data.myNewField = newValue
DataService.Client.DataChanged:Fire(player, "myNewField", newValue)
```

Only do this for simple assignments. For anything involving validation, currency, or cross-field consistency, add a proper method to DataService.

### Signals

**Client signals** (DataService.Client — fire to the specific player's client):

| Signal | Payload | Purpose |
|--------|---------|---------|
| `DataLoaded` | `PlayerData` (deep copy) | Initial data ready |
| `DataChanged` | `key, value` | Any data field changed |
| `MoneyGained` | `amount` | Money added (for UI popup) |

Check DataService.lua for additional client signals — more are added as features grow.

**Server signals** (on the DataService module, for other services):

| Signal | Payload | Purpose |
|--------|---------|---------|
| `PlayerDataLoaded` | `player, data` | Profile ready (server-side) |
| `AccumulationUpdated` | `player, totalAccumulated` | Periodic income accumulated |

Listen to server signals like this:

```lua
function MyService:KnitStart()
  local DataService = Knit.GetService("DataService")
  DataService.PlayerDataLoaded:Connect(function(player, data)
    -- React to player data being ready
  end)
end
```

### DataChanged Signal Convention

`DataChanged` fires with a key string and a value. The key indicates what changed. Read the DataService source to see all current keys — each mutation method documents what key it fires.

Common pattern for consuming on the client:

```lua
DataService.DataChanged:Connect(function(key, value)
  if key == "money" then
    updateMoneyDisplay(value)
  elseif key == "upgrades" then
    refreshUpgradeUI(value)
  end
end)
```

## Common Patterns

### Accessing data from another service

```lua
local DataService = nil

function MyService:KnitStart()
  DataService = Knit.GetService("DataService")
end

function MyService:DoSomething(player)
  local data = DataService:GetData(player)
  if not data then return end  -- Data not loaded yet
  -- Read from data...
end
```

### Waiting for player data on the client

```lua
local DataService = Knit.GetService("DataService")

DataService.DataLoaded:Connect(function(playerData)
  -- playerData is a deep copy of the full PlayerData
  initializeUI(playerData)
end)

DataService.DataChanged:Connect(function(key, value)
  -- Reactive updates when specific fields change
  if key == "money" then
    updateMoneyDisplay(value)
  end
end)
```

## Key Files Reference

| File | Purpose |
|------|---------|
| `src/shared/Types.lua` | Type definitions, DEFAULT_PLAYER_DATA, factory functions, deepCopyPlayerData |
| `src/server/Services/DataService.lua` | All data persistence, profile loading, mutation methods, signals |
| `src/shared/RarityConfig.lua` | Income rates, sell values, accumulation calculation |
| `wally.toml` | ProfileService dependency (`thunn/profileservice@3.2.1`) |
