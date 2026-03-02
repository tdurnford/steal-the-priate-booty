--[[
  HudDoubloonsCounter.lua
  Fusion 0.3 component that displays the player's held (unbanked) doubloons
  in the top-right area of the screen with a coin icon, animated count,
  and pulse feedback on pickup/loss.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local HudDoubloonsCounter = {}

-- Constants
local COUNTER_HEIGHT = 44
local COUNTER_MIN_WIDTH = 140
local ICON_SIZE = 28
local TEXT_SIZE = 22
local LABEL_SIZE = 11

-- Coin icon text (gold circle unicode)
local COIN_ICON = "\xF0\x9F\xAA\x99" -- 🪙

--[[
  Formats a doubloon count with comma separators for readability.
  @param n The number to format
  @return Formatted string (e.g. "1,234")
]]
local function formatNumber(n: number): string
  local formatted = tostring(math.floor(n))
  -- Insert commas from right to left
  local k
  while true do
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
    if k == 0 then
      break
    end
  end
  return formatted
end

--[[
  Creates the held doubloons HUD counter component.
  @param scope Fusion scope
  @param currentValue Fusion.Value<number> — the current held doubloons count
  @return Frame instance (the root component)
]]
function HudDoubloonsCounter.create(scope, currentValue)
  -- Animated display value for smooth count transitions
  local DisplayValue = scope:Tween(
    scope:Computed(function(use)
      return use(currentValue)
    end),
    TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
  )

  -- Formatted text derived from animated value
  local DisplayText = scope:Computed(function(use)
    return formatNumber(use(DisplayValue))
  end)

  -- Pulse scale for pickup/loss feedback (driven externally via PulseScale value)
  local PulseScale = scope:Value(1)
  local AnimatedPulse =
    scope:Tween(PulseScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out))

  -- Text color: gold when holding doubloons, muted when empty
  local TextColor = scope:Computed(function(use)
    return if use(currentValue) > 0 then UITheme.Colors.Gold else UITheme.Colors.TextMuted
  end)

  local AnimatedTextColor = scope:Tween(TextColor, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Build the component
  local counter = scope:New("Frame")({
    Name = "DoubloonsCounter",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 16),
    Size = UDim2.new(0, COUNTER_MIN_WIDTH, 0, COUNTER_HEIGHT),
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundColor3 = UITheme.Colors.DarkBackground,
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Medium,
      }),

      scope:New("UIStroke")({
        Color = UITheme.Colors.GoldDark,
        Thickness = 2,
        Transparency = 0.3,
      }),

      scope:New("UIScale")({
        Scale = AnimatedPulse,
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 14),
        PaddingTop = UDim.new(0, 0),
        PaddingBottom = UDim.new(0, 0),
      }),

      -- Horizontal layout
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Label ("HELD")
      scope:New("TextLabel")({
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.new(0, 0, 0, COUNTER_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = LABEL_SIZE,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Text = "HELD",
      }),

      -- Coin icon
      scope:New("TextLabel")({
        Name = "CoinIcon",
        LayoutOrder = 2,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = UITheme.Colors.Gold,
        TextSize = ICON_SIZE - 4,
        Text = COIN_ICON,
      }),

      -- Doubloon count
      scope:New("TextLabel")({
        Name = "CountText",
        LayoutOrder = 3,
        Size = UDim2.new(0, 0, 0, COUNTER_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = AnimatedTextColor,
        TextSize = TEXT_SIZE,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Center,
        Text = DisplayText,

        [Children] = {
          UITheme.addTextStroke(scope, TEXT_SIZE),
        },
      }),
    },
  })

  -- Expose pulse trigger method on the counter instance via attributes
  -- The controller calls counter:SetAttribute("Pulse", tick()) to trigger
  local function triggerPulse()
    PulseScale:set(1.15)
    task.delay(0.05, function()
      PulseScale:set(1)
    end)
  end

  -- Store pulse function so controller can call it
  counter:SetAttribute("_hasPulse", true)

  -- Return counter + triggerPulse function
  return counter, triggerPulse
end

return HudDoubloonsCounter
