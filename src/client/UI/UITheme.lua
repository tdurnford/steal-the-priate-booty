--[[
	UITheme.lua
	Shared design tokens for the playful arcade/casino UI design system.
	All UI files import from this module for consistent styling.
]]

local UITheme = {}

-- Color palette
UITheme.Colors = {
  -- Backgrounds
  DarkBackground = Color3.fromRGB(40, 45, 55),
  PanelBackground = Color3.fromRGB(60, 65, 75),
  Surface = Color3.fromRGB(70, 75, 85),
  SurfaceHover = Color3.fromRGB(85, 90, 100),
  SurfaceSelected = Color3.fromRGB(70, 120, 90),

  -- Primary actions
  ButtonCyan = Color3.fromRGB(0, 200, 255),
  ButtonCyanHover = Color3.fromRGB(40, 220, 255),
  MoneyGreen = Color3.fromRGB(80, 200, 80),
  MoneyGreenHover = Color3.fromRGB(100, 220, 100),
  Gold = Color3.fromRGB(255, 200, 50),
  GoldDark = Color3.fromRGB(200, 150, 0),
  CloseRed = Color3.fromRGB(255, 70, 80),
  CloseRedHover = Color3.fromRGB(255, 100, 110),
  AccentPink = Color3.fromRGB(255, 100, 180),
  PlayerBlue = Color3.fromRGB(100, 180, 255),

  -- Robux
  RobuxBlue = Color3.fromRGB(0, 162, 255),
  RobuxBlueHover = Color3.fromRGB(30, 180, 255),

  -- Text
  TextPrimary = Color3.fromRGB(240, 240, 250),
  TextMuted = Color3.fromRGB(160, 165, 180),
  TextMoney = Color3.fromRGB(80, 220, 100),
  TextRobux = Color3.fromRGB(0, 200, 255),
  TextRed = Color3.fromRGB(255, 100, 100),
  TextGreen = Color3.fromRGB(100, 255, 100),
  TextActive = Color3.fromRGB(255, 200, 50),

  -- Disabled
  Disabled = Color3.fromRGB(90, 90, 105),

  -- Strokes
  StrokeLight = Color3.fromRGB(80, 85, 100),
  StrokeDark = Color3.fromRGB(30, 35, 45),

  -- Toggle
  ToggleOn = Color3.fromRGB(80, 200, 120),
  ToggleOff = Color3.fromRGB(100, 100, 120),
  ToggleKnob = Color3.fromRGB(255, 255, 255),

  -- Powerup types
  TimedBoost = Color3.fromRGB(100, 180, 255),
  Permanent = Color3.fromRGB(180, 100, 255),
  Gamepass = Color3.fromRGB(255, 180, 50),

  -- Loading screen
  LoadingBg = Color3.fromRGB(20, 25, 35),
  LoadingPrimary = Color3.fromRGB(80, 220, 100),
  LoadingSecondary = Color3.fromRGB(40, 180, 80),
  LoadingAccent = Color3.fromRGB(255, 180, 50),

  -- Type badge colors (for powerups)
  TypeBadge = {
    timed_boost = { bg = Color3.fromRGB(40, 80, 120), text = Color3.fromRGB(100, 180, 255) },
    permanent = { bg = Color3.fromRGB(80, 40, 100), text = Color3.fromRGB(180, 100, 255) },
    gamepass = { bg = Color3.fromRGB(100, 80, 30), text = Color3.fromRGB(255, 200, 80) },
  },

  -- Inventory
  OpenButton = Color3.fromRGB(200, 150, 50),
  OpenButtonHover = Color3.fromRGB(230, 180, 60),
  EmptySlot = Color3.fromRGB(50, 55, 65),

  -- Rebirth lock
  RebirthLocked = Color3.fromRGB(45, 40, 50),
  RebirthLockedButton = Color3.fromRGB(80, 40, 40),

  -- HUD buttons
  HudButtonBg = Color3.fromRGB(80, 85, 95),
  HudButtonBgHover = Color3.fromRGB(100, 105, 118),
  HudButtonBorder = Color3.fromRGB(120, 125, 140),
}

-- Fonts
UITheme.Fonts = {
  PRIMARY = Enum.Font.FredokaOne,
  SECONDARY = Enum.Font.GothamBold,
}

-- Corner radii
UITheme.CornerRadius = {
  Small = UDim.new(0, 10),
  Medium = UDim.new(0, 16),
  Large = UDim.new(0, 24),
  Pill = UDim.new(0.5, 0),
  Circle = UDim.new(1, 0),
}

-- Stroke thicknesses
UITheme.Stroke = {
  Panel = 3,
  Button = 3,
  Item = 2,
  PanelTransparency = 0.15,
}

-- Animation presets
UITheme.Animation = {
  Instant = TweenInfo.new(0.1, Enum.EasingStyle.Back),
  Snappy = TweenInfo.new(0.25, Enum.EasingStyle.Quad),
  Bouncy = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
  Fade = TweenInfo.new(0.2, Enum.EasingStyle.Quad),
  Press = TweenInfo.new(0.1, Enum.EasingStyle.Back),
}

--[[
	Returns the recommended UIStroke thickness for a given text size.
	Larger text gets thicker strokes for readability.
	@param textSize The font size
	@return thickness number
]]
function UITheme.getTextStrokeThickness(textSize: number): number
  if textSize >= 28 then
    return 2.5
  elseif textSize >= 20 then
    return 2
  elseif textSize >= 14 then
    return 1.5
  else
    return 1
  end
end

--[[
	Creates a UIStroke child for text with proper thickness based on size.
	@param scope Fusion scope
	@param textSize The font size
	@param color Optional stroke color (defaults to black)
	@return UIStroke instance
]]
function UITheme.addTextStroke(scope, textSize: number, color: Color3?)
  return scope:New("UIStroke")({
    Color = color or Color3.fromRGB(0, 0, 0),
    Thickness = UITheme.getTextStrokeThickness(textSize),
    Transparency = 0.1,
  })
end

return UITheme
