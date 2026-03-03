--[[
  LeaderboardPanel.lua
  Fusion 0.3 component that displays the leaderboard panel.
  Shows top players in 3 categories: Held Doubloons, Treasury, Notoriety.
  Highlights the local player's row. Tabbed navigation at top.

  The panel is rebuilt by the controller on every data refresh and tab change.
  Tab state is owned by the controller so switching tabs triggers a full rebuild.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local LeaderboardPanel = {}

-- Constants
local PANEL_WIDTH = 380
local HEADER_HEIGHT = 50
local TAB_BAR_HEIGHT = 36
local ROW_HEIGHT = 36
local ROW_SPACING = 3
local FOOTER_HEIGHT = 10
local MAX_ROWS = 10

-- Tab definitions
local TABS = {
  { id = "held", label = "HELD", icon = "\xF0\x9F\xAA\x99" },
  { id = "treasury", label = "TREASURY", icon = "\xF0\x9F\x8F\xA6" },
  { id = "notoriety", label = "NOTORIETY", icon = "\xE2\x9A\x94" },
}

-- Rank colors (matching NotorietyIndicator palette)
local RANK_COLORS = {
  deckhand = Color3.fromRGB(160, 165, 180),
  buccaneer = Color3.fromRGB(100, 200, 100),
  raider = Color3.fromRGB(100, 180, 255),
  captain = Color3.fromRGB(200, 100, 255),
  pirate_lord = Color3.fromRGB(255, 200, 50),
  dread_pirate = Color3.fromRGB(255, 80, 80),
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
  Creates a single player row in the leaderboard.
  @param scope Fusion scope
  @param rank number — position (1-based)
  @param entry { userId, name, value, rankName?, rankId? }
  @param isLocal boolean — whether this is the local player
  @param tabId string — current tab ("held", "treasury", "notoriety")
  @param animTransparency Fusion.Tween — animated transparency
  @return Frame instance
]]
local function createPlayerRow(scope, rank, entry, isLocal, tabId, animTransparency)
  -- Rank medal colors for top 3
  local rankColor
  if rank == 1 then
    rankColor = Color3.fromRGB(255, 215, 0) -- Gold
  elseif rank == 2 then
    rankColor = Color3.fromRGB(192, 192, 210) -- Silver
  elseif rank == 3 then
    rankColor = Color3.fromRGB(205, 127, 50) -- Bronze
  else
    rankColor = UITheme.Colors.TextMuted
  end

  local rowBg = if isLocal then UITheme.Colors.SurfaceSelected else UITheme.Colors.Surface

  -- Value display text
  local valueText
  if tabId == "notoriety" and entry.rankName then
    valueText = entry.rankName .. " (" .. formatNumber(entry.value) .. " XP)"
  else
    valueText = formatNumber(entry.value)
  end

  -- Value color
  local valueColor
  if tabId == "notoriety" and entry.rankId then
    valueColor = RANK_COLORS[entry.rankId] or UITheme.Colors.TextPrimary
  else
    valueColor = UITheme.Colors.Gold
  end

  return scope:New("Frame")({
    Name = "Row_" .. rank,
    LayoutOrder = rank,
    Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
    BackgroundColor3 = rowBg,
    BackgroundTransparency = animTransparency,
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0, 6),
      }),

      -- Highlight stroke for local player
      if isLocal
        then scope:New("UIStroke")({
          Color = UITheme.Colors.Gold,
          Thickness = 1.5,
          Transparency = scope:Computed(function(use)
            return math.clamp(use(animTransparency) + 0.3, 0, 1)
          end),
        })
        else nil,

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 10),
      }),

      -- Rank number
      scope:New("TextLabel")({
        Name = "Rank",
        Position = UDim2.new(0, 0, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.new(0, 28, 0, 20),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = rankColor,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextTransparency = animTransparency,
        Text = "#" .. rank,

        [Children] = {
          UITheme.addTextStroke(scope, 14),
        },
      }),

      -- Player name
      scope:New("TextLabel")({
        Name = "PlayerName",
        Position = UDim2.new(0, 32, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.new(0.45, -32, 0, 20),
        BackgroundTransparency = 1,
        Font = if isLocal then UITheme.Fonts.PRIMARY else UITheme.Fonts.SECONDARY,
        TextColor3 = if isLocal then UITheme.Colors.Gold else UITheme.Colors.TextPrimary,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTransparency = animTransparency,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Text = entry.name,

        [Children] = {
          UITheme.addTextStroke(scope, 13),
        },
      }),

      -- Value
      scope:New("TextLabel")({
        Name = "Value",
        Position = UDim2.new(1, 0, 0.5, 0),
        AnchorPoint = Vector2.new(1, 0.5),
        Size = UDim2.new(0.55, -4, 0, 20),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = valueColor,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTransparency = animTransparency,
        Text = valueText,

        [Children] = {
          UITheme.addTextStroke(scope, 12),
        },
      }),
    },
  })
