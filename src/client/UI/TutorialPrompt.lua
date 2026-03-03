--[[
  TutorialPrompt.lua
  Fusion 0.3 component that displays the tutorial step prompt at the bottom
  of the screen with a pirate-themed style, fade-in/out animation, and
  an optional "skip tutorial" button.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local TutorialPrompt = {}

-- Constants
local PROMPT_WIDTH = 500
local PROMPT_HEIGHT = 70
local TEXT_SIZE = 22
local STEP_TEXT_SIZE = 14
local SKIP_TEXT_SIZE = 14

--[[
  Creates the tutorial prompt component.
  @param scope Fusion scope
  @param props {
    message: Fusion.Value<string>,  -- current step message
    step: Fusion.Value<number>,     -- current step number (1-5)
    visible: Fusion.Value<boolean>, -- whether the prompt is visible
    onSkip: () -> (),               -- callback when skip is pressed
  }
  @return Frame instance
]]
function TutorialPrompt.create(scope, props)
  local message = props.message
  local step = props.step
  local visible = props.visible
  local onSkip = props.onSkip

  -- Animated transparency for fade in/out
  local targetTransparency = scope:Computed(function(use)
    return if use(visible) then 0 else 1
  end)

  local animatedTransparency = scope:Tween(
    targetTransparency,
    TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
  )

  -- Step indicator text ("Step 1 of 5")
  local stepText = scope:Computed(function(use)
    local s = use(step)
    if s <= 0 then
      return ""
    end
    return string.format("Step %d of 5", s)
  end)

  return scope:New("Frame")({
    Name = "TutorialPrompt",
    Size = UDim2.fromOffset(PROMPT_WIDTH, PROMPT_HEIGHT + 30), -- extra for skip button
    Position = UDim2.new(0.5, 0, 1, -40),
    AnchorPoint = Vector2.new(0.5, 1),
    BackgroundTransparency = 1,

    [Children] = {
      -- Main prompt box
      scope:New("Frame")({
        Name = "PromptBox",
        Size = UDim2.new(1, 0, 0, PROMPT_HEIGHT),
        BackgroundColor3 = UITheme.Colors.DarkBackground,
        BackgroundTransparency = scope:Computed(function(use)
          return 0.15 + use(animatedTransparency) * 0.85
        end),

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UITheme.CornerRadius.Medium,
          }),
          scope:New("UIStroke")({
            Color = UITheme.Colors.Gold,
            Thickness = 2,
            Transparency = scope:Computed(function(use)
              return 0.3 + use(animatedTransparency) * 0.7
            end),
          }),
          scope:New("UIPadding")({
            PaddingLeft = UDim.new(0, 16),
            PaddingRight = UDim.new(0, 16),
            PaddingTop = UDim.new(0, 8),
            PaddingBottom = UDim.new(0, 8),
          }),

          -- Step indicator (top-left, small)
          scope:New("TextLabel")({
            Name = "StepLabel",
            Size = UDim2.new(0, 100, 0, 16),
            Position = UDim2.new(0, 0, 0, 0),
            BackgroundTransparency = 1,
            Text = stepText,
            TextColor3 = UITheme.Colors.Gold,
            Font = UITheme.Fonts.SECONDARY,
            TextSize = STEP_TEXT_SIZE,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = animatedTransparency,
            [Children] = {
              UITheme.addTextStroke(scope, STEP_TEXT_SIZE),
            },
          }),

          -- Main message text
          scope:New("TextLabel")({
            Name = "Message",
            Size = UDim2.new(1, 0, 1, -8),
            Position = UDim2.new(0, 0, 0, 10),
            BackgroundTransparency = 1,
            Text = scope:Computed(function(use)
              return use(message)
            end),
            TextColor3 = UITheme.Colors.TextPrimary,
            Font = UITheme.Fonts.PRIMARY,
            TextSize = TEXT_SIZE,
            TextWrapped = true,
            TextTransparency = animatedTransparency,
            [Children] = {
              UITheme.addTextStroke(scope, TEXT_SIZE),
            },
          }),
        },
      }),

      -- Skip tutorial button (below prompt box)
      scope:New("TextButton")({
        Name = "SkipButton",
        Size = UDim2.new(0, 120, 0, 24),
        Position = UDim2.new(1, 0, 0, PROMPT_HEIGHT + 4),
        AnchorPoint = Vector2.new(1, 0),
        BackgroundColor3 = UITheme.Colors.PanelBackground,
        BackgroundTransparency = scope:Computed(function(use)
          return 0.3 + use(animatedTransparency) * 0.7
        end),
        Text = "Skip Tutorial",
        TextColor3 = UITheme.Colors.TextMuted,
        Font = UITheme.Fonts.SECONDARY,
        TextSize = SKIP_TEXT_SIZE,
        TextTransparency = scope:Computed(function(use)
          return 0.2 + use(animatedTransparency) * 0.8
        end),

        [Fusion.OnEvent("Activated")] = function()
          if onSkip then
            onSkip()
          end
        end,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UITheme.CornerRadius.Small,
          }),
          scope:New("UIStroke")({
            Color = UITheme.Colors.StrokeLight,
            Thickness = 1,
            Transparency = scope:Computed(function(use)
              return 0.5 + use(animatedTransparency) * 0.5
            end),
          }),
        },
      }),
    },
  })
end

return TutorialPrompt
