--[[
  DoubloonService.lua
  Server-authoritative doubloon pickup entity management.

  Handles:
    - Scattering doubloon pickups on the ground (from container breaks, PvP spills, NPC drops, disconnects)
    - Proximity-based auto-collection when players walk near pickups
    - 15-second despawn timer per pickup
    - Global 200 loose pickup cap (oldest removed first)
    - Client signals for collection VFX/SFX feedback

  Other services call ScatterDoubloons(position, amount, scatterRadius) to spawn pickups.
  Players auto-collect pickups by walking within GameConfig.Pickups.pickupRadius (4 studs).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local DoubloonService = Knit.CreateService({
  Name = "DoubloonService",
  Client = {
    -- Fired to a player when they collect a pickup.
    -- Args: (pickupPosition: Vector3, amount: number)
    DoubloonCollected = Knit.CreateSignal(),
  },
})

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local RankEffectsService = nil

-- Server-side signal: fired when doubloons are collected by a player.
-- Args: (player: Player, amount: number, position: Vector3)
DoubloonService.DoubloonCollected = Signal.new()

--------------------------------------------------------------------------------
-- PICKUP REGISTRY
--------------------------------------------------------------------------------

-- Each pickup entry: { part: Part, value: number, createdAt: number, position: Vector3 }
local ActivePickups: { { part: Part, value: number, createdAt: number, position: Vector3 } } = {}

-- Incrementing ID for unique pickup naming
local nextPickupId = 1

-- Folder in workspace to hold all pickup parts
local PickupsFolder: Folder = nil

-- Pickup collection check interval (seconds). Checks every ~0.1s instead of every frame.
local COLLECTION_CHECK_INTERVAL = 0.1
local collectionTimer = 0

-- Config references (cached at start)
local DESPAWN_TIME = GameConfig.Pickups.despawnTime
local MAX_LOOSE_PICKUPS = GameConfig.Pickups.maxLoosePickups
local PICKUP_RADIUS = GameConfig.Pickups.pickupRadius
local PICKUP_RADIUS_SQ = PICKUP_RADIUS * PICKUP_RADIUS

-- Target number of individual pickup entities per scatter event
local MIN_PICKUPS_PER_SCATTER = 3
local MAX_PICKUPS_PER_SCATTER = 15

--------------------------------------------------------------------------------
-- PICKUP ENTITY CREATION
--------------------------------------------------------------------------------

--[[
  Creates a single doubloon pickup part in workspace.
  @param position The world position to place the pickup
  @param value The doubloon value this pickup represents
  @return The created Part
]]
local function createPickupPart(position: Vector3, value: number): Part
  local part = Instance.new("Part")
  part.Name = "DoubloonPickup_" .. nextPickupId
  nextPickupId = nextPickupId + 1

  -- Small gold coin appearance
  part.Shape = Enum.PartType.Cylinder
  part.Size = Vector3.new(0.2, 1.0, 1.0)
  -- Rotate so the flat face is up (cylinder axis along X by default)
  part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
  part.Color = Color3.fromRGB(255, 200, 50) -- Gold
  part.Material = Enum.Material.SmoothPlastic
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = false

  -- Gold glow
  local light = Instance.new("PointLight")
  light.Color = Color3.fromRGB(255, 200, 50)
  light.Brightness = 0.5
  light.Range = 6
  light.Parent = part

  -- Store the value as an attribute for debugging
  part:SetAttribute("DoubloonValue", value)

  part.Parent = PickupsFolder
  return part
end

--------------------------------------------------------------------------------
-- SCATTER LOGIC
--------------------------------------------------------------------------------

--[[
  Splits a total doubloon amount into individual pickup values.
  Targets MIN_PICKUPS_PER_SCATTER to MAX_PICKUPS_PER_SCATTER entities per scatter.
  @param totalAmount The total doubloons to scatter
  @return Array of individual pickup values that sum to totalAmount
]]
local function splitIntoPickups(totalAmount: number): { number }
  if totalAmount <= 0 then
    return {}
  end

  -- For very small amounts, one pickup per doubloon
  if totalAmount <= MIN_PICKUPS_PER_SCATTER then
    local values = {}
    for _ = 1, totalAmount do
      table.insert(values, 1)
    end
    return values
  end

  -- Target count: scale with amount but clamp to range
  local targetCount =
    math.clamp(math.ceil(totalAmount / 10), MIN_PICKUPS_PER_SCATTER, MAX_PICKUPS_PER_SCATTER)

  local baseValue = math.floor(totalAmount / targetCount)
  local remainder = totalAmount - (baseValue * targetCount)

  local values = {}
  for i = 1, targetCount do
    local v = baseValue
    -- Distribute remainder across first N pickups
    if i <= remainder then
      v = v + 1
    end
    table.insert(values, v)
  end

  return values
end

--[[
  Generates a random position within a scatter radius around a center point.
  Pickups land on a slight Y offset above ground level.
  @param center The center position
  @param radius The scatter radius in studs
  @return A scattered position
]]
local function randomScatterPosition(center: Vector3, radius: number): Vector3
  local angle = math.random() * math.pi * 2
  local dist = math.random() * radius
  local offsetX = math.cos(angle) * dist
  local offsetZ = math.sin(angle) * dist
  -- Place slightly above ground to be visible
  return Vector3.new(center.X + offsetX, center.Y + 0.5, center.Z + offsetZ)
end

--[[
  Enforces the global pickup cap by removing the oldest pickups first.
  @param headroom How many slots to free up beyond the cap
]]
local function enforcePickupCap(headroom: number)
  local limit = MAX_LOOSE_PICKUPS - headroom
  while #ActivePickups > limit do
    local oldest = table.remove(ActivePickups, 1)
    if oldest and oldest.part and oldest.part.Parent then
      oldest.part:Destroy()
    end
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Scatters doubloon pickups on the ground at the given position.
  This is the primary entry point for other services.

  @param position The center position to scatter around
  @param amount The total doubloons to scatter (must be > 0)
  @param scatterRadius The radius in studs to spread pickups (default 4)
  @return The number of pickup entities created
]]
function DoubloonService:ScatterDoubloons(
  position: Vector3,
  amount: number,
  scatterRadius: number?
): number
  if amount <= 0 then
    return 0
  end

  local radius = scatterRadius or 4
  local pickupValues = splitIntoPickups(amount)
  local numPickups = #pickupValues

  -- Enforce cap before adding new pickups
  enforcePickupCap(numPickups)

  local now = os.clock()
  for _, value in pickupValues do
    local pos = randomScatterPosition(position, radius)
    local part = createPickupPart(pos, value)
    table.insert(ActivePickups, {
      part = part,
      value = value,
      createdAt = now,
      position = pos,
    })
  end

  return numPickups
