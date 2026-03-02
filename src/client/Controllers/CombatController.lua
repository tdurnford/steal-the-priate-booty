--[[
  CombatController.lua
  Client-side combat input handler for light swing attacks.

  Handles:
    - Detecting primary click (Mouse1 / Touch tap) for light swing
    - Sending attack intent to CombatService
    - Client-side cooldown display (to prevent spamming the server)
    - Playing swing animation and SFX on attack
    - Receiving hit confirmation and ragdoll triggers from server
    - Playing ragdoll visual on the local character when hit

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

--[[
  Applies ragdoll visual effect to a character.
  Disables movement and makes the character go limp for the duration.
  This is a simplified ragdoll — full physics-based ragdoll is COMBAT-005.
]]
local function applyRagdollVisual(character: Model, duration: number)
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if not humanoid then
    return
  end

  -- Simple ragdoll: set to PlatformStanding so character falls over
  humanoid.PlatformStanding = true

  task.delay(duration, function()
    if humanoid and humanoid.Parent then
      humanoid.PlatformStanding = false
    end
  end)
end

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
  @param attackerName string Name of the player who hit us
  @param ragdollDuration number How long to ragdoll
]]
local function onRagdollTrigger(attackerName: string, ragdollDuration: number)
  IsRagdolled = true
  RagdollEndTime = os.clock() + ragdollDuration

  local character = LocalPlayer.Character
  if character then
    applyRagdollVisual(character, ragdollDuration)
  end

  -- Clear ragdoll state after duration + recovery window
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
