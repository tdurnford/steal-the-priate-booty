--[[
  PlayerStatsPanel.lua
  Fusion 0.3 component that displays the player's personal stats.
  Shows: total doubloons earned, total stolen, total raided, biggest haul,
  notoriety rank with XP progress bar, and current ship tier.

  The panel is rebuilt by the controller on every data refresh.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Fusion = require(Packages:WaitForChild("Fusion"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local PlayerStatsPanel = {}

-- Constants
local PANEL_WIDTH = 340
local HEADER_HEIGHT = 50
local ROW_HEIGHT = 40
local ROW_SPACING = 4
local SECTION_SPACING = 12
local PROGRESS_BAR_HEIGHT = 14

-- Rank colors (matching NotorietyIndicator palette)
local RANK_COLORS = {
  deckhand = Color3.fromRGB(160, 165, 180),
  buccaneer = Color3.fromRGB(100, 200, 100),
  raider = Color3.fromRGB(100, 180, 255),
  captain = Color3.fromRGB(200, 100, 255),
  pirate_lord = Color3.fromRGB(255, 200, 50),
  dread_pirate = Color3.fromRGB(255, 80, 80),
}

-- Ship tier colors
local SHIP_TIER_COLORS = {
  rowboat = Color3.fromRGB(160, 165, 180),
  sloop = Color3.fromRGB(100, 200, 100),
  schooner = Color3.fromRGB(100, 180, 255),
  brigantine = Color3.fromRGB(200, 100, 255),
  galleon = Color3.fromRGB(255, 200, 50),
  war_galleon = Color3.fromRGB(255, 140, 50),
  ghost_ship = Color3.fromRGB(255, 80, 80),
}

-- Stat row definitions
local STAT_ROWS = {
  { key = "totalEarned", label = "Doubloons Earned", icon = "\xF0\x9F\xAA\x99" },
  { key = "totalStolen", label = "Doubloons Stolen", icon = "\xE2\x9A\x94" },
  { key = "totalRaided", label = "Doubloons Raided", icon = "\xF0\x9F\x8F\xB4" },
  { key = "biggestHaul", label = "Biggest Haul", icon = "\xF0\x9F\x92\xB0" },
}

--[[
  Formats a number with comma separators.
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
  Creates a stat row with label and value.
  @param scope Fusion scope
  @param layoutOrder number
  @param icon string — emoji icon
  @param label string — stat label
  @param value number — stat value
  @param animTransparency Fusion.Tween
  @return Frame instance
]]
local function createStatRow(scope, layoutOrder, icon, label, value, animTransparency)
  return scope:New("Frame")({
    Name = "Stat_" .. label,
    LayoutOrder = layoutOrder,
    Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
    BackgroundColor3 = UITheme.Colors.Surface,
    BackgroundTransparency = animTransparency,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0, 6),
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
      }),

      -- Icon + Label
      scope:New("TextLabel")({
        Name = "Label",
        Position = UDim2.new(0, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.new(0.6, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = animTransparency,
        Text = icon .. "  " .. label,

        [Children] = {
          UITheme.addTextStroke(scope, 13),
        },
      }),

      -- Value
      scope:New("TextLabel")({
        Name = "Value",
        Position = UDim2.new(1, 0, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.new(0.4, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = UITheme.Colors.Gold,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTransparency = animTransparency,
        Text = formatNumber(value),

        [Children] = {
          UITheme.addTextStroke(scope, 14),
        },
      }),
    },
  })
end

--[[
  Creates a section header label.
  @param scope Fusion scope
  @param layoutOrder number
  @param text string
  @param animTransparency Fusion.Tween
  @return TextLabel instance
]]
local function createSectionHeader(scope, layoutOrder, text, animTransparency)
  return scope:New("TextLabel")({
    Name = "Section_" .. text,
    LayoutOrder = layoutOrder,
    Size = UDim2.new(1, 0, 0, 20),
    BackgroundTransparency = 1,
    Font = UITheme.Fonts.PRIMARY,
    TextColor3 = UITheme.Colors.TextPrimary,
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTransparency = animTransparency,
    Text = text,

    [Children] = {
      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 4),
      }),
      UITheme.addTextStroke(scope, 14),
    },
  })
end

--[[
  Creates the notoriety rank section with XP progress bar.
  @param scope Fusion scope
  @param layoutOrder number
  @param rankDef GameConfig.RankDef
  @param currentXP number
  @param animTransparency Fusion.Tween
  @return Frame instance
]]
local function createRankSection(scope, layoutOrder, rankDef, currentXP, animTransparency)
  local rankColor = RANK_COLORS[rankDef.id] or UITheme.Colors.TextPrimary

  -- Calculate progress to next rank
  local nextRank = nil
  for _, r in GameConfig.Ranks do
    if r.rank == rankDef.rank + 1 then
      nextRank = r
      break
    end
  end

  local progressFraction = 0
  local progressText = ""
  if nextRank then
    local xpIntoRank = currentXP - rankDef.xpThreshold
    local xpNeeded = nextRank.xpThreshold - rankDef.xpThreshold
    progressFraction = math.clamp(xpIntoRank / xpNeeded, 0, 1)
    progressText = formatNumber(currentXP) .. " / " .. formatNumber(nextRank.xpThreshold) .. " XP"
  else
    progressFraction = 1
    progressText = formatNumber(currentXP) .. " XP (MAX)"
  end

  return scope:New("Frame")({
    Name = "RankSection",
    LayoutOrder = layoutOrder,
    Size = UDim2.new(1, 0, 0, ROW_HEIGHT + PROGRESS_BAR_HEIGHT + 6),
    BackgroundColor3 = UITheme.Colors.Surface,
    BackgroundTransparency = animTransparency,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0, 6),
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
        PaddingTop = UDim.new(0, 6),
        PaddingBottom = UDim.new(0, 6),
      }),

      -- Rank name + icon
      scope:New("TextLabel")({
        Name = "RankName",
        Position = UDim2.new(0, 0, 0, 0),
        Size = UDim2.new(0.6, 0, 0, 22),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = rankColor,
        TextSize = 16,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = animTransparency,
        Text = "\xE2\x9A\x94  " .. rankDef.name,

        [Children] = {
          UITheme.addTextStroke(scope, 16),
        },
      }),

      -- Rank number badge
      scope:New("TextLabel")({
        Name = "RankNumber",
        Position = UDim2.new(1, 0, 0, 0),
        AnchorPoint = Vector2.new(1, 0),
        Size = UDim2.new(0.4, 0, 0, 22),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTransparency = animTransparency,
        Text = "Rank " .. rankDef.rank .. " of " .. #GameConfig.Ranks,

        [Children] = {
          UITheme.addTextStroke(scope, 12),
        },
      }),

      -- Progress bar background
      scope:New("Frame")({
        Name = "ProgressBg",
        Position = UDim2.new(0, 0, 1, -(PROGRESS_BAR_HEIGHT + 2)),
        Size = UDim2.new(1, 0, 0, PROGRESS_BAR_HEIGHT),
        BackgroundColor3 = UITheme.Colors.DarkBackground,
        BackgroundTransparency = animTransparency,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UDim.new(0, 4),
          }),

          -- Progress bar fill
          scope:New("Frame")({
            Name = "ProgressFill",
            Size = UDim2.new(progressFraction, 0, 1, 0),
            BackgroundColor3 = rankColor,
            BackgroundTransparency = animTransparency,
            BorderSizePixel = 0,

            [Children] = {
              scope:New("UICorner")({
                CornerRadius = UDim.new(0, 4),
              }),
            },
          }),

          -- Progress text
          scope:New("TextLabel")({
            Name = "ProgressText",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.SECONDARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 10,
            TextTransparency = animTransparency,
            Text = progressText,
            ZIndex = 2,

            [Children] = {
              UITheme.addTextStroke(scope, 10),
            },
          }),
        },
      }),
    },
  })
