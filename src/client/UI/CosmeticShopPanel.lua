--[[
  CosmeticShopPanel.lua
  Fusion 0.3 component that displays the cosmetic shop panel.
  Shows 6 category tabs (Cutlass Skins, Hats, Outfits, Pets, Emotes, Ship
  Customization) with items that can be bought, equipped, or unequipped.
  Follows GearShopPanel + LeaderboardPanel patterns.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local CosmeticShopPanel = {}

-- Constants
local PANEL_WIDTH = 440
local HEADER_HEIGHT = 50
local TAB_BAR_HEIGHT = 36
local ITEM_HEIGHT = 80
local ITEM_SPACING = 6
local FOOTER_HEIGHT = 44
local MAX_VISIBLE_ITEMS = 5

-- Category tab definitions (ordered to match CosmeticConfig.Categories)
local TABS = {
  { id = "Cutlass Skins", label = "SKINS" },
  { id = "Hats", label = "HATS" },
  { id = "Outfits", label = "OUTFITS" },
  { id = "Pets", label = "PETS" },
  { id = "Emotes", label = "EMOTES" },
  { id = "Ship Customization", label = "SHIP" },
}

--[[
  Formats a doubloon cost with comma separators.
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
  Creates a single cosmetic item row in the shop.
  @param scope Fusion scope
  @param entry Cosmetic catalog entry (from CosmeticService:GetCosmeticCatalog)
  @param treasury Fusion.Value<number> current treasury balance
  @param onAction Callback (cosmeticId, action, equippedSlotField?)
  @return Frame instance
]]
local function createCosmeticRow(scope, entry, treasury, onAction)
  local IsHovering = scope:Value(false)
  local IsActioning = scope:Value(false)

  -- Determine button state: "buy", "equip", or "unequip"
  local ButtonState = scope:Computed(function(use)
    if entry.equippedInSlot then
      return "unequip"
    elseif entry.owned then
      return "equip"
    else
      return "buy"
    end
  end)

  local CanAfford = scope:Computed(function(use)
    return use(treasury) >= entry.cost
  end)

  -- Button colors
  local ButtonColor = scope:Computed(function(use)
    local state = use(ButtonState)
    local hovering = use(IsHovering)
    if state == "unequip" then
      return if hovering then UITheme.Colors.CloseRedHover else UITheme.Colors.CloseRed
    elseif state == "equip" then
      return if hovering then UITheme.Colors.ButtonCyanHover else UITheme.Colors.ButtonCyan
    else -- buy
      if not use(CanAfford) then
        return UITheme.Colors.Disabled
      end
      return if hovering then UITheme.Colors.MoneyGreenHover else UITheme.Colors.MoneyGreen
    end
  end)

  local ButtonText = scope:Computed(function(use)
    local state = use(ButtonState)
    if state == "unequip" then
      return "UNEQUIP"
    elseif state == "equip" then
      return "EQUIP"
    else
      return "BUY"
    end
  end)

  local ButtonTextColor = scope:Computed(function(use)
    local state = use(ButtonState)
    if state == "buy" and not use(CanAfford) then
      return UITheme.Colors.TextMuted
    end
    return UITheme.Colors.TextPrimary
  end)

  local RowBg = scope:Computed(function(use)
    if entry.equippedInSlot then
      return UITheme.Colors.SurfaceSelected
    end
    return if use(IsHovering) then UITheme.Colors.SurfaceHover else UITheme.Colors.Surface
  end)

  return scope:New("Frame")({
    Name = "CosmeticRow_" .. entry.id,
    LayoutOrder = entry.displayOrder,
    Size = UDim2.new(1, 0, 0, ITEM_HEIGHT),
    BackgroundColor3 = scope:Tween(RowBg, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
    BorderSizePixel = 0,

    [Fusion.OnEvent("MouseEnter")] = function()
      IsHovering:set(true)
    end,

    [Fusion.OnEvent("MouseLeave")] = function()
      IsHovering:set(false)
    end,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Small,
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 10),
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
      }),

      -- Left section: name + description + status
      scope:New("Frame")({
        Name = "InfoSection",
        Size = UDim2.new(1, -90, 1, 0),
        BackgroundTransparency = 1,

        [Children] = {
          -- Item name
          scope:New("TextLabel")({
            Name = "ItemName",
            Position = UDim2.new(0, 0, 0, 0),
            Size = UDim2.new(1, 0, 0, 18),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 15,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = entry.name,

            [Children] = {
              UITheme.addTextStroke(scope, 15),
            },
          }),

          -- Description
          scope:New("TextLabel")({
            Name = "Description",
            Position = UDim2.new(0, 0, 0, 20),
            Size = UDim2.new(1, 0, 0, 14),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.SECONDARY,
            TextColor3 = UITheme.Colors.TextMuted,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = entry.description,
          }),

          -- Status + cost row
          scope:New("Frame")({
            Name = "StatusRow",
            Position = UDim2.new(0, 0, 0, 40),
            Size = UDim2.new(1, 0, 0, 18),
            BackgroundTransparency = 1,

            [Children] = {
              scope:New("UIListLayout")({
                FillDirection = Enum.FillDirection.Horizontal,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                Padding = UDim.new(0, 6),
                SortOrder = Enum.SortOrder.LayoutOrder,
              }),

              -- Equipped badge
              if entry.equippedInSlot
                then scope:New("Frame")({
                  Name = "EquippedBadge",
                  LayoutOrder = 1,
                  Size = UDim2.new(0, 0, 0, 16),
                  AutomaticSize = Enum.AutomaticSize.X,
                  BackgroundColor3 = UITheme.Colors.ButtonCyan,
                  BackgroundTransparency = 0.7,

                  [Children] = {
                    scope:New("UICorner")({ CornerRadius = UDim.new(0, 4) }),
                    scope:New("UIPadding")({
                      PaddingLeft = UDim.new(0, 6),
                      PaddingRight = UDim.new(0, 6),
                    }),
                    scope:New("TextLabel")({
                      Size = UDim2.new(0, 0, 1, 0),
                      AutomaticSize = Enum.AutomaticSize.X,
                      BackgroundTransparency = 1,
                      Font = UITheme.Fonts.SECONDARY,
                      TextColor3 = UITheme.Colors.TextPrimary,
                      TextSize = 10,
                      Text = "EQUIPPED",
                    }),
                  },
                })
                else nil,

              -- Owned badge (if owned but not equipped)
              if entry.owned and not entry.equippedInSlot
                then scope:New("Frame")({
                  Name = "OwnedBadge",
                  LayoutOrder = 2,
                  Size = UDim2.new(0, 0, 0, 16),
                  AutomaticSize = Enum.AutomaticSize.X,
                  BackgroundColor3 = UITheme.Colors.MoneyGreen,
                  BackgroundTransparency = 0.7,

                  [Children] = {
                    scope:New("UICorner")({ CornerRadius = UDim.new(0, 4) }),
                    scope:New("UIPadding")({
                      PaddingLeft = UDim.new(0, 6),
                      PaddingRight = UDim.new(0, 6),
                    }),
                    scope:New("TextLabel")({
                      Size = UDim2.new(0, 0, 1, 0),
                      AutomaticSize = Enum.AutomaticSize.X,
                      BackgroundTransparency = 1,
                      Font = UITheme.Fonts.SECONDARY,
                      TextColor3 = UITheme.Colors.TextGreen,
                      TextSize = 10,
                      Text = "OWNED",
                    }),
                  },
                })
                else nil,

              -- Cost display (if not owned)
              if not entry.owned
                then scope:New("Frame")({
                  Name = "CostFrame",
                  LayoutOrder = 3,
                  Size = UDim2.new(0, 0, 0, 16),
                  AutomaticSize = Enum.AutomaticSize.X,
                  BackgroundTransparency = 1,

                  [Children] = {
                    scope:New("UIListLayout")({
                      FillDirection = Enum.FillDirection.Horizontal,
                      VerticalAlignment = Enum.VerticalAlignment.Center,
                      Padding = UDim.new(0, 3),
                      SortOrder = Enum.SortOrder.LayoutOrder,
                    }),

                    scope:New("TextLabel")({
                      Name = "CoinIcon",
                      LayoutOrder = 1,
                      Size = UDim2.new(0, 14, 0, 14),
                      BackgroundTransparency = 1,
                      Font = UITheme.Fonts.PRIMARY,
                      TextColor3 = UITheme.Colors.Gold,
                      TextSize = 12,
                      Text = "\xF0\x9F\xAA\x99",
                    }),

                    scope:New("TextLabel")({
                      Name = "CostText",
                      LayoutOrder = 2,
                      Size = UDim2.new(0, 0, 0, 14),
                      AutomaticSize = Enum.AutomaticSize.X,
                      BackgroundTransparency = 1,
                      Font = UITheme.Fonts.SECONDARY,
                      TextSize = 12,
                      TextColor3 = scope:Computed(function(use)
                        return if use(CanAfford)
                          then UITheme.Colors.Gold
                          else UITheme.Colors.TextRed
                      end),
                      Text = formatNumber(entry.cost),
                    }),
                  },
                })
                else nil,
            },
          }),
        },
      }),

      -- Right section: action button
      scope:New("TextButton")({
        Name = "ActionButton",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(0, 80, 0, 32),
        BackgroundColor3 = scope:Tween(ButtonColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
        AutoButtonColor = false,
        Font = UITheme.Fonts.PRIMARY,
        TextColor3 = ButtonTextColor,
        TextSize = 12,
        Text = ButtonText,

        [Fusion.OnEvent("MouseButton1Click")] = function()
          if Fusion.peek(IsActioning) then
            return
          end

          local state = Fusion.peek(ButtonState)
          if state == "buy" and not Fusion.peek(CanAfford) then
            return
          end

          IsActioning:set(true)
          onAction(entry.id, state, entry.equippedInSlot)

          task.delay(0.5, function()
            IsActioning:set(false)
          end)
        end,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UITheme.CornerRadius.Small,
          }),
          scope:New("UIStroke")({
            Color = UITheme.Colors.StrokeDark,
            Thickness = 1.5,
            Transparency = 0.5,
          }),
          UITheme.addTextStroke(scope, 12),
        },
      }),
    },
  })
