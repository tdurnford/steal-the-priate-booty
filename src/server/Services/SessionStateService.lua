--[[
  SessionStateService.lua
  Manages per-player transient session state (server-authoritative).
  Session state is NOT saved to DataStore — it resets every time a player joins.

  Fields managed:
    heldDoubloons, shipHold, shipLocked, isRagdolling, ragdollEndTime,
    recoveryEndTime, dashCooldownEnd, lastHitTargets, lastRaidedShips,
    hasBounty, tutorialActive, tutorialStep, threatLevel, lastLockTime,
    phantomCaptainActive

  Other services read/write session state through this service's API.
  The client receives read-only snapshots of select fields via signals.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local Types = require(Shared:WaitForChild("Types"))

local SessionStateService = Knit.CreateService({
  Name = "SessionStateService",
  Client = {
    -- Fired to a specific player when any of their client-visible fields change.
    -- Args: (fieldName: string, value: any)
    SessionStateChanged = Knit.CreateSignal(),
  },
})

-- Lazy-loaded service references (set in KnitStart)
local DataService = nil

-- Per-player session state keyed by Player instance
local SessionStates: { [Player]: Types.SessionState } = {}

-- Server-side signal: fired when any session state field changes.
-- Args: (player: Player, fieldName: string, newValue: any)
SessionStateService.StateChanged = Signal.new()

-- Fields that the client is allowed to see for HUD display
local CLIENT_VISIBLE_FIELDS = {
  heldDoubloons = true,
  shipHold = true,
  shipLocked = true,
  threatLevel = true,
  hasBounty = true,
  tutorialActive = true,
  tutorialStep = true,
  inHarbor = true,
}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Notifies listeners of a field change.
  Fires the server-side StateChanged signal unconditionally.
  Fires the client signal only for CLIENT_VISIBLE_FIELDS.
]]
local function notifyChange(player: Player, fieldName: string, value: any)
  SessionStateService.StateChanged:Fire(player, fieldName, value)
  if CLIENT_VISIBLE_FIELDS[fieldName] then
    SessionStateService.Client.SessionStateChanged:Fire(player, fieldName, value)
  end
end

--------------------------------------------------------------------------------
-- SESSION LIFECYCLE
--------------------------------------------------------------------------------

--[[
  Initializes session state for a player.
  Called internally when the player's persistent data is loaded.
]]
function SessionStateService:_initSession(player: Player)
  if SessionStates[player] then
    return -- already initialized
  end

  local tutorialCompleted = false
  if DataService then
    tutorialCompleted = DataService:IsTutorialCompleted(player)
  end

  local state = Types.createSessionState(tutorialCompleted)
  SessionStates[player] = state

  print("[SessionStateService] Session initialized for", player.Name)
end

--[[
  Cleans up session state when a player leaves.
]]
function SessionStateService:_cleanupSession(player: Player)
  if SessionStates[player] then
    SessionStates[player] = nil
    print("[SessionStateService] Session cleaned up for", player.Name)
  end
end

--------------------------------------------------------------------------------
-- STATE ACCESSORS (read)
--------------------------------------------------------------------------------

--[[
  Gets the full session state for a player.
  @param player The player
  @return SessionState or nil if not initialized
]]
function SessionStateService:GetState(player: Player): Types.SessionState?
  return SessionStates[player]
end

--[[
  Gets a single field from a player's session state.
  @param player The player
  @param field The field name
  @return The field value, or nil if state not initialized
]]
function SessionStateService:GetField(player: Player, field: string): any
  local state = SessionStates[player]
  if state then
    return (state :: any)[field]
  end
  return nil
end

--[[
  Checks whether session state is initialized for a player.
]]
function SessionStateService:IsInitialized(player: Player): boolean
  return SessionStates[player] ~= nil
end

--------------------------------------------------------------------------------
-- HELD DOUBLOONS
--------------------------------------------------------------------------------

function SessionStateService:GetHeldDoubloons(player: Player): number
  local state = SessionStates[player]
  return if state then state.heldDoubloons else 0
end

