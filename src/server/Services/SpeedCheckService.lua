--[[
  SpeedCheckService.lua
  Server-authoritative speed monitoring for anti-exploit.

  Tracks player positions over time and flags players moving faster than
  their expected maximum speed (accounting for rank bonuses, block reduction,
  dash/lunge bursts, ragdoll knockback, quicksand immobilization, etc.).

  Detection strategy:
    - Sample player positions every CHECK_INTERVAL seconds via Heartbeat accumulator
    - Calculate horizontal speed from position delta / time delta
    - Compare against the player's expected max speed (state-aware)
    - Allow a tolerance buffer to prevent false positives from network lag
    - Track violations per player; warn at threshold, kick at kick threshold
    - Exempt players in transient high-velocity states (dash, lunge, ragdoll, rogue wave)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local SpeedCheckService = Knit.CreateService({
  Name = "SpeedCheckService",
  Client = {},
})

-- Lazy-loaded service references (set in KnitStart)
local RankEffectsService = nil
local SessionStateService = nil

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

-- How often to sample player positions (seconds)
local CHECK_INTERVAL = 0.5

-- Tolerance above expected speed before counting as a violation (studs/s).
-- Accounts for network latency, physics jitter, and brief desync.
local SPEED_TOLERANCE = 8

-- Base walk speed (Roblox default)
local BASE_WALK_SPEED = 16

-- Block speed multiplier
local BLOCK_SPEED_MULT = GameConfig.Combat.blockSpeedMultiplier -- 0.5

-- Duration after a dash/lunge/ragdoll ends where high speed is still expected.
-- Slightly longer than the actual burst to account for physics settling.
local BURST_GRACE_PERIOD = 0.5

-- Max allowed speed during burst grace period (ragdoll knockback can reach
-- 40 studs/s, dash ~50 studs/s; allow generous headroom for physics bounce).
local BURST_GRACE_MAX_SPEED = 60

-- Violation tracking thresholds
local VIOLATION_WARN_THRESHOLD = 10 -- violations in window → warn
local VIOLATION_KICK_THRESHOLD = 25 -- violations in window → kick
local VIOLATION_WINDOW = 30 -- seconds

--------------------------------------------------------------------------------
-- PER-PLAYER TRACKING STATE
--------------------------------------------------------------------------------

type PlayerTracker = {
  lastPosition: Vector3, -- XZ position at last sample
  lastSampleTime: number, -- os.clock() at last sample
  violations: number, -- count in current window
  windowStart: number, -- os.clock() when current window started
  lastBurstTime: number, -- os.clock() of last dash/lunge/ragdoll start
  exempt: boolean, -- true if player should be skipped (tutorial, just spawned, etc.)
}

local Trackers: { [Player]: PlayerTracker } = {}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Gets the HumanoidRootPart position for a player, or nil if unavailable.
]]
local function getHRPPosition(player: Player): Vector3?
  local character = player.Character
  if not character then
    return nil
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return nil
  end
  return hrp.Position
end

--[[
  Returns the expected maximum horizontal speed for a player given their
  current game state. Returns nil if the player should be exempt from
  checking (ragdolling, dashing, etc.).
]]
local function getExpectedMaxSpeed(player: Player): number?
  if not SessionStateService or not SessionStateService:IsInitialized(player) then
    return nil -- not yet initialized, skip
  end

  -- During ragdoll, physics-based velocity can be very high (knockback).
  -- Don't check speed while ragdolling — they can't control movement anyway.
  if SessionStateService:IsRagdolling(player) then
    return nil
  end

  -- During dash or lunge, the client applies a LinearVelocity burst.
  -- The isDashing flag is set for the duration of i-frames (0.3s).
  if SessionStateService:IsDashing(player) then
    return nil
  end

  -- Quicksand trap: speed should be ~0, but we don't need to flag for speed
  -- while trapped — they shouldn't be moving at all, and escape ejects them.
  if SessionStateService:IsQuicksandTrapped(player) then
    return nil
  end

  -- Get the expected walk speed based on rank
  local expectedSpeed = BASE_WALK_SPEED
  if RankEffectsService then
    expectedSpeed = RankEffectsService:GetWalkSpeed(player)
  end

  -- Block reduces speed to 50%
  if SessionStateService:IsBlocking(player) then
    expectedSpeed = expectedSpeed * BLOCK_SPEED_MULT
  end

  return expectedSpeed
end

--[[
  Initializes tracking state for a player. Called on spawn/respawn.
]]
local function initTracker(player: Player)
  local pos = getHRPPosition(player)
  local now = os.clock()
  Trackers[player] = {
    lastPosition = pos or Vector3.zero,
    lastSampleTime = now,
    violations = 0,
    windowStart = now,
    lastBurstTime = 0,
    exempt = true, -- exempt until first valid sample after spawn
  }

  -- Brief exemption after spawn/respawn to avoid false positives from
  -- character loading, teleportation, etc.
  task.delay(2, function()
    local tracker = Trackers[player]
    if tracker then
      tracker.exempt = false
      -- Reset position baseline after the grace period
      local freshPos = getHRPPosition(player)
      if freshPos then
        tracker.lastPosition = freshPos
        tracker.lastSampleTime = os.clock()
      end
    end
  end)
end

