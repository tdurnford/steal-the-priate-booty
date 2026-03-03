--[[
  TutorialService.lua
  Server-authoritative tutorial sequence manager (TUTORIAL-001, TUTORIAL-002).

  Manages the 10-step "Shipwrecked" tutorial for new players:
    Step 1:  Spawn on tutorial beach, "Find something to defend yourself"
    Step 2:  Walk to glowing driftwood pickup, equip driftwood weapon
    Step 3:  Smash a tutorial crate (3 hits with driftwood)
    Step 4:  Collect scattered doubloons
    Step 5:  Fight and kill a weakened skeleton (5 HP)
    Step 6:  Navigate to the Harbor (compass marker, 1-2 path crates)
    Step 7:  Arrive at Harbor, deposit doubloons into ship
    Step 8:  Lock ship to secure treasure in treasury
    Step 9:  Visit the shop, equip the Rusty Cutlass (free), driftwood removed
    Step 10: Tutorial complete — full HUD appears, player released

  Tutorial players are in a soft safe zone — other players cannot attack them
  or steal from them. Tutorial NPCs/containers are scripted and separate from
  normal world spawns.

  Delegates:
    - SessionStateService for tutorial state (tutorialActive, tutorialStep)
    - DataService for persistent tutorialCompleted flag
    - GearService pattern for equipping driftwood
    - ContainerService for spawning tutorial crates
    - DoubloonService for detecting pickups
    - NPCService for spawning a weakened skeleton
    - HarborService for Harbor zone detection (step 6→7)
    - ShipService for deposit and lock events (steps 7→8, 8→9)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local Server = ServerScriptService:WaitForChild("Server")
local RateLimiter = require(Server:WaitForChild("RateLimiter"))

local TutorialService = Knit.CreateService({
  Name = "TutorialService",
  Client = {
    -- Fired to the tutorial player when step changes.
    -- Args: (step: number, message: string)
    TutorialStepChanged = Knit.CreateSignal(),

    -- Fired to the tutorial player when tutorial completes.
    TutorialCompleted = Knit.CreateSignal(),

    -- Fired to the tutorial player to show/clear a waypoint marker.
    -- Args: (position: Vector3?) — nil to clear
    TutorialWaypoint = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
TutorialService.TutorialStarted = Signal.new() -- (player)
TutorialService.TutorialFinished = Signal.new() -- (player)

-- Rate limiters for client-callable methods
local stateLimit = RateLimiter.new("TutorialService.GetTutorialState", 2.0)
local skipLimit = RateLimiter.new("TutorialService.SkipTutorial", 5.0)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local ContainerService = nil
local DoubloonService = nil
local NPCService = nil
local ShipService = nil
local HarborService = nil

--------------------------------------------------------------------------------
-- TUTORIAL CONFIG
--------------------------------------------------------------------------------

local TUTORIAL_CONFIG = GameConfig.Tutorial

-- Step messages displayed to the player
local STEP_MESSAGES = {
  [1] = "Find something to defend yourself...",
  [2] = "A driftwood club! That'll work.",
  [3] = "Smash the crate open!",
  [4] = "Grab the doubloons!",
  [5] = "Watch out! Hit it before it gets you!",
  [6] = "Get to the Harbor to claim your ship!",
  [7] = "This is your ship. Deposit your doubloons!",
  [8] = "Lock your ship to secure your treasure.",
  [9] = "Visit the shop to claim your Rusty Cutlass.",
  [10] = "You're on your own now, pirate. The island is watching.",
}

-- Default tutorial spawn position (MAP-002 will place a TutorialBeach part)
local DEFAULT_TUTORIAL_POSITION = Vector3.new(200, 10, 200)

-- Default harbor position (MAP-001 will place HarborSpawn / HarborZone parts)
local DEFAULT_HARBOR_POSITION = Vector3.new(0, 10, 0)

--------------------------------------------------------------------------------
-- PER-PLAYER TUTORIAL STATE
--------------------------------------------------------------------------------

type TutorialInstance = {
  player: Player,
  spawnPosition: Vector3,

  -- Entity references (cleaned up on completion or disconnect)
  driftwoodPickup: BasePart?, -- glowing Part the player walks to
  tutorialContainerId: string?, -- ContainerService container ID
  tutorialNPCId: number?, -- NPCService NPC ID
  harborBeacon: BasePart?, -- glowing beacon at Harbor for step 6
  pathCrateIds: { string }, -- ContainerService IDs for path crates

  -- Step tracking
  currentStep: number,
  stepAdvancePending: boolean, -- debounce for step transitions

  -- Connections (cleaned up on completion or disconnect)
  connections: { RBXScriptConnection },
}

local ActiveTutorials: { [Player]: TutorialInstance } = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Gets a suitable tutorial spawn position.
  Looks for a TutorialBeach part in workspace, falls back to default.
]]
local function getTutorialSpawnPosition(): Vector3
  local beach = workspace:FindFirstChild("TutorialBeach")
  if beach and beach:IsA("BasePart") then
    return beach.Position + Vector3.new(0, 3, 0)
  end
  return DEFAULT_TUTORIAL_POSITION
end

--[[
  Gets the forward direction at the tutorial spawn (toward the driftwood).
]]
local function getTutorialForwardDirection(spawnPos: Vector3): Vector3
  local beach = workspace:FindFirstChild("TutorialBeach")
  if beach and beach:IsA("BasePart") then
    return beach.CFrame.LookVector
  end
  return Vector3.new(0, 0, -1) -- default: face -Z
end

--[[
  Gets the Harbor target position for the compass waypoint.
]]
local function getHarborPosition(): Vector3
  local harborSpawn = workspace:FindFirstChild("HarborSpawn")
  if harborSpawn and harborSpawn:IsA("BasePart") then
    return harborSpawn.Position
  end
  local harborZone = workspace:FindFirstChild("HarborZone")
  if harborZone and harborZone:IsA("BasePart") then
    return harborZone.Position
  end
  return DEFAULT_HARBOR_POSITION
end

--[[
  Gets the shop trigger position for step 9 waypoint.
]]
local function getShopPosition(): Vector3
  local shopTrigger = workspace:FindFirstChild("ShopTrigger")
  if shopTrigger and shopTrigger:IsA("BasePart") then
    return shopTrigger.Position
  end
  -- Fallback: near the harbor position
  return getHarborPosition() + Vector3.new(20, 0, 0)
end

--[[
  Disconnects and clears all connections for a tutorial instance.
]]
local function cleanupConnections(instance: TutorialInstance)
  for _, conn in instance.connections do
    conn:Disconnect()
  end
  table.clear(instance.connections)
end

--[[
  Removes all tutorial entities for a player.
]]
local function cleanupEntities(instance: TutorialInstance)
  -- Remove driftwood pickup Part
  if instance.driftwoodPickup then
    instance.driftwoodPickup:Destroy()
    instance.driftwoodPickup = nil
  end

  -- Remove tutorial container (if it still exists)
  if instance.tutorialContainerId and ContainerService then
    pcall(function()
      ContainerService:RemoveContainer(instance.tutorialContainerId, false)
    end)
    instance.tutorialContainerId = nil
  end

  -- Despawn tutorial NPC (if still alive)
  if instance.tutorialNPCId and NPCService then
    pcall(function()
      NPCService:DespawnBonusNPC(instance.tutorialNPCId)
    end)
    instance.tutorialNPCId = nil
  end

  -- Remove harbor beacon
  if instance.harborBeacon then
    instance.harborBeacon:Destroy()
    instance.harborBeacon = nil
  end

  -- Remove path crates
  if instance.pathCrateIds then
    for _, crateId in instance.pathCrateIds do
      pcall(function()
        ContainerService:RemoveContainer(crateId, false)
      end)
    end
    table.clear(instance.pathCrateIds)
  end
end

--[[
  Creates a glowing driftwood pickup Part at the given position.
]]
local function createDriftwoodPickup(position: Vector3): BasePart
  local part = Instance.new("Part")
  part.Name = "TutorialDriftwood"
  part.Size = Vector3.new(0.5, 0.5, 3.5)
  part.BrickColor = BrickColor.new("Reddish brown")
  part.Material = Enum.Material.Wood
  part.Anchored = true
  part.CanCollide = false
  part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(15))

  -- Glow effect to attract the player
  local light = Instance.new("PointLight")
  light.Color = Color3.fromRGB(255, 220, 100)
  light.Brightness = 2
  light.Range = 12
  light.Parent = part

  -- Shimmer particles
  local particles = Instance.new("ParticleEmitter")
  particles.Color = ColorSequence.new(Color3.fromRGB(255, 220, 100))
  particles.Size = NumberSequence.new(0.2, 0)
  particles.Lifetime = NumberRange.new(0.5, 1)
  particles.Rate = 8
  particles.Speed = NumberRange.new(1, 2)
  particles.SpreadAngle = Vector2.new(180, 180)
  particles.LightEmission = 1
  particles.Parent = part

  -- Billboard prompt
  local billboard = Instance.new("BillboardGui")
  billboard.Size = UDim2.fromOffset(200, 50)
  billboard.StudsOffset = Vector3.new(0, 3, 0)
  billboard.AlwaysOnTop = true
  billboard.Parent = part

  local label = Instance.new("TextLabel")
  label.Size = UDim2.fromScale(1, 1)
  label.BackgroundTransparency = 1
  label.Text = "Pick Up"
  label.TextColor3 = Color3.fromRGB(255, 220, 100)
  label.Font = Enum.Font.FredokaOne
  label.TextSize = 18
  label.TextStrokeTransparency = 0.3
  label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
  label.Parent = billboard

  -- Put in a tutorial folder
  local folder = workspace:FindFirstChild("TutorialEntities")
  if not folder then
    folder = Instance.new("Folder")
    folder.Name = "TutorialEntities"
    folder.Parent = workspace
  end
  part.Parent = folder

  return part
end

--[[
  Creates a tall glowing beacon at the Harbor to guide the player during step 6.
  Visible from far away with particles and light.
]]
local function createHarborBeacon(position: Vector3): BasePart
  local beaconHeight = TUTORIAL_CONFIG.beaconHeight or 40

  local part = Instance.new("Part")
  part.Name = "TutorialHarborBeacon"
  part.Size = Vector3.new(2, beaconHeight, 2)
  part.BrickColor = BrickColor.new("Bright yellow")
  part.Material = Enum.Material.Neon
  part.Anchored = true
  part.CanCollide = false
  part.Transparency = 0.5
  part.CFrame = CFrame.new(position + Vector3.new(0, beaconHeight / 2, 0))

  -- Bright light visible from far away
  local light = Instance.new("PointLight")
  light.Color = Color3.fromRGB(255, 220, 100)
  light.Brightness = 4
  light.Range = 60
  light.Parent = part

  -- Upward particles for visibility
  local particles = Instance.new("ParticleEmitter")
  particles.Color = ColorSequence.new(Color3.fromRGB(255, 220, 100))
  particles.Size = NumberSequence.new(1, 0)
  particles.Lifetime = NumberRange.new(2, 4)
  particles.Rate = 15
  particles.Speed = NumberRange.new(5, 10)
  particles.SpreadAngle = Vector2.new(10, 10)
  particles.LightEmission = 1
  particles.EmissionDirection = Enum.NormalId.Top
  particles.Parent = part

  -- Billboard label
  local billboard = Instance.new("BillboardGui")
  billboard.Size = UDim2.fromOffset(250, 50)
  billboard.StudsOffset = Vector3.new(0, beaconHeight / 2 + 3, 0)
  billboard.AlwaysOnTop = true
  billboard.MaxDistance = 500
  billboard.Parent = part

  local label = Instance.new("TextLabel")
  label.Size = UDim2.fromScale(1, 1)
  label.BackgroundTransparency = 1
  label.Text = "Harbor"
  label.TextColor3 = Color3.fromRGB(255, 220, 100)
  label.Font = Enum.Font.FredokaOne
  label.TextSize = 24
  label.TextStrokeTransparency = 0.2
  label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
  label.Parent = billboard

  -- Put in tutorial folder
  local folder = workspace:FindFirstChild("TutorialEntities")
  if not folder then
    folder = Instance.new("Folder")
    folder.Name = "TutorialEntities"
    folder.Parent = workspace
  end
  part.Parent = folder

  return part
end

--[[
  Equips the driftwood weapon on a player via DataService + visual Tool.
  This bypasses the shop — driftwood is a tutorial-only item.
]]
local function equipDriftwood(player: Player)
  -- Add driftwood to owned gear and equip it
  local data = DataService:GetData(player)
  if not data then
    return
  end

  -- Add to owned if not already
  local hasDriftwood = false
  for _, id in data.ownedGear do
    if id == "driftwood" then
      hasDriftwood = true
      break
    end
  end
  if not hasDriftwood then
    table.insert(data.ownedGear, "driftwood")
  end

  -- Equip it
  DataService:EquipGear(player, "driftwood")

  -- Give the physical Tool (reuse GearService's pattern)
  -- We access the GearService's GearChanged signal to trigger the visual
  local GearService = Knit.GetService("GearService")
  if GearService then
    GearService.Client.GearChanged:Fire(player, "driftwood", "equipped")
    GearService.GearEquipped:Fire(player, "driftwood")
  end

  -- Create and give the tool directly (matching GearService's createGearTool pattern)
  local character = player.Character
  if not character then
    return
  end

  -- Remove any existing Cutlass tools
  for _, child in character:GetChildren() do
    if child:IsA("Tool") and child.Name == "Cutlass" then
      child:Destroy()
    end
  end
  local backpack = player:FindFirstChildOfClass("Backpack")
  if backpack then
    for _, child in backpack:GetChildren() do
      if child:IsA("Tool") and child.Name == "Cutlass" then
        child:Destroy()
      end
    end
  end

  local tool = Instance.new("Tool")
  tool.Name = "Cutlass"
  tool.CanBeDropped = false
  tool.RequiresHandle = true
  tool.ToolTip = "Driftwood Club"

  local handle = Instance.new("Part")
  handle.Name = "Handle"
  handle.Size = Vector3.new(0.3, 0.3, 3.5)
  handle.BrickColor = BrickColor.new("Reddish brown")
  handle.Material = Enum.Material.Wood
  handle.CanCollide = false
  handle.Massless = true
  handle.Parent = tool

  tool.Parent = character
end

--[[
  Removes driftwood from owned gear data.
]]
local function removeDriftwoodFromData(player: Player)
  local data = DataService:GetData(player)
  if not data then
    return
  end
  for i, id in data.ownedGear do
    if id == "driftwood" then
      table.remove(data.ownedGear, i)
      break
    end
  end
end

--------------------------------------------------------------------------------
-- STEP PROGRESSION
--------------------------------------------------------------------------------

-- Forward declaration: completeTutorial is defined below advanceStep but called
-- from the step 10 handler inside advanceStep.
local completeTutorial

--[[
  Advances the tutorial to the next step for a player.
  Handles spawning entities for the new step and notifying the client.
]]
local function advanceStep(instance: TutorialInstance, newStep: number)
  if instance.stepAdvancePending then
    return
  end
  instance.stepAdvancePending = true

  local player = instance.player
  instance.currentStep = newStep

  -- Update session state
  SessionStateService:SetTutorialStep(player, newStep)

  -- Notify client with step message
  local message = STEP_MESSAGES[newStep] or ""
  TutorialService.Client.TutorialStepChanged:Fire(player, newStep, message)

  -- Handle step-specific setup
  if newStep == 2 then
    -- Equip the driftwood weapon
    equipDriftwood(player)

    -- Brief pause to show "A driftwood club!" message, then advance to step 3
    task.delay(1.5, function()
      if ActiveTutorials[player] and ActiveTutorials[player].currentStep == 2 then
        -- Spawn the tutorial crate
        local forward = getTutorialForwardDirection(instance.spawnPosition)
        local cratePos = instance.spawnPosition + forward * TUTORIAL_CONFIG.crateDistance
        -- Ground the position
        cratePos = Vector3.new(cratePos.X, instance.spawnPosition.Y - 2, cratePos.Z)

        local containerEntry = ContainerService:SpawnContainerAt("crate", cratePos)
        if containerEntry then
          -- Override HP so it breaks in exactly tutorialCrateHits with driftwood (1 damage each)
          containerEntry.hp = TUTORIAL_CONFIG.tutorialCrateHits
          containerEntry.maxHp = TUTORIAL_CONFIG.tutorialCrateHits
          instance.tutorialContainerId = containerEntry.id
        end

        instance.stepAdvancePending = false
        advanceStep(instance, 3)
      end
    end)
    return
  elseif newStep == 5 then
    -- Spawn the weakened tutorial skeleton
    local forward = getTutorialForwardDirection(instance.spawnPosition)
    local skeletonPos = instance.spawnPosition + forward * 20 + Vector3.new(5, 0, 0)

    local npcEntry = NPCService:SpawnTutorialSkeleton(skeletonPos, player)
    if npcEntry then
      instance.tutorialNPCId = npcEntry.id
    end
  elseif newStep == 6 then
    -- Create a harbor beacon visible from the beach
    local harborPos = getHarborPosition()
    instance.harborBeacon = createHarborBeacon(harborPos)

    -- Send waypoint to client for compass indicator
    TutorialService.Client.TutorialWaypoint:Fire(player, harborPos)

    -- Spawn 1-2 crates along the path from beach to harbor
    local pathCrateCount = TUTORIAL_CONFIG.pathCrateCount or 2
    local beachPos = instance.spawnPosition
    for i = 1, pathCrateCount do
      local t = i / (pathCrateCount + 1) -- spread evenly between beach and harbor
      local cratePos = beachPos:Lerp(harborPos, t)
      -- Ground the crate
      cratePos = Vector3.new(cratePos.X, beachPos.Y - 2, cratePos.Z)
      -- Offset slightly to the side so they're not directly on the path
      cratePos = cratePos + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))

      local containerEntry = ContainerService:SpawnContainerAt("crate", cratePos)
      if containerEntry then
        containerEntry.hp = TUTORIAL_CONFIG.pathCrateHits or 2
        containerEntry.maxHp = TUTORIAL_CONFIG.pathCrateHits or 2
        table.insert(instance.pathCrateIds, containerEntry.id)
      end
    end
  elseif newStep == 7 then
    -- Clear the harbor beacon and waypoint
    if instance.harborBeacon then
      instance.harborBeacon:Destroy()
      instance.harborBeacon = nil
    end

    -- Send waypoint to player's ship position
    if ShipService then
      local shipPos = ShipService:GetShipPosition(player)
      if shipPos then
        TutorialService.Client.TutorialWaypoint:Fire(player, shipPos)
      end
    end
  elseif newStep == 8 then
    -- Keep waypoint at ship for lock action (same position as step 7)
    if ShipService then
      local shipPos = ShipService:GetShipPosition(player)
      if shipPos then
        TutorialService.Client.TutorialWaypoint:Fire(player, shipPos)
      end
    end
  elseif newStep == 9 then
    -- Clear ship waypoint, point to shop
    local shopPos = getShopPosition()
    TutorialService.Client.TutorialWaypoint:Fire(player, shopPos)
  elseif newStep == 10 then
    -- Clear all waypoints
    TutorialService.Client.TutorialWaypoint:Fire(player, nil)

    -- Brief celebration delay, then complete
    task.delay(3, function()
      if ActiveTutorials[player] then
        completeTutorial(instance)
      end
    end)
  end

  instance.stepAdvancePending = false
end

--[[
  Completes the tutorial for a player.
  Marks tutorial as done, cleans up driftwood, enables full gameplay.
]]
completeTutorial = function(instance: TutorialInstance)
  local player = instance.player

  -- Mark as complete in persistent data
  DataService:CompleteTutorial(player)

  -- Clear session state
  SessionStateService:CompleteTutorialSession(player)

  -- Remove driftwood from owned gear (if still present)
  removeDriftwoodFromData(player)

  -- If the player somehow still has driftwood equipped (skipped step 9),
  -- equip rusty cutlass as fallback
  local data = DataService:GetData(player)
  if data and data.equippedGear == "driftwood" then
    DataService:EquipGear(player, "rusty_cutlass")
    local GearService = Knit.GetService("GearService")
    if GearService then
      GearService.Client.GearChanged:Fire(player, "rusty_cutlass", "equipped")
      GearService.GearEquipped:Fire(player, "rusty_cutlass")
    end
  end

  -- Notify client
  TutorialService.Client.TutorialCompleted:Fire(player)

  -- Clear any remaining waypoint
  TutorialService.Client.TutorialWaypoint:Fire(player, nil)

  -- Clean up tutorial entities
  cleanupEntities(instance)
  cleanupConnections(instance)
  ActiveTutorials[player] = nil

  -- If player is NOT already in the Harbor (e.g. skipped tutorial), teleport them
  if HarborService and not HarborService:IsInHarbor(player) then
    task.defer(function()
      local character = player.Character
      if character then
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if hrp then
          local harborSpawn = workspace:FindFirstChild("HarborSpawn")
          if harborSpawn and harborSpawn:IsA("BasePart") then
            hrp.CFrame = harborSpawn.CFrame + Vector3.new(0, 3, 0)
          else
            hrp.CFrame = CFrame.new(DEFAULT_HARBOR_POSITION)
          end
        end
      end
    end)
  end

  -- Fire server-side signal
  TutorialService.TutorialFinished:Fire(player)

  print(string.format("[TutorialService] Tutorial completed for %s", player.Name))
end

--------------------------------------------------------------------------------
-- TUTORIAL STARTUP
--------------------------------------------------------------------------------

--[[
  Starts the tutorial sequence for a new player.
  Called when a player joins with tutorialCompleted = false.
]]
function TutorialService:StartTutorial(player: Player)
  if ActiveTutorials[player] then
    return -- already in tutorial
  end

  local spawnPos = getTutorialSpawnPosition()

  local instance: TutorialInstance = {
    player = player,
    spawnPosition = spawnPos,
    driftwoodPickup = nil,
    tutorialContainerId = nil,
    tutorialNPCId = nil,
    harborBeacon = nil,
    pathCrateIds = {},
    currentStep = 0,
    stepAdvancePending = false,
    connections = {},
  }

  ActiveTutorials[player] = instance

  -- Wait for character to load
  local character = player.Character
  if not character then
    character = player.CharacterAdded:Wait()
  end

  -- Wait a frame for character to be fully set up
  task.wait()

  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    -- Character may not be fully loaded yet, wait briefly
    task.wait(0.5)
    hrp = character:FindFirstChild("HumanoidRootPart")
  end

  -- Teleport to tutorial beach
  if hrp then
    hrp.CFrame = CFrame.new(spawnPos)
  end

  -- Create the driftwood pickup
  local forward = getTutorialForwardDirection(spawnPos)
  local driftwoodPos = spawnPos + forward * TUTORIAL_CONFIG.driftwoodDistance
  -- Ground it slightly below spawn
  driftwoodPos = Vector3.new(driftwoodPos.X, spawnPos.Y - 2, driftwoodPos.Z)

  local driftwoodPart = createDriftwoodPickup(driftwoodPos)
  instance.driftwoodPickup = driftwoodPart

  -- Set up proximity detection for driftwood pickup
  local pickupRadius = 4 -- studs
  local pickupCheckConn = RunService.Heartbeat:Connect(function()
    if not instance.driftwoodPickup then
      return
    end
    if instance.currentStep ~= 1 then
      return
    end

    local char = player.Character
    if not char then
      return
    end
    local playerHRP = char:FindFirstChild("HumanoidRootPart")
    if not playerHRP then
      return
    end

    local dist = (playerHRP.Position - driftwoodPart.Position).Magnitude
    if dist <= pickupRadius then
      -- Player reached the driftwood!
      -- Remove the pickup Part
      driftwoodPart:Destroy()
      instance.driftwoodPickup = nil

      advanceStep(instance, 2)
    end
  end)
  table.insert(instance.connections, pickupCheckConn)

  -- Listen for container breaks (step 3→4)
  -- ContainerBroken fires (containerEntry, attackingPlayer)
  local containerBreakConn = ContainerService.ContainerBroken:Connect(
    function(containerEntry, attackingPlayer)
      if attackingPlayer ~= player then
        return
      end
      if instance.currentStep ~= 3 then
        return
      end
      if containerEntry and containerEntry.id == instance.tutorialContainerId then
        instance.tutorialContainerId = nil
        -- Brief delay for doubloons to scatter visually
        task.delay(0.5, function()
          if ActiveTutorials[player] and ActiveTutorials[player].currentStep == 3 then
            advanceStep(instance, 4)
          end
        end)
      end
    end
  )
  table.insert(instance.connections, containerBreakConn)

  -- Listen for doubloon pickup (step 4→5)
  local stateChangedConn = SessionStateService.StateChanged:Connect(
    function(changedPlayer, field, value)
      if changedPlayer ~= player then
        return
      end
      if instance.currentStep ~= 4 then
        return
      end
      if field == "heldDoubloons" and value > 0 then
        advanceStep(instance, 5)
      end
    end
  )
  table.insert(instance.connections, stateChangedConn)

  -- Listen for NPC death (step 5→6)
  -- NPCDied fires (npcEntry, killedByPlayer) where npcEntry has .id
  local npcKillConn = NPCService.NPCDied:Connect(function(npcEntry, killedByPlayer)
    if killedByPlayer ~= player then
      return
    end
    if instance.currentStep ~= 5 then
      return
    end
    if npcEntry and npcEntry.id == instance.tutorialNPCId then
      instance.tutorialNPCId = nil

      -- Brief delay for death animation, then advance to step 6
      task.delay(1.5, function()
        if ActiveTutorials[player] then
          advanceStep(instance, 6)
        end
      end)
    end
  end)
  table.insert(instance.connections, npcKillConn)

  -- Listen for Harbor entry (step 6→7)
  if HarborService then
    local harborEntryConn = HarborService.PlayerEnteredHarbor:Connect(function(enteredPlayer)
      if enteredPlayer ~= player then
        return
      end
      if instance.currentStep ~= 6 then
        return
      end
      advanceStep(instance, 7)
    end)
    table.insert(instance.connections, harborEntryConn)
  end

  -- Listen for deposit (step 7→8)
  if ShipService then
    local depositConn = ShipService.DepositCompleted:Connect(
      function(depositPlayer, _amount, _newHold)
        if depositPlayer ~= player then
          return
        end
        if instance.currentStep ~= 7 then
          return
        end
        -- Brief delay for feedback
        task.delay(0.5, function()
          if ActiveTutorials[player] and ActiveTutorials[player].currentStep == 7 then
            advanceStep(instance, 8)
          end
        end)
      end
    )
    table.insert(instance.connections, depositConn)
  end

  -- Listen for lock (step 8→9)
  if ShipService then
    local lockConn = ShipService.LockCompleted:Connect(function(lockPlayer, _amount, _newTreasury)
      if lockPlayer ~= player then
        return
      end
      if instance.currentStep ~= 8 then
        return
      end
      -- Brief delay for feedback
      task.delay(0.5, function()
        if ActiveTutorials[player] and ActiveTutorials[player].currentStep == 8 then
          advanceStep(instance, 9)
        end
      end)
    end)
    table.insert(instance.connections, lockConn)
  end

  -- Listen for gear equip of rusty_cutlass (step 9→10)
  local GearService = Knit.GetService("GearService")
  if GearService then
    local gearConn = GearService.GearEquipped:Connect(function(equipPlayer, gearId)
      if equipPlayer ~= player then
        return
      end
      if instance.currentStep ~= 9 then
        return
      end
      if gearId == "rusty_cutlass" then
        -- Remove driftwood from owned gear
        removeDriftwoodFromData(player)

        -- Brief delay for feedback
        task.delay(0.5, function()
          if ActiveTutorials[player] and ActiveTutorials[player].currentStep == 9 then
            advanceStep(instance, 10)
          end
        end)
      end
    end)
    table.insert(instance.connections, gearConn)
  end

  -- Fire server-side signal
  TutorialService.TutorialStarted:Fire(player)

  -- Begin step 1
  advanceStep(instance, 1)

  print(string.format("[TutorialService] Tutorial started for %s", player.Name))
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Checks if a player is currently in the tutorial.
  Used by CombatService and others for tutorial protection.
]]
function TutorialService:IsInTutorial(player: Player): boolean
  return ActiveTutorials[player] ~= nil
