--[[
  CombatController.lua
  Client-side combat input handler for light swing, heavy swing, and block.

  Handles:
    - Detecting primary click (Mouse1 / Touch tap) for attack
    - Tap / quick release → light swing (fast, 0.4s cooldown)
    - Hold 0.8s then release → heavy swing (charge, 1.2s cooldown, vulnerable)
    - Detecting secondary click (Mouse2) for block
    - Hold Mouse2 → block stance (50% speed, reduced ragdoll/spill on hit)
    - Sending attack/block intent to CombatService
    - Client-side cooldown display (to prevent spamming the server)
    - Playing swing/charge/block animations and SFX
    - Receiving hit confirmation, ragdoll triggers, and block impacts from server
    - Physics-based ragdoll via RagdollModule (joint disabling, knockback, tumble)
    - Character respawn cleanup for ragdoll/block state

  The server performs all validation and hit detection.
  This controller is purely for input and visual feedback.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

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

-- Charge state
local IsCharging = false
local ChargeStartTime = 0
local ChargeReady = false -- true when charge threshold is met
local ChargeVFXPart: BasePart? = nil
local ChargeTween: Tween? = nil

-- Block state
local IsBlocking = false
local BlockAnimTrack: AnimationTrack? = nil

-- Tracks the active ragdoll cleanup task so overlapping ragdolls cancel the old one
local RagdollCleanupThread: thread? = nil

-- Config values
local LIGHT_SWING_COOLDOWN = GameConfig.Combat.lightSwingCooldown -- 0.4s
local HEAVY_SWING_COOLDOWN = GameConfig.Combat.heavySwingCooldown -- 1.2s
local HEAVY_CHARGE_TIME = GameConfig.Combat.heavySwingChargeTime -- 0.8s

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
  Plays a light swing animation on the local character.
  Uses a placeholder animation — replace with proper cutlass animation later.
]]
local function playLightSwingAnimation()
  local humanoid = getLocalHumanoid()
  if not humanoid then
    return
  end

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
  Plays a heavy swing animation on the local character.
  Slower, more dramatic slash with full weight.
]]
local function playHeavySwingAnimation()
  local humanoid = getLocalHumanoid()
  if not humanoid then
    return
  end

  local animator = humanoid:FindFirstChildOfClass("Animator")
  if not animator then
    return
  end

  local animation = Instance.new("Animation")
  animation.AnimationId = "rbxassetid://522635514" -- same placeholder, different speed
  local track = animator:LoadAnimation(animation)
  track.Priority = Enum.AnimationPriority.Action4
  track:Play(0.05, 1, 1) -- slower speed for heavy feel
  animation:Destroy()
end

