--[[
  RagdollModule.lua
  Physics-based ragdoll system for Roblox characters.

  Enables exaggerated, satisfying ragdoll physics by:
    - Disabling Motor6D joints and replacing them with BallSocketConstraints
    - Making limbs collide with the environment for tumbling
    - Supporting directional knockback impulses with comedic spin
    - Clean restoration when ragdoll ends

  Usage:
    RagdollModule.enable(character, knockbackVelocity?)
    RagdollModule.disable(character)
    RagdollModule.isRagdolled(character) -> boolean
    RagdollModule.cleanup(character) -- for destroyed/respawned characters
]]

local RagdollModule = {}

-- Active ragdoll data per character
local ActiveRagdolls: {
  [Model]: {
    motors: { Motor6D },
    constraints: { BallSocketConstraint },
    attachments: { Attachment },
    originalCanCollide: { [BasePart]: boolean },
  },
} =
  {}

--------------------------------------------------------------------------------
-- JOINT CONFIGURATION
--------------------------------------------------------------------------------

-- Joint limits per body part (exaggerated for comedic tumbling)
local JOINT_LIMITS = {
  -- Neck: moderate range for head bobble
  Neck = { UpperAngle = 50, TwistLower = -35, TwistUpper = 35 },
  -- Waist: moderate for torso bending
  Waist = { UpperAngle = 35, TwistLower = -25, TwistUpper = 25 },
  -- Shoulders: very loose for floppy arm comedy
  RightShoulder = { UpperAngle = 130, TwistLower = -90, TwistUpper = 90 },
  LeftShoulder = { UpperAngle = 130, TwistLower = -90, TwistUpper = 90 },
  -- Elbows: wide bend range
  RightElbow = { UpperAngle = 130, TwistLower = -10, TwistUpper = 10 },
  LeftElbow = { UpperAngle = 130, TwistLower = -10, TwistUpper = 10 },
  -- Wrists: moderate
  RightWrist = { UpperAngle = 50, TwistLower = -30, TwistUpper = 30 },
  LeftWrist = { UpperAngle = 50, TwistLower = -30, TwistUpper = 30 },
  -- Hips: wide for exaggerated leg flailing
  RightHip = { UpperAngle = 100, TwistLower = -35, TwistUpper = 35 },
  LeftHip = { UpperAngle = 100, TwistLower = -35, TwistUpper = 35 },
  -- Knees: large bend (legs fold dramatically)
  RightKnee = { UpperAngle = 100, TwistLower = -5, TwistUpper = 5 },
  LeftKnee = { UpperAngle = 100, TwistLower = -5, TwistUpper = 5 },
  -- Ankles: moderate
  RightAnkle = { UpperAngle = 50, TwistLower = -15, TwistUpper = 15 },
  LeftAnkle = { UpperAngle = 50, TwistLower = -15, TwistUpper = 15 },
}

local DEFAULT_LIMITS = { UpperAngle = 90, TwistLower = -45, TwistUpper = 45 }

-- Parts that should become collidable during ragdoll for ground interaction
local COLLIDABLE_PARTS: { [string]: boolean } = {
  Head = true,
  UpperTorso = true,
  LowerTorso = true,
  RightUpperArm = true,
  RightLowerArm = true,
  LeftUpperArm = true,
  LeftLowerArm = true,
  RightUpperLeg = true,
  RightLowerLeg = true,
  RightFoot = true,
  LeftUpperLeg = true,
  LeftLowerLeg = true,
  LeftFoot = true,
}

-- Spin multiplier: how much angular velocity to add (comedy factor)
local SPIN_FACTOR = 0.5
local MAX_SPIN = 15 -- max angular velocity
-- Upward kick: percentage of horizontal knockback magnitude added as upward force
local UP_KICK_FACTOR = 0.35

--------------------------------------------------------------------------------
-- ENABLE RAGDOLL
--------------------------------------------------------------------------------

