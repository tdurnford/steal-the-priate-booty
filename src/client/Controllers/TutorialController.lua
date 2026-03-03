--[[
  TutorialController.lua
  Client-side controller that manages the tutorial UI, camera effects,
  compass waypoint, and audio cues during the tutorial sequence
  (TUTORIAL-001, TUTORIAL-002).

  Displays:
    - Step prompt messages at the bottom of the screen
    - Skip tutorial button
    - Brief camera zoom on tutorial start
    - Step transition audio cues
    - Compass waypoint arrow for navigation (steps 6-9)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local UIFolder = script.Parent.Parent:WaitForChild("UI")
local TutorialPrompt = require(UIFolder:WaitForChild("TutorialPrompt"))

local TutorialController = Knit.CreateController({
  Name = "TutorialController",
})

-- Service/controller references (set in KnitStart)
local TutorialService = nil
local SessionStateService = nil
local SoundController = nil

-- Fusion state
local FusionScope = nil
local TutorialMessage = nil -- Fusion.Value<string>
local TutorialStep = nil -- Fusion.Value<number>
local TutorialVisible = nil -- Fusion.Value<boolean>

-- UI references
local ScreenGui = nil

-- Waypoint state
local WaypointFrame = nil -- ScreenGui Frame for the compass arrow
local WaypointPosition = nil -- Vector3? target position
local WaypointConnection = nil -- RenderStepped connection for arrow updates

-- Local player
local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- CAMERA EFFECTS
--------------------------------------------------------------------------------

--[[
  Plays a brief cinematic camera zoom on tutorial start.
  Lowers the camera and zooms slightly, then returns to normal.
]]
local function playCameraIntro()
  local camera = workspace.CurrentCamera
  if not camera then
    return
  end

  -- Store original settings
  local character = LocalPlayer.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  -- Brief custom camera effect: zoom to low angle looking at player
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if not humanoid then
    return
  end

  -- Temporarily zoom in closer
  local originalMinDistance = humanoid.CameraOffset
  humanoid.CameraOffset = Vector3.new(0, -1, 0) -- lower camera slightly

  -- Reset after a brief moment
  task.delay(2, function()
    if humanoid and humanoid.Parent then
      local tween = TweenService:Create(
        humanoid,
        TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { CameraOffset = Vector3.new(0, 0, 0) }
      )
      tween:Play()
    end
  end)
end

--------------------------------------------------------------------------------
-- WAYPOINT COMPASS
--------------------------------------------------------------------------------

--[[
  Creates the compass waypoint arrow UI element.
  Returns a Frame with a triangular arrow indicator and distance label.
]]
local function createWaypointUI()
  if WaypointFrame then
    return
  end

  local gui = ScreenGui
  if not gui then
    return
  end

  -- Container frame at screen center for rotation
  local container = Instance.new("Frame")
  container.Name = "WaypointCompass"
  container.Size = UDim2.fromOffset(60, 60)
  container.Position = UDim2.new(0.5, 0, 0.15, 0)
  container.AnchorPoint = Vector2.new(0.5, 0.5)
  container.BackgroundTransparency = 1
  container.Parent = gui

  -- Arrow indicator (triangle using ImageLabel or a rotated frame)
  local arrow = Instance.new("Frame")
  arrow.Name = "Arrow"
  arrow.Size = UDim2.fromOffset(30, 30)
  arrow.Position = UDim2.new(0.5, 0, 0, 0)
  arrow.AnchorPoint = Vector2.new(0.5, 0.5)
  arrow.BackgroundColor3 = Color3.fromRGB(255, 220, 100)
  arrow.BackgroundTransparency = 0
  arrow.Rotation = 45 -- diamond shape as compass
  arrow.Parent = container

  local arrowCorner = Instance.new("UICorner")
  arrowCorner.CornerRadius = UDim.new(0, 4)
  arrowCorner.Parent = arrow

  local arrowStroke = Instance.new("UIStroke")
  arrowStroke.Color = Color3.fromRGB(180, 140, 20)
  arrowStroke.Thickness = 2
  arrowStroke.Parent = arrow

  -- Distance label below compass
  local distLabel = Instance.new("TextLabel")
  distLabel.Name = "DistLabel"
  distLabel.Size = UDim2.fromOffset(120, 20)
  distLabel.Position = UDim2.new(0.5, 0, 1, 8)
  distLabel.AnchorPoint = Vector2.new(0.5, 0)
  distLabel.BackgroundTransparency = 1
  distLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
  distLabel.Font = Enum.Font.GothamBold
  distLabel.TextSize = 14
  distLabel.TextStrokeTransparency = 0.3
  distLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
  distLabel.Text = ""
  distLabel.Parent = container

  WaypointFrame = container
end

--[[
  Updates the compass waypoint arrow direction and distance.
  Called every RenderStepped when a waypoint is active.
]]
local function updateWaypoint()
  if not WaypointFrame or not WaypointPosition then
    return
  end

  local character = LocalPlayer.Character
  if not character then
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    return
  end

  local camera = workspace.CurrentCamera
  if not camera then
    return
  end

  -- Calculate direction in screen-space
  local playerPos = hrp.Position
  local toTarget = (WaypointPosition - playerPos)
  local distance = toTarget.Magnitude
  local flatDir = Vector3.new(toTarget.X, 0, toTarget.Z)
  if flatDir.Magnitude < 0.01 then
    return
  end
  flatDir = flatDir.Unit

  -- Get camera look direction (flattened)
  local camLook = camera.CFrame.LookVector
  local camFlat = Vector3.new(camLook.X, 0, camLook.Z)
  if camFlat.Magnitude < 0.01 then
    return
  end
  camFlat = camFlat.Unit

  -- Angle between camera forward and target direction
  local dot = camFlat:Dot(flatDir)
  local cross = camFlat:Cross(flatDir)
  local angle = math.deg(math.atan2(cross.Y, dot))

  -- Rotate the container frame
  WaypointFrame.Rotation = angle

  -- Update distance label
  local distLabel = WaypointFrame:FindFirstChild("DistLabel")
  if distLabel then
    distLabel.Text = string.format("%d studs", math.floor(distance))
  end
end

--[[
  Shows the compass waypoint pointing to a position.
]]
local function showWaypoint(position: Vector3)
  WaypointPosition = position
  createWaypointUI()

  if WaypointFrame then
    WaypointFrame.Visible = true
  end

  -- Start updating if not already
  if not WaypointConnection then
    WaypointConnection = RunService.RenderStepped:Connect(updateWaypoint)
  end
end

--[[
  Hides and cleans up the compass waypoint.
]]
local function hideWaypoint()
  WaypointPosition = nil

  if WaypointConnection then
    WaypointConnection:Disconnect()
    WaypointConnection = nil
  end

  if WaypointFrame then
    WaypointFrame.Visible = false
  end
end

--[[
  Destroys the waypoint UI entirely.
]]
local function destroyWaypointUI()
  hideWaypoint()
  if WaypointFrame then
    WaypointFrame:Destroy()
    WaypointFrame = nil
  end
end

--------------------------------------------------------------------------------
-- UI MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Creates the tutorial ScreenGui with the prompt component.
]]
local function createTutorialUI()
  FusionScope = Fusion.scoped(Fusion)
  TutorialMessage = FusionScope:Value("")
  TutorialStep = FusionScope:Value(0)
  TutorialVisible = FusionScope:Value(false)

  ScreenGui = FusionScope:New("ScreenGui")({
    Name = "TutorialGui",
    DisplayOrder = 50, -- above HUD, below critical UI
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    Parent = LocalPlayer:WaitForChild("PlayerGui"),

    [Fusion.Children] = {
      TutorialPrompt.create(FusionScope, {
        message = TutorialMessage,
        step = TutorialStep,
        visible = TutorialVisible,
        onSkip = function()
          -- Ask server to skip
          if TutorialService then
            TutorialService:SkipTutorial()
              :andThen(function(success)
                if success then
                  print("[TutorialController] Tutorial skipped")
                end
              end)
              :catch(function(err)
                warn("[TutorialController] Skip failed:", err)
              end)
          end
        end,
      }),
    },
  })