function SessionStateService:AddHeldDoubloons(player: Player, amount: number): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  state.heldDoubloons = math.max(0, state.heldDoubloons + amount)
  notifyChange(player, "heldDoubloons", state.heldDoubloons)
  return true
end

function SessionStateService:SetHeldDoubloons(player: Player, amount: number): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  state.heldDoubloons = math.max(0, amount)
  notifyChange(player, "heldDoubloons", state.heldDoubloons)
  return true
end

--------------------------------------------------------------------------------
-- SHIP HOLD
--------------------------------------------------------------------------------

function SessionStateService:GetShipHold(player: Player): number
  local state = SessionStates[player]
  return if state then state.shipHold else 0
end

function SessionStateService:AddShipHold(player: Player, amount: number): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  state.shipHold = math.max(0, state.shipHold + amount)
  notifyChange(player, "shipHold", state.shipHold)
  return true
end

function SessionStateService:SetShipHold(player: Player, amount: number): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  state.shipHold = math.max(0, amount)
  notifyChange(player, "shipHold", state.shipHold)
  return true
end

--------------------------------------------------------------------------------
-- SHIP LOCK
--------------------------------------------------------------------------------

function SessionStateService:IsShipLocked(player: Player): boolean
  local state = SessionStates[player]
  return if state then state.shipLocked else true
end

function SessionStateService:SetShipLocked(player: Player, locked: boolean)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.shipLocked = locked
  if locked then
    state.lastLockTime = os.clock()
  end
  notifyChange(player, "shipLocked", locked)
end

--------------------------------------------------------------------------------
-- RAGDOLL / COMBAT STATE
--------------------------------------------------------------------------------

function SessionStateService:IsRagdolling(player: Player): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  if state.isRagdolling and os.clock() >= state.ragdollEndTime then
    state.isRagdolling = false
    state.recoveryEndTime = os.clock() + 0.5
    notifyChange(player, "isRagdolling", false)
  end
  return state.isRagdolling
end

function SessionStateService:IsInRecovery(player: Player): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  return os.clock() < state.recoveryEndTime
end

function SessionStateService:StartRagdoll(player: Player, duration: number)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.isRagdolling = true
  state.ragdollEndTime = os.clock() + duration
  notifyChange(player, "isRagdolling", true)
end

function SessionStateService:EndRagdoll(player: Player)
  local state = SessionStates[player]
  if not state then
    return
  end
  if state.isRagdolling then
    state.isRagdolling = false
    state.recoveryEndTime = os.clock() + 0.5
    notifyChange(player, "isRagdolling", false)
  end
end

--------------------------------------------------------------------------------
-- BLOCK STATE
--------------------------------------------------------------------------------

function SessionStateService:IsBlocking(player: Player): boolean
  local state = SessionStates[player]
  return if state then state.isBlocking else false
end

function SessionStateService:SetBlocking(player: Player, blocking: boolean)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.isBlocking = blocking
  notifyChange(player, "isBlocking", blocking)
end

--------------------------------------------------------------------------------
-- DASH COOLDOWN
--------------------------------------------------------------------------------

function SessionStateService:IsDashOnCooldown(player: Player): boolean
  local state = SessionStates[player]
  if not state then
    return true
  end
  return os.clock() < state.dashCooldownEnd
end

function SessionStateService:StartDashCooldown(player: Player, cooldown: number)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.dashCooldownEnd = os.clock() + cooldown
end

--[[
  Checks if a player is currently in dash invulnerability frames.
  Auto-clears isDashing when invulnerability expires.
]]
function SessionStateService:IsDashing(player: Player): boolean
  local state = SessionStates[player]
  if not state then
    return false
  end
  if state.isDashing and os.clock() >= state.dashInvulnEnd then
    state.isDashing = false
  end
  return state.isDashing
end