--[[
  Enables physics-based ragdoll on a character.
  Disables Motor6D joints, replaces them with BallSocketConstraints,
  enables limb collisions, and optionally applies knockback impulse.

  @param character The character Model to ragdoll
  @param knockbackVelocity Optional Vector3 velocity impulse for knockback direction
]]
function RagdollModule.enable(character: Model, knockbackVelocity: Vector3?)
  -- If already ragdolled, disable first to reset cleanly
  if ActiveRagdolls[character] then
    RagdollModule.disable(character)
  end

  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if not humanoid then
    return
  end

  local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?

  -- Storage for cleanup
  local motors: { Motor6D } = {}
  local constraints: { BallSocketConstraint } = {}
  local attachments: { Attachment } = {}
  local originalCanCollide: { [BasePart]: boolean } = {}

  -- Step 1: Disable Humanoid auto-recovery
  humanoid.PlatformStanding = true
  humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
  humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)

  -- Step 2: Enable collisions on body parts for ground/wall interaction
  for _, part in character:GetDescendants() do
    if part:IsA("BasePart") and COLLIDABLE_PARTS[part.Name] then
      originalCanCollide[part] = part.CanCollide
      part.CanCollide = true
    end
  end

  -- Step 3: Replace Motor6D joints with BallSocketConstraints
  for _, descendant in character:GetDescendants() do
    if descendant:IsA("Motor6D") and descendant.Enabled then
      local motor: Motor6D = descendant
      local part0 = motor.Part0
      local part1 = motor.Part1

      if part0 and part1 then
        -- Create attachments at the motor's joint positions
        local att0 = Instance.new("Attachment")
        att0.Name = "RagdollAtt0_" .. motor.Name
        att0.CFrame = motor.C0
        att0.Parent = part0
        table.insert(attachments, att0)

        local att1 = Instance.new("Attachment")
        att1.Name = "RagdollAtt1_" .. motor.Name
        att1.CFrame = motor.C1
        att1.Parent = part1
        table.insert(attachments, att1)

        -- Create BallSocketConstraint to keep limbs attached but floppy
        local constraint = Instance.new("BallSocketConstraint")
        constraint.Name = "RagdollJoint_" .. motor.Name
        constraint.Attachment0 = att0
        constraint.Attachment1 = att1

        -- Apply joint-specific limits
        local limits = JOINT_LIMITS[motor.Name] or DEFAULT_LIMITS
        constraint.LimitsEnabled = true
        constraint.UpperAngle = limits.UpperAngle
        constraint.TwistLimitsEnabled = true
        constraint.TwistLowerAngle = limits.TwistLower
        constraint.TwistUpperAngle = limits.TwistUpper

        -- Slight restitution for bouncy tumble feel
        constraint.Restitution = 0.3

        constraint.Parent = part0
        table.insert(constraints, constraint)

        -- Disable the original motor
        motor.Enabled = false
        table.insert(motors, motor)
      end
    end
  end

  -- Store ragdoll data for cleanup
  ActiveRagdolls[character] = {
    motors = motors,
    constraints = constraints,
    attachments = attachments,
    originalCanCollide = originalCanCollide,
  }

  -- Step 4: Apply knockback impulse (after joints are loose for tumble effect)
  if knockbackVelocity and hrp then
    local mag = knockbackVelocity.Magnitude
    if mag > 0.1 then
      -- Add upward kick for exaggerated launch
      local upKick = Vector3.new(0, mag * UP_KICK_FACTOR, 0)
      hrp.AssemblyLinearVelocity = knockbackVelocity + upKick

      -- Add spin perpendicular to knockback direction for comedic tumbling
      local spinAxis = knockbackVelocity.Unit:Cross(Vector3.yAxis)
      if spinAxis.Magnitude > 0.01 then
        local spinSpeed = math.min(mag * SPIN_FACTOR, MAX_SPIN)
        hrp.AssemblyAngularVelocity = spinAxis.Unit * spinSpeed
      end
    end
  end
end

--------------------------------------------------------------------------------
-- DISABLE RAGDOLL
--------------------------------------------------------------------------------

--[[
  Disables ragdoll and restores normal character movement.
  Re-enables Motor6D joints, removes constraints, restores collisions.

  @param character The character Model to un-ragdoll
]]
function RagdollModule.disable(character: Model)
  local data = ActiveRagdolls[character]
  if not data then
    return
  end

  -- Clear stored data first to prevent re-entry
  ActiveRagdolls[character] = nil

  -- Step 1: Re-enable all Motor6D joints
  for _, motor in data.motors do
    if motor and motor.Parent then
      motor.Enabled = true
    end
  end

  -- Step 2: Remove all BallSocketConstraints
  for _, constraint in data.constraints do
    if constraint and constraint.Parent then
      constraint:Destroy()
    end
  end

  -- Step 3: Remove all ragdoll attachments
  for _, attachment in data.attachments do
    if attachment and attachment.Parent then
      attachment:Destroy()
    end
  end

  -- Step 4: Restore original collisions
  for part, wasCollidable in data.originalCanCollide do
    if part and part.Parent then
      part.CanCollide = wasCollidable
    end
  end

  -- Step 5: Restore Humanoid to normal state
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if humanoid then
    humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
    humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
    humanoid.PlatformStanding = false
    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
  end
end

--------------------------------------------------------------------------------
-- QUERY & CLEANUP
--------------------------------------------------------------------------------

--[[
  Checks if a character is currently ragdolled.
  @param character The character Model to check
  @return true if the character has active ragdoll physics
]]
function RagdollModule.isRagdolled(character: Model): boolean
  return ActiveRagdolls[character] ~= nil
end

--[[
  Cleans up ragdoll tracking data for a character being removed or respawned.
  Does NOT attempt to modify instances (they may already be destroyed).
  Call this from CharacterRemoving or Destroying events.

  @param character The character Model being removed
]]
function RagdollModule.cleanup(character: Model)
  ActiveRagdolls[character] = nil
end

return RagdollModule