end

--[[
  Shows the tutorial prompt with a new message.
]]
local function showPrompt(step: number, message: string)
  if not FusionScope then
    return
  end

  -- Brief fade out then update then fade in for smooth transition
  TutorialVisible:set(false)
  task.delay(0.3, function()
    if TutorialStep then
      TutorialStep:set(step)
    end
    if TutorialMessage then
      TutorialMessage:set(message)
    end
    if TutorialVisible then
      TutorialVisible:set(true)
    end
  end)
end

--[[
  Hides the tutorial prompt.
]]
local function hidePrompt()
  if TutorialVisible then
    TutorialVisible:set(false)
  end
end

--[[
  Cleans up tutorial UI.
]]
local function destroyTutorialUI()
  hidePrompt()
  destroyWaypointUI()
  if FusionScope then
    Fusion.doCleanup(FusionScope)
    FusionScope = nil
  end
  TutorialMessage = nil
  TutorialStep = nil
  TutorialVisible = nil
  ScreenGui = nil
end

--------------------------------------------------------------------------------
-- AUDIO CUES
--------------------------------------------------------------------------------

local function playStepSound(step: number)
  if not SoundController then
    return
  end
  pcall(function()
    if step == 2 then
      SoundController:PlayCoinPickupSound() -- driftwood pickup chime
    elseif step == 5 then
      SoundController:PlayPhaseTransitionSound("Dusk") -- danger horn for skeleton
    elseif step == 6 then
      SoundController:PlayPhaseTransitionSound("Dawn") -- hopeful horn for Harbor journey
    elseif step == 7 then
      SoundController:PlayCoinPickupSound() -- arrival chime
    elseif step == 8 then
      SoundController:PlayCoinPickupSound() -- lock confirmation chime
    elseif step == 10 then
      SoundController:PlayPhaseTransitionSound("Dawn") -- completion fanfare
    end
  end)