--[[
  Starts a dash: sets isDashing, invulnerability end time, and cooldown.
  @param player The dashing player
  @param invulnTime Duration of i-frames (seconds)
  @param cooldown Cooldown before next dash (seconds)
]]
function SessionStateService:StartDash(player: Player, invulnTime: number, cooldown: number)
  local state = SessionStates[player]
  if not state then
    return
  end
  local now = os.clock()
  state.isDashing = true
  state.dashInvulnEnd = now + invulnTime
  state.dashCooldownEnd = now + cooldown
end

--[[
  Ends dash invulnerability early (e.g. if ragdolled during dash).
]]
function SessionStateService:EndDash(player: Player)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.isDashing = false
end

--------------------------------------------------------------------------------
-- PER-TARGET HIT TRACKING
--------------------------------------------------------------------------------

--[[
  Checks if a player can hit a specific target (2s per-target cooldown).
  @param attacker The attacking player
  @param targetUserId The target's UserId
  @return true if the target can be hit
]]
function SessionStateService:CanHitTarget(attacker: Player, targetUserId: number): boolean
  local state = SessionStates[attacker]
  if not state then
    return false
  end
  local lastHitTime = state.lastHitTargets[targetUserId]
  if lastHitTime and (os.clock() - lastHitTime) < 2 then
    return false
  end
  return true
end

function SessionStateService:RecordHitTarget(attacker: Player, targetUserId: number)
  local state = SessionStates[attacker]
  if not state then
    return
  end
  state.lastHitTargets[targetUserId] = os.clock()
end

--[[
  Cleans up expired entries from lastHitTargets to prevent memory growth.
]]
function SessionStateService:CleanupHitTargets(player: Player)
  local state = SessionStates[player]
  if not state then
    return
  end
  local now = os.clock()
  for targetId, hitTime in state.lastHitTargets do
    if (now - hitTime) >= 2 then
      state.lastHitTargets[targetId] = nil
    end
  end
end

--------------------------------------------------------------------------------
-- SHIP RAID TRACKING
--------------------------------------------------------------------------------

--[[
  Checks if a raider can raid a specific ship (30s cooldown per ship).
  @param raider The raiding player
  @param ownerUserId The ship owner's UserId
  @return true if the ship can be raided
]]
function SessionStateService:CanRaidShip(raider: Player, ownerUserId: number): boolean
  local state = SessionStates[raider]
  if not state then
    return false
  end
  local lastRaidTime = state.lastRaidedShips[ownerUserId]
  if lastRaidTime and (os.clock() - lastRaidTime) < 30 then
    return false
  end
  return true
end

function SessionStateService:RecordShipRaid(raider: Player, ownerUserId: number)
  local state = SessionStates[raider]
  if not state then
    return
  end
  state.lastRaidedShips[ownerUserId] = os.clock()
end

--------------------------------------------------------------------------------
-- BOUNTY
--------------------------------------------------------------------------------

function SessionStateService:HasBounty(player: Player): boolean
  local state = SessionStates[player]
  return if state then state.hasBounty else false
end

function SessionStateService:SetBounty(player: Player, active: boolean)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.hasBounty = active
  notifyChange(player, "hasBounty", active)
end

--------------------------------------------------------------------------------
-- TUTORIAL
--------------------------------------------------------------------------------

function SessionStateService:IsTutorialActive(player: Player): boolean
  local state = SessionStates[player]
  return if state then state.tutorialActive else false
end

function SessionStateService:GetTutorialStep(player: Player): number
  local state = SessionStates[player]
  return if state then state.tutorialStep else 0
end

function SessionStateService:SetTutorialStep(player: Player, step: number)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.tutorialStep = step
  notifyChange(player, "tutorialStep", step)
end

function SessionStateService:CompleteTutorialSession(player: Player)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.tutorialActive = false
  state.tutorialStep = 0
  notifyChange(player, "tutorialActive", false)
  notifyChange(player, "tutorialStep", 0)
end

--------------------------------------------------------------------------------
-- THREAT LEVEL
--------------------------------------------------------------------------------

function SessionStateService:GetThreatLevel(player: Player): number
  local state = SessionStates[player]
  return if state then state.threatLevel else 0
end

