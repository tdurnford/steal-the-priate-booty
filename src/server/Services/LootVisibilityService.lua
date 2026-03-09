--[[
  LootVisibilityService.lua
  Server-authoritative player loot visibility system (LOOT-006).

  Attaches visual indicators to player characters based on held doubloons:
    - 0-49: no indicator
    - 50-199: small coin purse (brown, belt area)
    - 200-499: medium purse with gold shimmer (PointLight + particles)
    - 500+: large overflowing purse with gold particle trail and coin jingle 3D sound

  Night glow: players carrying 200+ doubloons emit a faint gold glow at night
  (visible through fog), applied/removed on phase transitions.

  All visuals are server-created Parts/Accessories, automatically replicated to
  all clients. The client controller handles tier change notifications and SFX.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local ServerScriptService = game:GetService("ServerScriptService")
local Server = ServerScriptService:WaitForChild("Server")
local DoubloonModels = require(Server:WaitForChild("DoubloonModels"))

local LootVisibilityService = Knit.CreateService({
  Name = "LootVisibilityService",
  Client = {
    -- Fired to a specific player when their loot visibility tier changes.
    -- Args: (newTier: string, oldTier: string, doubloons: number)
    TierChanged = Knit.CreateSignal(),
  },
})

-- Server-side signal: (player, newTier, oldTier)
LootVisibilityService.TierChanged = Signal.new()

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DayNightService = nil

-- Per-player state
local PlayerTier: { [Player]: string } = {}
local PlayerConnections: { [Player]: { RBXScriptConnection } } = {}

-- Tag names for finding our created instances
local PURSE_TAG = "LootVisibility_Purse"
local TRAIL_TAG = "LootVisibility_Trail"
local JINGLE_TAG = "LootVisibility_Jingle"
local NIGHT_GLOW_TAG = "LootVisibility_NightGlow"

-- Coin jingle asset (looping 3D sound with rolloff)
local COIN_JINGLE_ID = "rbxassetid://4612373815"

--------------------------------------------------------------------------------
-- COIN PURSE VISUAL DEFINITIONS
--------------------------------------------------------------------------------

-- Purse visual properties per tier
local PURSE_DEFS = {
  small = {
    size = Vector3.new(0.6, 0.6, 0.6),
    color = Color3.fromRGB(139, 90, 43), -- brown leather
    lightBrightness = 0,
    lightRange = 0,
    hasShimmer = false,
    hasTrail = false,
    hasJingle = false,
  },
  medium = {
    size = Vector3.new(0.8, 0.8, 0.8),
    color = Color3.fromRGB(184, 134, 11), -- dark gold
    lightBrightness = 0.5,
    lightRange = 6,
    hasShimmer = true,
    hasTrail = false,
    hasJingle = false,
  },
  large = {
    size = Vector3.new(1.0, 1.0, 1.0),
    color = Color3.fromRGB(255, 200, 50), -- bright gold
    lightBrightness = 0.8,
    lightRange = 8,
    hasShimmer = true,
    hasTrail = true,
    hasJingle = true,
  },
}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Removes all loot visibility visuals from a character.
]]
local function clearVisuals(character: Model)
  if not character then
    return
  end

  -- Check character-level children (purse, trail)
  for _, child in character:GetChildren() do
    if child.Name == PURSE_TAG or child.Name == TRAIL_TAG then
      child:Destroy()
    end
  end

  -- Check HumanoidRootPart children (jingle sound, night glow)
  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if rootPart then
    for _, child in rootPart:GetChildren() do
      if child.Name == JINGLE_TAG or child.Name == NIGHT_GLOW_TAG then
        child:Destroy()
      end
    end
  end
end