end

--[[
  Creates the ship tier section.
  @param scope Fusion scope
  @param layoutOrder number
  @param shipTierDef GameConfig.ShipTierDef
  @param treasury number
  @param animTransparency Fusion.Tween
  @return Frame instance
]]
local function createShipTierSection(scope, layoutOrder, shipTierDef, treasury, animTransparency)
  local tierColor = SHIP_TIER_COLORS[shipTierDef.id] or UITheme.Colors.TextPrimary

  -- Find next tier
  local nextTier = nil
  for _, t in GameConfig.ShipTiers do
    if t.tier == shipTierDef.tier + 1 then
      nextTier = t
      break
    end
  end

  local progressText = ""
  if nextTier then
    progressText = formatNumber(treasury)
      .. " / "
      .. formatNumber(nextTier.treasuryThreshold)
      .. " treasury"
  else
    progressText = formatNumber(treasury) .. " treasury (MAX)"
  end

  return scope:New("Frame")({
    Name = "ShipTierSection",
    LayoutOrder = layoutOrder,
    Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
    BackgroundColor3 = UITheme.Colors.Surface,
    BackgroundTransparency = animTransparency,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0, 6),
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
      }),

      -- Ship name + icon
      scope:New("TextLabel")({
        Name = "ShipName",
        Position = UDim2.new(0, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.new(0.5, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = tierColor,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = animTransparency,
        Text = "\xE2\x9A\x93  " .. shipTierDef.name,

        [Children] = {
          UITheme.addTextStroke(scope, 14),
        },
      }),

      -- Progress text
      scope:New("TextLabel")({
        Name = "TierProgress",
        Position = UDim2.new(1, 0, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.new(0.5, 0, 0, 20),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTransparency = animTransparency,
        Text = progressText,

        [Children] = {
          UITheme.addTextStroke(scope, 11),
        },
      }),
    },
  })
