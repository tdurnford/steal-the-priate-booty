--[[
  RateLimiter.lua
  Simple per-player, per-action rate limiter for server-side input validation.

  Usage:
    local RateLimiter = require(path.to.RateLimiter)

    local purchaseLimiter = RateLimiter.new("PurchaseGear", 1.0)

    function MyService.Client:PurchaseGear(player, gearId)
      if not purchaseLimiter:check(player) then
        return false, "Too many requests"
      end
      -- ... normal logic
    end

    -- In PlayerRemoving:
    RateLimiter.cleanup(player)

  Tracks violation counts and logs warnings when a player triggers too many
  rate limit violations in a short window (potential exploit attempt).
]]

local Players = game:GetService("Players")

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- All active limiter instances (for cleanup)
local AllLimiters: { any } = {}

-- Per-player violation tracking (across all limiters)
local ViolationCounts: { [number]: number } = {} -- UserId -> total violations
local ViolationWindows: { [number]: number } = {} -- UserId -> window start time

-- How many violations in a 60s window before we warn
local VIOLATION_WARN_THRESHOLD = 20
local VIOLATION_WINDOW = 60

--[[
  Creates a new rate limiter for a specific action.
  @param actionName Display name for logging
  @param cooldown Minimum seconds between allowed calls
  @return RateLimiter instance
]]
function RateLimiter.new(actionName: string, cooldown: number)
  local self = setmetatable({}, RateLimiter)
  self._actionName = actionName
  self._cooldown = cooldown
  self._lastCall = {} :: { [number]: number } -- UserId -> os.clock()
  table.insert(AllLimiters, self)
  return self
end

--[[
  Checks whether a player's request should be allowed.
  @param player The requesting player
  @return true if allowed, false if rate limited
]]
function RateLimiter:check(player: Player): boolean
  local userId = player.UserId
  local now = os.clock()

  local lastTime = self._lastCall[userId]
  if lastTime and (now - lastTime) < self._cooldown then
    -- Rate limited — track violation
    self:_recordViolation(player, now)
    return false
  end

  self._lastCall[userId] = now
  return true
end

--[[
  Records a rate limit violation and logs if threshold exceeded.
]]
function RateLimiter:_recordViolation(player: Player, now: number)
  local userId = player.UserId
  local windowStart = ViolationWindows[userId]

  -- Reset window if expired
  if not windowStart or (now - windowStart) > VIOLATION_WINDOW then
    ViolationCounts[userId] = 0
    ViolationWindows[userId] = now
  end

  ViolationCounts[userId] = (ViolationCounts[userId] or 0) + 1
  local count = ViolationCounts[userId]

  if count == VIOLATION_WARN_THRESHOLD then
    warn(
      string.format(
        "[RateLimiter] SUSPICIOUS: %s (UserId %d) hit %d rate limit violations in %ds (latest: %s)",
        player.Name,
        userId,
        count,
        VIOLATION_WINDOW,
        self._actionName
      )
    )
  end
end

--[[
  Cleans up all rate limiter state for a player.
  Call from PlayerRemoving.
  @param player The leaving player
]]
function RateLimiter.cleanup(player: Player)
  local userId = player.UserId
  for _, limiter in AllLimiters do
    limiter._lastCall[userId] = nil
  end
  ViolationCounts[userId] = nil
  ViolationWindows[userId] = nil
end

-- Auto-cleanup on player leave
Players.PlayerRemoving:Connect(function(player: Player)
  -- Defer cleanup so services process their own PlayerRemoving first
  task.defer(function()
    RateLimiter.cleanup(player)
  end)
end)

return RateLimiter
