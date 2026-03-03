--[[
  RaidAlertOverlay.lua
  Fusion 0.3 component that displays a persistent "YOUR SHIP IS BEING RAIDED!"
  warning when another player is actively raiding the local player's ship.

  Shows:
    - Pulsing warning icon
    - "YOUR SHIP IS BEING RAIDED!" text
    - Raider's name
    - Red/orange glowing border with pulse animation
    - Persists while raid is in progress, dismisses when raid ends
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local RaidAlertOverlay = {}

-- Constants
local PANEL_WIDTH = 300
local PANEL_HEIGHT = 52
local ICON_SIZE = 24
local TITLE_TEXT_SIZE = 16
local RAIDER_TEXT_SIZE = 12
local WARNING_ICON = "\xE2\x9A\xA0" -- ⚠
local RAID_COLOR = Color3.fromRGB(255, 100, 50) -- orange-red
local RAID_GLOW_COLOR = Color3.fromRGB(255, 140, 70)
local PULSE_MIN = 0.9
local PULSE_MAX = 1.05
local PULSE_SPEED = 4.5

--[[
  Creates the raid alert overlay HUD component.
  @param scope Fusion scope
  @param isVisible Fusion.Value<boolean> — whether the alert is visible
  @param raiderName Fusion.Value<string> — name of the player raiding the ship
  @return Frame instance
]]
function RaidAlertOverlay.create(scope, isVisible, raiderName)
  -- Visibility drives transparency
  local TargetTransparency = scope:Computed(function(use)
    return if use(isVisible) then 0 else 1
  end)

  local AnimatedTransparency =
    scope:Tween(TargetTransparency, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Pulse scale driven by RunService
  local PulseScale = scope:Value(1)
  local pulseConnection = nil

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

  -- Stroke glow pulse
  local StrokeColor = scope:Computed(function(use)
    local scale = use(PulseScale)
    local t = math.clamp((scale - PULSE_MIN) / (PULSE_MAX - PULSE_MIN), 0, 1)
    return RAID_COLOR:Lerp(RAID_GLOW_COLOR, t)
  end)

  -- Raider name text
  local RaiderText = scope:Computed(function(use)
    local name = use(raiderName)
    if name == "" then
      return ""
    end
    return "by " .. name
  end)

  -- Build the component
  local overlay = scope:New("Frame")({
    Name = "RaidAlertOverlay",
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 106), -- Below bounty alert (52 + 48 + 6 gap)
    Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT),
    BackgroundColor3 = Color3.fromRGB(60, 25, 10),
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

      -- Inner layout: icon + text column
      scope:New("UIListLayout")({
        FillDirection = Enum.FillDirection.Horizontal,
        VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
      }),

      -- Left warning icon
      scope:New("TextLabel")({
        Name = "WarningLeft",
        LayoutOrder = 1,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = RAID_COLOR,
        TextTransparency = AnimatedTransparency,
        TextSize = ICON_SIZE,
        Text = WARNING_ICON,
      }),

      -- Text column (title + raider name)
      scope:New("Frame")({
        Name = "TextColumn",
        LayoutOrder = 2,
        Size = UDim2.new(0, 210, 0, PANEL_HEIGHT - 8),
        BackgroundTransparency = 1,

        [Children] = {
          scope:New("UIListLayout")({
            FillDirection = Enum.FillDirection.Vertical,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            Padding = UDim.new(0, 1),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          -- Title text
          scope:New("TextLabel")({
            Name = "RaidTitle",
            LayoutOrder = 1,
            Size = UDim2.new(1, 0, 0, TITLE_TEXT_SIZE + 4),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = RAID_COLOR,
            TextTransparency = AnimatedTransparency,
            TextSize = TITLE_TEXT_SIZE,
            Text = "YOUR SHIP IS BEING RAIDED!",

            [Children] = {
              UITheme.addTextStroke(scope, TITLE_TEXT_SIZE),
            },
          }),

          -- Raider name
          scope:New("TextLabel")({
            Name = "RaiderName",
            LayoutOrder = 2,
            Size = UDim2.new(1, 0, 0, RAIDER_TEXT_SIZE + 4),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.SECONDARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextTransparency = AnimatedTransparency,
            TextSize = RAIDER_TEXT_SIZE,
            Text = RaiderText,

            [Children] = {
              UITheme.addTextStroke(scope, RAIDER_TEXT_SIZE),
            },
          }),
        },
      }),

      -- Right warning icon
      scope:New("TextLabel")({
        Name = "WarningRight",
        LayoutOrder = 3,
        Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = RAID_COLOR,
        TextTransparency = AnimatedTransparency,
        TextSize = ICON_SIZE,
        Text = WARNING_ICON,
      }),
    },
  })

  return overlay
end

return RaidAlertOverlay
