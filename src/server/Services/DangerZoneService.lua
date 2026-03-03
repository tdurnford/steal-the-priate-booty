--[[
  DangerZoneService.lua
  Server-authoritative danger zone detection and tracking.

  Handles:
    - Detecting when players enter/exit danger zones via AABB checks
    - Tracking inDangerZone + dangerZoneName in SessionStateService
    - Providing IsInDangerZone()/GetCurrentZone() API for other services
    - Firing server-side signals for inter-service use (ThreatService, etc.)
    - Providing IsPositionInDangerZone() for ContainerService/NPCService

  Danger zones are defined by Parts inside a "DangerZones" Folder in workspace.
  Each Part is named by its zone ID (e.g. "skull_cave", "volcano", "deep_jungle").
  Zone definitions are in GameConfig.DangerZones.

  If no DangerZones folder exists, detection is disabled gracefully.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local DangerZoneService = Knit.CreateService({
  Name = "DangerZoneService",
  Client = {
    -- Fired to a player when they enter or leave a danger zone.
    -- Args: (inDangerZone: boolean, zoneName: string?)
    DangerZoneChanged = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
DangerZoneService.PlayerEnteredDangerZone = Signal.new() -- (player: Player, zoneId: string, zoneName: string)
DangerZoneService.PlayerExitedDangerZone = Signal.new() -- (player: Player, zoneId: string, zoneName: string)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil

-- Zone parts keyed by zone ID: { [string]: BasePart }
local ZoneParts: { [string]: BasePart } = {}

-- How often to check player positions (seconds)
local CHECK_INTERVAL = GameConfig.DangerZoneConfig.checkInterval

-- Per-player current zone tracking (to detect transitions without SessionState read)
local PlayerCurrentZone: { [Player]: string? } = {}

--------------------------------------------------------------------------------
-- ZONE DETECTION
--------------------------------------------------------------------------------

--[[
  Checks whether a position is inside a zone part's AABB.
  @param zonePart The Part defining the zone boundary
  @param position The world position to check
  @return true if inside the zone
]]
local function isPositionInZone(zonePart: BasePart, position: Vector3): boolean
  local zoneCF = zonePart.CFrame
  local zoneHalfSize = zonePart.Size / 2
  local localPos = zoneCF:PointToObjectSpace(position)

  return math.abs(localPos.X) <= zoneHalfSize.X
    and math.abs(localPos.Y) <= zoneHalfSize.Y
    and math.abs(localPos.Z) <= zoneHalfSize.Z
end

--[[
  Finds which danger zone a position is in, if any.
  @param position The world position to check
  @return zoneId, zoneName or nil, nil
]]
local function findZoneAtPosition(position: Vector3): (string?, string?)
  for zoneId, zonePart in ZoneParts do
    if isPositionInZone(zonePart, position) then
      local def = GameConfig.DangerZoneById[zoneId]
      local zoneName = if def then def.name else zoneId
      return zoneId, zoneName
    end
  end
  return nil, nil
end

--[[
  Gets a player's current world position via HumanoidRootPart.
  @param player The player
  @return Position or nil if character/root part unavailable
]]
local function getPlayerPosition(player: Player): Vector3?
  local character = player.Character
  if not character then
    return nil
  end
  local rootPart = character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return nil
  end
  return (rootPart :: BasePart).Position
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Checks whether a player is currently inside any danger zone.
  Reads from SessionStateService for consistency.
  @param player The player to check
  @return true if the player is in a danger zone
]]
function DangerZoneService:IsInDangerZone(player: Player): boolean
  if not SessionStateService then
    return false
  end
  return SessionStateService:IsInDangerZone(player)
end

--[[
  Gets the zone ID the player is currently in, if any.
  @param player The player to check
  @return Zone ID string or nil
]]
function DangerZoneService:GetCurrentZone(player: Player): string?
  return PlayerCurrentZone[player]
end

--[[
  Checks whether a world position is inside any danger zone.
  Used by ContainerService for Cursed Chest spawning, NPCService for patrol, etc.
  @param position The world position to check
  @return true if inside any danger zone
]]
function DangerZoneService:IsPositionInDangerZone(position: Vector3): boolean
  local zoneId = findZoneAtPosition(position)
  return zoneId ~= nil
end

--[[
  Gets the zone ID for a position, or nil if not in any danger zone.
  @param position The world position to check
  @return Zone ID string or nil
]]
function DangerZoneService:GetZoneAtPosition(position: Vector3): string?
  local zoneId = findZoneAtPosition(position)
  return zoneId
end

--------------------------------------------------------------------------------
-- ZONE CHECK LOOP
--------------------------------------------------------------------------------

--[[
  Called periodically to check all players' positions against danger zones.
  Detects entry/exit transitions and fires signals.
]]
local function checkPlayerPositions()
  for _, player in Players:GetPlayers() do
    if not SessionStateService or not SessionStateService:IsInitialized(player) then
      continue
    end

    local position = getPlayerPosition(player)
    if not position then
      continue
    end

    local previousZoneId = PlayerCurrentZone[player]
    local currentZoneId, currentZoneName = findZoneAtPosition(position)

    if currentZoneId ~= previousZoneId then
      -- Player changed zones (entered, exited, or moved between zones)

      if previousZoneId and not currentZoneId then
        -- Exited danger zone
        local prevDef = GameConfig.DangerZoneById[previousZoneId]
        local prevName = if prevDef then prevDef.name else previousZoneId
        PlayerCurrentZone[player] = nil
        SessionStateService:SetInDangerZone(player, false, nil)
        DangerZoneService.Client.DangerZoneChanged:Fire(player, false, nil)
        DangerZoneService.PlayerExitedDangerZone:Fire(player, previousZoneId, prevName)
        print("[DangerZoneService]", player.Name, "exited", prevName)
      elseif not previousZoneId and currentZoneId then
        -- Entered danger zone
        PlayerCurrentZone[player] = currentZoneId
        SessionStateService:SetInDangerZone(player, true, currentZoneName)
        DangerZoneService.Client.DangerZoneChanged:Fire(player, true, currentZoneName)
        DangerZoneService.PlayerEnteredDangerZone:Fire(
          player,
          currentZoneId,
          currentZoneName :: string
        )
        print("[DangerZoneService]", player.Name, "entered", currentZoneName)
      else
        -- Moved from one danger zone to another
        local prevDef = GameConfig.DangerZoneById[previousZoneId :: string]
        local prevName = if prevDef then prevDef.name else previousZoneId :: string
        PlayerCurrentZone[player] = currentZoneId
        -- Fire exit for old zone
        DangerZoneService.PlayerExitedDangerZone:Fire(player, previousZoneId :: string, prevName)
        -- Update session state to new zone
        SessionStateService:SetInDangerZone(player, true, currentZoneName)
        DangerZoneService.Client.DangerZoneChanged:Fire(player, true, currentZoneName)
        -- Fire enter for new zone
        DangerZoneService.PlayerEnteredDangerZone:Fire(
          player,
          currentZoneId :: string,
          currentZoneName :: string
        )
        print("[DangerZoneService]", player.Name, "moved from", prevName, "to", currentZoneName)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- CLEANUP
--------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
  PlayerCurrentZone[player] = nil
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DangerZoneService:KnitInit()
  -- Find the DangerZones folder in workspace
  local dangerZonesFolder = workspace:FindFirstChild("DangerZones")
  if not dangerZonesFolder then
    warn(
      "[DangerZoneService] No DangerZones folder found in workspace — danger zone detection disabled"
    )
    print("[DangerZoneService] Initialized (no zones)")
    return
  end

  -- Load zone parts by their name (must match zone IDs in GameConfig)
  local foundCount = 0
  for _, child in dangerZonesFolder:GetChildren() do
    if child:IsA("BasePart") then
      local zoneId = child.Name
      if GameConfig.DangerZoneById[zoneId] then
        ZoneParts[zoneId] = child
        foundCount = foundCount + 1
        print("[DangerZoneService] Loaded zone:", zoneId, "size:", child.Size)
      else
        warn("[DangerZoneService] Unknown zone part:", zoneId, "— not in GameConfig.DangerZones")
      end
    end
  end

  print("[DangerZoneService] Initialized — found", foundCount, "danger zone(s)")
end

function DangerZoneService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")

  -- Clean up on player leave
  Players.PlayerRemoving:Connect(onPlayerRemoving)

  -- Check if we have any zone parts
  local hasZones = false
  for _ in ZoneParts do
    hasZones = true
    break
  end

  if not hasZones then
    print("[DangerZoneService] Started (no zones — detection inactive)")
    return
  end

  -- Run position checks on Heartbeat with throttled interval
  local accumulator = 0
  RunService.Heartbeat:Connect(function(dt: number)
    accumulator = accumulator + dt
    if accumulator >= CHECK_INTERVAL then
      accumulator = accumulator - CHECK_INTERVAL
      checkPlayerPositions()
    end
  end)

  print("[DangerZoneService] Started — zone detection active (check every", CHECK_INTERVAL, "s)")
end

return DangerZoneService
