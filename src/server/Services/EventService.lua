--[[
  EventService.lua
  Server-authoritative world event manager.

  Implements:
    - Shipwreck event (EVENT-002): spawns a wrecked ship model at a random
      location containing 3-5 high-value containers (Reinforced Trunks and
      Captain's Vaults). Announced to all players. Despawns after 60 seconds.
    - Loot Surge event (EVENT-003): highlights a zone on the map where
      containers spawn at 3x rate and yield 2x doubloons. Lasts 45 seconds.
      Announced to all players with zone position.

  Timer runs on Heartbeat, randomized interval between events.
  Only one major event active at a time. The timer alternates between
  event types randomly.

  Depends on: ContainerService, DayNightService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local EventService = Knit.CreateService({
  Name = "EventService",
  Client = {
    EventStarted = Knit.CreateSignal(), -- (eventType, position, duration)
    EventEnded = Knit.CreateSignal(), -- (eventType)
  },
})

-- Server-side signals for inter-service communication
EventService.EventStarted = Signal.new() -- (eventType, position, duration)
EventService.EventEnded = Signal.new() -- (eventType)

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local ContainerService = nil
local DayNightService = nil

-- Active event tracking
local ActiveEvent: {
  eventType: string,
  position: Vector3,
  containerIds: { string },
  model: Model?,
  zonePart: BasePart?, -- for loot surge: the zone Part
  startTime: number,
  duration: number,
}? =
  nil

-- Timer state
local TimerAccumulator = 0
local NextEventInterval = 0 -- seconds until next event attempt
local EventsFolder: Folder? = nil -- workspace.EventSpawnPoints
local LootSurgeZonesFolder: Folder? = nil -- workspace.LootSurgeZones

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Picks a random interval for the next event.
  Uses the shorter of the two event intervals for more dynamic timing.
  @return number Seconds until next event
]]
local function rollNextInterval(): number
  -- Use the shorter interval range (shipwreck 3-5min) so events feel frequent.
  -- The actual event type is chosen randomly at trigger time.
  local shipwreckConfig = GameConfig.ShipwreckEvent
  local surgeConfig = GameConfig.LootSurgeEvent
  local minInterval = math.min(shipwreckConfig.intervalMin, surgeConfig.intervalMin)
  local maxInterval = math.min(shipwreckConfig.intervalMax, surgeConfig.intervalMax)
  return math.random(minInterval, maxInterval)
end

--[[
  Selects a weighted random container type from the shipwreck config.
  @return string Container type ID
]]
local function pickShipwreckContainerType(): string
  local config = GameConfig.ShipwreckEvent
  local types = config.containerTypes
  local weights = config.containerTypeWeights

  -- Weighted random selection
  local totalWeight = 0
  for _, w in weights do
    totalWeight = totalWeight + w
  end

  local roll = math.random() * totalWeight
  local cumulative = 0
  for i, w in weights do
    cumulative = cumulative + w
    if roll <= cumulative then
      return types[i]
    end
  end

  -- Fallback
  return types[1]
end

--[[
  Returns a list of spawn point positions from workspace.EventSpawnPoints.
  Each spawn point is a Part with a Position.
  @return { Vector3 }
]]
local function getEventSpawnPositions(): { Vector3 }
  local positions = {}
  if not EventsFolder then
    return positions
  end

  for _, child in EventsFolder:GetChildren() do
    if child:IsA("BasePart") then
      table.insert(positions, child.Position)
    end
  end

  return positions
end

--[[
  Returns all loot surge zone Parts from workspace.LootSurgeZones.
  @return { BasePart }
]]
local function getLootSurgeZones(): { BasePart }
  local zones = {}
  if not LootSurgeZonesFolder then
    return zones
  end

  for _, child in LootSurgeZonesFolder:GetChildren() do
    if child:IsA("BasePart") then
      table.insert(zones, child)
    end
  end

  return zones
end

--[[
  Creates a placeholder shipwreck model at the given position.
  In production this would be a detailed wrecked ship mesh. For now
  we create a recognizable placeholder: a tilted hull shape with
  broken-mast detail and a glowing beacon.

  @param position Vector3 The center position of the wreck
  @return Model The wreck model
]]
local function createShipwreckModel(position: Vector3): Model
  local model = Instance.new("Model")
  model.Name = "ShipwreckEvent"

  -- Hull: tilted dark brown box
  local hull = Instance.new("Part")
  hull.Name = "Hull"
  hull.Size = Vector3.new(24, 6, 10)
  hull.Position = position + Vector3.new(0, 3, 0)
  hull.Anchored = true
  hull.CanCollide = true
  hull.CanQuery = false
  hull.CanTouch = false
  hull.Material = Enum.Material.Wood
  hull.BrickColor = BrickColor.new("Dark orange")
  hull.CFrame = CFrame.new(position + Vector3.new(0, 3, 0))
    * CFrame.Angles(0, math.random() * math.pi * 2, math.rad(12))
  hull.Parent = model

  -- Broken mast
  local mast = Instance.new("Part")
  mast.Name = "BrokenMast"
  mast.Size = Vector3.new(1.5, 10, 1.5)
  mast.Position = hull.Position + Vector3.new(0, 8, 0)
  mast.Anchored = true
  mast.CanCollide = false
  mast.CanQuery = false
  mast.CanTouch = false
  mast.Material = Enum.Material.Wood
  mast.BrickColor = BrickColor.new("Brown")
  mast.CFrame = CFrame.new(hull.Position + Vector3.new(0, 8, 0))
    * CFrame.Angles(math.rad(25), 0, math.rad(-15))
  mast.Parent = model

  -- Beacon glow (so players can see it from afar)
  local beacon = Instance.new("Part")
  beacon.Name = "Beacon"
  beacon.Shape = Enum.PartType.Ball
  beacon.Size = Vector3.new(3, 3, 3)
  beacon.Position = hull.Position + Vector3.new(0, 14, 0)
  beacon.Anchored = true
  beacon.CanCollide = false
  beacon.CanQuery = false
  beacon.CanTouch = false
  beacon.Material = Enum.Material.Neon
  beacon.BrickColor = BrickColor.new("Gold")
  beacon.Transparency = 0.3
  beacon.Parent = model

  local light = Instance.new("PointLight")
  light.Color = Color3.fromRGB(255, 200, 50)
  light.Brightness = 3
  light.Range = 60
  light.Parent = beacon

  -- Billboard label visible from distance
  local billboard = Instance.new("BillboardGui")
  billboard.Name = "EventLabel"
  billboard.Size = UDim2.new(0, 200, 0, 50)
  billboard.StudsOffset = Vector3.new(0, 18, 0)
  billboard.AlwaysOnTop = true
  billboard.MaxDistance = 500
  billboard.Parent = beacon

  local label = Instance.new("TextLabel")
  label.Name = "Label"
  label.Size = UDim2.new(1, 0, 1, 0)
  label.BackgroundTransparency = 1
  label.Text = "SHIPWRECK"
  label.TextColor3 = Color3.fromRGB(255, 200, 50)
  label.Font = Enum.Font.FredokaOne
  label.TextSize = 24
  label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
  label.TextStrokeTransparency = 0.2
  label.Parent = billboard

  model.PrimaryPart = hull
  model.Parent = workspace

  return model
end

--[[
  Calculates container positions spread evenly around the wreck center.
  @param center Vector3 The wreck center
  @param count number How many containers
  @return { Vector3 }
]]
local function calculateContainerPositions(center: Vector3, count: number): { Vector3 }
  local positions = {}
  local spread = GameConfig.ShipwreckEvent.containerSpread
  local angleStep = (2 * math.pi) / count

  for i = 1, count do
    local angle = angleStep * (i - 1) + math.random() * angleStep * 0.4
    local dist = spread * (0.6 + math.random() * 0.4)
    local offset = Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
    table.insert(positions, center + offset)
  end

  return positions
end

--------------------------------------------------------------------------------
-- EVENT LIFECYCLE
--------------------------------------------------------------------------------

--[[
  Triggers a shipwreck world event at a random spawn point.
  Does nothing if an event is already active or no spawn points exist.
]]
local function triggerShipwreckEvent()
  if ActiveEvent then
    return -- only one event at a time
  end

  local positions = getEventSpawnPositions()
  if #positions == 0 then
    -- No spawn points configured; pick a fallback position in the world
    warn("[EventService] No EventSpawnPoints found in workspace; using fallback position")
    positions = { Vector3.new(0, 5, 0) }
  end

  -- Pick random spawn position
  local spawnPos = positions[math.random(1, #positions)]
  local config = GameConfig.ShipwreckEvent

  -- Determine container count
  local containerCount = math.random(config.containerCount.min, config.containerCount.max)

  -- Create shipwreck model
  local wreckModel = createShipwreckModel(spawnPos)

  -- Spawn containers around the wreck
  local containerIds = {}
  local containerPositions = calculateContainerPositions(spawnPos, containerCount)

  for _, pos in containerPositions do
    local typeId = pickShipwreckContainerType()
    local entry = ContainerService:SpawnContainerAt(typeId, pos)
    if entry then
      table.insert(containerIds, entry.id)
    end
  end

  -- Set up active event
  ActiveEvent = {
    eventType = "shipwreck",
    position = spawnPos,
    containerIds = containerIds,
    model = wreckModel,
    zonePart = nil,
    startTime = os.clock(),
    duration = config.duration,
  }

  -- Announce to all clients
  EventService.Client.EventStarted:FireAll("shipwreck", spawnPos, config.duration)
  EventService.EventStarted:Fire("shipwreck", spawnPos, config.duration)

  print(
    string.format(
      "[EventService] Shipwreck event started at (%.0f, %.0f, %.0f) with %d containers",
      spawnPos.X,
      spawnPos.Y,
      spawnPos.Z,
      #containerIds
    )
  )
end

--[[
  Triggers a loot surge world event in a random zone.
  Does nothing if an event is already active or no surge zones exist.
]]
local function triggerLootSurgeEvent()
  if ActiveEvent then
    return -- only one event at a time
  end

  local zones = getLootSurgeZones()
  if #zones == 0 then
    warn("[EventService] No LootSurgeZones found in workspace; skipping loot surge event")
    return
  end

  -- Pick a random zone
  local zonePart = zones[math.random(1, #zones)]
  local config = GameConfig.LootSurgeEvent
  local zoneCenter = zonePart.Position

  -- Activate loot surge on ContainerService
  ContainerService:SetLootSurge(zonePart, config.spawnRateMultiplier, config.yieldMultiplier)

  -- Set up active event
  ActiveEvent = {
    eventType = "loot_surge",
    position = zoneCenter,
    containerIds = {},
    model = nil,
    zonePart = zonePart,
    startTime = os.clock(),
    duration = config.duration,
  }

  -- Announce to all clients (send zone center position + zone size for highlighting)
  local zoneSize = zonePart.Size
  EventService.Client.EventStarted:FireAll("loot_surge", zoneCenter, config.duration, zoneSize)
  EventService.EventStarted:Fire("loot_surge", zoneCenter, config.duration, zoneSize)

  print(
    string.format(
      "[EventService] Loot Surge event started at zone '%s' (%.0f, %.0f, %.0f) — %dx spawn, %dx yield for %ds",
      zonePart.Name,
      zoneCenter.X,
      zoneCenter.Y,
      zoneCenter.Z,
      config.spawnRateMultiplier,
      config.yieldMultiplier,
      config.duration
    )
  )
end

--[[
  Ends the active event (shipwreck or loot surge).
]]
local function endActiveEvent()
  if not ActiveEvent then
    return
  end

  local eventType = ActiveEvent.eventType

  if eventType == "shipwreck" then
    -- Remove any unbroken containers
    for _, containerId in ActiveEvent.containerIds do
      if ContainerService:GetContainer(containerId) then
        ContainerService:RemoveContainer(containerId, true)
      end
    end

    -- Remove wreck model
    if ActiveEvent.model and ActiveEvent.model.Parent then
      ActiveEvent.model:Destroy()
    end
  elseif eventType == "loot_surge" then
    -- Clear loot surge multipliers on ContainerService
    ContainerService:ClearLootSurge()
  end

  ActiveEvent = nil

  -- Notify clients
  EventService.Client.EventEnded:FireAll(eventType)
  EventService.EventEnded:Fire(eventType)

  print(string.format("[EventService] %s event ended", eventType))
end

--[[
  Picks a random event type to trigger. Equal chance of shipwreck or loot surge,
  but falls back to the other type if one can't be triggered (e.g. no zones).
]]
local function triggerRandomEvent()
  local hasShipwreckPoints = #getEventSpawnPositions() > 0
  local hasSurgeZones = #getLootSurgeZones() > 0

  if hasShipwreckPoints and hasSurgeZones then
    -- Both available: pick randomly (50/50)
    if math.random() < 0.5 then
      triggerShipwreckEvent()
    else
      triggerLootSurgeEvent()
    end
  elseif hasShipwreckPoints then
    triggerShipwreckEvent()
  elseif hasSurgeZones then
    triggerLootSurgeEvent()
  else
    -- Neither available; just shipwreck with fallback position
    triggerShipwreckEvent()
  end
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS
--------------------------------------------------------------------------------

--[[
  Returns info about the currently active event, or nil if none.
  Used for late-join sync.
  @return { eventType: string, position: { number }, remainingTime: number, zoneSize: { number }? }?
]]
function EventService.Client:GetActiveEvent(_player: Player): {
  eventType: string,
  position: { number },
  remainingTime: number,
  zoneSize: { number }?,
}?
  if not ActiveEvent then
    return nil
  end

  local elapsed = os.clock() - ActiveEvent.startTime
  local remaining = math.max(0, ActiveEvent.duration - elapsed)

  -- Serialize Vector3 for Knit RPC
  local result: any = {
    eventType = ActiveEvent.eventType,
    position = { ActiveEvent.position.X, ActiveEvent.position.Y, ActiveEvent.position.Z },
    remainingTime = remaining,
  }

  -- Include zone size for loot surge so clients can render the highlight
  if ActiveEvent.eventType == "loot_surge" and ActiveEvent.zonePart then
    local size = ActiveEvent.zonePart.Size
    result.zoneSize = { size.X, size.Y, size.Z }
  end

  return result
end

--------------------------------------------------------------------------------
-- PUBLIC SERVER API
--------------------------------------------------------------------------------

--[[
  Returns whether a world event is currently active.
  @return boolean
]]
function EventService:IsEventActive(): boolean
  return ActiveEvent ~= nil
end

--[[
  Returns the active event type, or nil.
  @return string?
]]
function EventService:GetActiveEventType(): string?
  if ActiveEvent then
    return ActiveEvent.eventType
  end
  return nil
end

--[[
  Returns the active loot surge zone Part, or nil.
  Used by other server services to check if a position is in the surge zone.
  @return BasePart?
]]
function EventService:GetLootSurgeZonePart(): BasePart?
  if ActiveEvent and ActiveEvent.eventType == "loot_surge" then
    return ActiveEvent.zonePart
  end
  return nil
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function EventService:KnitInit()
  -- Look for EventSpawnPoints folder in workspace
  EventsFolder = workspace:FindFirstChild("EventSpawnPoints")
  if not EventsFolder then
    EventsFolder = Instance.new("Folder")
    EventsFolder.Name = "EventSpawnPoints"
    EventsFolder.Parent = workspace
    warn(
      "[EventService] Created empty EventSpawnPoints folder — add Parts to define event spawn locations"
    )
  end

  -- Look for LootSurgeZones folder in workspace
  LootSurgeZonesFolder = workspace:FindFirstChild("LootSurgeZones")
  if not LootSurgeZonesFolder then
    LootSurgeZonesFolder = Instance.new("Folder")
    LootSurgeZonesFolder.Name = "LootSurgeZones"
    LootSurgeZonesFolder.Parent = workspace
    warn(
      "[EventService] Created empty LootSurgeZones folder — add Parts to define loot surge zones"
    )
  end

  print("[EventService] Initialized")
end

function EventService:KnitStart()
  ContainerService = Knit.GetService("ContainerService")
  DayNightService = Knit.GetService("DayNightService")

  -- Roll initial interval
  NextEventInterval = rollNextInterval()

  -- Listen for containers being broken so we can track event container removal
  ContainerService.ContainerBroken:Connect(function(entry, _player)
    if ActiveEvent and ActiveEvent.containerIds then
      -- Remove broken container from our tracking list
      local idx = table.find(ActiveEvent.containerIds, entry.id)
      if idx then
        table.remove(ActiveEvent.containerIds, idx)
      end
    end
  end)

  -- Main event timer loop
  RunService.Heartbeat:Connect(function(dt)
    -- Check if active event should end
    if ActiveEvent then
      local elapsed = os.clock() - ActiveEvent.startTime
      if elapsed >= ActiveEvent.duration then
        endActiveEvent()
        -- Roll next interval after event ends
        NextEventInterval = rollNextInterval()
        TimerAccumulator = 0
      end
      return -- don't accumulate timer while event is active
    end

    -- Accumulate timer
    TimerAccumulator = TimerAccumulator + dt
    if TimerAccumulator >= NextEventInterval then
      TimerAccumulator = 0
      triggerRandomEvent()
    end
  end)

  print(
    string.format(
      "[EventService] Started — next event in %.0fs, %d spawn points, %d surge zones",
      NextEventInterval,
      #getEventSpawnPositions(),
      #getLootSurgeZones()
    )
  )
end

return EventService