--[[
  Records a speed violation for a player. Logs warnings and kicks at thresholds.
]]
local function recordViolation(player: Player, actualSpeed: number, expectedSpeed: number)
  local tracker = Trackers[player]
  if not tracker then
    return
  end

  local now = os.clock()

  -- Reset violation window if expired
  if (now - tracker.windowStart) > VIOLATION_WINDOW then
    tracker.violations = 0
    tracker.windowStart = now
  end

  tracker.violations = tracker.violations + 1

  if tracker.violations == VIOLATION_WARN_THRESHOLD then
    warn(
      string.format(
        "[SpeedCheckService] SUSPICIOUS: %s (UserId %d) — %d speed violations in %ds (last: %.1f vs expected %.1f studs/s)",
        player.Name,
        player.UserId,
        tracker.violations,
        VIOLATION_WINDOW,
        actualSpeed,
        expectedSpeed
      )
    )
  end

  if tracker.violations >= VIOLATION_KICK_THRESHOLD then
    warn(
      string.format(
        "[SpeedCheckService] KICKING: %s (UserId %d) — %d speed violations in %ds",
        player.Name,
        player.UserId,
        tracker.violations,
        VIOLATION_WINDOW
      )
    )
    player:Kick("Connection issue detected. Please rejoin.")
  end
end

--[[
  Marks a player as having just experienced a velocity burst (dash, lunge,
  ragdoll knockback, rogue wave push). This grants a brief grace period
  where high speeds are expected.
]]
local function markBurst(player: Player)
  local tracker = Trackers[player]
  if tracker then
    tracker.lastBurstTime = os.clock()
  end
end

--[[
  Checks whether a player is still within the burst grace period.
]]
local function isInBurstGrace(player: Player): boolean
  local tracker = Trackers[player]
  if not tracker then
    return false
  end
  return (os.clock() - tracker.lastBurstTime) < BURST_GRACE_PERIOD
end

--[[
  Main check loop: samples all player positions and validates speed.
]]
local function checkAllPlayers()
  local now = os.clock()

  for _, player in Players:GetPlayers() do
    local tracker = Trackers[player]
    if not tracker or tracker.exempt then
      continue
    end

    local pos = getHRPPosition(player)
    if not pos then
      continue
    end

    local dt = now - tracker.lastSampleTime
    if dt < 0.05 then
      -- Too short an interval, skip to avoid division noise
      continue
    end

    -- Calculate horizontal distance (ignore Y for speed check)
    local dx = pos.X - tracker.lastPosition.X
    local dz = pos.Z - tracker.lastPosition.Z
    local horizontalDist = math.sqrt(dx * dx + dz * dz)
    local actualSpeed = horizontalDist / dt

    -- Update tracking state for next sample
    tracker.lastPosition = pos
    tracker.lastSampleTime = now

    -- Get expected max speed for this player's current state
    local expectedMax = getExpectedMaxSpeed(player)
    if expectedMax == nil then
      -- Player is in an exempt state (ragdoll, dash, quicksand, etc.)
      -- Mark burst so post-state speed is allowed to settle
      markBurst(player)
      continue
    end

    -- During burst grace period, allow much higher speeds
    if isInBurstGrace(player) then
      expectedMax = math.max(expectedMax, BURST_GRACE_MAX_SPEED)
    end

    -- Check if actual speed exceeds expected + tolerance
    if actualSpeed > expectedMax + SPEED_TOLERANCE then
      recordViolation(player, actualSpeed, expectedMax)
    end
  end
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function SpeedCheckService:KnitInit()
  print("[SpeedCheckService] Initializing...")
end

function SpeedCheckService:KnitStart()
  RankEffectsService = Knit.GetService("RankEffectsService")
  SessionStateService = Knit.GetService("SessionStateService")

  -- Initialize tracker on player join
  Players.PlayerAdded:Connect(function(player: Player)
    player.CharacterAdded:Connect(function(_character: Model)
      -- Wait for HumanoidRootPart to exist
      task.defer(function()
        initTracker(player)
      end)
    end)
  end)

  -- Handle players already in game
  for _, player in Players:GetPlayers() do
    if player.Character then
      initTracker(player)
    end
    player.CharacterAdded:Connect(function(_character: Model)
      task.defer(function()
        initTracker(player)
      end)
    end)
  end

  -- Clean up on player leave
  Players.PlayerRemoving:Connect(function(player: Player)
    Trackers[player] = nil
  end)

  -- Wire up burst detection from SessionStateService changes.
  -- When a player starts dashing/ragdolling, mark the burst so the grace
  -- period kicks in after the state ends.
  if SessionStateService.StateChanged then
    SessionStateService.StateChanged:Connect(function(player: Player, key: string, _value: any)
      if key == "isDashing" or key == "isRagdolling" then
        markBurst(player)
      end
    end)
  end

  -- Run position checks on Heartbeat with throttled interval
  local accumulator = 0
  RunService.Heartbeat:Connect(function(dt: number)
    accumulator = accumulator + dt
    if accumulator >= CHECK_INTERVAL then
      accumulator = accumulator - CHECK_INTERVAL
      checkAllPlayers()
    end
  end)

  print(
    "[SpeedCheckService] Started — speed monitoring active (check every",
    CHECK_INTERVAL,
    "s)"
  )
end

return SpeedCheckService
