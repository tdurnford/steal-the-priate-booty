--[[
  NotorietyIndicator.lua
  Fusion 0.3 component that displays the player's notoriety rank and XP progress
  as a compact HUD element. Shows rank icon, rank name, and XP progress bar.
  Hover tooltip shows exact XP and XP to next rank.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children
local OnEvent = Fusion.OnEvent

local NotorietyIndicator = {}

-- Constants
local INDICATOR_WIDTH = 52
local INDICATOR_HEIGHT = 52
local ICON_SIZE = 20
local TEXT_SIZE = 10
local TOOLTIP_TEXT_SIZE = 11
local TOOLTIP_WIDTH = 130
local TOOLTIP_HEIGHT = 44
local PROGRESS_BAR_HEIGHT = 4

-- Rank visual configuration
local RANK_VISUALS = {
  deckhand = {
    color = Color3.fromRGB(160, 165, 180), -- gray/muted
    icon = "\xE2\x9A\x93", -- ⚓
  },
  buccaneer = {
    color = Color3.fromRGB(100, 200, 100), -- green
    icon = "\xE2\x9A\x94", -- ⚔
  },
  raider = {
    color = Color3.fromRGB(80, 180, 255), -- blue
    icon = "\xF0\x9F\x97\xA1", -- 🗡
  },
  captain = {
    color = Color3.fromRGB(255, 200, 50), -- gold
    icon = "\xF0\x9F\x91\x91", -- 👑
  },
  pirate_lord = {
    color = Color3.fromRGB(255, 100, 180), -- pink/magenta
    icon = "\xF0\x9F\x94\xB1", -- 🔱
  },
  dread_pirate = {
    color = Color3.fromRGB(180, 60, 255), -- purple
    icon = "\xF0\x9F\x92\x80", -- 💀
  },
}

local DEFAULT_VISUAL = RANK_VISUALS.deckhand

--[[
  Gets the visual configuration for a given rank.
  @param rank RankDef
  @return table with color and icon fields
]]
local function getVisualForRank(rank: GameConfig.RankDef)
  return RANK_VISUALS[rank.id] or DEFAULT_VISUAL
end

--[[
  Formats XP as a compact string (e.g., "1.2k", "25k", "1.5M").
  @param xp number
  @return string
]]
local function formatXP(xp: number): string
  if xp >= 1000000 then
    return string.format("%.1fM", xp / 1000000)
  elseif xp >= 10000 then
    return string.format("%.0fk", xp / 1000)
  elseif xp >= 1000 then
    return string.format("%.1fk", xp / 1000)
  end
  return tostring(xp)
end

--[[
  Creates the notoriety indicator HUD component.
  @param scope Fusion scope
  @param notorietyXP Fusion.Value<number> — current XP total
  @param progressToNextRank Fusion.Value<number> — 0-1 fraction to next rank
  @return Frame instance, triggerPulse function
]]
function NotorietyIndicator.create(scope, notorietyXP, progressToNextRank)
  -- Derived rank from XP
  local Rank = scope:Computed(function(use)
    return GameConfig.getRankForXP(use(notorietyXP))
  end)

  -- Derived visual from rank
  local RankVisual = scope:Computed(function(use)
    return getVisualForRank(use(Rank))
  end)

  -- Derived color
  local RankColor = scope:Computed(function(use)
    return use(RankVisual).color
  end)

  local AnimatedColor = scope:Tween(RankColor, TweenInfo.new(0.5, Enum.EasingStyle.Quad))

  -- Derived icon
  local RankIcon = scope:Computed(function(use)
    return use(RankVisual).icon
  end)

  -- Rank name label
  local RankName = scope:Computed(function(use)
    local rank = use(Rank)
    return string.upper(rank.name)
  end)

  -- Tooltip text: "XP: 1.2k / 2k"
  local TooltipText = scope:Computed(function(use)
    local rank = use(Rank)
    local xp = use(notorietyXP)
    local nextRankIndex = rank.rank + 1
    if nextRankIndex > #GameConfig.Ranks then
      return "XP: " .. formatXP(xp) .. " (MAX)"
    end
    local nextRank = GameConfig.Ranks[nextRankIndex]
    return "XP: " .. formatXP(xp) .. " / " .. formatXP(nextRank.xpThreshold)
  end)

  -- Hover state for tooltip
  local IsHovered = scope:Value(false)

  -- Tooltip visibility
  local TooltipTransparency = scope:Computed(function(use)
    return if use(IsHovered) then 0 else 1
  end)

  local AnimatedTooltipTransparency =
    scope:Tween(TooltipTransparency, TweenInfo.new(0.15, Enum.EasingStyle.Quad))

  -- Progress bar width fraction (0-1)
  local AnimatedProgress =
    scope:Tween(progressToNextRank, TweenInfo.new(0.3, Enum.EasingStyle.Quad))

  -- Pulse scale for rank-up
  local PulseScale = scope:Value(1)
  local AnimatedPulse =
    scope:Tween(PulseScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out))

  -- Build the component
  local indicator = scope:New("Frame")({
    Name = "NotorietyIndicator",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 274), -- Below day/night indicator (214 + 52 + 8 gap)
    Size = UDim2.new(0, INDICATOR_WIDTH, 0, INDICATOR_HEIGHT),
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

      -- Rank icon
      scope:New("TextLabel")({
        Name = "RankIcon",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 4),
        Size = UDim2.new(1, 0, 0, ICON_SIZE),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = AnimatedColor,
        TextSize = ICON_SIZE,
        Text = RankIcon,
      }),

      -- Rank name (e.g., "DECKHAND")
      scope:New("TextLabel")({
        Name = "RankLabel",
        AnchorPoint = Vector2.new(0.5, 0),
        Position = UDim2.new(0.5, 0, 0, 25),
        Size = UDim2.new(1, -4, 0, TEXT_SIZE + 2),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = AnimatedColor,
        TextSize = TEXT_SIZE,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextScaled = true,
        Text = RankName,

        [Children] = {
          scope:New("UITextSizeConstraint")({
            MinTextSize = 7,
            MaxTextSize = TEXT_SIZE,
          }),
          UITheme.addTextStroke(scope, TEXT_SIZE),
        },
      }),

      -- Progress bar background
      scope:New("Frame")({
        Name = "ProgressBarBg",
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, -5),
        Size = UDim2.new(1, -10, 0, PROGRESS_BAR_HEIGHT),
        BackgroundColor3 = UITheme.Colors.Surface,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UDim.new(0.5, 0),
          }),

          -- Progress bar fill
          scope:New("Frame")({
            Name = "ProgressBarFill",
            Size = scope:Computed(function(use)
              return UDim2.new(use(AnimatedProgress), 0, 1, 0)
            end),
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

      -- Tooltip (shows XP details on hover)
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
            Text = TooltipText,

            [Children] = {
              UITheme.addTextStroke(scope, TOOLTIP_TEXT_SIZE),
            },
          }),
        },
      }),
    },
  })

  -- Pulse trigger function for rank-up
  local function triggerPulse()
    PulseScale:set(1.25)
    task.delay(0.05, function()
      PulseScale:set(1)
    end)
  end

  return indicator, triggerPulse
end

return NotorietyIndicator
