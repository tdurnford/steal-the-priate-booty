--[[
  ShipInteractionController.lua
  Client-side controller for ship interactions (deposit, future: lock, raid).

  Handles:
    - Creating ProximityPrompt on the local player's own docked ship
    - Deposit interaction: press E near own ship to deposit all held doubloons
    - Deposit SFX feedback on successful deposit
    - Cleanup on ship despawn or player leave

  The ProximityPrompt is created CLIENT-SIDE only on the local player's ship,
  so only the owner sees the deposit prompt. The server validates all deposits
  via ShipService:DepositAll().
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
local PromptConnection: RBXScriptConnection? = nil

-- Deposit cooldown to prevent spam
local DEPOSIT_COOLDOWN = 0.5 -- seconds
local LastDepositTime = 0

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
  if PromptConnection then
    PromptConnection:Disconnect()
    PromptConnection = nil
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

  PromptConnection = prompt.Triggered:Connect(function()
    local now = os.clock()
    if (now - LastDepositTime) < DEPOSIT_COOLDOWN then
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
  Removes the deposit ProximityPrompt and disconnects events.
]]
local function cleanupDepositPrompt()
  if PromptConnection then
    PromptConnection:Disconnect()
    PromptConnection = nil
  end
  if DepositPrompt then
    DepositPrompt:Destroy()
    DepositPrompt = nil
  end
end

--------------------------------------------------------------------------------
-- SHIP TRACKING
--------------------------------------------------------------------------------

--[[
  Sets up the local player's own ship with a deposit prompt.
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

    print("[ShipInteractionController] Deposit prompt created on own ship at slot", slotIndex)
  end)
end

--[[
  Cleans up the local player's ship tracking.
]]
local function cleanupOwnShip()
  cleanupDepositPrompt()
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
    function(_slotIndex: number, amountDeposited: number, _newShipHold: number)
      if SoundController then
        SoundController:PlayDepositSound()
      end
    end
  )

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
