--[[
  EventService.lua
  Server-authoritative world event manager.

  Currently implements:
    - Shipwreck event (EVENT-002): spawns a wrecked ship model at a random
      location containing 3-5 high-value containers (Reinforced Trunks and
      Captain's Vaults). Announced to all players. Despawns after 60 seconds.

  Timer runs on Heartbeat, randomized interval between events.
  Only one major event active at a time.

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
  startTime: number,
  duration: number,
}? =
  nil

-- Timer state
local TimerAccumulator = 0
local NextEventInterval = 0 -- seconds until next event attempt
local EventsFolder: Folder? = nil -- workspace.EventSpawnPoints

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Picks a random interval for the next shipwreck event.
  @return number Seconds until next event
]]
local function rollNextInterval(): number
  local config = GameConfig.ShipwreckEvent
  return math.random(config.intervalMin, config.intervalMax)
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
  Ends the active shipwreck event. Removes unbroken containers and
  the wreck model.
]]
local function endShipwreckEvent()
  if not ActiveEvent then
    return
  end

  local eventType = ActiveEvent.eventType

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

  ActiveEvent = nil

  -- Notify clients
  EventService.Client.EventEnded:FireAll(eventType)
  EventService.EventEnded:Fire(eventType)

  print("[EventService] Shipwreck event ended")
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS
--------------------------------------------------------------------------------

--[[
  Returns info about the currently active event, or nil if none.
  Used for late-join sync.
  @return { eventType: string, position: Vector3, remainingTime: number }?
]]
function EventService.Client:GetActiveEvent(_player: Player): {
  eventType: string,
  position: { number },
  remainingTime: number,
}?
  if not ActiveEvent then
    return nil
  end

  local elapsed = os.clock() - ActiveEvent.startTime
  local remaining = math.max(0, ActiveEvent.duration - elapsed)

  -- Serialize Vector3 for Knit RPC
  return {
    eventType = ActiveEvent.eventType,
    position = { ActiveEvent.position.X, ActiveEvent.position.Y, ActiveEvent.position.Z },
    remainingTime = remaining,
  }
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

  print("[EventService] Initialized")
end

function EventService:KnitStart()
  ContainerService = Knit.GetService("ContainerService")
  DayNightService = Knit.GetService("DayNightService")

  -- Roll initial interval
  NextEventInterval = rollNextInterval()

  -- Listen for containers being broken so we can track event container removal
  ContainerService.ContainerBroken:Connect(function(entry, _player)
    if ActiveEvent then
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
        endShipwreckEvent()
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
      triggerShipwreckEvent()
    end
  end)

  print(
    string.format(
      "[EventService] Started — next event in %.0fs, %d spawn points",
      NextEventInterval,
      #getEventSpawnPositions()
    )
  )
end

return EventService
