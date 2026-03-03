--[[
  MinimapPanel.lua
  Fusion 0.3 component that displays a circular minimap in the bottom-left
  corner of the screen. Shows the player's position at center with a
  direction arrow. Entity dots are managed by MinimapController.

  The minimap rotates relative to the player's facing direction so
  "up" on the minimap always means "forward" for the player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local MinimapPanel = {}

-- Constants
local MAP_SIZE = 160
local PLAYER_ARROW_SIZE = 14
local BORDER_THICKNESS = 2

--[[
  Creates the minimap HUD component.
  @param scope Fusion scope
  @param isVisible Fusion.Value<boolean> — whether the minimap is shown
  @return Frame container, Frame dotsContainer
]]
function MinimapPanel.create(scope, isVisible)
  -- Player direction arrow at center (always points up = forward)
  local playerArrow = scope:New("TextLabel")({
    Name = "PlayerArrow",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.new(0, PLAYER_ARROW_SIZE, 0, PLAYER_ARROW_SIZE),
    BackgroundTransparency = 1,
    Text = "\u{25B2}", -- ▲
    TextColor3 = Color3.fromRGB(100, 200, 255),
    TextSize = PLAYER_ARROW_SIZE,
    Font = UITheme.Fonts.SECONDARY,
    ZIndex = 10,

    [Children] = {
      UITheme.addTextStroke(scope, PLAYER_ARROW_SIZE),
    },
  })

  -- Subtle range ring at 75% radius for distance reference
  local rangeRing = scope:New("Frame")({
    Name = "RangeRing",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.new(0.75, 0, 0.75, 0),
    BackgroundTransparency = 1,
    ZIndex = 1,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0.5, 0),
      }),
      scope:New("UIStroke")({
        Color = UITheme.Colors.StrokeLight,
        Thickness = 1,
        Transparency = 0.7,
      }),
    },
  })

  -- Dots container (MinimapController adds entity dot instances here)
  local dotsContainer = scope:New("Frame")({
    Name = "DotsContainer",
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    ZIndex = 2,

    [Children] = {
      playerArrow,
      rangeRing,
    },
  })

  -- Main circular container
  local container = scope:New("Frame")({
    Name = "Minimap",
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 16, 1, -16),
    Size = UDim2.new(0, MAP_SIZE, 0, MAP_SIZE),
    BackgroundColor3 = UITheme.Colors.DarkBackground,
    BackgroundTransparency = 0.2,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Visible = isVisible,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0.5, 0),
      }),
      scope:New("UIStroke")({
        Color = UITheme.Colors.StrokeLight,
        Thickness = BORDER_THICKNESS,
        Transparency = 0.15,
      }),
      dotsContainer,
    },
  })

  return container, dotsContainer
end

return MinimapPanel