end

--[[
  Creates a tab button.
  @param scope Fusion scope
  @param tab { id, label, icon }
  @param activeTabId string — the currently active tab ID
  @param onTabChange function(tabId) — callback when this tab is clicked
  @param animTransparency Fusion.Tween
  @param layoutOrder number
  @return TextButton instance
]]
local function createTabButton(scope, tab, activeTabId, onTabChange, animTransparency, layoutOrder)
  local IsHovering = scope:Value(false)
  local isActive = activeTabId == tab.id

  local BgColor = scope:Computed(function(use)
    local hovering = use(IsHovering)
    if isActive then
      return UITheme.Colors.Gold
    end
    return if hovering then UITheme.Colors.SurfaceHover else UITheme.Colors.Surface
  end)

  local textColor = if isActive then UITheme.Colors.DarkBackground else UITheme.Colors.TextPrimary

  return scope:New("TextButton")({
    Name = "Tab_" .. tab.id,
    LayoutOrder = layoutOrder,
    Size = UDim2.new(1 / #TABS, -4, 1, -6),
    BackgroundColor3 = scope:Tween(BgColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
    BackgroundTransparency = animTransparency,
    AutoButtonColor = false,
    Font = UITheme.Fonts.PRIMARY,
    TextColor3 = textColor,
    TextSize = 11,
    TextTransparency = animTransparency,
    Text = tab.icon .. " " .. tab.label,

    [Fusion.OnEvent("MouseEnter")] = function()
      IsHovering:set(true)
    end,

    [Fusion.OnEvent("MouseLeave")] = function()
      IsHovering:set(false)
    end,

    [Fusion.OnEvent("MouseButton1Click")] = function()
      if not isActive then
        onTabChange(tab.id)
      end
    end,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UDim.new(0, 6),
      }),
      UITheme.addTextStroke(scope, 11),
    },
  })
end

