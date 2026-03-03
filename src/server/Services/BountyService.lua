--[[
  BountyService.lua
  Server-authoritative bounty system (EVENT-001).

  Every 60 seconds, checks for the player with the most held (unbanked)
  doubloons. If that player has 200+, they receive a bounty:
    - Skull BillboardGui above their head (visible to all)
    - Double loot spill on PvP hits (handled by CombatService via SessionState)
    - Position on minimap (future: UI-005)

  Bounty clears when:
    1. Target deposits loot (held < clearThreshold)
    2. Held doubloons drop below 100 (from spills, etc.)
    3. 90 seconds elapsed
    4. Target disconnects

  Only one bounty active at a time.
  All gameplay effects (double spill, XP hooks) are already wired via
  SessionStateService:HasBounty() — this service just manages assignment/clearing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local BountyService = Knit.CreateService({
  Name = "BountyService",
  Client = {
    -- Fired to ALL clients when a bounty is assigned.
    -- Args: (targetUserId: number, targetDisplayName: string)
    BountyStarted = Knit.CreateSignal(),

    -- Fired to ALL clients when a bounty ends.
    -- Args: (targetUserId: number, reason: string)
    BountyEnded = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service use
BountyService.BountyAssigned = Signal.new() -- (player: Player)
BountyService.BountyCleared = Signal.new() -- (player: Player, reason: string)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local HarborService = nil

-- Current bounty state
local BountyTarget: Player? = nil -- the player with the active bounty
local BountyStartTime: number = 0 -- os.clock() when bounty was assigned
local SkullBillboard: BillboardGui? = nil -- the skull icon above the target

-- Timer accumulator for the 60s check
local CheckAccumulator: number = 0

--------------------------------------------------------------------------------
-- SKULL BILLBOARD GUI
--------------------------------------------------------------------------------

--[[
  Creates a skull BillboardGui and parents it to the target character's head.
  Visible to all players (server-created = replicated).
]]
local function createSkullBillboard(character: Model): BillboardGui?
  local head = character:FindFirstChild("Head")
  if not head then
    return nil
  end

  local billboard = Instance.new("BillboardGui")
  billboard.Name = "BountySkull"
  billboard.Size = UDim2.new(0, 50, 0, 50)
  billboard.StudsOffset = Vector3.new(0, 3, 0)
  billboard.AlwaysOnTop = true
  billboard.MaxDistance = 200
  billboard.LightInfluence = 0

  -- Skull emoji text label
  local skullLabel = Instance.new("TextLabel")
  skullLabel.Name = "SkullIcon"
  skullLabel.Size = UDim2.new(1, 0, 1, 0)
  skullLabel.BackgroundTransparency = 1
  skullLabel.Text = "\u{1F480}" -- skull emoji
  skullLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
  skullLabel.TextScaled = true
  skullLabel.Font = Enum.Font.GothamBold
  skullLabel.TextStrokeTransparency = 0.3
  skullLabel.TextStrokeColor3 = Color3.fromRGB(80, 0, 0)
  skullLabel.Parent = billboard

  -- Pulsing glow ring behind the skull
  local glowLabel = Instance.new("TextLabel")
  glowLabel.Name = "Glow"
  glowLabel.Size = UDim2.new(1.4, 0, 1.4, 0)
  glowLabel.Position = UDim2.new(-0.2, 0, -0.2, 0)
  glowLabel.BackgroundTransparency = 1
  glowLabel.Text = "\u{1F480}"
  glowLabel.TextColor3 = Color3.fromRGB(255, 0, 0)
  glowLabel.TextTransparency = 0.6
  glowLabel.TextScaled = true
  glowLabel.Font = Enum.Font.GothamBold
  glowLabel.ZIndex = 0
  glowLabel.Parent = billboard

  billboard.Parent = head
  return billboard
end

--[[
  Removes the skull BillboardGui from the target.
]]
local function removeSkullBillboard()
  if SkullBillboard then
    SkullBillboard:Destroy()
    SkullBillboard = nil
  end
end

--------------------------------------------------------------------------------
-- BOUNTY ASSIGNMENT / CLEARING
--------------------------------------------------------------------------------

--[[
  Assigns a bounty to the given player.
  @param player The player to receive the bounty
]]
local function assignBounty(player: Player)
  if BountyTarget then
    return -- already have an active bounty
  end

  BountyTarget = player
  BountyStartTime = os.clock()

  -- Set session state (enables double spill in CombatService, XP hooks in NotorietyService)
  SessionStateService:SetBounty(player, true)

  -- Create skull billboard above their head
  local character = player.Character
  if character then
    SkullBillboard = createSkullBillboard(character)
  end

  -- Fire server-side signal
  BountyService.BountyAssigned:Fire(player)

  -- Notify all clients
  BountyService.Client.BountyStarted:FireAll(player.UserId, player.DisplayName)

  print("[BountyService] Bounty assigned to", player.Name, "(" .. player.DisplayName .. ")")
end

--[[
  Clears the active bounty.
  @param reason Why the bounty was cleared (deposit, loot_dropped, timeout, disconnect)
]]
local function clearBounty(reason: string)
  local target = BountyTarget
  if not target then
    return
  end

  -- Clear state
  BountyTarget = nil
  BountyStartTime = 0
  removeSkullBillboard()

  -- Clear session state (only if player is still connected)
  if target.Parent then
    SessionStateService:SetBounty(target, false)
  end

  -- Fire server-side signal
  BountyService.BountyCleared:Fire(target, reason)

  -- Notify all clients
  BountyService.Client.BountyEnded:FireAll(target.UserId, reason)

  print("[BountyService] Bounty cleared on", target.Name, "- reason:", reason)
end

--------------------------------------------------------------------------------
-- BOUNTY CHECK LOGIC
--------------------------------------------------------------------------------

--[[
  Runs the 60-second bounty eligibility check.
  Finds the player with the most held doubloons (200+ threshold).
  Skips if:
    - A bounty is already active
    - Player is in the harbor
]]
local function runBountyCheck()
  -- Skip if bounty already active
  if BountyTarget then
    return
  end

  local bestPlayer: Player? = nil
  local bestHeld = 0

  for _, player in Players:GetPlayers() do
    -- Skip players without session state
    if not SessionStateService:IsInitialized(player) then
      continue
    end

    -- Skip players in harbor (safe zone)
    if HarborService and SessionStateService:IsInHarbor(player) then
      continue
    end

    local held = SessionStateService:GetHeldDoubloons(player)
    if held >= GameConfig.Bounty.activationThreshold and held > bestHeld then
      bestHeld = held
      bestPlayer = player
    end
  end

  if bestPlayer then
    assignBounty(bestPlayer)
  end
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS
--------------------------------------------------------------------------------

--[[
  Returns whether a bounty is currently active on the server.
]]
function BountyService.Client:IsBountyActive(_player: Player): boolean
  return BountyTarget ~= nil
end

--[[
  Returns the UserId of the current bounty target, or 0 if none.
]]
function BountyService.Client:GetBountyTargetUserId(_player: Player): number
  if BountyTarget then
    return BountyTarget.UserId
  end
  return 0
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function BountyService:KnitInit()
  print("[BountyService] Initialized")
end

function BountyService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")

  -- HarborService may not exist yet; try to get it
  local ok, harbor = pcall(function()
    return Knit.GetService("HarborService")
  end)
  if ok then
    HarborService = harbor
  end

  -- Listen for held doubloon changes to check clear condition
  SessionStateService.StateChanged:Connect(
    function(player: Player, fieldName: string, newValue: any)
      if fieldName ~= "heldDoubloons" then
        return
      end

      -- Check if the bounty target's doubloons dropped below threshold
      if BountyTarget and BountyTarget == player then
        if type(newValue) == "number" and newValue < GameConfig.Bounty.clearThreshold then
          clearBounty("loot_dropped")
        end
      end
    end
  )

  -- Clear bounty if target disconnects
  Players.PlayerRemoving:Connect(function(player: Player)
    if BountyTarget and BountyTarget == player then
      clearBounty("disconnect")
    end
  end)

  -- Re-attach skull if bounty target respawns (character reload)
  Players.PlayerAdded:Connect(function(player: Player)
    player.CharacterAdded:Connect(function(character: Model)
      if BountyTarget and BountyTarget == player then
        removeSkullBillboard()
        -- Small delay for character to fully load
        task.delay(0.5, function()
          if BountyTarget and BountyTarget == player then
            SkullBillboard = createSkullBillboard(character)
          end
        end)
      end
    end)
  end)

  -- Handle players already in game (studio edge case)
  for _, player in Players:GetPlayers() do
    player.CharacterAdded:Connect(function(character: Model)
      if BountyTarget and BountyTarget == player then
        removeSkullBillboard()
        task.delay(0.5, function()
          if BountyTarget and BountyTarget == player then
            SkullBillboard = createSkullBillboard(character)
          end
        end)
      end
    end)
  end

  -- Main bounty check loop (60s interval) + timeout check
  local timeoutAccumulator = 0
  RunService.Heartbeat:Connect(function(dt: number)
    -- Check for bounty timeout
    if BountyTarget then
      timeoutAccumulator = timeoutAccumulator + dt
      if timeoutAccumulator >= 1 then -- check once per second
        timeoutAccumulator = 0
        local elapsed = os.clock() - BountyStartTime
        if elapsed >= GameConfig.Bounty.duration then
          clearBounty("timeout")
        end
      end
    else
      timeoutAccumulator = 0
    end

    -- Run 60s bounty assignment check
    CheckAccumulator = CheckAccumulator + dt
    if CheckAccumulator >= GameConfig.Bounty.checkInterval then
      CheckAccumulator = 0
      runBountyCheck()
    end
  end)

  print("[BountyService] Started")
end

return BountyService