end

--[[
  Creates the full player stats panel.
  @param scope Fusion scope (owned by the controller)
  @param isVisible Fusion.Value<boolean> controlling panel visibility
  @param statsData table { stats: PlayerStats, notorietyXP: number, treasury: number }
  @param onClose Callback when close button is clicked
  @return Frame instance (the panel root)
]]
function PlayerStatsPanel.create(scope, isVisible, statsData, onClose)
  -- Animated visibility
  local AnimatedScale = scope:Tween(
    scope:Computed(function(use)
      return if use(isVisible) then 1 else 0.9
    end),
    UITheme.Animation.Bouncy
  )

  local AnimatedTransparency = scope:Tween(
    scope:Computed(function(use)
      return if use(isVisible) then 0 else 1
    end),
    TweenInfo.new(0.15, Enum.EasingStyle.Quad)
  )

  -- Close button hover
  local IsCloseHovering = scope:Value(false)
  local CloseButtonColor = scope:Computed(function(use)
    return if use(IsCloseHovering) then UITheme.Colors.CloseRedHover else UITheme.Colors.CloseRed
  end)

  -- Extract data
  local data = Fusion.peek(statsData)
  local stats = data.stats or { totalEarned = 0, totalStolen = 0, totalRaided = 0, biggestHaul = 0 }
  local notorietyXP = data.notorietyXP or 0
  local treasury = data.treasury or 0

  local rankDef = GameConfig.getRankForXP(notorietyXP)
  local shipTierDef = GameConfig.getShipTierForTreasury(treasury)

  -- Build content rows
  local contentChildren = {}
  local order = 0

  -- Doubloon stats section
  order = order + 1
  table.insert(
    contentChildren,
    createSectionHeader(scope, order, "DOUBLOON STATS", AnimatedTransparency)
  )

  for _, statDef in STAT_ROWS do
    order = order + 1
    table.insert(
      contentChildren,
      createStatRow(
        scope,
        order,
        statDef.icon,
        statDef.label,
        stats[statDef.key] or 0,
        AnimatedTransparency
      )
    )
  end

  -- Spacer
  order = order + 1
  table.insert(
    contentChildren,
    scope:New("Frame")({
      Name = "Spacer1",
      LayoutOrder = order,
      Size = UDim2.new(1, 0, 0, SECTION_SPACING - ROW_SPACING),
      BackgroundTransparency = 1,
    })
  )

  -- Notoriety section
  order = order + 1
  table.insert(
    contentChildren,
    createSectionHeader(scope, order, "NOTORIETY RANK", AnimatedTransparency)
  )

  order = order + 1
  table.insert(
    contentChildren,
    createRankSection(scope, order, rankDef, notorietyXP, AnimatedTransparency)
  )

  -- Spacer
  order = order + 1
  table.insert(
    contentChildren,
    scope:New("Frame")({
      Name = "Spacer2",
      LayoutOrder = order,
      Size = UDim2.new(1, 0, 0, SECTION_SPACING - ROW_SPACING),
      BackgroundTransparency = 1,
    })
  )

  -- Ship tier section
  order = order + 1
  table.insert(contentChildren, createSectionHeader(scope, order, "SHIP", AnimatedTransparency))

  order = order + 1
  table.insert(
    contentChildren,
    createShipTierSection(scope, order, shipTierDef, treasury, AnimatedTransparency)
  )

  -- Calculate total content height
  local statRowsCount = #STAT_ROWS
  local sectionHeaderCount = 3
  local spacerCount = 2
  local rankSectionHeight = ROW_HEIGHT + PROGRESS_BAR_HEIGHT + 6
  local contentHeight = (statRowsCount * ROW_HEIGHT)
    + (sectionHeaderCount * 20)
    + rankSectionHeight
    + ROW_HEIGHT -- ship tier row
    + (spacerCount * (SECTION_SPACING - ROW_SPACING))
    + ((statRowsCount + sectionHeaderCount + spacerCount + 2 - 1) * ROW_SPACING) -- list layout padding
    + 24 -- top/bottom padding
  local panelHeight = HEADER_HEIGHT + contentHeight + 10 -- footer

  -- Add list layout at the start
  table.insert(
    contentChildren,
    1,
    scope:New("UIPadding")({
      PaddingLeft = UDim.new(0, 12),
      PaddingRight = UDim.new(0, 12),
      PaddingTop = UDim.new(0, 8),
      PaddingBottom = UDim.new(0, 8),
    })
  )

  table.insert(
    contentChildren,
    2,
    scope:New("UIListLayout")({
      Padding = UDim.new(0, ROW_SPACING),
      SortOrder = Enum.SortOrder.LayoutOrder,
    })
  )

  local panel = scope:New("Frame")({
    Name = "PlayerStatsPanel",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    Size = UDim2.new(0, PANEL_WIDTH, 0, panelHeight),
    BackgroundColor3 = UITheme.Colors.DarkBackground,
    BackgroundTransparency = AnimatedTransparency,
    Visible = scope:Computed(function(use)
      return use(AnimatedTransparency) < 0.99
    end),
    ZIndex = 100,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Large,
      }),

      scope:New("UIStroke")({
        Color = UITheme.Colors.StrokeLight,
        Thickness = UITheme.Stroke.Panel,
        Transparency = AnimatedTransparency,
      }),

      scope:New("UIScale")({
        Scale = AnimatedScale,
      }),

      -- Header
      scope:New("Frame")({
        Name = "Header",
        Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
        BackgroundColor3 = UITheme.Colors.PanelBackground,
        BackgroundTransparency = AnimatedTransparency,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UITheme.CornerRadius.Large,
          }),

          -- Cover bottom corners
          scope:New("Frame")({
            Name = "BottomCover",
            Position = UDim2.new(0, 0, 1, -24),
            Size = UDim2.new(1, 0, 0, 24),
            BackgroundColor3 = UITheme.Colors.PanelBackground,
            BackgroundTransparency = AnimatedTransparency,
            BorderSizePixel = 0,
          }),

          -- Title
          scope:New("TextLabel")({
            Name = "Title",
            Position = UDim2.new(0, 16, 0.5, 0),
            AnchorPoint = Vector2.new(0, 0.5),
            Size = UDim2.new(0.6, 0, 0, 24),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 20,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = AnimatedTransparency,
            Text = "PLAYER STATS",

            [Children] = {
              UITheme.addTextStroke(scope, 20),
            },
          }),

          -- Keybind hint
          scope:New("TextLabel")({
            Name = "KeyHint",
            Position = UDim2.new(0, 16, 0.5, 12),
            AnchorPoint = Vector2.new(0, 0.5),
            Size = UDim2.new(0.4, 0, 0, 14),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.SECONDARY,
            TextColor3 = UITheme.Colors.TextMuted,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = AnimatedTransparency,
            Text = "Press P to close",

            [Children] = {
              UITheme.addTextStroke(scope, 10),
            },
          }),

          -- Close button
          scope:New("TextButton")({
            Name = "CloseButton",
            Position = UDim2.new(1, -4, 0, 4),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.new(0, 40, 0, 40),
            ZIndex = 10,
            BackgroundColor3 = scope:Tween(CloseButtonColor, TweenInfo.new(0.1)),
            BackgroundTransparency = AnimatedTransparency,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 22,
            Text = "X",
            AutoButtonColor = false,

            [Fusion.OnEvent("MouseEnter")] = function()
              IsCloseHovering:set(true)
            end,

            [Fusion.OnEvent("MouseLeave")] = function()
              IsCloseHovering:set(false)
            end,

            [Fusion.OnEvent("MouseButton1Click")] = function()
              onClose()
            end,

            [Children] = {
              scope:New("UICorner")({
                CornerRadius = UITheme.CornerRadius.Pill,
              }),
              UITheme.addTextStroke(scope, 22),
            },
          }),
        },
      }),

      -- Content area
      scope:New("ScrollingFrame")({
        Name = "Content",
        Position = UDim2.new(0, 0, 0, HEADER_HEIGHT),
        Size = UDim2.new(1, 0, 0, contentHeight),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = UITheme.Colors.TextMuted,
        CanvasSize = UDim2.new(0, 0, 0, contentHeight),
        ScrollingDirection = Enum.ScrollingDirection.Y,

        [Children] = contentChildren,
      }),
    },
  })

  return panel
end

return PlayerStatsPanel