end

--[[
  Returns the current number of active pickup entities.
]]
function DoubloonService:GetActivePickupCount(): number
  return #ActivePickups
end

--------------------------------------------------------------------------------
-- DESPAWN LOGIC
--------------------------------------------------------------------------------

--[[
  Removes pickups that have exceeded their despawn time.
  Called every collection check cycle.
]]
local function despawnExpired()
  local now = os.clock()
  local i = 1
  while i <= #ActivePickups do
    local pickup = ActivePickups[i]
    if (now - pickup.createdAt) >= DESPAWN_TIME then
      if pickup.part and pickup.part.Parent then
        pickup.part:Destroy()
      end
      table.remove(ActivePickups, i)
      -- Don't increment i; the next element shifted into this index
    else
      i = i + 1
    end
  end
end

--------------------------------------------------------------------------------
-- COLLECTION LOGIC
--------------------------------------------------------------------------------

--[[
  Checks all active players against all active pickups for proximity collection.
  Uses squared distance to avoid sqrt for performance.
  Per-player pickup radius accounts for Rank 5 bonus (+10%).
]]
local function checkCollections()
  if #ActivePickups == 0 then
    return
  end

  local players = Players:GetPlayers()
  -- Build a list of player positions for this frame (with per-player radius)
  local playerPositions: { { player: Player, position: Vector3, radiusSq: number } } = {}
  for _, player in players do
    local character = player.Character
    if character then
      local rootPart = character:FindFirstChild("HumanoidRootPart")
      if rootPart then
        -- Get per-player pickup radius (includes rank bonus if applicable)
        local radius = PICKUP_RADIUS
        if RankEffectsService then
          radius = RankEffectsService:GetPickupRadius(player)
        end
        table.insert(playerPositions, {
          player = player,
          position = rootPart.Position,
          radiusSq = radius * radius,
        })
      end
    end
  end

  if #playerPositions == 0 then
    return
  end

  -- Check each pickup against each player
  local i = 1
  while i <= #ActivePickups do
    local pickup = ActivePickups[i]
    local collected = false

    for _, pdata in playerPositions do
      local dx = pdata.position.X - pickup.position.X
      local dz = pdata.position.Z - pickup.position.Z
      local distSq = dx * dx + dz * dz

      if distSq <= pdata.radiusSq then
        -- Collect this pickup
        if SessionStateService then
          SessionStateService:AddHeldDoubloons(pdata.player, pickup.value)
        end

        -- Notify client for VFX/SFX
        DoubloonService.Client.DoubloonCollected:Fire(pdata.player, pickup.position, pickup.value)

        -- Fire server-side signal
        DoubloonService.DoubloonCollected:Fire(pdata.player, pickup.value, pickup.position)

        -- Destroy the pickup part
        if pickup.part and pickup.part.Parent then
          pickup.part:Destroy()
        end
        table.remove(ActivePickups, i)
        collected = true
        break -- This pickup is consumed; move to next pickup
      end
    end

    if not collected then
      i = i + 1
    end
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DoubloonService:KnitInit()
  -- Create the workspace folder for pickup entities
  PickupsFolder = Instance.new("Folder")
  PickupsFolder.Name = "Pickups"
  PickupsFolder.Parent = workspace

  print("[DoubloonService] Initialized")
end

function DoubloonService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DataService = Knit.GetService("DataService")
  RankEffectsService = Knit.GetService("RankEffectsService")

  -- Connect to disconnect doubloon spill signal
  DataService.DisconnectDoubloonSpill:Connect(
    function(player: Player, amount: number, position: Vector3)
      local scatterRadius = 4
      local created = self:ScatterDoubloons(position, amount, scatterRadius)
      print(
        "[DoubloonService] Scattered",
        amount,
        "doubloons (" .. created .. " pickups) for disconnecting player",
        player.Name
      )
    end
  )

  -- Heartbeat loop for despawning and collection
  RunService.Heartbeat:Connect(function(dt: number)
    collectionTimer = collectionTimer + dt
    if collectionTimer >= COLLECTION_CHECK_INTERVAL then
      collectionTimer = collectionTimer - COLLECTION_CHECK_INTERVAL
      despawnExpired()
      checkCollections()
    end
  end)

  print("[DoubloonService] Started")
end

return DoubloonService
