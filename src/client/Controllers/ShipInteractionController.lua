--[[
  ShipInteractionController.lua
  Client-side controller for ship interactions (deposit, lock, raid).

  Handles:
    - Creating ProximityPrompts on the local player's own docked ship (deposit, lock)
    - Creating "Raid Ship" ProximityPrompts on OTHER players' unlocked ships
    - Deposit interaction: press E near own ship to deposit all held doubloons
    - Lock interaction: press F near own ship to lock and move hold to treasury
    - Raid interaction: hold R near another player's unlocked ship for 3s to steal 25%
    - Raid progress bar (BillboardGui above raider) during 3s interaction
    - Raid interrupt: cancelled if raider moves too far or is ragdolled
    - Raid alert: notification when YOUR ship is being raided
    - SFX feedback for deposit/lock/unlock/raid events
    - Cleanup on ship despawn or player leave

  ProximityPrompts are created CLIENT-SIDE.
  Own-ship prompts only visible to owner.
  Raid prompts visible to all nearby players on other players' ships.
  The server validates all interactions via ShipService RPCs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local ShipInteractionController = Knit.CreateController({
  Name = "ShipInteractionController",
})

-- Lazy-loaded service/controller references (set in KnitStart)
local ShipService = nil
local SoundController = nil
local NotificationController = nil

-- Local player
local LocalPlayer = Players.LocalPlayer

-- State tracking for the local player's ship
local OwnShipSlotIndex: number? = nil
local OwnShipModel: Model? = nil
local DepositPrompt: ProximityPrompt? = nil
local DepositPromptConnection: RBXScriptConnection? = nil
local LockPrompt: ProximityPrompt? = nil
local LockPromptConnection: RBXScriptConnection? = nil

-- Interaction cooldown to prevent spam
local INTERACTION_COOLDOWN = 0.5 -- seconds
local LastDepositTime = 0
local LastLockTime = 0

-- Raid state tracking for other players' ships
-- Keyed by slotIndex: { prompt, connection, model, ownerUserId, ownerName }
local RaidPrompts: {
  [number]: {
    prompt: ProximityPrompt,
    connection: RBXScriptConnection,
    model: Model,
    ownerUserId: number,
    ownerName: string,
  },
} =
  {}

-- Active raid state (local player is raiding)
local IsRaiding = false
local RaidProgressGui: BillboardGui? = nil
local RaidProgressBar: Frame? = nil
local RaidStartTime: number = 0
local RaidHeartbeatConnection: RBXScriptConnection? = nil
local RAID_DURATION = 3 -- matches GameConfig.ShipSystem.raidDuration

--------------------------------------------------------------------------------
-- SHIP MODEL LOOKUP
--------------------------------------------------------------------------------

--[[
  Finds a ship model in workspace.DockedShips by slot index and owner name.
  @param slotIndex The dock slot index
  @param ownerName The owner's display name
  @return Model or nil
]]
local function findShipModel(slotIndex: number, ownerName: string): Model?
  local shipsFolder = workspace:FindFirstChild("DockedShips")
  if not shipsFolder then
    return nil
  end

  local modelName = "Ship_" .. ownerName .. "_Slot" .. slotIndex
  return shipsFolder:FindFirstChild(modelName)
end

--------------------------------------------------------------------------------
-- RAID PROGRESS BAR
--------------------------------------------------------------------------------

--[[
  Removes the raid progress bar GUI.
]]
local function cleanupRaidProgressGui()
  if RaidHeartbeatConnection then
    RaidHeartbeatConnection:Disconnect()
    RaidHeartbeatConnection = nil
  end
  if RaidProgressGui then
    RaidProgressGui:Destroy()
    RaidProgressGui = nil
  end
  RaidProgressBar = nil
end

--[[
  Creates a BillboardGui progress bar above the local player's head
  to show raid progress (3 seconds).
]]
local function createRaidProgressGui()
  cleanupRaidProgressGui()

  local character = LocalPlayer.Character
  local head = character and character:FindFirstChild("Head")
  if not head then
    return
  end

  local gui = Instance.new("BillboardGui")
  gui.Name = "RaidProgressGui"
  gui.Size = UDim2.new(0, 120, 0, 16)
  gui.StudsOffset = Vector3.new(0, 3, 0)
  gui.AlwaysOnTop = true
  gui.MaxDistance = 60
  gui.Parent = head

  -- Background bar
  local bgBar = Instance.new("Frame")
  bgBar.Name = "Background"
  bgBar.Size = UDim2.new(1, 0, 1, 0)
  bgBar.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
  bgBar.BorderSizePixel = 0
  bgBar.Parent = gui

  local bgCorner = Instance.new("UICorner")
  bgCorner.CornerRadius = UDim.new(0, 4)
  bgCorner.Parent = bgBar

  local bgStroke = Instance.new("UIStroke")
  bgStroke.Color = Color3.fromRGB(255, 70, 70)
  bgStroke.Thickness = 2
  bgStroke.Parent = bgBar

  -- Fill bar
  local fillBar = Instance.new("Frame")
  fillBar.Name = "Fill"
  fillBar.Size = UDim2.new(0, 0, 1, 0)
  fillBar.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
  fillBar.BorderSizePixel = 0
  fillBar.Parent = bgBar

  local fillCorner = Instance.new("UICorner")
  fillCorner.CornerRadius = UDim.new(0, 4)
  fillCorner.Parent = fillBar

  -- Label
  local label = Instance.new("TextLabel")
  label.Name = "Label"
  label.Size = UDim2.new(1, 0, 1, 0)
  label.BackgroundTransparency = 1
  label.Text = "RAIDING..."
  label.TextColor3 = Color3.fromRGB(255, 255, 255)
  label.TextSize = 10
  label.Font = Enum.Font.GothamBold
  label.ZIndex = 2
  label.Parent = bgBar

  RaidProgressGui = gui
  RaidProgressBar = fillBar
end

--------------------------------------------------------------------------------
-- PROXIMITY PROMPT MANAGEMENT (own ship)
--------------------------------------------------------------------------------

--[[
  Creates a ProximityPrompt on the ship hull for depositing.
  Only called for the local player's own ship.
  @param hull The ship's Hull BasePart
]]
local function createDepositPrompt(hull: BasePart)
  -- Clean up any existing prompt
  if DepositPrompt then
    DepositPrompt:Destroy()
    DepositPrompt = nil
  end
  if DepositPromptConnection then
    DepositPromptConnection:Disconnect()
    DepositPromptConnection = nil
  end

  local prompt = Instance.new("ProximityPrompt")
  prompt.Name = "DepositPrompt"
  prompt.ActionText = "Deposit All"
  prompt.ObjectText = "Your Ship"
  prompt.MaxActivationDistance = 15
  prompt.HoldDuration = 0
  prompt.RequiresLineOfSight = false
  prompt.KeyboardKeyCode = Enum.KeyCode.E
  prompt.Parent = hull

  DepositPrompt = prompt

  DepositPromptConnection = prompt.Triggered:Connect(function()
    local now = os.clock()
    if (now - LastDepositTime) < INTERACTION_COOLDOWN then
      return
    end
    LastDepositTime = now

    if not ShipService then
      return
    end

    ShipService:DepositAll()
      :andThen(function(success: boolean, message: string?)
        if not success then
          if message == "No doubloons to deposit" then
            return
          end
          warn("[ShipInteractionController] Deposit failed:", message)
        end
      end)
      :catch(function(err)
        warn("[ShipInteractionController] Deposit error:", err)
      end)
  end)
end

--[[
  Creates a ProximityPrompt on the ship hull for locking.
  Only called for the local player's own ship.
  @param hull The ship's Hull BasePart
]]
local function createLockPrompt(hull: BasePart)
  -- Clean up any existing prompt
  if LockPrompt then
    LockPrompt:Destroy()
    LockPrompt = nil
  end
  if LockPromptConnection then
    LockPromptConnection:Disconnect()
    LockPromptConnection = nil
  end

  local prompt = Instance.new("ProximityPrompt")
  prompt.Name = "LockPrompt"
  prompt.ActionText = "Lock Ship"
  prompt.ObjectText = "Secure Treasury"
  prompt.MaxActivationDistance = 15
  prompt.HoldDuration = 0
  prompt.RequiresLineOfSight = false
  prompt.KeyboardKeyCode = Enum.KeyCode.F
  prompt.Parent = hull

  LockPrompt = prompt

  LockPromptConnection = prompt.Triggered:Connect(function()
    local now = os.clock()
    if (now - LastLockTime) < INTERACTION_COOLDOWN then
      return
    end
    LastLockTime = now

    if not ShipService then
      return
    end

    ShipService:LockShip()
      :andThen(function(success: boolean, message: string?)
        if not success then
          if message == "Ship is already locked" then
            return
          end
          warn("[ShipInteractionController] Lock failed:", message)
        end
      end)
      :catch(function(err)
        warn("[ShipInteractionController] Lock error:", err)
      end)
  end)
end

--[[
  Removes the deposit ProximityPrompt and disconnects events.
]]
local function cleanupDepositPrompt()
  if DepositPromptConnection then
    DepositPromptConnection:Disconnect()
    DepositPromptConnection = nil
  end
  if DepositPrompt then
    DepositPrompt:Destroy()
    DepositPrompt = nil
  end
end

--[[
  Removes the lock ProximityPrompt and disconnects events.
]]
local function cleanupLockPrompt()
  if LockPromptConnection then
    LockPromptConnection:Disconnect()
    LockPromptConnection = nil
  end
  if LockPrompt then
    LockPrompt:Destroy()
    LockPrompt = nil
  end
end

--------------------------------------------------------------------------------
-- RAID PROMPT MANAGEMENT (other players' ships)
--------------------------------------------------------------------------------

--[[
  Cancels the local player's active raid (client-side cleanup + server cancel).
]]
local function cancelLocalRaid()
  if not IsRaiding then
    return
  end
  IsRaiding = false
  cleanupRaidProgressGui()
  if ShipService then
    ShipService:CancelRaid()
  end
end

--[[
  Creates a "Raid Ship" ProximityPrompt on another player's ship hull.
  Uses HoldDuration of 0 (server manages the timer); prompt triggers start.
  @param slotIndex The dock slot index
  @param ownerUserId The ship owner's UserId
  @param ownerName The ship owner's display name
  @param hull The ship's Hull BasePart
]]
local function createRaidPrompt(
  slotIndex: number,
  ownerUserId: number,
  ownerName: string,
  hull: BasePart
)
  -- Clean up any existing raid prompt for this slot
  if RaidPrompts[slotIndex] then
    if RaidPrompts[slotIndex].connection then
      RaidPrompts[slotIndex].connection:Disconnect()
    end
    if RaidPrompts[slotIndex].prompt then
      RaidPrompts[slotIndex].prompt:Destroy()
    end
    RaidPrompts[slotIndex] = nil
  end

  local prompt = Instance.new("ProximityPrompt")
  prompt.Name = "RaidPrompt"
  prompt.ActionText = "Raid Ship"
  prompt.ObjectText = ownerName .. "'s Ship"
  prompt.MaxActivationDistance = 15
  prompt.HoldDuration = 0
  prompt.RequiresLineOfSight = false
  prompt.KeyboardKeyCode = Enum.KeyCode.R
  prompt.Parent = hull

  local connection = prompt.Triggered:Connect(function()
    if IsRaiding then
      return
    end
    if not ShipService then
      return
    end

    -- Request server to start raid
    ShipService:StartRaid(slotIndex)
      :andThen(function(success: boolean, message: string?)
        if not success then
          if message and message ~= "" then
            if NotificationController then
              NotificationController:ShowNotification(message, Color3.fromRGB(255, 100, 100), 2)
            end
          end
          return
        end

        -- Raid started! Show progress bar
        IsRaiding = true
        RaidStartTime = os.clock()
        createRaidProgressGui()

        if SoundController then
          SoundController:PlayRaidStartSound()
        end

        -- Update progress bar each frame
        RaidHeartbeatConnection = RunService.Heartbeat:Connect(function()
          if not IsRaiding or not RaidProgressBar then
            return
          end
          local elapsed = os.clock() - RaidStartTime
          local progress = math.clamp(elapsed / RAID_DURATION, 0, 1)
          RaidProgressBar.Size = UDim2.new(progress, 0, 1, 0)
        end)
      end)
      :catch(function(err)
        warn("[ShipInteractionController] StartRaid error:", err)
      end)
  end)

  RaidPrompts[slotIndex] = {
    prompt = prompt,
    connection = connection,
    model = hull.Parent :: Model,
    ownerUserId = ownerUserId,
    ownerName = ownerName,
  }
end

--[[
  Removes a raid prompt for a specific dock slot.
  @param slotIndex The dock slot index
]]
local function cleanupRaidPrompt(slotIndex: number)
  local data = RaidPrompts[slotIndex]
  if not data then
    return
  end
  if data.connection then
    data.connection:Disconnect()
  end
  if data.prompt then
    data.prompt:Destroy()
  end
  RaidPrompts[slotIndex] = nil
end

--------------------------------------------------------------------------------
-- SHIP TRACKING (own ship)
--------------------------------------------------------------------------------

--[[
  Sets up the local player's own ship with deposit and lock prompts.
  @param slotIndex The dock slot index
  @param ownerName The owner's display name
]]
local function setupOwnShip(slotIndex: number, ownerName: string)
  -- Small delay to ensure model replication
  task.defer(function()
    local model = findShipModel(slotIndex, ownerName)
    if not model then
      warn("[ShipInteractionController] Could not find own ship model at slot", slotIndex)
      return
    end

    local hull = model:FindFirstChild("Hull")
    if not hull or not hull:IsA("BasePart") then
      warn("[ShipInteractionController] Ship model has no Hull part")
      return
    end

    OwnShipSlotIndex = slotIndex
    OwnShipModel = model
    createDepositPrompt(hull)
    createLockPrompt(hull)

    print("[ShipInteractionController] Ship prompts created on own ship at slot", slotIndex)
  end)
end

--[[
  Cleans up the local player's ship tracking.
]]
local function cleanupOwnShip()
  cleanupDepositPrompt()
  cleanupLockPrompt()
  OwnShipSlotIndex = nil
  OwnShipModel = nil
end

--------------------------------------------------------------------------------
-- SHIP TRACKING (other players' ships — raid prompts)
--------------------------------------------------------------------------------

--[[
  Sets up a raid prompt on another player's ship.
  @param slotIndex The dock slot index
  @param ownerUserId The ship owner's UserId
  @param ownerName The ship owner's display name
]]
local function setupRaidableShip(slotIndex: number, ownerUserId: number, ownerName: string)
  task.defer(function()
    local model = findShipModel(slotIndex, ownerName)
    if not model then
      return
    end

    local hull = model:FindFirstChild("Hull")
    if not hull or not hull:IsA("BasePart") then
      return
    end

    createRaidPrompt(slotIndex, ownerUserId, ownerName, hull)
  end)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ShipInteractionController:KnitInit()
  print("[ShipInteractionController] Initialized")
end

function ShipInteractionController:KnitStart()
  ShipService = Knit.GetService("ShipService")
  SoundController = Knit.GetController("SoundController")
  NotificationController = Knit.GetController("NotificationController")

  local localUserId = LocalPlayer.UserId

  -- Listen for ship spawns — set up prompts
  ShipService.ShipSpawned:Connect(
    function(
      slotIndex: number,
      ownerUserId: number,
      ownerName: string,
      _shipTierId: string,
      _position: Vector3
    )
      if ownerUserId == localUserId then
        setupOwnShip(slotIndex, ownerName)
      else
        -- Other player's ship: add raid prompt
        setupRaidableShip(slotIndex, ownerUserId, ownerName)
      end
    end
  )

  -- Listen for ship despawns — clean up prompts
  ShipService.ShipDespawned:Connect(function(slotIndex: number, ownerUserId: number)
    if ownerUserId == localUserId then
      cleanupOwnShip()
    else
      cleanupRaidPrompt(slotIndex)
    end
  end)

  -- Listen for ship tier changes — recreate prompts on new model
  ShipService.ShipTierChanged:Connect(
    function(slotIndex: number, ownerUserId: number, _newShipTierId: string)
      if ownerUserId == localUserId then
        cleanupOwnShip()
        setupOwnShip(slotIndex, LocalPlayer.Name)
      else
        -- Other player's ship tier changed — recreate raid prompt
        local data = RaidPrompts[slotIndex]
        if data then
          local ownerName = data.ownerName
          cleanupRaidPrompt(slotIndex)
          setupRaidableShip(slotIndex, ownerUserId, ownerName)
        end
      end
    end
  )

  -- Listen for deposit completion — play SFX
  ShipService.DepositCompleted:Connect(
    function(_slotIndex: number, _amountDeposited: number, _newShipHold: number)
      if SoundController then
        SoundController:PlayDepositSound()
      end
    end
  )

  -- Listen for lock completion — play SFX
  ShipService.LockCompleted:Connect(
    function(_slotIndex: number, _amountLocked: number, _newTreasury: number)
      if SoundController then
        SoundController:PlayLockSound()
      end
    end
  )

  -- Listen for ship unlock — play SFX
  ShipService.ShipUnlocked:Connect(function(_slotIndex: number)
    if SoundController then
      SoundController:PlayUnlockSound()
    end
  end)

  -- Listen for raid completion — play SFX, clean up progress bar
  ShipService.RaidCompleted:Connect(function(_slotIndex: number, amountStolen: number)
    IsRaiding = false
    cleanupRaidProgressGui()
    if SoundController then
      SoundController:PlayRaidCompleteSound()
    end
    if NotificationController then
      NotificationController:ShowNotification(
        "Raided " .. amountStolen .. " doubloons!",
        Color3.fromRGB(255, 200, 50),
        3
      )
    end
  end)

  -- Listen for raid interrupts — clean up progress bar
  ShipService.RaidInterrupted:Connect(function(reason: string)
    IsRaiding = false
    cleanupRaidProgressGui()
    if NotificationController and reason ~= "Cancelled by player" then
      NotificationController:ShowNotification(
        "Raid interrupted: " .. reason,
        Color3.fromRGB(255, 100, 100),
        2
      )
    end
  end)

  -- Listen for raid alerts (someone is raiding YOUR ship)
  ShipService.RaidAlert:Connect(function(raiderName: string, _slotIndex: number)
    if SoundController then
      SoundController:PlayRaidAlertSound()
    end
    if NotificationController then
      NotificationController:ShowNotification(
        "YOUR SHIP IS BEING RAIDED by " .. raiderName .. "!",
        Color3.fromRGB(255, 70, 70),
        4
      )
    end
  end)

  -- Check if own ship is already spawned (late join / studio restart)
  ShipService:GetMyShip()
    :andThen(function(slotIndex: number?, _shipTierId: string?, _position: Vector3?)
      if slotIndex then
        setupOwnShip(slotIndex, LocalPlayer.Name)
      end
    end)
    :catch(function(err)
      warn("[ShipInteractionController] Failed to get own ship:", err)
    end)

  -- Also fetch all existing ships to set up raid prompts on late join
  ShipService:GetAllDockedShips()
    :andThen(function(ships)
      if not ships then
        return
      end
      for _, ship in ships do
        if ship.ownerUserId ~= localUserId then
          setupRaidableShip(ship.slotIndex, ship.ownerUserId, ship.ownerName)
        end
      end
    end)
    :catch(function(err)
      warn("[ShipInteractionController] Failed to get all docked ships:", err)
    end)

  print("[ShipInteractionController] Started")
end

return ShipInteractionController
