--[[
  VolcanicVentService.lua
  Server-authoritative volcanic vent environmental hazard system.

  Handles:
    - Loading vent Parts from workspace.VolcanicVents folder
    - Independent vent cycle: dormant (20s) → warning (5s) → eruption (3s) → repeat
    - Server-side player detection during eruption phase
    - Hit players: 2.0s ragdoll, launched upward, 15% held doubloons spill
    - Client signals for VFX/SFX at each phase transition

  Vent Parts should be BaseParts in workspace.VolcanicVents.
  Each vent Part defines the eruption zone (players whose HRP is within
  the vent's horizontal bounds + a vertical tolerance are affected).

  Other services can call:
    - GetVentStates() to read all vent phase states
    - IsPositionOnVent(position) to check if a position overlaps a vent
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local VolcanicVentService = Knit.CreateService({
  Name = "VolcanicVentService",
  Client = {
    -- Fired to ALL clients when a vent changes phase.
    -- Args: (ventId: string, phase: string, ventPosition: Vector3, ventSize: Vector3)
    --   phase: "dormant" | "warning" | "eruption"
    VentPhaseChanged = Knit.CreateSignal(),

    -- Fired to a specific player when they are hit by an eruption.
    -- Args: (ventPosition: Vector3, launchVelocity: Vector3, ragdollDuration: number)
    VentEruptionHit = Knit.CreateSignal(),

    -- Fired to ALL clients when a player is launched by an eruption (for spectator VFX).
    -- Args: (playerUserId: number, ventPosition: Vector3)
    VentEruptionLaunchVFX = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
VolcanicVentService.PlayerHitByVent = Signal.new() -- (player: Player, ventId: string, spillAmount: number)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DoubloonService = nil

--------------------------------------------------------------------------------
-- VENT REGISTRY
--------------------------------------------------------------------------------

type VentPhase = "dormant" | "warning" | "eruption"

type VentEntry = {
  id: string,
  part: BasePart,
  position: Vector3,
  size: Vector3,
  phase: VentPhase,
  phaseTimer: number, -- time remaining in current phase (seconds)
}

-- Active vents keyed by vent ID (Part name)
local Vents: { [string]: VentEntry } = {}

-- Config shortcuts
local DORMANT_DURATION = GameConfig.VolcanicVent.dormantDuration
local WARNING_DURATION = GameConfig.VolcanicVent.warningDuration
local ERUPTION_DURATION = GameConfig.VolcanicVent.eruptionDuration
local RAGDOLL_DURATION = GameConfig.VolcanicVent.ragdollDuration
local SPILL_PERCENT = GameConfig.VolcanicVent.lootSpillPercent

-- Vertical tolerance: players up to this many studs above the vent surface are hit
local VERTICAL_TOLERANCE = 12

-- Upward launch force when hit by eruption
local LAUNCH_VELOCITY_UP = 80
-- Small random horizontal scatter
local LAUNCH_SCATTER = 15

--------------------------------------------------------------------------------
-- VENT ZONE DETECTION
--------------------------------------------------------------------------------

--[[
  Checks if a world position is within a vent's horizontal bounds (AABB XZ)
  and within vertical tolerance above the vent surface.
  @param vent The vent entry
  @param position World position to check
  @return true if the position overlaps the vent zone
]]
local function isPositionOnVent(vent: VentEntry, position: Vector3): boolean
  local localPos = vent.part.CFrame:PointToObjectSpace(position)
  local halfSize = vent.size / 2

  -- XZ bounds check
  if math.abs(localPos.X) > halfSize.X then
    return false
  end
  if math.abs(localPos.Z) > halfSize.Z then
    return false
  end

  -- Vertical check: player should be above the vent surface (not below)
  -- and within the tolerance distance
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

--------------------------------------------------------------------------------
-- ERUPTION DAMAGE
--------------------------------------------------------------------------------

--[[
  Checks all players against an erupting vent and applies effects:
  - 2.0s ragdoll
  - Upward launch (knockback velocity)
  - 15% held doubloons spill
  Players who are already ragdolled, in i-frames, or dead are skipped.
]]
local function applyEruptionDamage(vent: VentEntry)
  for _, player in Players:GetPlayers() do
    local hrp = getHRP(player)
    if not hrp then
      continue
    end

    if not isPositionOnVent(vent, hrp.Position) then
      continue
    end

    -- Skip if player is already ragdolled
    if SessionStateService:IsRagdolling(player) then
      continue
    end

    -- Skip if player is in dash i-frames
    if SessionStateService:IsDashing(player) then
      continue
    end

    -- Skip tutorial players (they're protected)
    if SessionStateService:IsTutorialActive(player) then
      continue
    end

    -- Apply ragdoll
    SessionStateService:StartRagdoll(player, RAGDOLL_DURATION)

    -- Calculate upward launch velocity with slight random horizontal scatter
    local scatterX = (math.random() - 0.5) * 2 * LAUNCH_SCATTER
    local scatterZ = (math.random() - 0.5) * 2 * LAUNCH_SCATTER
    local launchVelocity = Vector3.new(scatterX, LAUNCH_VELOCITY_UP, scatterZ)

    -- Notify the hit player for ragdoll + launch VFX
    VolcanicVentService.Client.VentEruptionHit:Fire(
      player,
      vent.position,
      launchVelocity,
      RAGDOLL_DURATION
    )

    -- Notify all clients for spectator VFX (fire geyser launch)
    VolcanicVentService.Client.VentEruptionLaunchVFX:FireAll(player.UserId, vent.position)

    -- Calculate and apply loot spill
    local heldDoubloons = SessionStateService:GetHeldDoubloons(player)
    local hasBounty = SessionStateService:HasBounty(player)
    local spillAmount = GameConfig.calculateSpill(heldDoubloons, SPILL_PERCENT, hasBounty)

    if spillAmount > 0 then
      SessionStateService:AddHeldDoubloons(player, -spillAmount)

      if DoubloonService then
        DoubloonService:ScatterDoubloons(hrp.Position, spillAmount, 5)
      end
    end

    -- Fire server-side signal
    VolcanicVentService.PlayerHitByVent:Fire(player, vent.id, spillAmount)

    print(
      string.format(
        "[VolcanicVentService] %s hit by vent %s — ragdoll %.1fs, spilled %d doubloons",
        player.Name,
        vent.id,
        RAGDOLL_DURATION,
        spillAmount
      )
    )
  end
end

--------------------------------------------------------------------------------
-- VENT PHASE CYCLING
--------------------------------------------------------------------------------

--[[
  Transitions a vent to the next phase in the cycle.
  dormant → warning → eruption → dormant
  Fires client signals for VFX transitions.
]]
local function advanceVentPhase(vent: VentEntry)
  local oldPhase = vent.phase

  if oldPhase == "dormant" then
    vent.phase = "warning"
    vent.phaseTimer = WARNING_DURATION
  elseif oldPhase == "warning" then
    vent.phase = "eruption"
    vent.phaseTimer = ERUPTION_DURATION
    -- Check for players on the vent at eruption start
    applyEruptionDamage(vent)
  elseif oldPhase == "eruption" then
    vent.phase = "dormant"
    -- Add slight randomization to dormant duration (±20%) to desync vents
    local variance = DORMANT_DURATION * 0.2
    vent.phaseTimer = DORMANT_DURATION + (math.random() - 0.5) * 2 * variance
  end

  -- Notify all clients of the phase change
  VolcanicVentService.Client.VentPhaseChanged:FireAll(vent.id, vent.phase, vent.position, vent.size)
end

--[[
  Called every Heartbeat to tick all vent timers.
  When a vent's timer expires, it advances to the next phase.
  During eruption phase, continuously checks for players (not just at start).
]]
local function updateVents(dt: number)
  for _, vent in Vents do
    vent.phaseTimer = vent.phaseTimer - dt

    -- Continuously check for players walking onto an erupting vent
    if vent.phase == "eruption" and vent.phaseTimer > 0 then
      applyEruptionDamage(vent)
    end

    if vent.phaseTimer <= 0 then
      advanceVentPhase(vent)
    end
  end
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the current phase states of all vents.
  @return Array of { id: string, phase: string, position: Vector3, size: Vector3 }
]]
function VolcanicVentService:GetVentStates(): {
  {
    id: string,
    phase: string,
    position: Vector3,
    size: Vector3,
  }
}
  local states = {}
  for _, vent in Vents do
    table.insert(states, {
      id = vent.id,
      phase = vent.phase,
      position = vent.position,
      size = vent.size,
    })
  end
  return states
end

--[[
  Returns the current vent states for a client that just joined.
  @param player The requesting player
  @return Array of vent states
]]
function VolcanicVentService.Client:GetVentStates(player: Player)
  return VolcanicVentService:GetVentStates()
end

--[[
  Checks if a world position is on any active vent.
  @param position World position to check
  @return boolean
]]
function VolcanicVentService:IsPositionOnVent(position: Vector3): boolean
  for _, vent in Vents do
    if isPositionOnVent(vent, position) then
      return true
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function VolcanicVentService:KnitInit()
  local ventFolder = workspace:FindFirstChild("VolcanicVents")
  if not ventFolder then
    warn("[VolcanicVentService] No VolcanicVents folder in workspace — vents disabled")
    print("[VolcanicVentService] Initialized (no vents)")
    return
  end

  -- Load vent parts
  local count = 0
  for _, child in ventFolder:GetChildren() do
    if child:IsA("BasePart") then
      local ventId = child.Name
      -- Stagger initial dormant timers so vents don't all erupt at once
      local initialTimer = DORMANT_DURATION * (0.3 + math.random() * 0.7)

      Vents[ventId] = {
        id = ventId,
        part = child,
        position = child.Position,
        size = child.Size,
        phase = "dormant",
        phaseTimer = initialTimer,
      }
      count = count + 1
      print("[VolcanicVentService] Loaded vent:", ventId, "at", child.Position, "size:", child.Size)
    end
  end

  print("[VolcanicVentService] Initialized —", count, "vent(s) loaded")
end

function VolcanicVentService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DoubloonService = Knit.GetService("DoubloonService")

  -- Check if we have any vents
  local hasVents = false
  for _ in Vents do
    hasVents = true
    break
  end

  if not hasVents then
    print("[VolcanicVentService] Started (no vents — cycling inactive)")
    return
  end

  -- Run vent update loop on Heartbeat
  RunService.Heartbeat:Connect(updateVents)

  print("[VolcanicVentService] Started — vent cycling active")
end

return VolcanicVentService