--[[
  Creates the full leaderboard panel.
  @param scope Fusion scope (owned by the controller)
  @param isVisible Fusion.Value<boolean> controlling panel visibility
  @param leaderboardData Fusion.Value<table> { held, treasury, notoriety }
  @param localUserId number — local player's UserId
  @param activeTabId string — current active tab ID ("held" | "treasury" | "notoriety")
  @param onTabChange function(tabId) — callback when a tab is clicked (triggers rebuild)
  @param onClose Callback when close button is clicked
  @return Frame instance (the panel root)
]]
function LeaderboardPanel.create(
  scope,
  isVisible,
  leaderboardData,
  localUserId,
  activeTabId,
  onTabChange,
  onClose
)
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

  -- Get the entries for the active tab
  local data = Fusion.peek(leaderboardData)
  local entries = data[activeTabId] or {}

  -- Clamp to MAX_ROWS
  local displayEntries = {}
  for i = 1, math.min(#entries, MAX_ROWS) do
    table.insert(displayEntries, entries[i])
  end

  -- Check if local player is in the displayed list
  local localInList = false
  local localEntry = nil
  local localRank = 0
  for i, entry in entries do
    if entry.userId == localUserId then
      localRank = i
      localEntry = entry
      if i <= MAX_ROWS then
        localInList = true
      end
      break
    end
  end

  -- Build player rows
  local playerRows = {}
  for i, entry in displayEntries do
    local isLocal = entry.userId == localUserId
    table.insert(
      playerRows,
      createPlayerRow(scope, i, entry, isLocal, activeTabId, AnimatedTransparency)
    )
  end

  -- Add "..." separator and local player row if they're not in top 10
  if not localInList and localEntry then
    -- Separator
    table.insert(
      playerRows,
      scope:New("TextLabel")({
        Name = "Separator",
        LayoutOrder = MAX_ROWS + 1,
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = 12,
        TextTransparency = AnimatedTransparency,
        Text = "\xC2\xB7\xC2\xB7\xC2\xB7",
      })
    )

    -- Local player row at their actual rank
    table.insert(
      playerRows,
      createPlayerRow(scope, localRank, localEntry, true, activeTabId, AnimatedTransparency)
    )
  end

  -- Empty state
  if #displayEntries == 0 then
    table.insert(
      playerRows,
      scope:New("TextLabel")({
        Name = "EmptyState",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 60),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = 14,
        TextTransparency = AnimatedTransparency,
        Text = "No players yet...",
      })
    )
  end

  -- Calculate panel height
  local rowCount = math.min(#entries, MAX_ROWS)
  if not localInList and localEntry then
    rowCount = rowCount + 2 -- separator + local row
  end
  if rowCount == 0 then
    rowCount = 1 -- empty state
  end
  local contentHeight = rowCount * ROW_HEIGHT + math.max(0, rowCount - 1) * ROW_SPACING
  local panelHeight = HEADER_HEIGHT + TAB_BAR_HEIGHT + contentHeight + 24 + FOOTER_HEIGHT

  -- Build tab buttons
  local tabButtons = {}
  for i, tab in TABS do
    table.insert(
      tabButtons,
      createTabButton(scope, tab, activeTabId, onTabChange, AnimatedTransparency, i)
    )
  end

  local panel = scope:New("Frame")({
    Name = "LeaderboardPanel",
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
            Text = "LEADERBOARD",

            [Children] = {
              UITheme.addTextStroke(scope, 20),
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

      -- Tab bar
      scope:New("Frame")({
        Name = "TabBar",
        Position = UDim2.new(0, 0, 0, HEADER_HEIGHT),
        Size = UDim2.new(1, 0, 0, TAB_BAR_HEIGHT),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UIPadding")({
            PaddingLeft = UDim.new(0, 10),
            PaddingRight = UDim.new(0, 10),
            PaddingTop = UDim.new(0, 3),
            PaddingBottom = UDim.new(0, 3),
          }),

          scope:New("UIListLayout")({
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 4),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          table.unpack(tabButtons),
        },
      }),

      -- Content area with player rows
      scope:New("ScrollingFrame")({
        Name = "Content",
        Position = UDim2.new(0, 0, 0, HEADER_HEIGHT + TAB_BAR_HEIGHT),
        Size = UDim2.new(1, 0, 0, contentHeight + 24),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = UITheme.Colors.TextMuted,
        CanvasSize = UDim2.new(0, 0, 0, contentHeight + 24),
        ScrollingDirection = Enum.ScrollingDirection.Y,

        [Children] = {
          scope:New("UIPadding")({
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 12),
            PaddingTop = UDim.new(0, 8),
            PaddingBottom = UDim.new(0, 8),
          }),

          scope:New("UIListLayout")({
            Padding = UDim.new(0, ROW_SPACING),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          table.unpack(playerRows),
        },
      }),
    },
  })

  return panel
end

return LeaderboardPanel
