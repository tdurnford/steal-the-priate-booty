--[[
  ShipInteractionController.lua
  Client-side controller for ship interactions (deposit, lock, future: raid).

  Handles:
    - Creating ProximityPrompts on the local player's own docked ship
    - Deposit interaction: press E near own ship to deposit all held doubloons
    - Lock interaction: press F near own ship to lock and move hold to treasury
    - Deposit/Lock SFX feedback on success
    - Ship unlock notification when leaving Harbor zone
    - Cleanup on ship despawn or player leave

  ProximityPrompts are created CLIENT-SIDE only on the local player's ship,
  so only the owner sees the prompts. The server validates all interactions
  via ShipService RPCs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))

local ShipInteractionController = Knit.CreateController({
  Name = "ShipInteractionController",
})

-- Lazy-loaded service/controller references (set in KnitStart)
local ShipService = nil
local SoundController = nil

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
-- PROXIMITY PROMPT MANAGEMENT
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
            -- Silent — no doubloons is a normal state
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
            -- Silent — already locked is a normal state
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
-- SHIP TRACKING
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
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function ShipInteractionController:KnitInit()
  print("[ShipInteractionController] Initialized")
end

function ShipInteractionController:KnitStart()
  ShipService = Knit.GetService("ShipService")
  SoundController = Knit.GetController("SoundController")

  local localUserId = LocalPlayer.UserId

  -- Listen for ship spawns — set up prompt on own ship
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
      end
    end
  )

  -- Listen for ship despawns — clean up if own ship
  ShipService.ShipDespawned:Connect(function(_slotIndex: number, ownerUserId: number)
    if ownerUserId == localUserId then
      cleanupOwnShip()
    end
  end)

  -- Listen for ship tier changes — recreate prompt on new model
  ShipService.ShipTierChanged:Connect(
    function(slotIndex: number, ownerUserId: number, _newShipTierId: string)
      if ownerUserId == localUserId then
        -- Tier change replaces the model, so we need to re-setup
        cleanupOwnShip()
        setupOwnShip(slotIndex, LocalPlayer.Name)
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

  print("[ShipInteractionController] Started")
end

return ShipInteractionController
