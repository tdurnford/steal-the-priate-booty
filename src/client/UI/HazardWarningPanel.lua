--[[
  HazardWarningPanel.lua
  Fusion 0.3 component that displays flashing hazard warning prompts
  when environmental hazards are imminent near the player.

  Shows a pulsing warning bar at bottom-center of screen with:
    - Hazard-specific icon and color
    - Warning text (e.g., "ERUPTION IMMINENT!")
    - Flashing border animation
    - Auto-hides when hazard passes

  Supports stacking multiple simultaneous warnings (rare but possible).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local HazardWarningPanel = {}

-- Hazard type visual configs
HazardWarningPanel.HazardTypes = {
  volcanic_vent = {
    icon = "\xF0\x9F\x8C\x8B", -- 🌋
    text = "ERUPTION IMMINENT!",
    color = Color3.fromRGB(255, 120, 30), -- orange
    glowColor = Color3.fromRGB(255, 160, 60),
    bgColor = Color3.fromRGB(80, 30, 10),
  },
  tidal_surge = {
    icon = "\xF0\x9F\x8C\x8A", -- 🌊
    text = "TIDAL SURGE INCOMING!",
    color = Color3.fromRGB(40, 160, 220), -- ocean blue
    glowColor = Color3.fromRGB(80, 200, 255),
    bgColor = Color3.fromRGB(15, 40, 60),
  },
  rogue_wave = {
    icon = "\xF0\x9F\x8C\x8A", -- 🌊
    text = "ROGUE WAVE APPROACHING!",
    color = Color3.fromRGB(30, 100, 180), -- deep blue
    glowColor = Color3.fromRGB(60, 140, 220),
    bgColor = Color3.fromRGB(10, 25, 50),
  },
  quicksand = {
    icon = "\xE2\x9A\xA0\xEF\xB8\x8F", -- ⚠️
    text = "QUICKSAND NEARBY!",
    color = Color3.fromRGB(210, 160, 50), -- amber
    glowColor = Color3.fromRGB(240, 200, 80),
    bgColor = Color3.fromRGB(60, 45, 15),
  },
}

-- Layout constants
local PANEL_WIDTH = 320
local PANEL_HEIGHT = 52
local ICON_SIZE = 28
local TEXT_SIZE = 18
local PULSE_SPEED = 5
local PULSE_MIN = 0.85
local PULSE_MAX = 1.08
local STACK_SPACING = 6

--[[
  Creates a single hazard warning element.
  @param scope Fusion scope
  @param hazardType string — key into HazardTypes
  @param isVisible Fusion.Value<boolean> — whether this warning is visible
  @param layoutOrder number — for stacking
  @return Frame instance
]]
function HazardWarningPanel.createWarning(scope, hazardType: string, isVisible, layoutOrder: number)
  local config = HazardWarningPanel.HazardTypes[hazardType]
  if not config then
    config = HazardWarningPanel.HazardTypes.volcanic_vent
  end

  -- Visibility drives transparency
  local TargetTransparency = scope:Computed(function(use)
    return if use(isVisible) then 0 else 1
  end)

  local AnimatedTransparency =
    scope:Tween(TargetTransparency, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Pulse scale for attention
  local PulseScale = scope:Value(1)
  local pulseConnection = nil

  scope:Observer(isVisible):onBind(function()
    local visible = Fusion.peek(isVisible)
    if visible then
      if not pulseConnection then
        local startTime = os.clock()
        pulseConnection = RunService.Heartbeat:Connect(function()
          local t = (os.clock() - startTime) * PULSE_SPEED
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

  -- Cleanup
  table.insert(scope, function()
    if pulseConnection then
      pulseConnection:Disconnect()
      pulseConnection = nil
    end
  end)

  local AnimatedPulse = scope:Tween(PulseScale, TweenInfo.new(0.06, Enum.EasingStyle.Quad))

  -- Flashing stroke color
  local StrokeColor = scope:Computed(function(use)
    local scale = use(PulseScale)
    local t = (scale - PULSE_MIN) / (PULSE_MAX - PULSE_MIN)
    return config.color:Lerp(config.glowColor, t)
  end)

  -- Flashing text transparency (rapid flash)
  local TextFlash = scope:Computed(function(use)
    local base = use(AnimatedTransparency)
    if base > 0.5 then
      return base
    end
    local scale = use(PulseScale)
    local t = (scale - PULSE_MIN) / (PULSE_MAX - PULSE_MIN)
    -- Subtle flash between 0 and 0.15
    return base + t * 0.15
  end)

  local warning = scope:New("Frame")({
    Name = "HazardWarning_" .. hazardType,
    LayoutOrder = layoutOrder,
    Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT),
    BackgroundColor3 = config.bgColor,
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

      -- Horizontal layout: icon + text + icon
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Padding = UDim.new(0, 10),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Left icon
      scope:New("TextLabel")({
        Name = "IconLeft",
        LayoutOrder = 1,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = config.color,
        TextTransparency = TextFlash,
        TextSize = ICON_SIZE,
        Text = config.icon,
      }),

      -- Warning text
      scope:New("TextLabel")({
        Name = "WarningText",
        LayoutOrder = 2,
        Size = UDim2.new(0, PANEL_WIDTH - ICON_SIZE * 2 - 40, 0, PANEL_HEIGHT),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = config.color,
        TextTransparency = TextFlash,
        TextSize = TEXT_SIZE,
        Text = config.text,

        [Children] = {
          UITheme.addTextStroke(scope, TEXT_SIZE),
        },
      }),

      -- Right icon
      scope:New("TextLabel")({
        Name = "IconRight",
        LayoutOrder = 3,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = config.color,
        TextTransparency = TextFlash,
        TextSize = ICON_SIZE,
        Text = config.icon,
      }),
    },
  })

  return warning
end

--[[
  Creates the hazard warning container that holds stacked warning elements.
  Positioned at bottom-center of screen, above the action bar area.
  @param scope Fusion scope
  @param warnings table — { [hazardType] = Fusion.Value<boolean> }
  @return Frame instance (container)
]]
function HazardWarningPanel.createContainer(scope, warnings)
  local children = {
    scope:New("UIListLayout")({
      FillDirection = Enum.FillDirection.Vertical,
      VerticalAlignment = Enum.VerticalAlignment.Bottom,
      HorizontalAlignment = Enum.HorizontalAlignment.Center,
      Padding = UDim.new(0, STACK_SPACING),
      SortOrder = Enum.SortOrder.LayoutOrder,
    }),
  }

  -- Create a warning element for each hazard type
  local order = 1
  for hazardType, isVisible in warnings do
    local warningElement = HazardWarningPanel.createWarning(scope, hazardType, isVisible, order)
    table.insert(children, warningElement)
    order = order + 1
  end

  local container = scope:New("Frame")({
    Name = "HazardWarningContainer",
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -120),
    Size = UDim2.new(0, PANEL_WIDTH, 0, (PANEL_HEIGHT + STACK_SPACING) * 4),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,

    [Children] = children,
  })

  return container
end

return HazardWarningPanel