--[[
  Creates a charge-up glow VFX on the player's weapon/hand.
  A gold-orange point light that intensifies during charge.
]]
local function startChargeVFX()
  -- Clean up any existing charge VFX
  if ChargeVFXPart then
    ChargeVFXPart:Destroy()
    ChargeVFXPart = nil
  end
  if ChargeTween then
    ChargeTween:Cancel()
    ChargeTween = nil
  end

  local character = LocalPlayer.Character
  if not character then
    return
  end

  -- Attach to the right hand or HumanoidRootPart
  local attachParent = character:FindFirstChild("RightHand")
    or character:FindFirstChild("Right Arm")
    or character:FindFirstChild("HumanoidRootPart")
  if not attachParent or not attachParent:IsA("BasePart") then
    return
  end

  -- Create a glow light that intensifies during charge
  local light = Instance.new("PointLight")
  light.Name = "ChargeGlow"
  light.Color = Color3.fromRGB(255, 180, 50) -- warm gold-orange
  light.Brightness = 0
  light.Range = 0
  light.Parent = attachParent

  -- Tween the light intensity over the charge duration
  local tweenInfo = TweenInfo.new(HEAVY_CHARGE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
  ChargeTween = TweenService:Create(light, tweenInfo, {
    Brightness = 4,
    Range = 12,
  })
  ChargeTween:Play()

  -- Store reference for cleanup
  ChargeVFXPart = light :: any
end

--[[
  Cleans up any active charge VFX.
]]
local function stopChargeVFX()
  if ChargeTween then
    ChargeTween:Cancel()
    ChargeTween = nil
  end
  if ChargeVFXPart then
    ChargeVFXPart:Destroy()
    ChargeVFXPart = nil
  end
end

--[[
  Plays a block stance animation (looping) on the local character.
  Returns the AnimationTrack for later stopping.
]]
local function playBlockAnimation(): AnimationTrack?
  local humanoid = getLocalHumanoid()
  if not humanoid then
    return nil
  end

  local animator = humanoid:FindFirstChildOfClass("Animator")
  if not animator then
    return nil
  end

  local animation = Instance.new("Animation")
  animation.AnimationId = "rbxassetid://522635514" -- placeholder (defensive stance)
  local track = animator:LoadAnimation(animation)
  track.Priority = Enum.AnimationPriority.Action2
  track.Looped = true
  track:Play(0.1, 1, 0.5) -- slow speed for held stance feel
  animation:Destroy()
  return track
end

--[[
  Stops the block stance animation.
]]
local function stopBlockAnimation()
  if BlockAnimTrack then
    BlockAnimTrack:Stop(0.15)
    BlockAnimTrack = nil
  end
end

--[[
  Sends block state change to the server and manages local state.
  @param blocking Whether to start or stop blocking
]]
local function setBlockState(blocking: boolean)
  if IsBlocking == blocking then
    return
  end

  IsBlocking = blocking

  if blocking then
    BlockAnimTrack = playBlockAnimation()
    if SoundController then
      SoundController:PlayBlockRaiseSound()
    end
  else
    stopBlockAnimation()
  end

  -- Notify server
  if CombatService then
    CombatService.BlockStateChanged:Fire(blocking)
  end
end

--[[
  Checks if the client-side cooldown has elapsed for a given cooldown duration.
  @param cooldown The cooldown time to check against
  @return true if the player can swing
]]
local function canSwing(cooldown: number): boolean
  if IsRagdolled then
    return false
  end

  if IsBlocking then
    return false
  end

  local now = os.clock()
  return (now - LastSwingTime) >= cooldown
end

--------------------------------------------------------------------------------
-- CHARGE & ATTACK
--------------------------------------------------------------------------------

--[[
  Called on primary button press (Mouse1 down).
  Begins charging for a potential heavy swing.
]]
local function onPrimaryDown()
  -- Cannot start an attack while blocking — must release block first
  if IsBlocking then
    return
  end

  -- Must be able to at least light swing to start charging
  if not canSwing(LIGHT_SWING_COOLDOWN) then
    return
  end

  IsCharging = true
  ChargeStartTime = os.clock()
  ChargeReady = false

  -- Start charge VFX after a brief delay (don't show for quick taps)
  task.delay(0.15, function()
    if IsCharging and not IsRagdolled then
      startChargeVFX()

      -- Play charge SFX
      if SoundController then
        SoundController:PlayHeavyChargeSound()
      end
    end
  end)
end

--[[
  Called on primary button release (Mouse1 up).
  Determines whether to fire light or heavy swing based on charge time.
]]
local function onPrimaryUp()
  if not IsCharging then
    return
  end

  local chargeTime = os.clock() - ChargeStartTime
  IsCharging = false
  ChargeReady = false

  -- Clean up charge VFX
  stopChargeVFX()

  -- If ragdolled during charge, cancel entirely
  if IsRagdolled then
    return
  end

  if chargeTime >= HEAVY_CHARGE_TIME then
    -- HEAVY SWING — charged long enough
    if not canSwing(HEAVY_SWING_COOLDOWN) then
      return
    end

    LastSwingTime = os.clock()

    -- Play heavy swing animation and SFX
    playHeavySwingAnimation()
    if SoundController then
      SoundController:PlayHeavySwingSound()
    end

    -- Send heavy attack request to server with charge time
    if CombatService then
      CombatService.HeavyAttackRequest:Fire(chargeTime)
    end
  else
    -- LIGHT SWING — released before charge threshold
    if not canSwing(LIGHT_SWING_COOLDOWN) then
      return
    end

    LastSwingTime = os.clock()

    -- Play light swing animation and SFX
    playLightSwingAnimation()
    if SoundController then
      SoundController:PlaySwingSound()
    end

    -- Send light attack request to server
    if CombatService then
      CombatService.AttackRequest:Fire()
    end
  end
end

--------------------------------------------------------------------------------
-- SERVER EVENT HANDLERS
--------------------------------------------------------------------------------

--[[
  Called when the server confirms a swing result.
  @param hitType "player" | "container" | "miss"
  @param targetName string? Name of what was hit
  @param attackType string? "light" | "heavy"
]]
local function onSwingResult(hitType: string, targetName: string?, attackType: string?)
  -- Play appropriate hit sound
  if SoundController then
    local hrp = getLocalHRP()
    if attackType == "heavy" and hitType == "player" then
      SoundController:PlayHeavyHitSound(hrp)
    else
      SoundController:PlayCombatHitSound(hitType, hrp)
    end
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
  -- If charging, cancel the charge (interrupted by being hit)
  if IsCharging then
    IsCharging = false
    ChargeReady = false
    stopChargeVFX()
  end

  -- If blocking, cancel the block (ragdolled out of block stance)
  if IsBlocking then
    setBlockState(false)
  end

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

--[[
  Called when the server confirms this player blocked an incoming hit.
  Plays block impact SFX.
  @param attackerName string Name of the player who hit us
  @param ragdollDuration number Brief block-stagger duration
]]
local function onBlockImpact(attackerName: string, ragdollDuration: number)
  if SoundController then
    SoundController:PlayBlockImpactSound()
  end
end

--[[
  Called on secondary button press (Mouse2 down).
  Starts blocking.
]]
local function onSecondaryDown()
  if IsRagdolled then
    return
  end

  -- Cannot block while charging a heavy swing
  if IsCharging then
    return
  end

  setBlockState(true)
end

--[[
  Called on secondary button release (Mouse2 up).
  Stops blocking.
]]
local function onSecondaryUp()
  if IsBlocking then
    setBlockState(false)
  end
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
  CombatService.BlockImpact:Connect(onBlockImpact)

  -- Clean up ragdoll and block state on character removal (death/respawn)
  LocalPlayer.CharacterRemoving:Connect(function(character: Model)
    RagdollModule.cleanup(character)
    IsRagdolled = false
    IsCharging = false
    ChargeReady = false
    IsBlocking = false
    stopChargeVFX()
    stopBlockAnimation()
    if RagdollCleanupThread then
      task.cancel(RagdollCleanupThread)
      RagdollCleanupThread = nil
    end
  end)

  -- Listen for primary button down (start charge)
  UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then
      return
    end

    if
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.Touch
    then
      onPrimaryDown()
    end
  end)

  -- Listen for primary button up (release → light or heavy swing)
  UserInputService.InputEnded:Connect(function(input: InputObject)
    if
      input.UserInputType == Enum.UserInputType.MouseButton1
      or input.UserInputType == Enum.UserInputType.Touch
    then
      onPrimaryUp()
    end
  end)

  -- Listen for secondary button down (start block)
  UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then
      return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton2 then
      onSecondaryDown()
    end
  end)

  -- Listen for secondary button up (stop block)
  UserInputService.InputEnded:Connect(function(input: InputObject)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
      onSecondaryUp()
    end
  end)

  print("[CombatController] Started — click to swing, hold to charge, right-click to block")
end

return CombatController
