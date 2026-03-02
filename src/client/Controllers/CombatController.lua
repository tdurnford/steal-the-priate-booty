--[[
  CombatController.lua
  Client-side combat input handler for light swing attacks.

  Handles:
    - Detecting primary click (Mouse1 / Touch tap) for light swing
    - Sending attack intent to CombatService
    - Client-side cooldown display (to prevent spamming the server)
    - Playing swing animation and SFX on attack
    - Receiving hit confirmation and ragdoll triggers from server
    - Physics-based ragdoll via RagdollModule (joint disabling, knockback, tumble)
    - Character respawn cleanup for ragdoll state

  The server performs all validation and hit detection.
  This controller is purely for input and visual feedback.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local RagdollModule = require(Shared:WaitForChild("RagdollModule"))

local CombatController = Knit.CreateController({
  Name = "CombatController",
})

-- Lazy-loaded references
local CombatService = nil
local SoundController = nil

-- Local state
local LocalPlayer = Players.LocalPlayer
local LastSwingTime = 0
local IsRagdolled = false
local RagdollEndTime = 0

-- Client-side cooldown (mirrors server for responsive feel)
local LIGHT_SWING_COOLDOWN = GameConfig.Combat.lightSwingCooldown

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Gets the local player's HumanoidRootPart.
  @return BasePart? or nil
]]
local function getLocalHRP(): BasePart?
  local character = LocalPlayer.Character
  if not character then
    return nil
  end
  return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
  Gets the local player's Humanoid.
  @return Humanoid? or nil
]]
local function getLocalHumanoid(): Humanoid?
  local character = LocalPlayer.Character
  if not character then
    return nil
  end
  return character:FindFirstChildOfClass("Humanoid")
end

--[[
  Plays a simple swing animation on the local character.
  Uses a placeholder animation — replace with proper cutlass animation later.
]]
local function playSwingAnimation()
  local humanoid = getLocalHumanoid()
  if not humanoid then
    return
  end

  -- Create a simple animation track for the swing.
  -- This uses a generic slash animation ID as a placeholder.
  -- Replace with custom cutlass animation when COMBAT-VFX-001 is implemented.
  local animator = humanoid:FindFirstChildOfClass("Animator")
  if not animator then
    return
  end

  local animation = Instance.new("Animation")
  animation.AnimationId = "rbxassetid://522635514" -- generic slash placeholder
  local track = animator:LoadAnimation(animation)
  track.Priority = Enum.AnimationPriority.Action
  track:Play(0.05, 1, 2) -- fast fadein, full weight, 2x speed for snappy feel
  animation:Destroy()
end

-- Tracks the active ragdoll cleanup task so overlapping ragdolls cancel the old one
local RagdollCleanupThread: thread? = nil

--[[
  Checks if the client-side cooldown has elapsed.
  @return true if the player can swing
]]
local function canSwing(): boolean
  if IsRagdolled then
    return false
  end

  local now = os.clock()
  return (now - LastSwingTime) >= LIGHT_SWING_COOLDOWN
end

--------------------------------------------------------------------------------
-- INPUT HANDLING
--------------------------------------------------------------------------------

--[[
  Called on primary click (Mouse1).
  Validates local cooldown and sends attack intent to server.
]]
local function onPrimaryClick()
  if not canSwing() then
    return
  end

  -- Update local cooldown
  LastSwingTime = os.clock()

  -- Play swing animation and swoosh SFX immediately (client-side prediction)
  playSwingAnimation()
  if SoundController then
    SoundController:PlaySwingSound()
  end

  -- Send attack request to server
  if CombatService then
    CombatService.AttackRequest:Fire()
  end
end

--------------------------------------------------------------------------------
-- SERVER EVENT HANDLERS
--------------------------------------------------------------------------------

--[[
  Called when the server confirms a swing result.
  @param hitType "player" | "container" | "miss"
  @param targetName string? Name of what was hit
]]
local function onSwingResult(hitType: string, targetName: string?)
  -- Play appropriate hit sound
  if SoundController then
    local hrp = getLocalHRP()
    SoundController:PlayCombatHitSound(hitType, hrp)
  end
end

--[[
  Called when the server tells this player to ragdoll.
  Enables physics-based ragdoll with knockback and schedules recovery.
  @param attackerName string Name of the player who hit us
  @param ragdollDuration number How long to ragdoll
  @param knockbackVelocity Vector3? Optional knockback impulse direction + force
]]
local function onRagdollTrigger(
  attackerName: string,
  ragdollDuration: number,
  knockbackVelocity: Vector3?
)
  IsRagdolled = true
  RagdollEndTime = os.clock() + ragdollDuration

  -- Cancel any pending ragdoll cleanup from a previous hit
  if RagdollCleanupThread then
    task.cancel(RagdollCleanupThread)
    RagdollCleanupThread = nil
  end

  local character = LocalPlayer.Character
  if character then
    -- Enable physics-based ragdoll with knockback
    RagdollModule.enable(character, knockbackVelocity)

    -- Schedule ragdoll disable after duration
    RagdollCleanupThread = task.delay(ragdollDuration, function()
      RagdollCleanupThread = nil
      if character and character.Parent then
        RagdollModule.disable(character)
      end
    end)
  end

  -- Clear input lockout after ragdoll + recovery window
  local totalLockout = ragdollDuration + GameConfig.Combat.recoveryWindow
  task.delay(totalLockout, function()
    IsRagdolled = false
  end)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function CombatController:KnitInit()
  print("[CombatController] Initializing...")
end

function CombatController:KnitStart()
  -- Get service and controller references
  CombatService = Knit.GetService("CombatService")
  SoundController = Knit.GetController("SoundController")

  -- Listen for server events
  CombatService.SwingResult:Connect(onSwingResult)
  CombatService.RagdollTrigger:Connect(onRagdollTrigger)

  -- Clean up ragdoll state on character removal (death/respawn)
  LocalPlayer.CharacterRemoving:Connect(function(character: Model)
    RagdollModule.cleanup(character)
    IsRagdolled = false
    if RagdollCleanupThread then
      task.cancel(RagdollCleanupThread)
      RagdollCleanupThread = nil
    end
  end)

  -- Listen for primary click input
  UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then
      return
    end

    if
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.Touch
    then
      onPrimaryClick()
    end
  end)

  print("[CombatController] Started — primary click to attack")
end

return CombatController