end

-- Client-side step messages for late-join sync
local STEP_MESSAGES_CLIENT = {
  [1] = "Find something to defend yourself...",
  [2] = "A driftwood club! That'll work.",
  [3] = "Smash the crate open!",
  [4] = "Grab the doubloons!",
  [5] = "Watch out! Hit it before it gets you!",
  [6] = "Get to the Harbor to claim your ship!",
  [7] = "This is your ship. Deposit your doubloons!",
  [8] = "Lock your ship to secure your treasure.",
  [9] = "Visit the shop to claim your Rusty Cutlass.",
  [10] = "You're on your own now, pirate. The island is watching.",
}

--------------------------------------------------------------------------------
-- CONTROLLER LIFECYCLE
--------------------------------------------------------------------------------

function TutorialController:KnitInit()
  print("[TutorialController] Initializing...")
end

function TutorialController:KnitStart()
  TutorialService = Knit.GetService("TutorialService")
  SessionStateService = Knit.GetService("SessionStateService")

  -- Get SoundController safely
  local ok, ctrl = pcall(function()
    return Knit.GetController("SoundController")
  end)
  if ok then
    SoundController = ctrl
  end

  -- Create the UI immediately (it starts hidden)
  createTutorialUI()

  -- Listen for tutorial step changes from server
  TutorialService.TutorialStepChanged:Connect(function(step: number, message: string)
    print(string.format("[TutorialController] Step %d: %s", step, message))

    showPrompt(step, message)
    playStepSound(step)

    -- Camera intro on step 1
    if step == 1 then
      playCameraIntro()
    end
  end)

  -- Listen for waypoint updates from server
  TutorialService.TutorialWaypoint:Connect(function(position)
    if position then
      showWaypoint(position)
    else
      hideWaypoint()
    end
  end)

  -- Listen for tutorial completion
  TutorialService.TutorialCompleted:Connect(function()
    print("[TutorialController] Tutorial completed!")
    hidePrompt()
    hideWaypoint()

    -- Show a completion message briefly
    task.delay(0.5, function()
      if TutorialMessage and TutorialStep and TutorialVisible then
        TutorialStep:set(0)
        TutorialMessage:set("Welcome to Pirate Island, sailor!")
        TutorialVisible:set(true)

        task.delay(3, function()
          hidePrompt()
          -- Clean up UI after fade
          task.delay(0.5, function()
            destroyTutorialUI()
          end)
        end)
      end
    end)
  end)

  -- Check if we're already in a tutorial (late join / studio restart)
  TutorialService:GetTutorialState()
    :andThen(function(state)
      if state and state.active then
        local step = state.step
        local message = STEP_MESSAGES_CLIENT[step] or ""
        showPrompt(step, message)
      end
    end)
    :catch(function() end)

  print("[TutorialController] Started")
end

return TutorialController