--[[
  Creates and attaches the coin purse Part to a character's HumanoidRootPart.
  Uses DoubloonModels for detailed purse visuals.
]]
local function createPurse(character: Model, def: typeof(PURSE_DEFS.small), tier: string)
  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return
  end

  -- Build detailed purse model from DoubloonModels
  local purse = DoubloonModels.buildPurse(tier)
  if not purse then
    return
  end
  purse.Name = PURSE_TAG

  -- Weld to belt area (left hip, slightly forward)
  local w = Instance.new("Weld")
  w.Part0 = rootPart
  w.Part1 = purse
  w.C0 = CFrame.new(-0.8, -0.5, 0.3)
  w.Parent = purse

  -- Gold PointLight for medium/large
  if def.lightBrightness > 0 then
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(255, 200, 50)
    light.Brightness = def.lightBrightness
    light.Range = def.lightRange
    light.Parent = purse
  end

  -- Shimmer particles for medium/large
  if def.hasShimmer then
    local emitter = Instance.new("ParticleEmitter")
    emitter.Color = ColorSequence.new(Color3.fromRGB(255, 200, 50))
    emitter.Size = NumberSequence.new(0.1, 0)
    emitter.Lifetime = NumberRange.new(0.5, 1.0)
    emitter.Rate = if def.hasTrail then 12 else 6
    emitter.Speed = NumberRange.new(0.5, 1.5)
    emitter.SpreadAngle = Vector2.new(180, 180)
    emitter.Parent = purse
  end

  purse.Parent = character
end

--[[
  Creates a gold particle trail on the character's HumanoidRootPart.
  Visible as a sparkle trail behind the player as they move.
]]
local function createTrail(character: Model)
  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return
  end

  -- Attachment-based Trail for movement sparkle
  local trailPart = Instance.new("Part")
  trailPart.Name = TRAIL_TAG
  trailPart.Size = Vector3.new(0.1, 0.1, 0.1)
  trailPart.Transparency = 1
  trailPart.CanCollide = false
  trailPart.CanQuery = false
  trailPart.CanTouch = false
  trailPart.CastShadow = false
  trailPart.Massless = true

  local weld = Instance.new("Weld")
  weld.Part0 = rootPart
  weld.Part1 = trailPart
  weld.C0 = CFrame.new(0, -2, 0) -- at feet
  weld.Parent = trailPart

  -- Gold particle emitter that acts as a trail
  local emitter = Instance.new("ParticleEmitter")
  emitter.Color = ColorSequence.new(Color3.fromRGB(255, 215, 0), Color3.fromRGB(255, 180, 50))
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.15),
    NumberSequenceKeypoint.new(1, 0),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.7, 0.5),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(0.8, 1.5)
  emitter.Rate = 15
  emitter.Speed = NumberRange.new(0.2, 0.8)
  emitter.SpreadAngle = Vector2.new(30, 30)
  emitter.Drag = 2
  emitter.Parent = trailPart

  trailPart.Parent = character
end

--[[
  Creates a looping 3D coin jingle sound attached to the character.
  Other players hear the jingle when nearby (RollOff).
]]
local function createJingle(character: Model)
  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return
  end

  local sound = Instance.new("Sound")
  sound.Name = JINGLE_TAG
  sound.SoundId = COIN_JINGLE_ID
  sound.Volume = 0.3
  sound.Looped = true
  sound.RollOffMode = Enum.RollOffMode.Linear
  sound.RollOffMinDistance = 5
  sound.RollOffMaxDistance = 40
  sound.Parent = rootPart
  sound:Play()
end

--[[
  Applies a faint gold night glow PointLight to a character.
  Only for players carrying 200+ doubloons during Night phase.
]]
local function applyNightGlow(character: Model)
  if not character then
    return
  end

  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return
  end

  -- Don't duplicate
  if rootPart:FindFirstChild(NIGHT_GLOW_TAG) then
    return
  end

  local glow = Instance.new("PointLight")
  glow.Name = NIGHT_GLOW_TAG
  glow.Color = Color3.fromRGB(255, 215, 0) -- warm gold
  glow.Brightness = 0.6
  glow.Range = 15
  glow.Parent = rootPart
end

--[[
  Removes the night glow PointLight from a character.
]]
local function removeNightGlow(character: Model)
  if not character then
    return
  end

  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if rootPart then
    local glow = rootPart:FindFirstChild(NIGHT_GLOW_TAG)
    if glow then
      glow:Destroy()
    end
  end
end

--[[
  Applies all visuals for a given tier to a character.
  Clears previous visuals first.
]]
local function applyTierVisuals(player: Player, tier: string)
  local character = player.Character
  if not character then
    return
  end

  clearVisuals(character)

  if tier == "none" then
    return
  end

  local def = PURSE_DEFS[tier]
  if not def then
    return
  end

  createPurse(character, def, tier)

  if def.hasTrail then
    createTrail(character)
  end

  if def.hasJingle then
    createJingle(character)
  end

  -- Apply night glow if currently night and threshold met
  if DayNightService and DayNightService:IsNight() then
    local doubloons = SessionStateService and SessionStateService:GetHeldDoubloons(player) or 0
    if doubloons >= GameConfig.NightGlowThreshold then
      applyNightGlow(character)
    end
  end
