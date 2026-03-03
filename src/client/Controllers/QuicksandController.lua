--[[
  QuicksandController.lua
  Client-side controller for quicksand VFX and SFX.

  Handles:
    - Listening for PatchStateChanged signals from QuicksandService
    - Active patches: subtle sandy shimmer particles, occasional bubble
    - Dormant patches: no visual effects (normal ground)
    - QuicksandTrapped: sinking VFX/SFX on local player, notification
    - QuicksandReleased: pop-out VFX, notification
    - Late-join sync via GetPatchStates RPC

  Depends on: QuicksandService (server signals), SoundController,
              NotificationController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))

local QuicksandController = Knit.CreateController({
  Name = "QuicksandController",
})

local LocalPlayer = Players.LocalPlayer

-- Lazy-loaded references (set in KnitStart)
local QuicksandService = nil
local NotificationController = nil

-- Colors
local SAND_COLOR = Color3.fromRGB(210, 180, 110) -- sandy yellow
local BUBBLE_COLOR = Color3.fromRGB(180, 160, 100) -- darker sand
local TRAP_COLOR = Color3.fromRGB(180, 140, 60) -- warning amber

-- Patch VFX state: patchId → { ... }
local PatchVFX: {
  [string]: {
    part: BasePart?,
    isActive: boolean,
    shimmerEmitter: ParticleEmitter?,
    bubbleEmitter: ParticleEmitter?,
  },
} =
  {}

-- Trapped state for local player VFX
local IsTrapped = false
local TrapCleanupThread: thread? = nil
local TrapVFXPart: Part? = nil

--------------------------------------------------------------------------------
-- VFX HELPERS
--------------------------------------------------------------------------------

--[[
  Finds the quicksand patch Part in workspace.QuicksandPatches by ID.
]]
local function findPatchPart(patchId: string): BasePart?
  local folder = workspace:FindFirstChild("QuicksandPatches")
  if not folder then
    return nil
  end
  return folder:FindFirstChild(patchId)
end

--[[
  Creates the subtle sandy shimmer particle emitter for an active patch.
  Small sand particles rising slowly with a warm sandy color.
]]
local function createShimmerEmitter(part: BasePart): ParticleEmitter
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "QuicksandShimmer"
  emitter.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, SAND_COLOR),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(230, 200, 130)),
    ColorSequenceKeypoint.new(1, SAND_COLOR),
  })
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.6),
    NumberSequenceKeypoint.new(1, 0.1),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.5),
    NumberSequenceKeypoint.new(0.3, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(1, 2.5)
  emitter.Rate = 4
  emitter.Speed = NumberRange.new(0.5, 1.5)
  emitter.SpreadAngle = Vector2.new(20, 20)
  emitter.RotSpeed = NumberRange.new(-20, 20)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.LightEmission = 0.2
  emitter.Parent = part
  return emitter
end

--[[
  Creates the occasional bubble particle emitter for an active patch.
  Infrequent dark bubbles popping on the surface.
]]
local function createBubbleEmitter(part: BasePart): ParticleEmitter
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "QuicksandBubbles"
  emitter.Color = ColorSequence.new(BUBBLE_COLOR)
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.7, 0.8),
    NumberSequenceKeypoint.new(1, 0),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.8, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(0.5, 1.2)
  emitter.Rate = 1.5
  emitter.Speed = NumberRange.new(1, 3)
  emitter.SpreadAngle = Vector2.new(5, 5)
  emitter.RotSpeed = NumberRange.new(0, 0)
  emitter.Parent = part
  return emitter
end

--[[
  Cleans up all VFX for a specific patch.
]]
local function cleanupPatchVFX(patchId: string)
  local vfx = PatchVFX[patchId]
  if not vfx then
    return
  end

  if vfx.shimmerEmitter then
    vfx.shimmerEmitter:Destroy()
    vfx.shimmerEmitter = nil
  end
  if vfx.bubbleEmitter then
    vfx.bubbleEmitter:Destroy()
    vfx.bubbleEmitter = nil
  end
end

--------------------------------------------------------------------------------
-- PATCH STATE CHANGES
--------------------------------------------------------------------------------

--[[
  Applies VFX for the given patch state.
]]
local function applyPatchState(patchId: string, isActive: boolean)
  -- Ensure we have a VFX entry
  if not PatchVFX[patchId] then
    local part = findPatchPart(patchId)
    if not part then
      return
    end
    PatchVFX[patchId] = {
      part = part,
      isActive = false,
    }
  end

  local vfx = PatchVFX[patchId]
  local part = vfx.part
  if not part then
    return
  end

  -- Clean up previous VFX
  cleanupPatchVFX(patchId)

  vfx.isActive = isActive

  if isActive then
    -- Active: subtle shimmer + bubbles
    vfx.shimmerEmitter = createShimmerEmitter(part)
    vfx.bubbleEmitter = createBubbleEmitter(part)
  end
  -- Dormant: no VFX (already cleaned up)
end

--------------------------------------------------------------------------------
-- TRAP VFX
--------------------------------------------------------------------------------

