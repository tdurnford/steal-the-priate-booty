--[[
  ShipHoldIndicator.lua
  Fusion 0.3 component that displays the player's ship hold doubloons
  and lock/unlock state on the HUD, positioned below the held doubloons counter.
  Shows:
    - Ship hold doubloon count with animated transitions
    - Lock/unlock icon reflecting current ship lock state
    - Treasury (banked) total with lock icon
    - Pulse animation on deposit/lock events
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local ShipHoldIndicator = {}

-- Constants
local ROW_HEIGHT = 36
local INDICATOR_MIN_WIDTH = 140
local ICON_SIZE = 22
local TEXT_SIZE = 18
local LABEL_SIZE = 10
local ROW_GAP = 4

-- Icons (UTF-8 encoded emoji)
local SHIP_ICON = "\xE2\x9A\x93" -- ⚓
local LOCKED_ICON = "\xF0\x9F\x94\x92" -- 🔒
local UNLOCKED_ICON = "\xF0\x9F\x94\x93" -- 🔓
local TREASURY_ICON = "\xF0\x9F\x92\xB0" -- 💰

--[[
  Formats a doubloon count with comma separators for readability.
  @param n The number to format
  @return Formatted string (e.g. "1,234")
]]
local function formatNumber(n: number): string
  local formatted = tostring(math.floor(n))
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
  Creates a single row (hold or treasury) with icon, label, and count.
  @param scope Fusion scope
  @param opts Table with: icon, label, displayValue, textColor, iconColor
  @return Frame instance
]]
local function createRow(
  scope,
  opts: {
    name: string,
    layoutOrder: number,
    icon: any, -- Fusion.Value<string> or string
    label: string,
    displayText: any, -- Fusion.Computed<string>
    textColor: any, -- Fusion.Computed<Color3> or Color3
    iconColor: any, -- Fusion.Computed<Color3> or Color3
  }
)
  return scope:New("Frame")({
    Name = opts.name,
    LayoutOrder = opts.layoutOrder,
    Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
    AutomaticSize = Enum.AutomaticSize.X,
    BackgroundTransparency = 1,

    [Children] = {
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, 5),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Label
      scope:New("TextLabel")({
        Name = "Label",
        LayoutOrder = 1,
        Size = UDim2.new(0, 0, 0, ROW_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = LABEL_SIZE,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Text = opts.label,
      }),

      -- Icon
      scope:New("TextLabel")({
        Name = "Icon",
        LayoutOrder = 2,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = opts.iconColor,
        TextSize = ICON_SIZE - 4,
        Text = opts.icon,
      }),

      -- Count text
      scope:New("TextLabel")({
        Name = "CountText",
        LayoutOrder = 3,
        Size = UDim2.new(0, 0, 0, ROW_HEIGHT),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = opts.textColor,
        TextSize = TEXT_SIZE,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextYAlignment = Enum.TextYAlignment.Center,
        Text = opts.displayText,

        [Children] = {
          UITheme.addTextStroke(scope, TEXT_SIZE),
        },
      }),

      -- Lock state icon (only for hold row)
      if opts.lockIcon
        then scope:New("TextLabel")({
          Name = "LockIcon",
          LayoutOrder = 4,
          Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
          BackgroundTransparency = 1,
          Font = UITheme.Fonts.PRIMARY,
          TextColor3 = opts.lockColor,
          TextSize = ICON_SIZE - 4,
          Text = opts.lockIcon,
        })
        else nil,
    },
  })
end