end

--[[
  Checks if an NPC is a tutorial NPC (should not count toward budgets, etc).
]]
function TutorialService:IsTutorialNPC(npcId: number): boolean
  for _, instance in ActiveTutorials do
    if instance.tutorialNPCId == npcId then
      return true
    end
  end
  return false
end

--[[
  Checks if a container is a tutorial container.
]]
function TutorialService:IsTutorialContainer(containerId: string): boolean
  for _, instance in ActiveTutorials do
    if instance.tutorialContainerId == containerId then
      return true
    end
    -- Also check path crates
    for _, crateId in instance.pathCrateIds do
      if crateId == containerId then
        return true
      end
    end
  end
  return false
end

--[[
  Client method to check tutorial state.
]]
function TutorialService.Client:GetTutorialState(player: Player): { active: boolean, step: number }
  if not stateLimit:check(player) then
    return { active = false, step = 0 }
  end
  local instance = ActiveTutorials[player]
  if instance then
    return { active = true, step = instance.currentStep }
  end
  return { active = false, step = 0 }
end

--[[
  Skip tutorial (for testing or if player wants to skip).
]]
function TutorialService.Client:SkipTutorial(player: Player): boolean
  if not skipLimit:check(player) then
    return false
  end
  local instance = ActiveTutorials[player]
  if not instance then
    return false
  end
  completeTutorial(instance)
  return true
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function TutorialService:KnitInit()
  -- Create workspace folder for tutorial entities
  local folder = Instance.new("Folder")
  folder.Name = "TutorialEntities"
  folder.Parent = workspace

  print("[TutorialService] Initialized")
