--[[
  ThreatLevelIndicator.lua
  Fusion 0.3 component that displays the player's current threat level
  as a color-coded icon on the HUD. Colors change based on threat tier:
    Calm (0-19): green
    Uneasy (20-39): yellow
    Hunted (40-59): orange
    Cursed (60-79): red
    Doomed (80-100): purple with skull icon
  Shows exact threat number as tooltip text on hover.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

local ThreatLevelIndicator = {}

-- Constants
local INDICATOR_SIZE = 44
local ICON_SIZE = 24
local TEXT_SIZE = 13
local TOOLTIP_TEXT_SIZE = 12
local TOOLTIP_WIDTH = 80
local TOOLTIP_HEIGHT = 26

-- Threat tier visual configuration
local TIER_VISUALS = {
  calm = {
    color = Color3.fromRGB(80, 200, 80), -- green
    icon = "\xE2\x9A\x93", -- ⚓ (anchor — safe)
  },
  uneasy = {
    color = Color3.fromRGB(240, 220, 60), -- yellow
    icon = "\xE2\x9A\xA0", -- ⚠ (warning)
  },
  hunted = {
    color = Color3.fromRGB(255, 150, 40), -- orange
    icon = "\xE2\x9A\xA0", -- ⚠ (warning)
  },
  cursed = {
    color = Color3.fromRGB(255, 70, 70), -- red
    icon = "\xE2\x98\xA0", -- ☠ (skull)
  },
  doomed = {
    color = Color3.fromRGB(180, 60, 255), -- purple
    icon = "\xF0\x9F\x92\x80", -- 💀 (skull)
  },
}

local DEFAULT_VISUAL = TIER_VISUALS.calm

--[[
  Gets the visual configuration for a given threat value.
  @param threat number (0-100)
  @return table with color and icon fields
]]
local function getVisualForThreat(threat: number)
  local tier = GameConfig.getThreatTier(threat)
  return TIER_VISUALS[tier.id] or DEFAULT_VISUAL
end

--[[
  Creates the threat level indicator HUD component.
  @param scope Fusion scope
  @param threatValue Fusion.Value<number> — current threat level (0-100)
  @return Frame instance, triggerPulse function
]]
function ThreatLevelIndicator.create(scope, threatValue)
  -- Derived tier visual from threat value
  local TierVisual = scope:Computed(function(use)
    return getVisualForThreat(use(threatValue))
  end)

  -- Derived color
  local TierColor = scope:Computed(function(use)
    return use(TierVisual).color
  end)

  local AnimatedColor = scope:Tween(TierColor, TweenInfo.new(0.5, Enum.EasingStyle.Quad))

  -- Derived icon
  local TierIcon = scope:Computed(function(use)
    return use(TierVisual).icon
  end)

  -- Tier name label
  local TierName = scope:Computed(function(use)
    local tier = GameConfig.getThreatTier(use(threatValue))
    return string.upper(tier.name)
  end)

  -- Threat number for tooltip
  local ThreatText = scope:Computed(function(use)
    return "Threat: " .. tostring(math.floor(use(threatValue)))
  end)

  -- Hover state for tooltip
  local IsHovered = scope:Value(false)

  -- Tooltip visibility
  local TooltipTransparency = scope:Computed(function(use)
    return if use(IsHovered) then 0 else 1
  end)

  local AnimatedTooltipTransparency =
    scope:Tween(TooltipTransparency, TweenInfo.new(0.15, Enum.EasingStyle.Quad))

  -- Pulse scale for threat tier changes
  local PulseScale = scope:Value(1)
  local AnimatedPulse =
    scope:Tween(PulseScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out))

  -- Build the component
  local indicator = scope:New("Frame")({
    Name = "ThreatLevelIndicator",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 160), -- Below ship hold indicator
    Size = UDim2.new(0, INDICATOR_SIZE, 0, INDICATOR_SIZE),
    BackgroundColor3 = UITheme.Colors.DarkBackground,
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,

    [OnEvent("MouseEnter")] = function()
      IsHovered:set(true)
    end,

    [OnEvent("MouseLeave")] = function()
      IsHovered:set(false)
    end,

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

      -- Vertical layout: icon on top, tier name below
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Vertical,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Padding = UDim.new(0, 0),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Threat icon
      scope:New("TextLabel")({
        Name = "ThreatIcon",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = AnimatedColor,
        TextSize = ICON_SIZE - 4,
        Text = TierIcon,
      }),

      -- Tier name (e.g. "CALM")
      scope:New("TextLabel")({
        Name = "TierLabel",
        LayoutOrder = 2,
        Size = UDim2.new(1, 0, 0, TEXT_SIZE + 2),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = AnimatedColor,
        TextSize = TEXT_SIZE,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = TierName,

        [Children] = {
          UITheme.addTextStroke(scope, TEXT_SIZE),
        },
      }),

      -- Tooltip (shows exact threat number on hover)
      scope:New("Frame")({
        Name = "Tooltip",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(0, -8, 0.5, 0),
        Size = UDim2.new(0, TOOLTIP_WIDTH, 0, TOOLTIP_HEIGHT),
        BackgroundColor3 = UITheme.Colors.DarkBackground,
        BackgroundTransparency = AnimatedTooltipTransparency,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UITheme.CornerRadius.Small,
          }),

          scope:New("UIStroke")({
            Color = UITheme.Colors.StrokeLight,
            Thickness = 1,
            Transparency = AnimatedTooltipTransparency,
          }),

          scope:New("TextLabel")({
            Name = "TooltipText",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.SECONDARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = TOOLTIP_TEXT_SIZE,
            TextTransparency = AnimatedTooltipTransparency,
            Text = ThreatText,

            [Children] = {
              UITheme.addTextStroke(scope, TOOLTIP_TEXT_SIZE),
            },
          }),
        },
      }),
    },
  })

  -- Pulse trigger function for tier changes
  local function triggerPulse()
    PulseScale:set(1.2)
    task.delay(0.05, function()
      PulseScale:set(1)
    end)
  end

  return indicator, triggerPulse
end

return ThreatLevelIndicator