--[[
  Creates sinking VFX on the local player when trapped.
  A ring of sand particles rises around the character.
]]
local function createTrapVFX()
  local character = LocalPlayer.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  -- Create a small part at the player's feet for particles
  local vfxPart = Instance.new("Part")
  vfxPart.Name = "QuicksandTrapVFX"
  vfxPart.Size = Vector3.new(4, 0.5, 4)
  vfxPart.CFrame = hrp.CFrame * CFrame.new(0, -2.5, 0)
  vfxPart.Transparency = 1
  vfxPart.Anchored = true
  vfxPart.CanCollide = false
  vfxPart.CanQuery = false
  vfxPart.CanTouch = false
  vfxPart.CastShadow = false
  vfxPart.Parent = workspace

  -- Sand swirl emitter
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "TrapSandSwirl"
  emitter.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, SAND_COLOR),
    ColorSequenceKeypoint.new(0.5, BUBBLE_COLOR),
    ColorSequenceKeypoint.new(1, SAND_COLOR),
  })
  emitter.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.5),
    NumberSequenceKeypoint.new(0.5, 1.5),
    NumberSequenceKeypoint.new(1, 0.3),
  })
  emitter.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.5, 0.4),
    NumberSequenceKeypoint.new(1, 1),
  })
  emitter.Lifetime = NumberRange.new(0.8, 1.5)
  emitter.Rate = 20
  emitter.Speed = NumberRange.new(2, 5)
  emitter.SpreadAngle = Vector2.new(60, 60)
  emitter.RotSpeed = NumberRange.new(-90, 90)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.Parent = vfxPart

  TrapVFXPart = vfxPart
end

--[[
  Cleans up trap VFX on the local player.
]]
local function cleanupTrapVFX()
  if TrapVFXPart then
    TrapVFXPart:Destroy()
    TrapVFXPart = nil
  end
end

--------------------------------------------------------------------------------
-- EVENT HANDLERS
--------------------------------------------------------------------------------

--[[
  Called when the local player is trapped in quicksand.
]]
local function onQuicksandTrapped(patchPosition: Vector3, duration: number)
  -- Show notification
  if NotificationController then
    NotificationController:ShowNotification("Quicksand! You're stuck!", TRAP_COLOR, duration)
  end

  -- Cancel any pending cleanup
  if TrapCleanupThread then
    task.cancel(TrapCleanupThread)
    TrapCleanupThread = nil
  end

  IsTrapped = true

  -- Create sinking VFX
  createTrapVFX()

  -- Play sinking sound
  local character = LocalPlayer.Character
  if character then
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
      local sound = Instance.new("Sound")
      sound.Name = "QuicksandSink"
      sound.SoundId = "rbxassetid://9116222901" -- bubbling/sinking
      sound.Volume = 0.4
      sound.Looped = false
      sound.Parent = hrp
      sound:Play()
      -- Auto-cleanup
      sound.Ended:Connect(function()
        sound:Destroy()
      end)
    end
  end

  -- Schedule cleanup
  TrapCleanupThread = task.delay(duration + 0.5, function()
    TrapCleanupThread = nil
    cleanupTrapVFX()
    IsTrapped = false
  end)
end

--[[
  Called when the local player is released from quicksand.
]]
local function onQuicksandReleased(ejectPosition: Vector3)
  -- Show notification
  if NotificationController then
    NotificationController:ShowNotification(
      "Freed from quicksand!",
      Color3.fromRGB(100, 200, 100),
      2
    )
  end

  -- Clean up trap VFX immediately
  cleanupTrapVFX()
  IsTrapped = false

  if TrapCleanupThread then
    task.cancel(TrapCleanupThread)
    TrapCleanupThread = nil
  end

  -- Pop-out sound
  local character = LocalPlayer.Character
  if character then
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if hrp then
      local sound = Instance.new("Sound")
      sound.Name = "QuicksandRelease"
      sound.SoundId = "rbxassetid://9114227726" -- pop/burst
      sound.Volume = 0.3
      sound.Looped = false
      sound.Parent = hrp
      sound:Play()
      sound.Ended:Connect(function()
        sound:Destroy()
      end)
    end
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function QuicksandController:KnitInit()
  print("[QuicksandController] Initialized")
end

function QuicksandController:KnitStart()
  QuicksandService = Knit.GetService("QuicksandService")
  NotificationController = Knit.GetController("NotificationController")

  -- Listen for patch state changes from server
  QuicksandService.PatchStateChanged:Connect(
    function(patchId: string, isActive: boolean, position: Vector3, size: Vector3)
      applyPatchState(patchId, isActive)
    end
  )

  -- Listen for quicksand trap on local player
  QuicksandService.QuicksandTrapped:Connect(onQuicksandTrapped)

  -- Listen for quicksand release on local player
  QuicksandService.QuicksandReleased:Connect(onQuicksandReleased)

  -- Late-join sync: get current patch states
  QuicksandService:GetPatchStates()
    :andThen(function(states)
      for _, state in states do
        applyPatchState(state.id, state.isActive)
      end
    end)
    :catch(function(err)
      warn("[QuicksandController] Failed to sync patch states:", err)
    end)

  -- Clean up VFX on character removal
  LocalPlayer.CharacterRemoving:Connect(function()
    cleanupTrapVFX()
    IsTrapped = false
    if TrapCleanupThread then
      task.cancel(TrapCleanupThread)
      TrapCleanupThread = nil
    end
  end)

  print("[QuicksandController] Started")
end

return QuicksandController
