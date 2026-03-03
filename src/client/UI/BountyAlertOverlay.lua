--[[
  BountyAlertOverlay.lua
  Fusion 0.3 component that displays a persistent pulsing "BOUNTY ON YOU!" warning
  when the local player has an active bounty. Positioned at top-center of screen.

  Shows:
    - Pulsing skull icon
    - "BOUNTY ON YOU!" text in red
    - Red glowing border with pulse animation
    - Fades in/out smoothly when bounty starts/ends
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local BountyAlertOverlay = {}

-- Constants
local PANEL_WIDTH = 260
local PANEL_HEIGHT = 48
local ICON_SIZE = 28
local TEXT_SIZE = 18
local SKULL_ICON = "\xF0\x9F\x92\x80" -- 💀
local BOUNTY_COLOR = Color3.fromRGB(255, 50, 50) -- bright red
local BOUNTY_GLOW_COLOR = Color3.fromRGB(255, 80, 80)
local PULSE_MIN = 0.85
local PULSE_MAX = 1.05
local PULSE_SPEED = 3.5

--[[
  Creates the bounty alert overlay HUD component.
  @param scope Fusion scope
  @param isVisible Fusion.Value<boolean> — whether the alert is visible
  @return Frame instance
]]
function BountyAlertOverlay.create(scope, isVisible)
  -- Visibility drives transparency (0 = visible, 1 = hidden)
  local TargetTransparency = scope:Computed(function(use)
    return if use(isVisible) then 0 else 1
  end)

  local AnimatedTransparency =
    scope:Tween(TargetTransparency, TweenInfo.new(0.4, Enum.EasingStyle.Quad))

  -- Pulse scale driven by RunService for continuous animation
  local PulseScale = scope:Value(1)
  local pulseConnection = nil

  -- Start/stop pulse loop based on visibility
  scope:Observer(isVisible):onBind(function()
    local visible = Fusion.peek(isVisible)
    if visible then
      if not pulseConnection then
        pulseConnection = RunService.Heartbeat:Connect(function()
          local t = os.clock() * PULSE_SPEED
          local scale = PULSE_MIN + (PULSE_MAX - PULSE_MIN) * (0.5 + 0.5 * math.sin(t))
          PulseScale:set(scale)
        end)
      end
    else
      if pulseConnection then
        pulseConnection:Disconnect()
        pulseConnection = nil
      end
      PulseScale:set(1)
    end
  end)

  -- Clean up on scope destruction
  table.insert(scope, function()
    if pulseConnection then
      pulseConnection:Disconnect()
      pulseConnection = nil
    end
  end)

  local AnimatedPulse = scope:Tween(PulseScale, TweenInfo.new(0.08, Enum.EasingStyle.Quad))

  -- Stroke glow pulse (alternates between two red shades)
  local StrokeColor = scope:Computed(function(use)
    local scale = use(PulseScale)
    local t = (scale - PULSE_MIN) / (PULSE_MAX - PULSE_MIN)
    return BOUNTY_COLOR:Lerp(BOUNTY_GLOW_COLOR, t)
  end)

  -- Build the component
  local overlay = scope:New("Frame")({
    Name = "BountyAlertOverlay",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 52),
    Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT),
    BackgroundColor3 = Color3.fromRGB(60, 15, 15),
    BackgroundTransparency = AnimatedTransparency,
    BorderSizePixel = 0,
    Visible = scope:Computed(function(use)
      return use(AnimatedTransparency) < 0.99
    end),

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Medium,
      }),

      scope:New("UIStroke")({
        Color = StrokeColor,
        Thickness = 3,
        Transparency = scope:Computed(function(use)
          return use(AnimatedTransparency) * 0.8
        end),
      }),

      scope:New("UIScale")({
        Scale = AnimatedPulse,
      }),

      -- Horizontal layout: skull + text + skull
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Left skull icon
      scope:New("TextLabel")({
        Name = "SkullLeft",
        LayoutOrder = 1,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = BOUNTY_COLOR,
        TextTransparency = AnimatedTransparency,
        TextSize = ICON_SIZE,
        Text = SKULL_ICON,
      }),

      -- Warning text
      scope:New("TextLabel")({
        Name = "BountyText",
        LayoutOrder = 2,
        Size = UDim2.new(0, 160, 0, PANEL_HEIGHT),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = BOUNTY_COLOR,
        TextTransparency = AnimatedTransparency,
        TextSize = TEXT_SIZE,
        Text = "BOUNTY ON YOU!",

        [Children] = {
          UITheme.addTextStroke(scope, TEXT_SIZE),
        },
      }),

      -- Right skull icon
      scope:New("TextLabel")({
        Name = "SkullRight",
        LayoutOrder = 3,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = BOUNTY_COLOR,
        TextTransparency = AnimatedTransparency,
        TextSize = ICON_SIZE,
        Text = SKULL_ICON,
      }),
    },
  })

  return overlay
end

return BountyAlertOverlay
