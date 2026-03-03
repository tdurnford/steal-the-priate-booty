--[[
  TutorialService.lua
  Server-authoritative tutorial sequence manager (TUTORIAL-001).

  Manages the 5-step "Shipwrecked" tutorial for new players:
    Step 1: Spawn on tutorial beach, "Find something to defend yourself"
    Step 2: Walk to glowing driftwood pickup, equip driftwood weapon
    Step 3: Smash a tutorial crate (3 hits with driftwood)
    Step 4: Collect scattered doubloons
    Step 5: Fight and kill a weakened skeleton (5 HP)

  Tutorial players are in a soft safe zone — other players cannot attack them
  or steal from them. Tutorial NPCs/containers are scripted and separate from
  normal world spawns.

  Delegates:
    - SessionStateService for tutorial state (tutorialActive, tutorialStep)
    - DataService for persistent tutorialCompleted flag
    - GearService pattern for equipping driftwood
    - ContainerService for spawning a tutorial crate
    - DoubloonService for detecting pickups
    - NPCService for spawning a weakened skeleton
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local TutorialService = Knit.CreateService({
  Name = "TutorialService",
  Client = {
    -- Fired to the tutorial player when step changes.
    -- Args: (step: number, message: string)
    TutorialStepChanged = Knit.CreateSignal(),

    -- Fired to the tutorial player when tutorial completes.
    TutorialCompleted = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
TutorialService.TutorialStarted = Signal.new() -- (player)
TutorialService.TutorialFinished = Signal.new() -- (player)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DataService = nil
local ContainerService = nil
local DoubloonService = nil
local NPCService = nil

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
}

-- Default tutorial spawn position (MAP-002 will place a TutorialBeach part)
local DEFAULT_TUTORIAL_POSITION = Vector3.new(200, 10, 200)

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
    local ok = pcall(function()
      ContainerService:RemoveContainer(instance.tutorialContainerId, false)
    end)
    if not ok then
      -- Container may have already been broken — that's fine
    end
    instance.tutorialContainerId = nil
  end

  -- Despawn tutorial NPC (if still alive)
  if instance.tutorialNPCId and NPCService then
    pcall(function()
      NPCService:DespawnBonusNPC(instance.tutorialNPCId)
    end)
    instance.tutorialNPCId = nil
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

--------------------------------------------------------------------------------
-- STEP PROGRESSION
--------------------------------------------------------------------------------

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
  end

  instance.stepAdvancePending = false
end

--[[
  Completes the tutorial for a player.
  Awards the rusty cutlass, marks tutorial as done, teleports to Harbor.
]]
local function completeTutorial(instance: TutorialInstance)
  local player = instance.player

  -- Mark as complete in persistent data
  DataService:CompleteTutorial(player)

  -- Clear session state
  SessionStateService:CompleteTutorialSession(player)

  -- Replace driftwood with rusty cutlass
  local data = DataService:GetData(player)
  if data then
    -- Remove driftwood from owned gear
    for i, id in data.ownedGear do
      if id == "driftwood" then
        table.remove(data.ownedGear, i)
        break
      end
    end
    -- Equip rusty cutlass (should already be owned from defaults)
    DataService:EquipGear(player, "rusty_cutlass")
  end

  -- Give rusty cutlass tool
  local GearService = Knit.GetService("GearService")
  if GearService then
    GearService.Client.GearChanged:Fire(player, "rusty_cutlass", "equipped")
    GearService.GearEquipped:Fire(player, "rusty_cutlass")
  end

  -- Notify client
  TutorialService.Client.TutorialCompleted:Fire(player)

  -- Clean up tutorial entities
  cleanupEntities(instance)
  cleanupConnections(instance)
  ActiveTutorials[player] = nil

  -- Teleport to Harbor spawn
  task.defer(function()
    local character = player.Character
    if character then
      local hrp = character:FindFirstChild("HumanoidRootPart")
      if hrp then
        local harborSpawn = workspace:FindFirstChild("HarborSpawn")
        if harborSpawn and harborSpawn:IsA("BasePart") then
          hrp.CFrame = harborSpawn.CFrame + Vector3.new(0, 3, 0)
        else
          -- Default harbor position
          hrp.CFrame = CFrame.new(0, 10, 0)
        end
      end
    end
  end)

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

  -- Listen for NPC death (step 5→complete)
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

      -- Brief delay for death animation
      task.delay(1.5, function()
        if ActiveTutorials[player] then
          completeTutorial(instance)
        end
      end)
    end
  end)
  table.insert(instance.connections, npcKillConn)

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
  end
  return false
end

--[[
  Client method to check tutorial state.
]]
function TutorialService.Client:GetTutorialState(player: Player): { active: boolean, step: number }
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
