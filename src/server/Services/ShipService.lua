--[[
  ShipService.lua
  Server-authoritative ship dock and spawn system.

  Handles:
    - Spawning player ships at dock slots on join
    - Ship tier calculation from treasury balance
    - Dock slot assignment and tracking (max 24)
    - 30-second delayed despawn after player leaves
    - Grace-save of ship hold doubloons before despawn
    - Ship tier upgrades/downgrades when treasury changes
    - Deposit mechanic: held doubloons → ship hold, threat reduction
    - Lock mechanic: ship hold → treasury, threat reset, auto-unlock on Harbor exit
    - Client signals for ship spawn/despawn/tier change/deposit/lock events

  Dock slots are defined as Parts in workspace.ShipDockPoints.
  Each dock slot Part should have:
    - Attribute "SlotIndex" (number): unique slot identifier (1-24)

  Other services call:
    - GetDockedShip(player) to get ship entry for a player
    - GetShipAtDock(slotIndex) to find which ship is at a dock
    - GetShipOwner(slotIndex) to find who owns a ship at a dock
    - RecalculateShipTier(player) when treasury changes
    - UnlockShip(player) when player exits Harbor zone (HARBOR-001)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local ShipService = Knit.CreateService({
  Name = "ShipService",
  Client = {
    -- Fired to ALL players when a ship spawns at a dock.
    -- Args: (slotIndex: number, ownerUserId: number, ownerName: string, shipTierId: string, position: Vector3)
    ShipSpawned = Knit.CreateSignal(),
    -- Fired to ALL players when a ship despawns from a dock.
    -- Args: (slotIndex: number, ownerUserId: number)
    ShipDespawned = Knit.CreateSignal(),
    -- Fired to ALL players when a ship tier changes.
    -- Args: (slotIndex: number, ownerUserId: number, newShipTierId: string)
    ShipTierChanged = Knit.CreateSignal(),
    -- Fired to the depositing player on successful deposit.
    -- Args: (slotIndex: number, amountDeposited: number, newShipHold: number)
    DepositCompleted = Knit.CreateSignal(),
    -- Fired to the locking player on successful lock.
    -- Args: (slotIndex: number, amountLocked: number, newTreasury: number)
    LockCompleted = Knit.CreateSignal(),
    -- Fired to a player when their ship is unlocked (e.g. leaving Harbor).
    -- Args: (slotIndex: number)
    ShipUnlocked = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
ShipService.ShipSpawned = Signal.new() -- (shipEntry)
ShipService.ShipDespawned = Signal.new() -- (shipEntry)
ShipService.ShipTierChanged = Signal.new() -- (shipEntry, oldTierId, newTierId)
ShipService.DepositCompleted = Signal.new() -- (player, amountDeposited, newShipHold)
ShipService.LockCompleted = Signal.new() -- (player, amountLocked, newTreasury)
ShipService.ShipUnlocked = Signal.new() -- (player)

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil
local SessionStateService = nil

--------------------------------------------------------------------------------
-- SHIP APPEARANCE (placeholder models — simple colored boxes per tier)
--------------------------------------------------------------------------------

local SHIP_APPEARANCE = {
  rowboat = {
    size = Vector3.new(6, 2, 10),
    color = Color3.fromRGB(139, 90, 43),
    material = Enum.Material.Wood,
  },
  sloop = {
    size = Vector3.new(8, 4, 16),
    color = Color3.fromRGB(160, 100, 50),
    material = Enum.Material.Wood,
  },
  schooner = {
    size = Vector3.new(10, 5, 20),
    color = Color3.fromRGB(130, 80, 40),
    material = Enum.Material.Wood,
  },
  brigantine = {
    size = Vector3.new(12, 6, 24),
    color = Color3.fromRGB(100, 70, 35),
    material = Enum.Material.Wood,
  },
  galleon = {
    size = Vector3.new(14, 8, 30),
    color = Color3.fromRGB(80, 55, 30),
    material = Enum.Material.Wood,
  },
  war_galleon = {
    size = Vector3.new(16, 9, 34),
    color = Color3.fromRGB(60, 40, 25),
    material = Enum.Material.Wood,
  },
  ghost_ship = {
    size = Vector3.new(16, 9, 34),
    color = Color3.fromRGB(120, 140, 180),
    material = Enum.Material.Neon,
  },
}

--------------------------------------------------------------------------------
-- SHIP REGISTRY
--------------------------------------------------------------------------------

type ShipEntry = {
  slotIndex: number,
  owner: Player,
  ownerUserId: number,
  ownerName: string,
  shipTierId: string,
  shipTierNumber: number,
  model: Model,
  position: Vector3,
  dockPoint: Part,
  createdAt: number,
}

-- Active docked ships keyed by player
local DockedShips: { [Player]: ShipEntry } = {}

-- Dock slot occupation: slotIndex → ShipEntry
local DockSlotOccupancy: { [number]: ShipEntry } = {}

-- Pending despawn tasks for disconnected players: userId → thread
local PendingDespawns: { [number]: thread } = {}

-- Folder in workspace for ship models
local ShipsFolder: Folder = nil

-- Dock points folder (expected in workspace)
local DockPointsFolder: Folder? = nil

--------------------------------------------------------------------------------
-- DOCK POINT MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Returns all dock point Parts from the workspace folder.
  @return Array of Parts sorted by SlotIndex
]]
local function getDockPoints(): { Part }
  if not DockPointsFolder then
    return {}
  end
  local points = {}
  for _, child in DockPointsFolder:GetChildren() do
    if child:IsA("BasePart") then
      table.insert(points, child)
    end
  end
  table.sort(points, function(a, b)
    local ai = a:GetAttribute("SlotIndex") or 999
    local bi = b:GetAttribute("SlotIndex") or 999
    return ai < bi
  end)
  return points
end

--[[
  Returns the first available (unoccupied) dock point.
  @return Part and slotIndex, or nil if all slots are full
]]
local function getAvailableDockSlot(): (Part?, number?)
  for _, point in getDockPoints() do
    local slotIndex = point:GetAttribute("SlotIndex")
    if slotIndex and not DockSlotOccupancy[slotIndex] then
      return point, slotIndex
    end
  end
  return nil, nil
end

--------------------------------------------------------------------------------
-- SHIP MODEL CREATION
--------------------------------------------------------------------------------

--[[
  Creates a placeholder ship model at the given dock position.
  When MODEL-001 (3D models) is implemented, replace this with proper models.
  @param shipTierDef The ship tier definition from GameConfig
  @param position World position of the dock point
  @param ownerName Display name of the ship owner
  @param ownerUserId UserId of the ship owner
  @param slotIndex Dock slot number
  @return The created Model
]]
local function createShipModel(
  shipTierDef: GameConfig.ShipTierDef,
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number
): Model
  local appearance = SHIP_APPEARANCE[shipTierDef.id] or SHIP_APPEARANCE.rowboat

  local model = Instance.new("Model")
  model.Name = "Ship_" .. ownerName .. "_Slot" .. slotIndex

  -- Hull (main body)
  local hull = Instance.new("Part")
  hull.Name = "Hull"
  hull.Size = appearance.size
  hull.Color = appearance.color
  hull.Material = appearance.material
  hull.Anchored = true
  hull.CanCollide = true
  hull.CanQuery = true
  hull.CanTouch = false
  hull.CastShadow = true
  hull.CFrame = CFrame.new(position + Vector3.new(0, appearance.size.Y / 2, 0))
  hull.Parent = model

  model.PrimaryPart = hull

  -- Store metadata as attributes
  hull:SetAttribute("ShipSlotIndex", slotIndex)
  hull:SetAttribute("ShipTierId", shipTierDef.id)
  hull:SetAttribute("ShipTierName", shipTierDef.name)
  hull:SetAttribute("OwnerName", ownerName)
  hull:SetAttribute("OwnerUserId", ownerUserId)

  -- Mast for ships above rowboat
  if shipTierDef.tier >= 2 then
    local mast = Instance.new("Part")
    mast.Name = "Mast"
    mast.Size = Vector3.new(0.5, appearance.size.Y * 2, 0.5)
    mast.Color = Color3.fromRGB(100, 70, 35)
    mast.Material = Enum.Material.Wood
    mast.Anchored = true
    mast.CanCollide = false
    mast.CanQuery = false
    mast.CanTouch = false
    mast.CastShadow = true
    mast.CFrame = CFrame.new(position + Vector3.new(0, appearance.size.Y + appearance.size.Y, 0))
    mast.Parent = model
  end

  -- Ghost ship gets a spectral glow
  if shipTierDef.id == "ghost_ship" then
    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(100, 180, 255)
    light.Brightness = 2
    light.Range = 40
    light.Parent = hull

    local particles = Instance.new("ParticleEmitter")
    particles.Color = ColorSequence.new(Color3.fromRGB(100, 180, 255))
    particles.Size = NumberSequence.new(0.5, 0)
    particles.Lifetime = NumberRange.new(1.5, 3)
    particles.Rate = 8
    particles.Speed = NumberRange.new(0.5, 1.5)
    particles.SpreadAngle = Vector2.new(180, 180)
    particles.Transparency = NumberSequence.new(0.4, 1)
    particles.Parent = hull
  end

  -- Owner name billboard
  local billboardGui = Instance.new("BillboardGui")
  billboardGui.Name = "OwnerLabel"
  billboardGui.Size = UDim2.new(0, 200, 0, 50)
  billboardGui.StudsOffset = Vector3.new(0, appearance.size.Y + 2, 0)
  billboardGui.AlwaysOnTop = false
  billboardGui.MaxDistance = 60
  billboardGui.Parent = hull

  local nameLabel = Instance.new("TextLabel")
  nameLabel.Name = "NameLabel"
  nameLabel.Size = UDim2.new(1, 0, 0.6, 0)
  nameLabel.BackgroundTransparency = 1
  nameLabel.Text = ownerName .. "'s " .. shipTierDef.name
  nameLabel.TextColor3 = Color3.fromRGB(255, 230, 150)
  nameLabel.TextStrokeTransparency = 0.3
  nameLabel.TextScaled = true
  nameLabel.Font = Enum.Font.GothamBold
  nameLabel.Parent = billboardGui

  model.Parent = ShipsFolder
  return model
end

--------------------------------------------------------------------------------
-- SHIP SPAWN / DESPAWN
--------------------------------------------------------------------------------

--[[
  Spawns a ship at an available dock slot for the given player.
  @param player The player whose ship to spawn
  @return The ShipEntry, or nil if no dock slot available or data not loaded
]]
local function spawnShip(player: Player): ShipEntry?
  -- Check if player already has a docked ship
  if DockedShips[player] then
    return DockedShips[player]
  end

  -- Get player's treasury for tier calculation
  local treasury = DataService:GetTreasury(player)
  if treasury == nil then
    warn("[ShipService] Cannot spawn ship — no data for", player.Name)
    return nil
  end

  -- Find available dock slot
  local dockPoint, slotIndex = getAvailableDockSlot()
  if not dockPoint or not slotIndex then
    warn("[ShipService] No available dock slots for", player.Name)
    return nil
  end

  -- Calculate ship tier
  local shipTierDef = GameConfig.getShipTierForTreasury(treasury)

  -- Create ship model at dock position
  local position = dockPoint.Position
  local model = createShipModel(shipTierDef, position, player.Name, player.UserId, slotIndex)

  -- Build ship entry
  local entry: ShipEntry = {
    slotIndex = slotIndex,
    owner = player,
    ownerUserId = player.UserId,
    ownerName = player.Name,
    shipTierId = shipTierDef.id,
    shipTierNumber = shipTierDef.tier,
    model = model,
    position = position,
    dockPoint = dockPoint,
    createdAt = os.clock(),
  }

  -- Register in both lookups
  DockedShips[player] = entry
  DockSlotOccupancy[slotIndex] = entry

  -- Fire signals
  ShipService.ShipSpawned:Fire(entry)
  ShipService.Client.ShipSpawned:FireAll(
    slotIndex,
    player.UserId,
    player.Name,
    shipTierDef.id,
    position
  )

  print("[ShipService] Spawned", shipTierDef.name, "for", player.Name, "at dock slot", slotIndex)
  return entry
end

--[[
  Despawns a ship, cleaning up the model and registry entries.
  @param entry The ship entry to despawn
]]
local function despawnShip(entry: ShipEntry)
  -- Clean up model
  if entry.model and entry.model.Parent then
    entry.model:Destroy()
  end

  -- Remove from registries
  DockSlotOccupancy[entry.slotIndex] = nil
  if DockedShips[entry.owner] == entry then
    DockedShips[entry.owner] = nil
  end

  -- Fire signals
  ShipService.ShipDespawned:Fire(entry)
  ShipService.Client.ShipDespawned:FireAll(entry.slotIndex, entry.ownerUserId)

  print("[ShipService] Despawned ship for", entry.ownerName, "from dock slot", entry.slotIndex)
end

--[[
  Starts a 30-second delayed despawn for a disconnected player's ship.
  If the player rejoins before the timer expires, the despawn is cancelled.
  @param entry The ship entry to schedule for despawn
]]
local function scheduleDespawn(entry: ShipEntry)
  local userId = entry.ownerUserId

  -- Cancel any existing pending despawn for this user
  if PendingDespawns[userId] then
    task.cancel(PendingDespawns[userId])
    PendingDespawns[userId] = nil
  end

  PendingDespawns[userId] = task.delay(GameConfig.ShipSystem.despawnDelay, function()
    PendingDespawns[userId] = nil
    -- Only despawn if still registered (player hasn't rejoined)
    if DockSlotOccupancy[entry.slotIndex] == entry then
      despawnShip(entry)
    end
  end)
end

--[[
  Cancels a pending despawn for a userId (e.g., player rejoined).
  @param userId The UserId of the player
  @return true if a pending despawn was cancelled
]]
local function cancelPendingDespawn(userId: number): boolean
  if PendingDespawns[userId] then
    task.cancel(PendingDespawns[userId])
    PendingDespawns[userId] = nil
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- SHIP TIER RECALCULATION
--------------------------------------------------------------------------------

--[[
  Recalculates a player's ship tier and swaps the model if the tier changed.
  Called when treasury changes (gear purchase, deposit+lock, etc.).
  @param player The player whose ship tier to recalculate
]]
function ShipService:RecalculateShipTier(player: Player)
  local entry = DockedShips[player]
  if not entry then
    return
  end

  local treasury = DataService:GetTreasury(player)
  if treasury == nil then
    return
  end

  local newTierDef = GameConfig.getShipTierForTreasury(treasury)
  if newTierDef.id == entry.shipTierId then
    return -- No change
  end

  local oldTierId = entry.shipTierId

  -- Destroy old model
  if entry.model and entry.model.Parent then
    entry.model:Destroy()
  end

  -- Create new model at same dock position
  local newModel =
    createShipModel(newTierDef, entry.position, entry.ownerName, entry.ownerUserId, entry.slotIndex)

  -- Update entry
  entry.shipTierId = newTierDef.id
  entry.shipTierNumber = newTierDef.tier
  entry.model = newModel

  -- Fire signals
  ShipService.ShipTierChanged:Fire(entry, oldTierId, newTierDef.id)
  ShipService.Client.ShipTierChanged:FireAll(entry.slotIndex, entry.ownerUserId, newTierDef.id)

  print(
    "[ShipService] Ship tier changed for",
    entry.ownerName,
    ":",
    oldTierId,
    "→",
    newTierDef.id
  )
end

--------------------------------------------------------------------------------
-- PUBLIC API (server-side)
--------------------------------------------------------------------------------

--[[
  Returns the docked ship entry for a player, or nil.
  @param player The player
  @return ShipEntry or nil
]]
function ShipService:GetDockedShip(player: Player): ShipEntry?
  return DockedShips[player]
end

--[[
  Returns the ship entry at a given dock slot, or nil.
  @param slotIndex The dock slot index
  @return ShipEntry or nil
]]
function ShipService:GetShipAtDock(slotIndex: number): ShipEntry?
  return DockSlotOccupancy[slotIndex]
end

--[[
  Returns the owner UserId for a ship at a dock slot, or nil.
  @param slotIndex The dock slot index
  @return UserId or nil
]]
function ShipService:GetShipOwnerUserId(slotIndex: number): number?
  local entry = DockSlotOccupancy[slotIndex]
  if entry then
    return entry.ownerUserId
  end
  return nil
end

--[[
  Returns the ship model for a player, or nil.
  @param player The player
  @return Model or nil
]]
function ShipService:GetShipModel(player: Player): Model?
  local entry = DockedShips[player]
  if entry then
    return entry.model
  end
  return nil
end

--[[
  Returns the position of a player's docked ship, or nil.
  @param player The player
  @return Vector3 or nil
]]
function ShipService:GetShipPosition(player: Player): Vector3?
  local entry = DockedShips[player]
  if entry then
    return entry.position
  end
  return nil
end

--[[
  Returns the dock slot index for a player's ship, or nil.
  @param player The player
  @return number or nil
]]
function ShipService:GetDockSlot(player: Player): number?
  local entry = DockedShips[player]
  if entry then
    return entry.slotIndex
  end
  return nil
end

--[[
  Returns an array of all currently docked ship entries.
  @return Array of { slotIndex, ownerUserId, ownerName, shipTierId, position }
]]
function ShipService:GetAllDockedShips(): {
  {
    slotIndex: number,
    ownerUserId: number,
    ownerName: string,
    shipTierId: string,
    position: Vector3,
  }
}
  local ships = {}
  for _, entry in DockedShips do
    table.insert(ships, {
      slotIndex = entry.slotIndex,
      ownerUserId = entry.ownerUserId,
      ownerName = entry.ownerName,
      shipTierId = entry.shipTierId,
      position = entry.position,
    })
  end
  return ships
end

--------------------------------------------------------------------------------
-- CLIENT-CALLABLE METHODS
--------------------------------------------------------------------------------

--[[
  Returns the dock slot index and ship tier for the calling player's ship.
  @param player The calling player (injected by Knit)
  @return slotIndex, shipTierId, position — or nil if no ship docked
]]
function ShipService.Client:GetMyShip(player: Player): (number?, string?, Vector3?)
  local entry = self.Server:GetDockedShip(player)
  if entry then
    return entry.slotIndex, entry.shipTierId, entry.position
  end
  return nil, nil, nil
end

--[[
  Returns all currently docked ships for the client to render.
  @param player The calling player (injected by Knit)
  @return Array of ship summaries
]]
function ShipService.Client:GetAllDockedShips(player: Player): {
  {
    slotIndex: number,
    ownerUserId: number,
    ownerName: string,
    shipTierId: string,
    position: Vector3,
  }
}
  return self.Server:GetAllDockedShips()
end

--[[
  Deposits all held doubloons into the player's ship hold.
  Validates proximity, ownership, and doubloon balance.
  Reduces threat by depositThreatReduction (25) on success.
  @param player The calling player (injected by Knit)
  @return (success: boolean, message: string?)
]]
function ShipService.Client:DepositAll(player: Player): (boolean, string?)
  local entry = DockedShips[player]
  if not entry then
    return false, "No ship docked"
  end

  -- Validate proximity (generous 20 stud threshold for network lag)
  local character = player.Character
  local rootPart = character and character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return false, "No character"
  end
  local distance = (rootPart.Position - entry.position).Magnitude
  if distance > 20 then
    return false, "Too far from ship"
  end

  -- Check held doubloons
  local heldDoubloons = SessionStateService:GetHeldDoubloons(player)
  if heldDoubloons <= 0 then
    return false, "No doubloons to deposit"
  end

  -- Process deposit: held → ship hold
  SessionStateService:SetHeldDoubloons(player, 0)
  SessionStateService:AddShipHold(player, heldDoubloons)

  -- Reduce threat by deposit amount (min 0, handled by AddThreat clamping)
  SessionStateService:AddThreat(player, -GameConfig.ShipSystem.depositThreatReduction)

  local newShipHold = SessionStateService:GetShipHold(player)

  -- Fire client signal to depositing player
  self.DepositCompleted:Fire(player, entry.slotIndex, heldDoubloons, newShipHold)

  -- Fire server-side signal for inter-service use
  ShipService.DepositCompleted:Fire(player, heldDoubloons, newShipHold)

  print(
    "[ShipService]",
    player.Name,
    "deposited",
    heldDoubloons,
    "doubloons. Ship hold:",
    newShipHold
  )
  return true, nil
end

--[[
  Locks the player's ship: moves all ship hold doubloons to permanent treasury.
  Resets threat to 0 and updates lastLockTime.
  Recalculates ship tier since treasury changed.
  @param player The calling player (injected by Knit)
  @return (success: boolean, message: string?)
]]
function ShipService.Client:LockShip(player: Player): (boolean, string?)
  local entry = DockedShips[player]
  if not entry then
    return false, "No ship docked"
  end

  -- Validate proximity (generous 20 stud threshold for network lag)
  local character = player.Character
  local rootPart = character and character:FindFirstChild("HumanoidRootPart")
  if not rootPart then
    return false, "No character"
  end
  local distance = (rootPart.Position - entry.position).Magnitude
  if distance > 20 then
    return false, "Too far from ship"
  end

  -- Check if already locked
  if SessionStateService:IsShipLocked(player) then
    return false, "Ship is already locked"
  end

  -- Get current ship hold
  local shipHold = SessionStateService:GetShipHold(player)

  -- Move ship hold → treasury (even if hold is 0, locking is still valid)
  if shipHold > 0 then
    local success = DataService:UpdateTreasury(player, shipHold)
    if not success then
      return false, "Failed to update treasury"
    end
    SessionStateService:SetShipHold(player, 0)
  end

  -- Set ship as locked
  SessionStateService:SetShipLocked(player, true)

  -- Reset threat to 0
  SessionStateService:SetThreatLevel(player, GameConfig.ShipSystem.lockThreatReset)

  -- Get updated treasury for client display
  local newTreasury = DataService:GetTreasury(player)

  -- Recalculate ship tier since treasury may have changed
  ShipService:RecalculateShipTier(player)

  -- Fire client signal to locking player
  self.LockCompleted:Fire(player, entry.slotIndex, shipHold, newTreasury)

  -- Fire server-side signal for inter-service use
  ShipService.LockCompleted:Fire(player, shipHold, newTreasury)

  print(
    "[ShipService]",
    player.Name,
    "locked ship. Moved",
    shipHold,
    "doubloons to treasury. New treasury:",
    newTreasury
  )
  return true, nil
end

--------------------------------------------------------------------------------
-- SHIP UNLOCK (called when player exits Harbor zone — HARBOR-001)
--------------------------------------------------------------------------------

--[[
  Unlocks a player's ship. Called by HARBOR-001 when the player exits
  the Harbor safe zone.
  @param player The player whose ship to unlock
]]
function ShipService:UnlockShip(player: Player)
  if not SessionStateService:IsShipLocked(player) then
    return
  end

  local entry = DockedShips[player]
  if not entry then
    return
  end

  SessionStateService:SetShipLocked(player, false)

  -- Fire client signal
  self.Client.ShipUnlocked:Fire(player, entry.slotIndex)

  -- Fire server-side signal
  ShipService.ShipUnlocked:Fire(player)

  print("[ShipService]", player.Name, "ship auto-unlocked (left Harbor)")
end

--------------------------------------------------------------------------------
-- PLAYER JOIN / LEAVE
--------------------------------------------------------------------------------

local function onPlayerDataLoaded(player: Player, _data: any)
  -- Cancel any pending despawn from a previous session
  local wasPending = cancelPendingDespawn(player.UserId)
  if wasPending then
    print("[ShipService] Cancelled pending despawn for rejoining player", player.Name)
    -- If the old ship entry is still registered with same userId, clean it up
    -- so we can spawn a fresh one
    for _, entry in DockSlotOccupancy do
      if entry.ownerUserId == player.UserId then
        despawnShip(entry)
        break
      end
    end
  end

  -- Spawn ship at available dock
  spawnShip(player)
end

local function onPlayerRemoving(player: Player)
  local entry = DockedShips[player]
  if not entry then
    return
  end

  -- Remove from player-keyed registry (but keep in slot occupancy for despawn delay)
  DockedShips[player] = nil

  -- Schedule delayed despawn
  scheduleDespawn(entry)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ShipService:KnitInit()
  -- Create workspace folder for ship models
  ShipsFolder = Instance.new("Folder")
  ShipsFolder.Name = "DockedShips"
  ShipsFolder.Parent = workspace

  -- Find dock points folder
  DockPointsFolder = workspace:FindFirstChild("ShipDockPoints")
  if not DockPointsFolder then
    warn(
      "[ShipService] workspace.ShipDockPoints not found!",
      "Ships will not spawn until dock points are placed."
    )
  else
    local dockPoints = getDockPoints()
    print("[ShipService] Found", #dockPoints, "dock points")
  end

  print("[ShipService] Initialized")
end

function ShipService:KnitStart()
  DataService = Knit.GetService("DataService")
  SessionStateService = Knit.GetService("SessionStateService")

  -- Spawn ship when player data is loaded (not on PlayerAdded, because we
  -- need treasury data to determine ship tier)
  DataService.PlayerDataLoaded:Connect(onPlayerDataLoaded)

  -- Handle disconnect: start despawn timer
  Players.PlayerRemoving:Connect(onPlayerRemoving)

  -- Handle players already in game (studio edge case)
  for _, player in Players:GetPlayers() do
    if DataService:GetData(player) then
      task.spawn(function()
        onPlayerDataLoaded(player, DataService:GetData(player))
      end)
    end
  end

  -- BindToClose: immediately despawn all ships on server shutdown
  game:BindToClose(function()
    for _, entry in DockedShips do
      if entry.model and entry.model.Parent then
        entry.model:Destroy()
      end
    end
    -- Cancel all pending despawns
    for userId, thread in PendingDespawns do
      task.cancel(thread)
      PendingDespawns[userId] = nil
    end
  end)

  print("[ShipService] Started")
end

return ShipService
