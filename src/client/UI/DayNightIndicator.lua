--[[
  DayNightIndicator.lua
  Fusion 0.3 component that displays the current day/night phase
  as a sun/moon icon with a progress bar showing time until the
  next phase transition.

  Phases and their icons:
    Dawn  — sunrise icon (orange-gold)
    Day   — sun icon (bright yellow)
    Dusk  — sunset icon (amber-red)
    Night — moon icon (cool blue-white)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local DayNightIndicator = {}

-- Constants
local INDICATOR_WIDTH = 52
local INDICATOR_HEIGHT = 52
local ICON_SIZE = 22
local LABEL_TEXT_SIZE = 11
local BAR_HEIGHT = 4
local BAR_INSET = 6 -- horizontal padding for the progress bar

-- Phase visual configuration
local PHASE_VISUALS = {
  Dawn = {
    color = Color3.fromRGB(255, 180, 60), -- warm orange-gold
    icon = "\xE2\x98\x80", -- ☀ (sunrise — same sun glyph, tinted warm)
    label = "DAWN",
  },
  Day = {
    color = Color3.fromRGB(255, 220, 60), -- bright sunny yellow
    icon = "\xE2\x98\x80", -- ☀ (sun)
    label = "DAY",
  },
  Dusk = {
    color = Color3.fromRGB(230, 120, 60), -- amber-red sunset
    icon = "\xF0\x9F\x8C\x85", -- 🌅 (sunset)
    label = "DUSK",
  },
  Night = {
    color = Color3.fromRGB(140, 170, 255), -- cool moonlight blue
    icon = "\xF0\x9F\x8C\x99", -- 🌙 (crescent moon)
    label = "NIGHT",
  },
}

local DEFAULT_VISUAL = PHASE_VISUALS.Day

--[[
  Creates the day/night indicator HUD component.
  @param scope Fusion scope
  @param phaseValue Fusion.Value<string> — current phase ("Dawn"|"Day"|"Dusk"|"Night")
  @param progressValue Fusion.Value<number> — progress through current phase [0, 1]
  @return Frame instance, triggerPulse function
]]
function DayNightIndicator.create(scope, phaseValue, progressValue)
  -- Derived visual from phase
  local PhaseVisual = scope:Computed(function(use)
    return PHASE_VISUALS[use(phaseValue)] or DEFAULT_VISUAL
  end)

  -- Derived color
  local PhaseColor = scope:Computed(function(use)
    return use(PhaseVisual).color
  end)

  local AnimatedColor = scope:Tween(PhaseColor, TweenInfo.new(0.5, Enum.EasingStyle.Quad))

  -- Derived icon
  local PhaseIcon = scope:Computed(function(use)
    return use(PhaseVisual).icon
  end)

  -- Derived label
  local PhaseLabel = scope:Computed(function(use)
    return use(PhaseVisual).label
  end)

  -- Progress bar width fraction (animated)
  local BarFraction = scope:Computed(function(use)
    return math.clamp(use(progressValue), 0, 1)
  end)

  -- Pulse scale for phase transitions
  local PulseScale = scope:Value(1)
  local AnimatedPulse =
    scope:Tween(PulseScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out))

  -- Build the component
  local indicator = scope:New("Frame")({
    Name = "DayNightIndicator",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 214), -- Below threat level indicator
    Size = UDim2.new(0, INDICATOR_WIDTH, 0, INDICATOR_HEIGHT),
    BackgroundColor3 = UITheme.Colors.DarkBackground,
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Medium,
      }),

      scope:New("UIStroke")({
        Color = AnimatedColor,
        Thickness = 2,
        Transparency = 0.3,
      }),

      scope:New("UIScale")({
        Scale = AnimatedPulse,
      }),

      -- Phase icon (top area)
      scope:New("TextLabel")({
        Name = "PhaseIcon",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 4),
        Size = UDim2.new(1, 0, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = AnimatedColor,
        TextSize = ICON_SIZE,
        Text = PhaseIcon,
      }),

      -- Phase name label
      scope:New("TextLabel")({
        Name = "PhaseLabel",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, ICON_SIZE + 4),
        Size = UDim2.new(1, 0, 0, LABEL_TEXT_SIZE + 2),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = AnimatedColor,
        TextSize = LABEL_TEXT_SIZE,
        Text = PhaseLabel,

        [Children] = {
          UITheme.addTextStroke(scope, LABEL_TEXT_SIZE),
        },
      }),

      -- Progress bar background (bottom of indicator)
      scope:New("Frame")({
        Name = "ProgressBarBg",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -6),
        Size = UDim2.new(1, -BAR_INSET * 2, 0, BAR_HEIGHT),
        BackgroundColor3 = Color3.fromRGB(30, 35, 45),
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UDim.new(0.5, 0),
          }),

          -- Progress bar fill
          scope:New("Frame")({
            Name = "ProgressBarFill",
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = scope:Tween(
              scope:Computed(function(use)
                return UDim2.new(use(BarFraction), 0, 1, 0)
              end),
              TweenInfo.new(0.3, Enum.EasingStyle.Quad)
            ),
            BackgroundColor3 = AnimatedColor,
            BackgroundTransparency = 0.1,
            BorderSizePixel = 0,

            [Children] = {
              scope:New("UICorner")({
                CornerRadius = UDim.new(0.5, 0),
              }),
            },
          }),
        },
      }),
    },
  })

  -- Pulse trigger function for phase transitions
  local function triggerPulse()
    PulseScale:set(1.2)
    task.delay(0.05, function()
      PulseScale:set(1)
    end)
  end

  return indicator, triggerPulse
end

return DayNightIndicator
