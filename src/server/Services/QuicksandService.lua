--[[
  QuicksandService.lua
  Server-authoritative quicksand environmental hazard system.

  Handles:
    - Loading patch Parts from workspace.QuicksandPatches folder
    - Maintaining 2-3 active patches out of 4-6 total (cycling active/dormant)
    - Server-side player detection on active patches
    - Hit players: 3s immobilization (WalkSpeed=0, JumpHeight=0, can still attack/pickup)
    - After 3s: eject player to nearest edge of patch, restore movement
    - Dash i-frames (0.3s) prevent quicksand trigger
    - Ragdoll from other sources frees the player from quicksand
    - Client signals for VFX/SFX at each state change

  Patch Parts should be BaseParts in workspace.QuicksandPatches.
  Each Part defines the quicksand zone (AABB). Players whose HRP is within
  the patch bounds (with vertical tolerance) get immobilized.

  Other services can call:
    - GetPatchStates() to read all patch active/dormant states
    - IsPositionOnQuicksand(position) to check if a position overlaps an active patch
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local QuicksandService = Knit.CreateService({
  Name = "QuicksandService",
  Client = {
    -- Fired to ALL clients when a patch changes state.
    -- Args: (patchId: string, isActive: boolean, patchPosition: Vector3, patchSize: Vector3)
    PatchStateChanged = Knit.CreateSignal(),

    -- Fired to a specific player when they are trapped.
    -- Args: (patchPosition: Vector3, duration: number)
    QuicksandTrapped = Knit.CreateSignal(),

    -- Fired to a specific player when they are ejected/freed.
    -- Args: (ejectPosition: Vector3)
    QuicksandReleased = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
QuicksandService.PlayerTrapped = Signal.new() -- (player: Player, patchId: string)
QuicksandService.PlayerReleased = Signal.new() -- (player: Player, patchId: string)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local RankEffectsService = nil

--------------------------------------------------------------------------------
-- PATCH REGISTRY
--------------------------------------------------------------------------------

type PatchEntry = {
  id: string,
  part: BasePart,
  position: Vector3,
  size: Vector3,
  isActive: boolean,
  cycleTimer: number, -- time remaining before this patch changes state
}

-- All patches keyed by patch ID (Part name)
local Patches: { [string]: PatchEntry } = {}

-- Players currently trapped: [Player] = { patchId, releaseThread, savedWalkSpeed, savedJumpHeight }
local TrappedPlayers: {
  [Player]: {
    patchId: string,
    releaseThread: thread,
    savedWalkSpeed: number,
    savedJumpHeight: number,
  },
} =
  {}

-- Config shortcuts
local CFG = GameConfig.Quicksand
local IMMOBILIZE_DURATION = CFG.immobilizeDuration
local ACTIVE_DURATION_MIN = CFG.activeDurationMin
local ACTIVE_DURATION_MAX = CFG.activeDurationMax
local EJECT_OFFSET = CFG.ejectOffset

-- Vertical tolerance: players up to this many studs above the patch surface are caught
local VERTICAL_TOLERANCE = 6

-- Player position check throttle (seconds) — no need to check every frame
local CHECK_INTERVAL = 0.25
local checkAccumulator = 0

--------------------------------------------------------------------------------
-- PATCH ZONE DETECTION
--------------------------------------------------------------------------------

--[[
  Checks if a world position is within a patch's AABB bounds.
  @param patch The patch entry
  @param position World position to check
  @return true if the position is inside the patch
]]
local function isPositionOnPatch(patch: PatchEntry, position: Vector3): boolean
  local localPos = patch.part.CFrame:PointToObjectSpace(position)
  local halfSize = patch.size / 2

  if math.abs(localPos.X) > halfSize.X then
    return false
  end
  if math.abs(localPos.Z) > halfSize.Z then
    return false
  end

  -- Player should be near/above the patch surface
  if localPos.Y < -halfSize.Y then
    return false
  end
  if localPos.Y > halfSize.Y + VERTICAL_TOLERANCE then
    return false
  end

  return true
end

--[[
  Returns the HumanoidRootPart for a player, or nil.
]]
local function getHRP(player: Player): BasePart?
  local character = player.Character
  if not character then
    return nil
  end
  return character:FindFirstChild("HumanoidRootPart")
end

--[[
  Returns the Humanoid for a player, or nil.
]]
local function getHumanoid(player: Player): Humanoid?
  local character = player.Character
  if not character then
    return nil
  end
  return character:FindFirstChildOfClass("Humanoid")
end

--------------------------------------------------------------------------------
-- EJECT POSITION CALCULATION
--------------------------------------------------------------------------------

--[[
  Calculates the nearest point on the edge of the patch for ejection.
  Returns a world position just outside the patch boundary.
]]
local function calculateEjectPosition(patch: PatchEntry, playerPosition: Vector3): Vector3
  local localPos = patch.part.CFrame:PointToObjectSpace(playerPosition)
  local halfSize = patch.size / 2

  -- Find the nearest edge: compare X and Z distances to edges
  local distToXEdge = halfSize.X - math.abs(localPos.X)
  local distToZEdge = halfSize.Z - math.abs(localPos.Z)

  local ejectLocal: Vector3
  if distToXEdge < distToZEdge then
    -- Closer to X edge — eject along X axis
    local sign = if localPos.X >= 0 then 1 else -1
    ejectLocal = Vector3.new(sign * (halfSize.X + EJECT_OFFSET), localPos.Y, localPos.Z)
  else
    -- Closer to Z edge — eject along Z axis
    local sign = if localPos.Z >= 0 then 1 else -1
    ejectLocal = Vector3.new(localPos.X, localPos.Y, sign * (halfSize.Z + EJECT_OFFSET))
  end

  -- Convert back to world space
  return patch.part.CFrame:PointToWorldSpace(ejectLocal)
end

--------------------------------------------------------------------------------
-- TRAPPING & RELEASING
--------------------------------------------------------------------------------

--[[
  Releases a trapped player: restores movement, ejects to edge, fires signals.
]]
local function releasePlayer(player: Player)
  local trapInfo = TrappedPlayers[player]
  if not trapInfo then
    return
  end

  local patch = Patches[trapInfo.patchId]
  TrappedPlayers[player] = nil

  -- End quicksand state in session
  SessionStateService:EndQuicksandTrap(player)

  -- Restore movement
  local humanoid = getHumanoid(player)
  if humanoid then
    humanoid.WalkSpeed = trapInfo.savedWalkSpeed
    humanoid.JumpHeight = trapInfo.savedJumpHeight
  end

  -- Calculate eject position and teleport
  local hrp = getHRP(player)
  if hrp and patch then
    local ejectPos = calculateEjectPosition(patch, hrp.Position)
    hrp.CFrame = CFrame.new(ejectPos)
  end

  -- Notify client
  local ejectPos = if hrp then hrp.Position else Vector3.zero
  QuicksandService.Client.QuicksandReleased:Fire(player, ejectPos)

  -- Fire server signal
  QuicksandService.PlayerReleased:Fire(player, if trapInfo then trapInfo.patchId else "")

  print(
    string.format(
      "[QuicksandService] %s released from quicksand patch %s",
      player.Name,
      if trapInfo then trapInfo.patchId else "?"
    )
  )
end

--[[
  Traps a player in quicksand: immobilizes, schedules release.
]]
local function trapPlayer(player: Player, patch: PatchEntry)
  -- Skip if already trapped
  if TrappedPlayers[player] then
    return
  end

  -- Skip if ragdolled
  if SessionStateService:IsRagdolling(player) then
    return
  end

  -- Skip if dashing (i-frames)
  if SessionStateService:IsDashing(player) then
    return
  end

  -- Skip tutorial players
  if SessionStateService:IsTutorialActive(player) then
    return
  end

  -- Skip harbor players
  if SessionStateService:IsInHarbor(player) then
    return
  end

  -- Get humanoid to store/modify speed
  local humanoid = getHumanoid(player)
  if not humanoid then
    return
  end

  -- Store current speed values for restoration
  local savedWalkSpeed = humanoid.WalkSpeed
  local savedJumpHeight = humanoid.JumpHeight

  -- Immobilize: set WalkSpeed and JumpHeight to 0
  humanoid.WalkSpeed = 0
  humanoid.JumpHeight = 0

  -- Set session state
  SessionStateService:StartQuicksandTrap(player, IMMOBILIZE_DURATION)

  -- Schedule release after duration
  local releaseThread = task.delay(IMMOBILIZE_DURATION, function()
    releasePlayer(player)
  end)

  TrappedPlayers[player] = {
    patchId = patch.id,
    releaseThread = releaseThread,
    savedWalkSpeed = savedWalkSpeed,
    savedJumpHeight = savedJumpHeight,
  }

  -- Notify client
  QuicksandService.Client.QuicksandTrapped:Fire(player, patch.position, IMMOBILIZE_DURATION)

  -- Fire server signal
  QuicksandService.PlayerTrapped:Fire(player, patch.id)

  print(
    string.format(
      "[QuicksandService] %s trapped in quicksand patch %s for %.1fs",
      player.Name,
      patch.id,
      IMMOBILIZE_DURATION
    )
  )
end

--------------------------------------------------------------------------------
-- PLAYER DETECTION
--------------------------------------------------------------------------------

--[[
  Checks all players against active patches and traps those standing on them.
]]
local function checkPlayersOnPatches()
  for _, player in Players:GetPlayers() do
    -- Skip if already trapped
    if TrappedPlayers[player] then
      continue
    end

    local hrp = getHRP(player)
    if not hrp then
      continue
    end

    -- Check against all active patches
    for _, patch in Patches do
      if not patch.isActive then
        continue
      end

      if isPositionOnPatch(patch, hrp.Position) then
        trapPlayer(player, patch)
        break -- only trap once per check
      end
    end
  end
end

--------------------------------------------------------------------------------
-- ACTIVE/DORMANT CYCLING
--------------------------------------------------------------------------------

--[[
  Returns the count of currently active patches.
]]
local function getActiveCount(): number
  local count = 0
  for _, patch in Patches do
    if patch.isActive then
      count = count + 1
    end
  end
  return count
end

--[[
  Returns a random dormant patch, or nil if none available.
]]
local function getRandomDormantPatch(): PatchEntry?
  local dormant = {}
  for _, patch in Patches do
    if not patch.isActive then
      table.insert(dormant, patch)
    end
  end
  if #dormant == 0 then
    return nil
  end
  return dormant[math.random(#dormant)]
end

--[[
  Returns a random active duration for a patch.
]]
local function getRandomActiveDuration(): number
  return ACTIVE_DURATION_MIN + math.random() * (ACTIVE_DURATION_MAX - ACTIVE_DURATION_MIN)
end

--[[
  Activates a dormant patch: sets active, resets timer, notifies clients.
]]
local function activatePatch(patch: PatchEntry)
  patch.isActive = true
  patch.cycleTimer = getRandomActiveDuration()

  -- Notify all clients
  QuicksandService.Client.PatchStateChanged:FireAll(patch.id, true, patch.position, patch.size)

  print(string.format("[QuicksandService] Patch %s activated (%.0fs)", patch.id, patch.cycleTimer))
end

--[[
  Deactivates an active patch: sets dormant, picks a replacement, notifies clients.
  If a player is currently trapped on this patch, they are released.
]]
local function deactivatePatch(patch: PatchEntry)
  patch.isActive = false

  -- Collect players to release (avoid modifying TrappedPlayers during iteration)
  local toRelease = {}
  for player, trapInfo in TrappedPlayers do
    if trapInfo.patchId == patch.id then
      if trapInfo.releaseThread then
        task.cancel(trapInfo.releaseThread)
      end
      table.insert(toRelease, player)
    end
  end
  for _, player in toRelease do
    releasePlayer(player)
  end

  -- Notify all clients
  QuicksandService.Client.PatchStateChanged:FireAll(patch.id, false, patch.position, patch.size)

  print(string.format("[QuicksandService] Patch %s deactivated", patch.id))

  -- Activate a random dormant patch to maintain the active count
  local targetActive = math.random(CFG.activeAtOnce.min, CFG.activeAtOnce.max)
  if getActiveCount() < targetActive then
    local replacement = getRandomDormantPatch()
    if replacement then
      activatePatch(replacement)
    end
  end
end

--[[
  Updates patch cycle timers. Active patches decrement; when timer expires,
  the patch deactivates and a dormant one takes its place.
]]
local function updatePatchCycles(dt: number)
  for _, patch in Patches do
    if patch.isActive then
      patch.cycleTimer = patch.cycleTimer - dt
      if patch.cycleTimer <= 0 then
        deactivatePatch(patch)
      end
    end
  end
end

--------------------------------------------------------------------------------
-- HEARTBEAT UPDATE
--------------------------------------------------------------------------------

--[[
  Main update loop: cycles patches and checks player positions (throttled).
]]
local function onHeartbeat(dt: number)
  -- Update patch active/dormant cycling
  updatePatchCycles(dt)

  -- Throttle player position checks
  checkAccumulator = checkAccumulator + dt
  if checkAccumulator >= CHECK_INTERVAL then
    checkAccumulator = checkAccumulator - CHECK_INTERVAL
    checkPlayersOnPatches()
  end

  -- Check if any trapped players got ragdolled by another source (free them)
  -- Collect first to avoid modifying TrappedPlayers during iteration
  local ragdolledPlayers = {}
  for player, trapInfo in TrappedPlayers do
    if SessionStateService:IsRagdolling(player) then
      table.insert(ragdolledPlayers, { player = player, trapInfo = trapInfo })
    end
  end
  for _, entry in ragdolledPlayers do
    local player = entry.player
    local trapInfo = entry.trapInfo
    if trapInfo.releaseThread then
      task.cancel(trapInfo.releaseThread)
    end
    -- Restore movement but don't eject (ragdoll handles positioning)
    local humanoid = getHumanoid(player)
    if humanoid then
      humanoid.WalkSpeed = trapInfo.savedWalkSpeed
      humanoid.JumpHeight = trapInfo.savedJumpHeight
    end
    SessionStateService:EndQuicksandTrap(player)
    TrappedPlayers[player] = nil
    QuicksandService.PlayerReleased:Fire(player, trapInfo.patchId)
    print(string.format("[QuicksandService] %s freed from quicksand by ragdoll", player.Name))
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the current state of all patches.
  @return Array of { id, isActive, position, size }
]]
function QuicksandService:GetPatchStates(): {
  {
    id: string,
    isActive: boolean,
    position: Vector3,
    size: Vector3,
  }
}
  local states = {}
  for _, patch in Patches do
    table.insert(states, {
      id = patch.id,
      isActive = patch.isActive,
      position = patch.position,
      size = patch.size,
    })
  end
  return states
end

--[[
  Returns patch states for a client that just joined.
  @param player The requesting player
  @return Array of patch states
]]
function QuicksandService.Client:GetPatchStates(player: Player)
  return QuicksandService:GetPatchStates()
end

--[[
  Checks if a world position is on any active quicksand patch.
  @param position World position to check
  @return boolean
]]
function QuicksandService:IsPositionOnQuicksand(position: Vector3): boolean
  for _, patch in Patches do
    if patch.isActive and isPositionOnPatch(patch, position) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function QuicksandService:KnitInit()
  local patchFolder = workspace:FindFirstChild("QuicksandPatches")
  if not patchFolder then
    warn("[QuicksandService] No QuicksandPatches folder in workspace — quicksand disabled")
    print("[QuicksandService] Initialized (no patches)")
    return
  end

  -- Load patch parts
  local count = 0
  for _, child in patchFolder:GetChildren() do
    if child:IsA("BasePart") then
      local patchId = child.Name

      Patches[patchId] = {
        id = patchId,
        part = child,
        position = child.Position,
        size = child.Size,
        isActive = false,
        cycleTimer = 0,
      }
      count = count + 1
      print("[QuicksandService] Loaded patch:", patchId, "at", child.Position, "size:", child.Size)
    end
  end

  print("[QuicksandService] Initialized —", count, "patch(es) loaded")
end

function QuicksandService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")

  -- Try to get RankEffectsService for correct walk speed restoration
  local ok, service = pcall(function()
    return Knit.GetService("RankEffectsService")
  end)
  if ok then
    RankEffectsService = service
  end

  -- Check if we have any patches
  local patchList = {}
  for _, patch in Patches do
    table.insert(patchList, patch)
  end

  if #patchList == 0 then
    print("[QuicksandService] Started (no patches — quicksand inactive)")
    return
  end

  -- Randomly select initial active patches (2-3)
  local targetActive = math.random(CFG.activeAtOnce.min, CFG.activeAtOnce.max)
  -- Shuffle patch list for random selection
  for i = #patchList, 2, -1 do
    local j = math.random(i)
    patchList[i], patchList[j] = patchList[j], patchList[i]
  end

  for i = 1, math.min(targetActive, #patchList) do
    activatePatch(patchList[i])
  end

  -- Clean up trapped players on disconnect
  Players.PlayerRemoving:Connect(function(player)
    local trapInfo = TrappedPlayers[player]
    if trapInfo then
      if trapInfo.releaseThread then
        task.cancel(trapInfo.releaseThread)
      end
      TrappedPlayers[player] = nil
    end
  end)

  -- Run update loop on Heartbeat
  RunService.Heartbeat:Connect(onHeartbeat)

  print("[QuicksandService] Started — quicksand cycling active")
end

return QuicksandService
