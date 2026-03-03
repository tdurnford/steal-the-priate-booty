--[[
  SimplePath.lua
  Lightweight PathfindingService wrapper for NPC navigation.

  Wraps Roblox PathfindingService into a clean API for NPC patrol/chase.
  Computes paths and follows waypoints via Humanoid:MoveTo() with
  MoveToFinished progression. Compatible with heartbeat AI loops — call
  :Run() to start, :Stop() to halt, and check :IsRunning() each tick.

  API:
    SimplePath.new(agent: Model, agentParams: {}?) → SimplePath
    path:Run(destination: Vector3)   — compute and follow path
    path:Stop()                      — halt movement
    path:IsRunning(): boolean        — true while following a path
    path:Destroy()                   — cleanup
    path.Reached  — Signal: fired when destination reached
    path.Blocked  — Signal: fired when path blocked mid-traversal
    path.Error    — Signal: fired on path computation failure (errorType: string)
]]

local PathfindingService = game:GetService("PathfindingService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Signal = require(Packages:WaitForChild("GoodSignal"))

local SimplePath = {}
SimplePath.__index = SimplePath

--[[
  Creates a new SimplePath instance for the given NPC agent model.
  @param agent The NPC Model (must have a Humanoid and PrimaryPart/HumanoidRootPart)
  @param agentParams PathfindingService agent parameters (AgentRadius, AgentHeight, etc.)
]]
function SimplePath.new(agent: Model, agentParams: { [string]: any }?)
  local self = setmetatable({}, SimplePath)

  self._agent = agent
  self._humanoid = agent:FindFirstChildOfClass("Humanoid")
  self._agentParams = agentParams or {}
  self._path = PathfindingService:CreatePath(self._agentParams)
  self._waypoints = {} :: { PathWaypoint }
  self._currentIndex = 0
  self._running = false
  self._moveConn = nil :: RBXScriptConnection?
  self._blockedConn = nil :: RBXScriptConnection?

  -- Public signals
  self.Reached = Signal.new()
  self.Blocked = Signal.new()
  self.Error = Signal.new()

  -- Listen for path blocked events
  self._blockedConn = self._path.Blocked:Connect(function(blockedWaypointIndex: number)
    if self._running and blockedWaypointIndex >= self._currentIndex then
      self:_cleanup()
      self.Blocked:Fire(blockedWaypointIndex)
    end
  end)

  return self
end

--[[
  Computes a path to the destination and begins following it.
  Cancels any existing path. Fires Reached when destination is reached,
  Blocked if the path becomes obstructed, or Error if path computation fails.
  @param destination Target world position
]]
function SimplePath:Run(destination: Vector3)
  -- Cancel any existing traversal
  self:_cleanup()

  local rootPart = self._agent.PrimaryPart or self._agent:FindFirstChild("HumanoidRootPart")
  if not rootPart or not self._humanoid then
    self.Error:Fire("NoAgent")
    return
  end

  -- Compute path
  local ok, _err = pcall(function()
    self._path:ComputeAsync(rootPart.Position, destination)
  end)

  if not ok then
    self.Error:Fire("ComputeFailed")
    return
  end

  if self._path.Status ~= Enum.PathStatus.Success then
    self.Error:Fire("PathNotFound")
    return
  end

  local waypoints = self._path:GetWaypoints()
  if #waypoints < 2 then
    -- Already at destination
    self.Reached:Fire()
    return
  end

  self._waypoints = waypoints
  self._currentIndex = 2 -- skip first waypoint (agent's current position)
  self._running = true

  self:_moveToNext()
end

--[[
  Stops following the current path. Does not fire any signals.
]]
function SimplePath:Stop()
  self:_cleanup()
end

--[[
  Returns whether the agent is currently following a path.
]]
function SimplePath:IsRunning(): boolean
  return self._running
end

--[[
  Cleans up all connections and resources.
]]
function SimplePath:Destroy()
  self:_cleanup()
  if self._blockedConn then
    self._blockedConn:Disconnect()
    self._blockedConn = nil
  end
  self.Reached:Destroy()
  self.Blocked:Destroy()
  self.Error:Destroy()
end

-- Internal: stop following without firing signals
function SimplePath:_cleanup()
  self._running = false
  if self._moveConn then
    self._moveConn:Disconnect()
    self._moveConn = nil
  end
end

-- Internal: move to the next waypoint in the path
function SimplePath:_moveToNext()
  if not self._running then
    return
  end

  if self._currentIndex > #self._waypoints then
    -- Reached destination
    self._running = false
    self.Reached:Fire()
    return
  end

  local waypoint = self._waypoints[self._currentIndex]

  -- Handle jump waypoints
  if waypoint.Action == Enum.PathWaypointAction.Jump and self._humanoid then
    self._humanoid.Jump = true
  end

  -- Move to waypoint
  if self._humanoid then
    self._humanoid:MoveTo(waypoint.Position)
  end

  -- Disconnect previous listener (safety)
  if self._moveConn then
    self._moveConn:Disconnect()
  end

  -- Wait for MoveToFinished (fires after reaching or 8s timeout)
  self._moveConn = self._humanoid.MoveToFinished:Connect(function(reached: boolean)
    if self._moveConn then
      self._moveConn:Disconnect()
      self._moveConn = nil
    end

    if not self._running then
      return
    end

    if reached then
      self._currentIndex += 1
      self:_moveToNext()
    else
      -- Timed out (8 seconds) — path may be blocked
      self._running = false
      self.Blocked:Fire(self._currentIndex)
    end
  end)
end

return SimplePath
