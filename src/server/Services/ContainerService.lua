--[[
  ContainerService.lua
  Server-authoritative container spawn manager.

  Handles:
    - Spawning breakable containers at fixed map points on rolling timers
    - Enforcing the 20 active container cap
    - Night modifier: 1.5x spawn rate
    - Spawning 2-3 Cursed Chests per night cycle in danger zones
    - Tracking container HP and handling damage/break (for LOOT-003)
    - Container type selection via weighted spawn frequency

  Spawn points are defined as Parts in workspace.ContainerSpawnPoints.
  Each spawn point Part can have:
    - Attribute "Zone" (string): zone name (e.g., "beach", "jungle", "danger")
      Cursed Chests only spawn at points with Zone = "danger"
    - Attribute "Occupied" is managed at runtime (not saved)

  Other services call:
    - DamageContainer(containerModel, damageAmount, player) to deal damage
    - GetContainerAtPosition(position) to find a container near a point
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local ContainerService = Knit.CreateService({
  Name = "ContainerService",
  Client = {
    -- Fired to ALL players when a container spawns.
    -- Args: (containerId: string, containerType: string, position: Vector3)
    ContainerSpawned = Knit.CreateSignal(),
    -- Fired to ALL players when a container takes damage.
    -- Args: (containerId: string, hpFraction: number)
    ContainerDamaged = Knit.CreateSignal(),
    -- Fired to ALL players when a container breaks.
    -- Args: (containerId: string, containerType: string, position: Vector3)
    ContainerBroken = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
ContainerService.ContainerSpawned = Signal.new() -- (containerEntry)
ContainerService.ContainerBroken = Signal.new() -- (containerEntry, player)

-- Lazy-loaded service references (set in KnitStart)
local DayNightService = nil
local DoubloonService = nil
local NPCService = nil

--------------------------------------------------------------------------------
-- SPAWN FREQUENCY WEIGHTS
--------------------------------------------------------------------------------

-- Maps spawnFrequency string to a relative weight for random selection.
-- Higher weight = more likely to be selected.
local SPAWN_WEIGHTS = {
  very_common = 40,
  common = 25,
  uncommon = 15,
  rare = 10,
  very_rare = 5,
  -- night_special is never picked by the normal spawn system; cursed chests
  -- are spawned separately at the start of each night cycle.
}

-- Build a weighted selection table from non-nightOnly containers
local DaytimeContainerPool: { { def: GameConfig.ContainerDef, weight: number } } = {}
local DaytimeTotalWeight = 0

for _, containerDef in GameConfig.Containers do
  if not containerDef.nightOnly then
    local w = SPAWN_WEIGHTS[containerDef.spawnFrequency] or 0
    if w > 0 then
      table.insert(DaytimeContainerPool, { def = containerDef, weight = w })
      DaytimeTotalWeight = DaytimeTotalWeight + w
    end
  end
end

--[[
  Selects a random container type from the weighted pool.
  @return ContainerDef
]]
local function pickRandomContainerType(): GameConfig.ContainerDef
  local roll = math.random() * DaytimeTotalWeight
  local cumulative = 0
  for _, entry in DaytimeContainerPool do
    cumulative = cumulative + entry.weight
    if roll <= cumulative then
      return entry.def
    end
  end
  -- Fallback (should never happen)
  return DaytimeContainerPool[1].def
end

--------------------------------------------------------------------------------
-- CONTAINER REGISTRY
--------------------------------------------------------------------------------

-- Each container entry:
-- {
--   id: string,           -- unique container instance ID
--   def: ContainerDef,    -- reference to GameConfig container definition
--   hp: number,           -- current HP
--   maxHp: number,        -- max HP (from def)
--   model: Model,         -- the workspace model
--   position: Vector3,    -- world position
--   spawnPoint: Part?,    -- the spawn point Part (nil for event spawns)
--   zone: string,         -- zone name from spawn point (e.g., "danger", "beach")
--   createdAt: number,    -- os.clock() when spawned
--   isNightSpawn: boolean -- true if spawned during night
-- }
type ContainerEntry = {
  id: string,
  def: GameConfig.ContainerDef,
  hp: number,
  maxHp: number,
  model: Model,
  position: Vector3,
  spawnPoint: Part?,
  zone: string,
  createdAt: number,
  isNightSpawn: boolean,
}

local ActiveContainers: { [string]: ContainerEntry } = {}
local ActiveContainerCount = 0

-- Incrementing ID for unique container naming
local nextContainerId = 1

-- Folder in workspace for container models
local ContainersFolder: Folder = nil

-- Spawn points folder (expected in workspace)
local SpawnPointsFolder: Folder? = nil

-- Tracks which spawn points are currently occupied
local OccupiedSpawnPoints: { [Part]: boolean } = {}

-- Rolling spawn timer state
local spawnTimer = 0
local BASE_SPAWN_INTERVAL = 8 -- seconds between spawn attempts (base rate)

-- Cursed chest state for current night
local cursedChestsSpawnedThisNight = 0
local cursedChestTargetThisNight = 0
local lastNightPhase = false -- tracks if we were in night last frame

--------------------------------------------------------------------------------
-- CONTAINER MODEL CREATION
--------------------------------------------------------------------------------

-- Container appearance by type (placeholder models — simple colored boxes)
local CONTAINER_APPEARANCE = {
  crate = { size = Vector3.new(3, 3, 3), color = Color3.fromRGB(139, 90, 43) },
  barrel = { size = Vector3.new(2.5, 4, 2.5), color = Color3.fromRGB(120, 75, 35) },
  treasure_chest = { size = Vector3.new(3.5, 2.5, 2.5), color = Color3.fromRGB(180, 140, 50) },
  reinforced_trunk = { size = Vector3.new(4, 3, 3), color = Color3.fromRGB(100, 100, 110) },
  captains_vault = { size = Vector3.new(4.5, 3.5, 3.5), color = Color3.fromRGB(200, 170, 60) },
  cursed_chest = { size = Vector3.new(3.5, 2.5, 2.5), color = Color3.fromRGB(100, 40, 130) },
}

--[[
  Creates a placeholder container model at the given position.
  When MODEL-001 (3D models) is implemented, replace this with proper models.
  @param containerDef The container definition
  @param position World position
  @param instanceId Unique ID string
  @return The created Model
]]
local function createContainerModel(
  containerDef: GameConfig.ContainerDef,
  position: Vector3,
  instanceId: string
): Model
  local appearance = CONTAINER_APPEARANCE[containerDef.id]
    or { size = Vector3.new(3, 3, 3), color = Color3.fromRGB(139, 90, 43) }

  local model = Instance.new("Model")
  model.Name = "Container_" .. instanceId

  -- Main body part
  local body = Instance.new("Part")
  body.Name = "Body"
  body.Size = appearance.size
  body.Color = appearance.color
  body.Material = Enum.Material.Wood
  body.Anchored = true
  body.CanCollide = true
  body.CanQuery = true
  body.CanTouch = false
  body.CastShadow = true
  body.CFrame = CFrame.new(position + Vector3.new(0, appearance.size.Y / 2, 0))
  body.Parent = model

  model.PrimaryPart = body

  -- Store metadata as attributes
  body:SetAttribute("ContainerId", instanceId)
  body:SetAttribute("ContainerType", containerDef.id)
  body:SetAttribute("MaxHP", containerDef.hp)
  body:SetAttribute("CurrentHP", containerDef.hp)

  -- Cursed chest gets a purple glow visible through fog
  if containerDef.id == "cursed_chest" then
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(140, 60, 200)
    light.Brightness = 1.5
    light.Range = 30 -- visible through fog (~30 studs per spec)
    light.Parent = body

    -- Eerie particle effect
    local particles = Instance.new("ParticleEmitter")
    particles.Color = ColorSequence.new(Color3.fromRGB(140, 60, 200))
    particles.Size = NumberSequence.new(0.3, 0)
    particles.Lifetime = NumberRange.new(1, 2)
    particles.Rate = 5
    particles.Speed = NumberRange.new(0.5, 1)
    particles.SpreadAngle = Vector2.new(180, 180)
    particles.Transparency = NumberSequence.new(0.3, 1)
    particles.Parent = body
  end

  -- Captain's Vault gets a gold glow
  if containerDef.id == "captains_vault" then
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(255, 200, 50)
    light.Brightness = 1
    light.Range = 15
    light.Parent = body
  end

  model.Parent = ContainersFolder
  return model
end

--------------------------------------------------------------------------------
-- SPAWN POINT MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Returns all spawn point Parts from the workspace folder.
  @return Array of Parts
]]
local function getSpawnPoints(): { Part }
  if not SpawnPointsFolder then
    return {}
  end
  local points = {}
  for _, child in SpawnPointsFolder:GetChildren() do
    if child:IsA("BasePart") then
      table.insert(points, child)
    end
  end
  return points
end

--[[
  Returns all unoccupied spawn points.
  @param zoneFilter Optional zone filter — only return points in this zone
  @return Array of available spawn point Parts
]]
local function getAvailableSpawnPoints(zoneFilter: string?): { Part }
  local available = {}
  for _, point in getSpawnPoints() do
    if not OccupiedSpawnPoints[point] then
      if zoneFilter then
        local zone = point:GetAttribute("Zone") or ""
        if zone == zoneFilter then
          table.insert(available, point)
        end
      else
        table.insert(available, point)
      end
    end
  end
  return available
end

--------------------------------------------------------------------------------
-- SPAWN LOGIC
--------------------------------------------------------------------------------

--[[
  Spawns a single container at the given spawn point.
  @param spawnPoint The spawn point Part (or nil for manual spawns)
  @param containerDef The container type to spawn
  @param position The world position (used if spawnPoint is nil)
  @return The container entry, or nil if spawn failed
]]
local function spawnContainer(
  spawnPoint: Part?,
  containerDef: GameConfig.ContainerDef,
  position: Vector3?
): ContainerEntry?
  -- Enforce cap
  if ActiveContainerCount >= GameConfig.ContainerSystem.maxActiveContainers then
    return nil
  end

  local pos = position or (spawnPoint and spawnPoint.Position) or nil
  if not pos then
    return nil
  end

  local instanceId = tostring(nextContainerId)
  nextContainerId = nextContainerId + 1

  local isNight = DayNightService and DayNightService:IsNight() or false

  local model = createContainerModel(containerDef, pos, instanceId)

  local zone = ""
  if spawnPoint then
    zone = spawnPoint:GetAttribute("Zone") or ""
  end

  local entry: ContainerEntry = {
    id = instanceId,
    def = containerDef,
    hp = containerDef.hp,
    maxHp = containerDef.hp,
    model = model,
    position = pos,
    spawnPoint = spawnPoint,
    zone = zone,
    createdAt = os.clock(),
    isNightSpawn = isNight,
  }

  ActiveContainers[instanceId] = entry
  ActiveContainerCount = ActiveContainerCount + 1

  if spawnPoint then
    OccupiedSpawnPoints[spawnPoint] = true
  end

  -- Fire signals
  ContainerService.ContainerSpawned:Fire(entry)
  ContainerService.Client.ContainerSpawned:FireAll(instanceId, containerDef.id, pos)

  return entry
end

--[[
  Attempts to spawn a regular (non-cursed) container at a random available spawn point.
  Uses weighted random selection for container type.
]]
local function trySpawnRegularContainer()
  if ActiveContainerCount >= GameConfig.ContainerSystem.maxActiveContainers then
    return
  end

  -- Get available spawn points (exclude danger-zone-only filtering for regular spawns)
  local available = getAvailableSpawnPoints()
  if #available == 0 then
    return
  end

  -- Pick a random spawn point
  local point = available[math.random(1, #available)]
  local containerDef = pickRandomContainerType()

  spawnContainer(point, containerDef)
end

--[[
  Spawns Cursed Chests at danger zone spawn points for the current night.
  Called once when night begins.
]]
local function spawnCursedChests()
  local config = GameConfig.ContainerSystem.cursedChestsPerNight
  cursedChestTargetThisNight = math.random(config.min, config.max)
  cursedChestsSpawnedThisNight = 0

  local cursedDef = GameConfig.ContainerById["cursed_chest"]
  if not cursedDef then
    warn("[ContainerService] Cursed chest definition not found in GameConfig")
    return
  end

  -- Find danger zone spawn points
  local dangerPoints = getAvailableSpawnPoints("danger")
  if #dangerPoints == 0 then
    warn("[ContainerService] No available danger zone spawn points for Cursed Chests")
    return
  end

  -- Shuffle danger points
  for i = #dangerPoints, 2, -1 do
    local j = math.random(1, i)
    dangerPoints[i], dangerPoints[j] = dangerPoints[j], dangerPoints[i]
  end

  local toSpawn = math.min(cursedChestTargetThisNight, #dangerPoints)
  for i = 1, toSpawn do
    if ActiveContainerCount >= GameConfig.ContainerSystem.maxActiveContainers then
      break
    end
    local entry = spawnContainer(dangerPoints[i], cursedDef)
    if entry then
      cursedChestsSpawnedThisNight = cursedChestsSpawnedThisNight + 1
    end
  end

  print(
    string.format(
      "[ContainerService] Spawned %d/%d Cursed Chests for this night cycle",
      cursedChestsSpawnedThisNight,
      cursedChestTargetThisNight
    )
  )
end

--[[
  Removes all Cursed Chests (called at Dawn when night ends).
  Cursed Chests that weren't broken despawn without dropping loot.
]]
local function despawnCursedChests()
  -- Collect IDs first to avoid mutating ActiveContainers during iteration
  local toRemove = {}
  for id, entry in ActiveContainers do
    if entry.def.id == "cursed_chest" then
      table.insert(toRemove, id)
    end
  end
  for _, id in toRemove do
    ContainerService:RemoveContainer(id, false) -- no loot drop
  end
  if #toRemove > 0 then
    print(
      string.format("[ContainerService] Despawned %d remaining Cursed Chests at Dawn", #toRemove)
    )
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Deals damage to a container by its instance ID.
  Returns true if the container was destroyed, false otherwise.
  @param containerId The container instance ID
  @param damage The damage amount
  @param attackingPlayer The player who dealt the damage (for loot attribution)
  @return (destroyed: boolean, hpFraction: number?)
]]
function ContainerService:DamageContainer(
  containerId: string,
  damage: number,
  attackingPlayer: Player?
): (boolean, number?)
  local entry = ActiveContainers[containerId]
  if not entry then
    return false, nil
  end

  entry.hp = math.max(0, entry.hp - damage)
  local hpFraction = entry.hp / entry.maxHp

  -- Update attribute on model for debugging
  local body = entry.model and entry.model:FindFirstChild("Body")
  if body then
    body:SetAttribute("CurrentHP", entry.hp)
  end

  -- Notify clients of damage (for VFX states)
  ContainerService.Client.ContainerDamaged:FireAll(containerId, hpFraction)

  if entry.hp <= 0 then
    -- Container is destroyed — break it
    self:BreakContainer(containerId, attackingPlayer)
    return true, 0
  end

  return false, hpFraction
end

--[[
  Breaks a container, scattering doubloons and removing it from the world.
  @param containerId The container instance ID
  @param attackingPlayer The player who broke it (for signals/attribution)
]]
function ContainerService:BreakContainer(containerId: string, attackingPlayer: Player?)
  local entry = ActiveContainers[containerId]
  if not entry then
    return
  end

  -- Calculate yield
  local yieldMin = entry.def.yieldMin
  local yieldMax = entry.def.yieldMax
  local yield = math.random(yieldMin, yieldMax)

  -- Apply night yield multiplier: all containers broken during night yield 2x
  local isNight = DayNightService and DayNightService:IsNight() or false
  if isNight then
    yield = yield * GameConfig.ContainerSystem.nightYieldMultiplier
    yield = math.floor(yield)
  end

  -- Scatter doubloons
  if DoubloonService and yield > 0 then
    DoubloonService:ScatterDoubloons(entry.position, yield, entry.def.scatterRadius)
  end

  -- Cursed Chest ambush: 50% chance to spawn 1-2 ambush NPCs at break location
  local ambushCount = 0
  if entry.def.id == "cursed_chest" then
    if math.random() < GameConfig.ContainerSystem.cursedChestAmbushChance then
      local ambushConfig = GameConfig.ContainerSystem.cursedChestAmbushCount
      ambushCount = math.random(ambushConfig.min, ambushConfig.max)
      if NPCService then
        local ambushZone = if entry.zone ~= "" then entry.zone else "danger"
        NPCService:SpawnAmbushNPCs(entry.position, ambushCount, ambushZone)
      end
    end
  end

  -- Notify clients
  ContainerService.Client.ContainerBroken:FireAll(containerId, entry.def.id, entry.position)

  -- Fire server-side signal
  ContainerService.ContainerBroken:Fire(entry, attackingPlayer)

  -- Remove from world
  self:RemoveContainer(containerId, false)

  local ambushMsg = ""
  if ambushCount > 0 then
    ambushMsg = string.format(" (ambush! %d NPCs spawned)", ambushCount)
  end
  print(
    string.format(
      "[ContainerService] %s broken by %s — scattered %d doubloons%s",
      entry.def.name,
      attackingPlayer and attackingPlayer.Name or "unknown",
      yield,
      ambushMsg
    )
  )
end

--[[
  Removes a container from the world and frees its spawn point.
  @param containerId The container instance ID
  @param silent If true, skip client notification (used internally)
]]
function ContainerService:RemoveContainer(containerId: string, silent: boolean?)
  local entry = ActiveContainers[containerId]
  if not entry then
    return
  end

  -- Free spawn point
  if entry.spawnPoint then
    OccupiedSpawnPoints[entry.spawnPoint] = nil
  end

  -- Destroy model
  if entry.model and entry.model.Parent then
    entry.model:Destroy()
  end

  ActiveContainers[containerId] = nil
  ActiveContainerCount = ActiveContainerCount - 1
end

--[[
  Returns the container entry for a given instance ID.
  @param containerId The container instance ID
  @return ContainerEntry or nil
]]
function ContainerService:GetContainer(containerId: string): ContainerEntry?
  return ActiveContainers[containerId]
end

--[[
  Finds a container whose model Body is the given Part.
  Used for hit detection (raycast hits the body Part, we need the container ID).
  @param part The Part to look up
  @return ContainerEntry or nil
]]
function ContainerService:GetContainerByPart(part: Part): ContainerEntry?
  local containerId = part:GetAttribute("ContainerId")
  if containerId then
    return ActiveContainers[containerId]
  end
  return nil
end

--[[
  Returns the number of active containers.
]]
function ContainerService:GetActiveContainerCount(): number
  return ActiveContainerCount
end

--[[
  Spawns a container at a specific position (for events, testing, etc.).
  @param containerTypeId The container type ID from GameConfig
  @param position World position
  @return ContainerEntry or nil
]]
function ContainerService:SpawnContainerAt(
  containerTypeId: string,
  position: Vector3
): ContainerEntry?
  local def = GameConfig.ContainerById[containerTypeId]
  if not def then
    warn("[ContainerService] Unknown container type: " .. tostring(containerTypeId))
    return nil
  end
  return spawnContainer(nil, def, position)
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS (read-only)
--------------------------------------------------------------------------------

--[[
  Returns the current active container count.
]]
function ContainerService.Client:GetActiveContainerCount(_player: Player): number
  return ContainerService:GetActiveContainerCount()
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ContainerService:KnitInit()
  -- Create the workspace folder for container models
  ContainersFolder = Instance.new("Folder")
  ContainersFolder.Name = "Containers"
  ContainersFolder.Parent = workspace

  -- Look for spawn points folder (created by map builders)
  SpawnPointsFolder = workspace:FindFirstChild("ContainerSpawnPoints")
  if not SpawnPointsFolder then
    -- Create it so map builders know where to put spawn points
    SpawnPointsFolder = Instance.new("Folder")
    SpawnPointsFolder.Name = "ContainerSpawnPoints"
    SpawnPointsFolder.Parent = workspace
    warn(
      "[ContainerService] No ContainerSpawnPoints folder found in workspace. "
        .. "Created an empty one. Map builders should add Parts to this folder."
    )
  end

  print("[ContainerService] Initialized")
end

function ContainerService:KnitStart()
  DayNightService = Knit.GetService("DayNightService")
  DoubloonService = Knit.GetService("DoubloonService")
  NPCService = Knit.GetService("NPCService")

  -- Listen for day/night transitions
  DayNightService.PhaseChanged:Connect(function(newPhase: string, previousPhase: string)
    if newPhase == "Night" then
      -- Night started — spawn Cursed Chests
      spawnCursedChests()
    elseif newPhase == "Dawn" then
      -- Dawn — despawn remaining Cursed Chests
      despawnCursedChests()
    end
  end)

  -- Track night state for spawn rate multiplier
  lastNightPhase = DayNightService:IsNight()

  -- Rolling spawn timer loop
  RunService.Heartbeat:Connect(function(dt: number)
    spawnTimer = spawnTimer + dt

    -- Calculate effective spawn interval (faster at night)
    local isNight = DayNightService:IsNight()
    local interval = BASE_SPAWN_INTERVAL
    if isNight then
      interval = interval / GameConfig.ContainerSystem.nightSpawnRateMultiplier
    end

    if spawnTimer >= interval then
      spawnTimer = spawnTimer - interval
      trySpawnRegularContainer()
    end

    -- Track night transitions for runtime (backup to signal)
    lastNightPhase = isNight
  end)

  -- Spawn initial batch of containers so the map isn't empty on server start
  local initialSpawnCount = math.min(5, GameConfig.ContainerSystem.maxActiveContainers)
  for _ = 1, initialSpawnCount do
    trySpawnRegularContainer()
  end

  print(
    string.format(
      "[ContainerService] Started — %d initial containers spawned, %d spawn points found",
      ActiveContainerCount,
      #getSpawnPoints()
    )
  )
end

return ContainerService