end

function TutorialService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DataService = Knit.GetService("DataService")
  ContainerService = Knit.GetService("ContainerService")
  DoubloonService = Knit.GetService("DoubloonService")
  NPCService = Knit.GetService("NPCService")
  ShipService = Knit.GetService("ShipService")
  HarborService = Knit.GetService("HarborService")

  -- Start tutorial for new players when their data loads
  DataService.PlayerDataLoaded:Connect(function(player: Player, data)
    if data and not data.tutorialCompleted then
      -- Defer to next frame so all services are fully ready
      task.defer(function()
        self:StartTutorial(player)
      end)
    end
  end)

  -- Clean up on disconnect
  Players.PlayerRemoving:Connect(function(player: Player)
    local instance = ActiveTutorials[player]
    if instance then
      cleanupEntities(instance)
      cleanupConnections(instance)
      ActiveTutorials[player] = nil
      print(string.format("[TutorialService] Cleaned up tutorial for disconnected %s", player.Name))
    end
  end)

  -- Handle players already in game (studio edge case)
  for _, player in Players:GetPlayers() do
    if DataService:IsDataLoaded(player) then
      local data = DataService:GetData(player)
      if data and not data.tutorialCompleted then
        task.defer(function()
          self:StartTutorial(player)
        end)
      end
    end
  end

  print("[TutorialService] Started")
end

return TutorialService