end

--[[
  Called when a player's held doubloons change. Recalculates tier and updates visuals.
]]
local function onDoubloonsChanged(player: Player, doubloons: number)
  local newTier = GameConfig.getLootVisibilityTier(doubloons)
  local oldTier = PlayerTier[player] or "none"

  if newTier == oldTier then
    -- Tier didn't change, but check night glow threshold
    if DayNightService and DayNightService:IsNight() then
      local character = player.Character
      if character then
        if doubloons >= GameConfig.NightGlowThreshold then
          applyNightGlow(character)
        else
          removeNightGlow(character)
        end
      end
    end
    return
  end

  PlayerTier[player] = newTier
  applyTierVisuals(player, newTier)

  -- Notify client and server listeners
  LootVisibilityService.Client.TierChanged:Fire(player, newTier, oldTier, doubloons)
  LootVisibilityService.TierChanged:Fire(player, newTier, oldTier)

  print(
    string.format(
      "[LootVisibilityService] %s tier changed: %s → %s (%d doubloons)",
      player.Name,
      oldTier,
      newTier,
      doubloons
    )
  )
end

--[[
  Handles day/night phase transition. Applies or removes night glow for all players.
]]
local function onPhaseChanged(newPhase: string, _previousPhase: string)
  local isNight = newPhase == "Night"

  for _, player in Players:GetPlayers() do
    local character = player.Character
    if not character then
      continue
    end

    if isNight then
      local doubloons = SessionStateService and SessionStateService:GetHeldDoubloons(player) or 0
      if doubloons >= GameConfig.NightGlowThreshold then
        applyNightGlow(character)
      end
    else
      removeNightGlow(character)
    end
  end
end

--[[
  Sets up event connections for a player.
]]
local function setupPlayer(player: Player)
  PlayerTier[player] = "none"
  local connections: { RBXScriptConnection } = {}

  -- Re-apply visuals on character respawn
  table.insert(
    connections,
    player.CharacterAdded:Connect(function(_character: Model)
      task.defer(function()
        if not player.Parent then
          return
        end
        local tier = PlayerTier[player] or "none"
        applyTierVisuals(player, tier)
      end)
    end)
  )

  PlayerConnections[player] = connections

  -- Apply initial tier if doubloons already set
  if SessionStateService and SessionStateService:IsInitialized(player) then
    local doubloons = SessionStateService:GetHeldDoubloons(player)
    if doubloons > 0 then
      onDoubloonsChanged(player, doubloons)
    end
  end
end

--[[
  Cleans up all state and visuals for a departing player.
]]
local function cleanupPlayer(player: Player)
  -- Disconnect events
  local connections = PlayerConnections[player]
  if connections then
    for _, conn in connections do
      conn:Disconnect()
    end
    PlayerConnections[player] = nil
  end

  -- Clear visuals from character (if still exists)
  local character = player.Character
  if character then
    clearVisuals(character)
  end

  PlayerTier[player] = nil
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the current loot visibility tier for a player.
  @param player The player to check
  @return "none" | "small" | "medium" | "large"
]]
function LootVisibilityService:GetTier(player: Player): string
  return PlayerTier[player] or "none"
end

--[[
  Client-callable: returns the player's current loot visibility tier.
]]
function LootVisibilityService.Client:GetTier(player: Player): string
  return LootVisibilityService:GetTier(player)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function LootVisibilityService:KnitInit()
  print("[LootVisibilityService] Initialized")
end

function LootVisibilityService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DayNightService = Knit.GetService("DayNightService")

  -- Listen for held doubloons changes
  SessionStateService.StateChanged:Connect(function(player: Player, fieldName: string, value: any)
    if fieldName == "heldDoubloons" then
      onDoubloonsChanged(player, value)
    end
  end)

  -- Listen for day/night phase changes (for night glow)
  DayNightService.PhaseChanged:Connect(onPhaseChanged)

  -- Set up existing players
  for _, player in Players:GetPlayers() do
    setupPlayer(player)
  end

  -- Set up new players
  Players.PlayerAdded:Connect(function(player: Player)
    setupPlayer(player)
  end)

  -- Clean up departing players
  Players.PlayerRemoving:Connect(function(player: Player)
    cleanupPlayer(player)
  end)

  print("[LootVisibilityService] Started")
end

return LootVisibilityService
