--[[
  GearShopPanel.lua
  Fusion 0.3 component that displays the gear shop panel.
  Shows all 5 purchasable cutlass tiers with name, cost, damage value,
  and Buy/Equip/Equipped action buttons. Respects treasury balance.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Fusion = require(Packages:WaitForChild("Fusion"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

local Children = Fusion.Children

local GearShopPanel = {}

-- Constants
local PANEL_WIDTH = 360
local HEADER_HEIGHT = 50
local ITEM_HEIGHT = 72
local ITEM_SPACING = 6
local FOOTER_HEIGHT = 44

-- Gear tier colors for the damage badge
local TIER_COLORS = {
  rusty_cutlass = Color3.fromRGB(140, 140, 140),
  iron_cutlass = Color3.fromRGB(170, 180, 190),
  steel_cutlass = Color3.fromRGB(210, 215, 220),
  captains_saber = Color3.fromRGB(255, 200, 50),
  legendary_blade = Color3.fromRGB(255, 140, 40),
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
  Creates a single gear item row in the shop.
  @param scope Fusion scope
  @param entry Gear catalog entry table
  @param treasury Fusion.Value<number> current treasury balance
  @param onAction Callback (gearId, action) where action is "buy" or "equip"
  @return Frame instance
]]
local function createGearRow(scope, entry, treasury, onAction)
  local IsHovering = scope:Value(false)
  local IsActioning = scope:Value(false)

  local tierColor = TIER_COLORS[entry.id] or UITheme.Colors.TextMuted

  -- Determine button state: "buy", "equip", or "equipped"
  local ButtonState = scope:Computed(function(use)
    if entry.equipped then
      return "equipped"
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
    if state == "equipped" then
      return UITheme.Colors.Disabled
    elseif state == "equip" then
      return if hovering then UITheme.Colors.ButtonCyanHover else UITheme.Colors.ButtonCyan
    else -- buy
      local canAfford = use(CanAfford)
      if not canAfford then
        return UITheme.Colors.Disabled
      end
      return if hovering then UITheme.Colors.MoneyGreenHover else UITheme.Colors.MoneyGreen
    end
  end)

  local ButtonText = scope:Computed(function(use)
    local state = use(ButtonState)
    if state == "equipped" then
      return "EQUIPPED"
    elseif state == "equip" then
      return "EQUIP"
    else
      return "BUY"
    end
  end)

  local ButtonTextColor = scope:Computed(function(use)
    local state = use(ButtonState)
    if state == "equipped" then
      return UITheme.Colors.TextMuted
    end
    local canAfford = use(CanAfford)
    if state == "buy" and not canAfford then
      return UITheme.Colors.TextMuted
    end
    return UITheme.Colors.TextPrimary
  end)

  local RowBg = scope:Computed(function(use)
    if entry.equipped then
      return UITheme.Colors.SurfaceSelected
    end
    return if use(IsHovering) then UITheme.Colors.SurfaceHover else UITheme.Colors.Surface
  end)

  return scope:New("Frame")({
    Name = "GearRow_" .. entry.id,
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

      -- Left section: name + stats
      scope:New("Frame")({
        Name = "InfoSection",
        Size = UDim2.new(1, -90, 1, 0),
        BackgroundTransparency = 1,

        [Children] = {
          -- Gear name
          scope:New("TextLabel")({
            Name = "GearName",
            Position = UDim2.new(0, 0, 0, 0),
            Size = UDim2.new(1, 0, 0, 20),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 16,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = entry.name,

            [Children] = {
              UITheme.addTextStroke(scope, 16),
            },
          }),

          -- Damage stat row
          scope:New("Frame")({
            Name = "DamageRow",
            Position = UDim2.new(0, 0, 0, 22),
            Size = UDim2.new(1, 0, 0, 16),
            BackgroundTransparency = 1,

            [Children] = {
              scope:New("UIListLayout")({
                FillDirection = Enum.FillDirection.Horizontal,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                Padding = UDim.new(0, 6),
                SortOrder = Enum.SortOrder.LayoutOrder,
              }),

              -- Damage badge
              scope:New("Frame")({
                Name = "DamageBadge",
                LayoutOrder = 1,
                Size = UDim2.new(0, 0, 0, 16),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundColor3 = tierColor,
                BackgroundTransparency = 0.7,

                [Children] = {
                  scope:New("UICorner")({
                    CornerRadius = UDim.new(0, 4),
                  }),
                  scope:New("UIPadding")({
                    PaddingLeft = UDim.new(0, 6),
                    PaddingRight = UDim.new(0, 6),
                  }),
                  scope:New("TextLabel")({
                    Name = "DamageText",
                    Size = UDim2.new(0, 0, 1, 0),
                    AutomaticSize = Enum.AutomaticSize.X,
                    BackgroundTransparency = 1,
                    Font = UITheme.Fonts.SECONDARY,
                    TextColor3 = UITheme.Colors.TextPrimary,
                    TextSize = 11,
                    Text = entry.containerDamage .. " DMG",
                  }),
                },
              }),

              -- Owned indicator
              scope:New("TextLabel")({
                Name = "OwnedLabel",
                LayoutOrder = 2,
                Size = UDim2.new(0, 0, 0, 16),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundTransparency = 1,
                Font = UITheme.Fonts.SECONDARY,
                TextColor3 = UITheme.Colors.TextMuted,
                TextSize = 11,
                Visible = entry.owned,
                Text = "OWNED",
              }),
            },
          }),

          -- Cost display
          scope:New("Frame")({
            Name = "CostRow",
            Position = UDim2.new(0, 0, 0, 40),
            Size = UDim2.new(1, 0, 0, 14),
            BackgroundTransparency = 1,
            Visible = not entry.owned,

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
                  if entry.cost == 0 then
                    return UITheme.Colors.TextGreen
                  end
                  return if use(CanAfford) then UITheme.Colors.Gold else UITheme.Colors.TextRed
                end),
                Text = if entry.cost == 0 then "FREE" else formatNumber(entry.cost),
              }),
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
        TextSize = 13,
        Text = ButtonText,

        [Fusion.OnEvent("MouseButton1Click")] = function()
          if Fusion.peek(IsActioning) then
            return
          end

          local state = Fusion.peek(ButtonState)
          if state == "equipped" then
            return
          end

          if state == "buy" and not Fusion.peek(CanAfford) then
            return
          end

          IsActioning:set(true)
          local action = if state == "buy" then "buy" else "equip"
          onAction(entry.id, action)

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
          UITheme.addTextStroke(scope, 13),
        },
      }),
    },
  })
end

--[[
  Creates the full gear shop panel.
  @param scope Fusion scope (owned by the controller)
  @param isVisible Fusion.Value<boolean> controlling panel visibility
  @param catalog Array of gear catalog entries (from GearService:GetGearCatalog)
  @param treasury Fusion.Value<number> current treasury balance
  @param onAction Callback (gearId, action) for buy/equip
  @param onClose Callback when close button is clicked
  @return Frame instance (the panel root)
]]
function GearShopPanel.create(scope, isVisible, catalog, treasury, onAction, onClose)
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

  -- Build gear rows from catalog
  local gearRows = {}
  local catalogEntries = Fusion.peek(catalog)
  for _, entry in catalogEntries do
    table.insert(gearRows, createGearRow(scope, entry, treasury, onAction))
  end

  -- Calculate panel height
  local itemCount = #catalogEntries
  local contentHeight = itemCount * ITEM_HEIGHT + math.max(0, itemCount - 1) * ITEM_SPACING
  local panelHeight = HEADER_HEIGHT + contentHeight + 24 + FOOTER_HEIGHT -- 24 = content padding

  -- Treasury display text
  local TreasuryText = scope:Computed(function(use)
    return formatNumber(use(treasury))
  end)

  local panel = scope:New("Frame")({
    Name = "GearShopPanel",
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
            Text = "GEAR SHOP",

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

      -- Content area with gear items
      scope:New("Frame")({
        Name = "Content",
        Position = UDim2.new(0, 0, 0, HEADER_HEIGHT),
        Size = UDim2.new(1, 0, 0, contentHeight + 24),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,

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

          table.unpack(gearRows),
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

return GearShopPanel