--[[
  Creates the ship hold indicator HUD component.
  @param scope Fusion scope
  @param shipHoldValue Fusion.Value<number> — current ship hold doubloons
  @param shipLockedValue Fusion.Value<boolean> — whether the ship is locked
  @param treasuryValue Fusion.Value<number> — current treasury total
  @return Frame instance, triggerPulse function
]]
function ShipHoldIndicator.create(scope, shipHoldValue, shipLockedValue, treasuryValue)
  -- Animated display values for smooth count transitions
  local AnimatedHold = scope:Tween(
    scope:Computed(function(use)
      return use(shipHoldValue)
    end),
    TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
  )

  local AnimatedTreasury = scope:Tween(
    scope:Computed(function(use)
      return use(treasuryValue)
    end),
    TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
  )

  -- Formatted display texts
  local HoldDisplayText = scope:Computed(function(use)
    return formatNumber(use(AnimatedHold))
  end)

  local TreasuryDisplayText = scope:Computed(function(use)
    return formatNumber(use(AnimatedTreasury))
  end)

  -- Lock icon changes based on locked state
  local LockIcon = scope:Computed(function(use)
    return if use(shipLockedValue) then LOCKED_ICON else UNLOCKED_ICON
  end)

  -- Lock color: green when locked (safe), orange when unlocked (vulnerable)
  local LockColor = scope:Computed(function(use)
    return if use(shipLockedValue) then UITheme.Colors.TextGreen else UITheme.Colors.Gold
  end)

  local AnimatedLockColor = scope:Tween(LockColor, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Hold text color: gold when holding, muted when empty
  local HoldTextColor = scope:Computed(function(use)
    return if use(shipHoldValue) > 0 then UITheme.Colors.Gold else UITheme.Colors.TextMuted
  end)

  local AnimatedHoldTextColor =
    scope:Tween(HoldTextColor, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Treasury text color: green when has treasury, muted when 0
  local TreasuryTextColor = scope:Computed(function(use)
    return if use(treasuryValue) > 0 then UITheme.Colors.TextGreen else UITheme.Colors.TextMuted
  end)

  local AnimatedTreasuryTextColor =
    scope:Tween(TreasuryTextColor, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Pulse scale for deposit/lock feedback
  local PulseScale = scope:Value(1)
  local AnimatedPulse =
    scope:Tween(PulseScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out))

  -- Build the component
  local indicator = scope:New("Frame")({
    Name = "ShipHoldIndicator",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 68), -- Below the doubloons counter (16 + 44 + 8 gap)
    Size = UDim2.new(0, INDICATOR_MIN_WIDTH, 0, 0),
    AutomaticSize = Enum.AutomaticSize.XY,
    BackgroundColor3 = UITheme.Colors.DarkBackground,
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Medium,
      }),

      scope:New("UIStroke")({
        Color = UITheme.Colors.StrokeLight,
        Thickness = 2,
        Transparency = 0.3,
      }),

      scope:New("UIScale")({
        Scale = AnimatedPulse,
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 12),
        PaddingTop = UDim.new(0, 6),
        PaddingBottom = UDim.new(0, 6),
      }),

      -- Vertical layout for two rows
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Vertical,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, ROW_GAP),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Row 1: Ship hold (⚓ HOLD 123 🔓)
      createRow(scope, {
        name = "HoldRow",
        layoutOrder = 1,
        icon = SHIP_ICON,
        label = "HOLD",
        displayText = HoldDisplayText,
        textColor = AnimatedHoldTextColor,
        iconColor = UITheme.Colors.PlayerBlue,
        lockIcon = LockIcon,
        lockColor = AnimatedLockColor,
      }),

      -- Row 2: Treasury (💰 BANKED 1,234)
      createRow(scope, {
        name = "TreasuryRow",
        layoutOrder = 2,
        icon = TREASURY_ICON,
        label = "BANKED",
        displayText = TreasuryDisplayText,
        textColor = AnimatedTreasuryTextColor,
        iconColor = UITheme.Colors.MoneyGreen,
      }),
    },
  })

  -- Pulse trigger function
  local function triggerPulse()
    PulseScale:set(1.12)
    task.delay(0.05, function()
      PulseScale:set(1)
    end)
  end

  return indicator, triggerPulse
end

return ShipHoldIndicator