function SessionStateService:AddThreat(player: Player, amount: number): number
  local state = SessionStates[player]
  if not state then
    return 0
  end
  state.threatLevel = math.clamp(state.threatLevel + amount, 0, 100)
  notifyChange(player, "threatLevel", state.threatLevel)
  return state.threatLevel
end

function SessionStateService:SetThreatLevel(player: Player, level: number)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.threatLevel = math.clamp(level, 0, 100)
  notifyChange(player, "threatLevel", state.threatLevel)
end

function SessionStateService:ResetThreat(player: Player)
  self:SetThreatLevel(player, 0)
end

function SessionStateService:GetLastLockTime(player: Player): number
  local state = SessionStates[player]
  return if state then state.lastLockTime else 0
end

--------------------------------------------------------------------------------
-- PHANTOM CAPTAIN
--------------------------------------------------------------------------------

function SessionStateService:IsPhantomCaptainActive(player: Player): boolean
  local state = SessionStates[player]
  return if state then state.phantomCaptainActive else false
end

function SessionStateService:SetPhantomCaptainActive(player: Player, active: boolean)
  local state = SessionStates[player]
  if not state then
    return
  end
  state.phantomCaptainActive = active
end

--------------------------------------------------------------------------------
-- HARBOR ZONE
--------------------------------------------------------------------------------

function SessionStateService:IsInHarbor(player: Player): boolean
  local state = SessionStates[player]
  return if state then state.inHarbor else false
end

function SessionStateService:SetInHarbor(player: Player, inHarbor: boolean)
  local state = SessionStates[player]
  if not state then
    return
  end
  if state.inHarbor == inHarbor then
    return -- no change
  end
  state.inHarbor = inHarbor
  notifyChange(player, "inHarbor", inHarbor)
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS (read-only)
--------------------------------------------------------------------------------

function SessionStateService.Client:GetHeldDoubloons(player: Player): number
  return SessionStateService:GetHeldDoubloons(player)
end

function SessionStateService.Client:GetShipHold(player: Player): number
  return SessionStateService:GetShipHold(player)
end

function SessionStateService.Client:IsShipLocked(player: Player): boolean
  return SessionStateService:IsShipLocked(player)
end

function SessionStateService.Client:GetThreatLevel(player: Player): number
  return SessionStateService:GetThreatLevel(player)
end

function SessionStateService.Client:HasBounty(player: Player): boolean
  return SessionStateService:HasBounty(player)
end

function SessionStateService.Client:IsTutorialActive(player: Player): boolean
  return SessionStateService:IsTutorialActive(player)
end

function SessionStateService.Client:GetTutorialStep(player: Player): number
  return SessionStateService:GetTutorialStep(player)
end

function SessionStateService.Client:IsInHarbor(player: Player): boolean
  return SessionStateService:IsInHarbor(player)
end

--[[
  Returns a snapshot of all client-visible session fields.
  Used by the client to initialize HUD state on load.
]]
function SessionStateService.Client:GetSessionSnapshot(player: Player): { [string]: any }?
  local state = SessionStates[player]
  if not state then
    return nil
  end
  return {
    heldDoubloons = state.heldDoubloons,
    shipHold = state.shipHold,
    shipLocked = state.shipLocked,
    threatLevel = state.threatLevel,
    hasBounty = state.hasBounty,
    tutorialActive = state.tutorialActive,
    tutorialStep = state.tutorialStep,
    inHarbor = state.inHarbor,
  }
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function SessionStateService:KnitInit()
  print("[SessionStateService] Initialized")
end

function SessionStateService:KnitStart()
  DataService = Knit.GetService("DataService")

  -- Initialize session when player data loads
  DataService.PlayerDataLoaded:Connect(function(player: Player, _data)
    self:_initSession(player)
  end)

  -- Clean up session on leave
  Players.PlayerRemoving:Connect(function(player: Player)
    self:_cleanupSession(player)
  end)

  -- Handle players already in game (studio edge case)
  for _, player in Players:GetPlayers() do
    if DataService:IsDataLoaded(player) then
      self:_initSession(player)
    end
  end

  print("[SessionStateService] Started")
end

return SessionStateService