end

--[[
  Creates a category tab button.
  @param scope Fusion scope
  @param tab { id, label }
  @param activeTabId string — the currently active tab ID
  @param onTabChange function(tabId) — callback when this tab is clicked
  @param animTransparency Fusion.Tween — animated transparency
  @param layoutOrder number
  @return TextButton instance
]]
local function createTabButton(scope, tab, activeTabId, onTabChange, animTransparency, layoutOrder)
  local IsHovering = scope:Value(false)
  local isActive = activeTabId == tab.id

  local BgColor = scope:Computed(function(use)
    if isActive then
      return UITheme.Colors.Gold
    end
    return if use(IsHovering) then UITheme.Colors.SurfaceHover else UITheme.Colors.Surface
  end)

  local textColor = if isActive then UITheme.Colors.DarkBackground else UITheme.Colors.TextPrimary

  return scope:New("TextButton")({
    Name = "Tab_" .. tab.label,
    LayoutOrder = layoutOrder,
    Size = UDim2.new(1 / #TABS, -3, 1, -6),
    BackgroundColor3 = scope:Tween(BgColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
    BackgroundTransparency = animTransparency,
    AutoButtonColor = false,
    Font = UITheme.Fonts.PRIMARY,
    TextColor3 = textColor,
    TextSize = 10,
    TextTransparency = animTransparency,
    Text = tab.label,

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
      UITheme.addTextStroke(scope, 10),
    },
  })
end

--[[
  Creates the full cosmetic shop panel.
  @param scope Fusion scope (owned by the controller)
  @param isVisible Fusion.Value<boolean> controlling panel visibility
  @param catalog Fusion.Value<table> full cosmetic catalog from server
  @param activeTab string — currently selected category tab ID
  @param treasury Fusion.Value<number> current treasury balance
  @param onTabChange function(tabId) — callback when a tab is clicked (triggers rebuild)
  @param onAction function(cosmeticId, action, equippedSlotField?) — buy/equip/unequip
  @param onClose function() — callback when close button is clicked
  @return Frame instance (the panel root)
]]
function CosmeticShopPanel.create(
  scope,
  isVisible,
  catalog,
  activeTab,
  treasury,
  onTabChange,
  onAction,
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

  -- Filter catalog entries by active tab
  local catalogEntries = Fusion.peek(catalog)
  local filteredEntries = {}
  for _, entry in catalogEntries do
    if entry.category == activeTab then
      table.insert(filteredEntries, entry)
    end
  end

  -- Sort by displayOrder
  table.sort(filteredEntries, function(a, b)
    return a.displayOrder < b.displayOrder
  end)

  -- Build item rows
  local itemRows = {}
  for _, entry in filteredEntries do
    table.insert(itemRows, createCosmeticRow(scope, entry, treasury, onAction))
  end

  -- Empty state
  if #filteredEntries == 0 then
    table.insert(
      itemRows,
      scope:New("TextLabel")({
        Name = "EmptyState",
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 60),
        BackgroundTransparency = 1,
        Font = UITheme.Fonts.SECONDARY,
        TextColor3 = UITheme.Colors.TextMuted,
        TextSize = 14,
        Text = "No items in this category.",
      })
    )
  end

  -- Calculate content and panel heights
  local itemCount = math.max(#filteredEntries, 1)
  local contentHeight = itemCount * ITEM_HEIGHT + math.max(0, itemCount - 1) * ITEM_SPACING + 24
  local maxContentHeight = MAX_VISIBLE_ITEMS * ITEM_HEIGHT
    + (MAX_VISIBLE_ITEMS - 1) * ITEM_SPACING
    + 24
  local displayContentHeight = math.min(contentHeight, maxContentHeight)
  local panelHeight = HEADER_HEIGHT + TAB_BAR_HEIGHT + displayContentHeight + FOOTER_HEIGHT

  -- Treasury display text
  local TreasuryText = scope:Computed(function(use)
    return formatNumber(use(treasury))
  end)

  -- Build tab buttons
  local tabButtons = {}
  for i, tab in TABS do
    table.insert(
      tabButtons,
      createTabButton(scope, tab, activeTab, onTabChange, AnimatedTransparency, i)
    )
  end

  local panel = scope:New("Frame")({
    Name = "CosmeticShopPanel",
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
            Text = "COSMETIC SHOP",

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
            PaddingLeft = UDim.new(0, 8),
            PaddingRight = UDim.new(0, 8),
            PaddingTop = UDim.new(0, 3),
            PaddingBottom = UDim.new(0, 3),
          }),

          scope:New("UIListLayout")({
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 3),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          table.unpack(tabButtons),
        },
      }),

      -- Scrollable content area with cosmetic items
      scope:New("ScrollingFrame")({
        Name = "Content",
        Position = UDim2.new(0, 0, 0, HEADER_HEIGHT + TAB_BAR_HEIGHT),
        Size = UDim2.new(1, 0, 0, displayContentHeight),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = UITheme.Colors.TextMuted,
        CanvasSize = UDim2.new(0, 0, 0, contentHeight),
        ScrollingDirection = Enum.ScrollingDirection.Y,

        [Children] = {
          scope:New("UIPadding")({
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 12),
            PaddingTop = UDim.new(0, 12),
            PaddingBottom = UDim.new(0, 12),
          }),

          scope:New("UIListLayout")({
            Padding = UDim.new(0, ITEM_SPACING),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          table.unpack(itemRows),
        },
      }),

      -- Footer: treasury balance
      scope:New("Frame")({
        Name = "Footer",
        Position = UDim2.new(0, 0, 1, -FOOTER_HEIGHT),
        Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("UIListLayout")({
            FillDirection = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Center,
            VerticalAlignment = Enum.VerticalAlignment.Center,
            Padding = UDim.new(0, 4),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          scope:New("TextLabel")({
            Name = "TreasuryLabel",
            LayoutOrder = 1,
            Size = UDim2.new(0, 0, 0, 20),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.SECONDARY,
            TextColor3 = UITheme.Colors.TextMuted,
            TextSize = 12,
            Text = "TREASURY:",
          }),

          scope:New("TextLabel")({
            Name = "CoinIcon",
            LayoutOrder = 2,
            Size = UDim2.new(0, 16, 0, 16),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.Gold,
            TextSize = 14,
            Text = "\xF0\x9F\xAA\x99",
          }),

          scope:New("TextLabel")({
            Name = "TreasuryValue",
            LayoutOrder = 3,
            Size = UDim2.new(0, 0, 0, 20),
            AutomaticSize = Enum.AutomaticSize.X,
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.Gold,
            TextSize = 14,
            Text = TreasuryText,

            [Children] = {
              UITheme.addTextStroke(scope, 14),
            },
          }),
        },
      }),
    },
  })

  return panel
end

return CosmeticShopPanel
