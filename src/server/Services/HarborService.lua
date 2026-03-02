--[[
  HarborService.lua
  Server-authoritative Harbor safe zone detection and enforcement.

  Handles:
    - Detecting when players enter/exit the Harbor zone via AABB check
    - Tracking inHarbor state in SessionStateService (replicated to clients)
    - Auto-unlocking ships when players EXIT the Harbor (ShipService integration)
    - Providing IsInHarbor() API for other services (CombatService, ThreatService)
    - Firing server-side signals for inter-service use

  The Harbor zone is defined by a Part named "HarborZone" in workspace.
  If no HarborZone part exists, harbor detection is disabled.

  PvP disable and threat pause are handled by CombatService and ThreatService
  respectively — they read inHarbor from SessionStateService.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))

local HarborService = Knit.CreateService({
  Name = "HarborService",
  Client = {
    -- Fired to a player when they enter or leave the Harbor.
    -- Args: (inHarbor: boolean)
    HarborStateChanged = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
HarborService.PlayerEnteredHarbor = Signal.new() -- (player: Player)
HarborService.PlayerExitedHarbor = Signal.new() -- (player: Player)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local ShipService = nil

-- The HarborZone part in workspace (nil if not found)
local HarborZonePart: BasePart? = nil

-- How often to check player positions (seconds)
local CHECK_INTERVAL = 0.25

--------------------------------------------------------------------------------
-- ZONE DETECTION
--------------------------------------------------------------------------------

--[[
  Checks whether a position is inside the HarborZone bounding box.
  @param position The world position to check
  @return true if inside the Harbor zone
]]
local function isPositionInHarbor(position: Vector3): boolean
  if not HarborZonePart then
    return false
  end

  local zoneCF = HarborZonePart.CFrame
  local zoneHalfSize = HarborZonePart.Size / 2
  local localPos = zoneCF:PointToObjectSpace(position)

  return math.abs(localPos.X) <= zoneHalfSize.X
    and math.abs(localPos.Y) <= zoneHalfSize.Y
    and math.abs(localPos.Z) <= zoneHalfSize.Z
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
  Checks whether a player is currently inside the Harbor safe zone.
  Reads from SessionStateService for consistency.
  @param player The player to check
  @return true if the player is inside the Harbor
]]
function HarborService:IsInHarbor(player: Player): boolean
  if not SessionStateService then
    return false
  end
  return SessionStateService:IsInHarbor(player)
end

--------------------------------------------------------------------------------
-- ZONE CHECK LOOP
--------------------------------------------------------------------------------

--[[
  Called periodically to check all players' positions against the Harbor zone.
  Detects entry/exit transitions and fires signals.
]]
local function checkPlayerPositions()
  if not HarborZonePart then
    return
  end

  for _, player in Players:GetPlayers() do
    if not SessionStateService or not SessionStateService:IsInitialized(player) then
      continue
    end

    local position = getPlayerPosition(player)
    if not position then
      continue
    end

    local wasInHarbor = SessionStateService:IsInHarbor(player)
    local isNowInHarbor = isPositionInHarbor(position)

    if isNowInHarbor and not wasInHarbor then
      -- Player entered Harbor
      SessionStateService:SetInHarbor(player, true)
      HarborService.Client.HarborStateChanged:Fire(player, true)
      HarborService.PlayerEnteredHarbor:Fire(player)
      print("[HarborService]", player.Name, "entered Harbor safe zone")
    elseif not isNowInHarbor and wasInHarbor then
      -- Player exited Harbor
      SessionStateService:SetInHarbor(player, false)
      HarborService.Client.HarborStateChanged:Fire(player, false)
      HarborService.PlayerExitedHarbor:Fire(player)

      -- Auto-unlock ship when leaving Harbor
      if ShipService then
        ShipService:UnlockShip(player)
      end

      print("[HarborService]", player.Name, "left Harbor safe zone")
    end
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function HarborService:KnitInit()
  -- Find the HarborZone part in workspace
  HarborZonePart = workspace:FindFirstChild("HarborZone")
  if HarborZonePart then
    print("[HarborService] Found HarborZone part:", HarborZonePart.Size)
  else
    warn("[HarborService] No HarborZone part found in workspace — harbor detection disabled")
  end

  print("[HarborService] Initialized")
end

function HarborService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  ShipService = Knit.GetService("ShipService")

  if not HarborZonePart then
    print("[HarborService] Started (no zone — detection inactive)")
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

  print("[HarborService] Started — zone detection active (check every", CHECK_INTERVAL, "s)")
end

return HarborService
