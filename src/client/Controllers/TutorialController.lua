--[[
  TutorialController.lua
  Client-side controller that manages the tutorial UI, camera effects,
  and audio cues during the tutorial sequence (TUTORIAL-001).

  Displays:
    - Step prompt messages at the bottom of the screen
    - Skip tutorial button
    - Brief camera zoom on tutorial start
    - Step transition audio cues
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

  -- Listen for tutorial completion
  TutorialService.TutorialCompleted:Connect(function()
    print("[TutorialController] Tutorial completed!")
    hidePrompt()

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
