---
name: fusion-ui
description: >
  Activate when creating, editing, or discussing any UI panel, component, HUD element,
  or screen built with Fusion in this Roblox project. Also activate when the user asks
  about Fusion 0.3 patterns, UITheme tokens, reactive state, or panel lifecycle.
---
# Building Reactive UI with Fusion 0.3

This project uses **Fusion 0.3** with the scoped API pattern. Every UI file lives under
`src/client/UI/` and is orchestrated by `src/client/Controllers/UIController.lua`.

## Core Concept: Scoped Fusion

Fusion 0.3 replaces the old `Fusion.New`, `Fusion.Value`, etc. with **scoped constructors**.
A scope tracks every reactive object created through it so they can be cleaned up together.

```lua
local Fusion = require(Packages:WaitForChild("Fusion"))
local Children = Fusion.Children

-- Create a scope. Pass Fusion itself so all constructors are available.
local scope = Fusion.scoped(Fusion)

-- Now use scope:Value(), scope:Computed(), scope:New(), etc.
local Count = scope:Value(0)
local Label = scope:Computed(function(use)
    return "Count: " .. use(Count)
end)
```

The `use` function inside `Computed` subscribes to reactive dependencies. When those
dependencies change, the computed re-evaluates automatically.

## Module Structure

Every UI module follows the same pattern:

1. A table is created and returned as the module (`local MyPanel = {}`).
2. A `create()` function builds and returns a Roblox `Frame` (or similar instance).
3. Inside `create()`, a fresh `scope` is created with `Fusion.scoped(Fusion)`.
4. Cleanup is tied to the instance's `Destroying` event.

```lua
-- src/client/UI/MyPanel.lua
local Fusion = require(Packages:WaitForChild("Fusion"))
local Knit = require(Packages:WaitForChild("Knit"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))
local Children = Fusion.Children

local MyPanel = {}

function MyPanel.create(isVisible: Fusion.Value<boolean>, onClose: () -> ())
    local scope = Fusion.scoped(Fusion)

    -- Reactive state
    local SomeData = scope:Value({})

    -- Animated visibility (standard pattern across all panels)
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

    local panel = scope:New("Frame")({
        Name = "MyPanel",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(0.92, 0, 0.85, 0),
        BackgroundColor3 = UITheme.Colors.DarkBackground,
        BackgroundTransparency = AnimatedTransparency,
        Visible = scope:Computed(function(use)
            return use(AnimatedTransparency) < 0.99
        end),
        ZIndex = 100,

        [Children] = {
            scope:New("UICorner")({ CornerRadius = UITheme.CornerRadius.Large }),
            scope:New("UIStroke")({
                Color = UITheme.Colors.StrokeLight,
                Thickness = UITheme.Stroke.Panel,
                Transparency = AnimatedTransparency,
            }),
            scope:New("UIScale")({ Scale = AnimatedScale }),
            -- ... header, content, footer
        },
    })

    -- Cleanup when the GUI instance is destroyed
    panel.Destroying:Connect(function()
        Fusion.doCleanup(scope)
    end)

    return panel
end

return MyPanel
```

Key points:
- `create()` receives `isVisible` (a `Value<boolean>`) and an `onClose` callback. The
  controller manages visibility; the panel just reacts to it.
- The `Visible` property uses `AnimatedTransparency < 0.99` so the instance only exists
  in the layout while it has any opacity. This prevents invisible panels from blocking input.
- `Fusion.doCleanup(scope)` is connected to `panel.Destroying`. This tears down every
  reactive object that was created through that scope.

## UITheme Design Tokens

Import `UITheme` from `src/client/UI/UITheme.lua`. Use its tokens instead of hardcoding
colors, fonts, or sizes. This keeps the visual language consistent.

### Colors
```lua
UITheme.Colors.DarkBackground    -- panel outer bg
UITheme.Colors.PanelBackground   -- header/footer bg
UITheme.Colors.Surface           -- item row bg
UITheme.Colors.SurfaceHover      -- item row hover
UITheme.Colors.SurfaceSelected   -- selected item

UITheme.Colors.ButtonCyan / ButtonCyanHover
UITheme.Colors.MoneyGreen / MoneyGreenHover
UITheme.Colors.CloseRed / CloseRedHover
UITheme.Colors.RobuxBlue / RobuxBlueHover
UITheme.Colors.Gold / GoldDark

UITheme.Colors.TextPrimary       -- main text
UITheme.Colors.TextMuted         -- secondary/hint text
UITheme.Colors.TextMoney         -- money amounts (green)
UITheme.Colors.Disabled          -- disabled buttons

UITheme.Colors.ToggleOn / ToggleOff / ToggleKnob
UITheme.Colors.HudButtonBg / HudButtonBgHover / HudButtonBorder
```

### Fonts, Corners, Strokes, Animations
```lua
UITheme.Fonts.PRIMARY             -- Enum.Font.FredokaOne (headings, buttons)
UITheme.Fonts.SECONDARY           -- Enum.Font.GothamBold (body text)

UITheme.CornerRadius.Small        -- UDim.new(0, 10)
UITheme.CornerRadius.Medium       -- UDim.new(0, 16)
UITheme.CornerRadius.Large        -- UDim.new(0, 24)
UITheme.CornerRadius.Pill         -- UDim.new(0.5, 0)
UITheme.CornerRadius.Circle       -- UDim.new(1, 0)

UITheme.Stroke.Panel              -- 3
UITheme.Stroke.Button             -- 3
UITheme.Stroke.Item               -- 2

UITheme.Animation.Instant         -- TweenInfo 0.1s Back
UITheme.Animation.Snappy          -- TweenInfo 0.25s Quad
UITheme.Animation.Bouncy          -- TweenInfo 0.5s Back Out
UITheme.Animation.Fade            -- TweenInfo 0.2s Quad
UITheme.Animation.Press           -- TweenInfo 0.1s Back
```

### Text Stroke Helper
For readable text over varied backgrounds, use `UITheme.addTextStroke`:
```lua
scope:New("TextLabel")({
    Text = "Hello",
    TextSize = 20,
    Font = UITheme.Fonts.PRIMARY,
    TextColor3 = UITheme.Colors.TextPrimary,
    [Children] = {
        UITheme.addTextStroke(scope, 20),  -- pass textSize for proper thickness
    },
})
```

## Reactive Primitives

### Value (mutable state)
```lua
local IsHovering = scope:Value(false)
IsHovering:set(true)                   -- update
local current = Fusion.peek(IsHovering) -- read without subscribing
```

### Computed (derived state)
```lua
local BgColor = scope:Computed(function(use)
    return if use(IsHovering)
        then UITheme.Colors.SurfaceHover
        else UITheme.Colors.Surface
end)
```
Use `use()` to subscribe to dependencies. The function re-runs when any dependency changes.

### Tween (animated transitions)
```lua
local AnimatedBgColor = scope:Tween(BgColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad))
```
Tweens interpolate between old and new values over time. Use them for colors, sizes,
positions, and transparency to make the UI feel polished.

### ForValues (dynamic lists)
Render a list of items from a reactive table. Fusion handles additions, removals, and
reordering automatically.
```lua
scope:ForValues(ItemList, function(use, itemScope, itemData)
    return createListItem(itemData, scope)
end)
```

### ForPairs (keyed dynamic lists)
Like `ForValues` but gives you access to both key and value:
```lua
scope:ForPairs(DataTable, function(use, itemScope, key, value)
    return key, createItemRow(value, scope)
end)
```

### Observer (side effects on change)
Used in UIController to fire side effects (e.g., telemetry) when state changes:
```lua
Fusion.Observer(scope, IsPanelOpen):onChange(function()
    local isOpen = Fusion.peek(IsPanelOpen)
    TelemetryHelper.Track(isOpen and "ui_panel_opened" or "ui_panel_closed")
end)
```

## Event Binding

Bind to Roblox instance events with `Fusion.OnEvent`:
```lua
[Fusion.OnEvent("MouseEnter")] = function()
    IsHovering:set(true)
end,
[Fusion.OnEvent("MouseLeave")] = function()
    IsHovering:set(false)
end,
[Fusion.OnEvent("MouseButton1Click")] = function()
    -- guard against repeat clicks or invalid state
    if Fusion.peek(IsPurchasing) or not Fusion.peek(CanAfford) then
        return
    end
    IsPurchasing:set(true)
    onPurchase(itemId)
    task.delay(0.5, function()
        IsPurchasing:set(false)
    end)
end,
```

For property changes, use `Fusion.OnChange`:
```lua
[Fusion.OnChange("AbsoluteSize")] = function(newSize)
    -- respond to size changes
end,
```

## Common UI Patterns

### Hover Effect on Buttons and Items
Every interactive element follows this pattern: a `Value<boolean>` for hover state,
a `Computed` for the target color, and a `Tween` to animate it.

```lua
local IsHovering = scope:Value(false)
local BgColor = scope:Computed(function(use)
    return if use(IsHovering)
        then UITheme.Colors.SurfaceHover
        else UITheme.Colors.Surface
end)

scope:New("Frame")({
    BackgroundColor3 = scope:Tween(BgColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
    -- ...
    [Children] = {
        -- Transparent overlay frame to catch mouse events
        scope:New("Frame")({
            Name = "HoverDetector",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            ZIndex = 0,
            [Fusion.OnEvent("MouseEnter")] = function() IsHovering:set(true) end,
            [Fusion.OnEvent("MouseLeave")] = function() IsHovering:set(false) end,
        }),
    },
})
```

### Toggle Switch (from SettingsPanel)
A toggle has a sliding knob whose position is tweened:
```lua
local ToggleBgColor = scope:Computed(function(use)
    return if use(currentValue) then UITheme.Colors.ToggleOn else UITheme.Colors.ToggleOff
end)
local KnobPosition = scope:Computed(function(use)
    return if use(currentValue)
        then UDim2.new(1, -22, 0.5, 0)
        else UDim2.new(0, 4, 0.5, 0)
end)

scope:New("TextButton")({
    Size = UDim2.new(0, 48, 0, 26),
    BackgroundColor3 = scope:Tween(ToggleBgColor, TweenInfo.new(0.2, Enum.EasingStyle.Quad)),
    Text = "",
    AutoButtonColor = false,
    [Fusion.OnEvent("MouseButton1Click")] = function()
        local newValue = not Fusion.peek(currentValue)
        onToggle(settingId, newValue)
    end,
    [Children] = {
        scope:New("UICorner")({ CornerRadius = UDim.new(1, 0) }),
        scope:New("Frame")({
            Name = "Knob",
            AnchorPoint = Vector2.new(0, 0.5),
            Position = scope:Tween(KnobPosition, TweenInfo.new(0.2, Enum.EasingStyle.Quad)),
            Size = UDim2.new(0, 18, 0, 18),
            BackgroundColor3 = UITheme.Colors.ToggleKnob,
            [Children] = {
                scope:New("UICorner")({ CornerRadius = UDim.new(1, 0) }),
            },
        }),
    },
})
```

### Panel Header with Close Button
Every panel has a consistent header structure:
```lua
scope:New("Frame")({
    Name = "Header",
    Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
    BackgroundColor3 = UITheme.Colors.PanelBackground,
    BackgroundTransparency = AnimatedTransparency,
    [Children] = {
        scope:New("UICorner")({ CornerRadius = UITheme.CornerRadius.Large }),
        -- Cover bottom corners so the header melds into the content area
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
            Position = UDim2.new(0, 16, 0.5, 0),
            AnchorPoint = Vector2.new(0, 0.5),
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 20,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = "PANEL TITLE",
            [Children] = { UITheme.addTextStroke(scope, 20) },
        }),
        -- Close button (top-right, red pill)
        scope:New("TextButton")({
            Position = UDim2.new(1, -4, 0, 4),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.new(0, 40, 0, 40),
            ZIndex = 10,
            BackgroundColor3 = scope:Tween(CloseButtonColor, TweenInfo.new(0.1)),
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 22,
            Text = "X",
            AutoButtonColor = false,
            [Fusion.OnEvent("MouseEnter")] = function() IsCloseHovering:set(true) end,
            [Fusion.OnEvent("MouseLeave")] = function() IsCloseHovering:set(false) end,
            [Fusion.OnEvent("MouseButton1Click")] = function() onClose() end,
            [Children] = {
                scope:New("UICorner")({ CornerRadius = UITheme.CornerRadius.Pill }),
                UITheme.addTextStroke(scope, 22),
            },
        }),
    },
})
```

### Scrolling List Content
Panels with variable-length content use `ScrollingFrame` with automatic canvas sizing:
```lua
scope:New("ScrollingFrame")({
    Position = UDim2.new(0, 0, 0, HEADER_HEIGHT),
    Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT - FOOTER_HEIGHT),
    BackgroundTransparency = 1,
    ScrollBarThickness = 6,
    ScrollBarImageColor3 = Color3.fromRGB(100, 100, 120),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    [Children] = {
        scope:New("UIPadding")({ PaddingLeft = UDim.new(0, 12), ... }),
        scope:New("UIListLayout")({ Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
        -- dynamic children via ForValues
        scope:ForValues(DataList, function(use, itemScope, item)
            return createItem(item, scope)
        end),
    },
})
```

### Conditional Rendering
Return `nil` from a `Computed` to hide elements:
```lua
scope:Computed(function(use)
    if use(IsLoading) then
        return scope:New("TextLabel")({ Text = "Loading..." })
    else
        return nil
    end
end),
```

## Connecting to Knit Services

Panels load data from server services via Knit. The connection is initialized in a
`task.spawn` block inside `create()`:

```lua
local DataService = nil

task.spawn(function()
    DataService = Knit.GetService("DataService")

    -- Listen for real-time updates
    DataService.DataChanged:Connect(function(field, value)
        if field == "money" then
            PlayerMoney:set(value)
        end
    end)

    -- Initial data load
    DataService:GetData()
        :andThen(function(data)
            SomeState:set(data.someField or {})
            IsLoading:set(false)
        end)
        :catch(function(err)
            warn("[MyPanel] Failed to load:", err)
            IsLoading:set(false)
        end)
end)
```

The `task.spawn` wrapper prevents blocking the UI constructor. Data flows through
Fusion `Value` objects, so the UI updates automatically when service signals fire.

## UIController Integration

`UIController.lua` is the Knit controller that owns the ScreenGui and coordinates all
panels. It:

1. Creates a long-lived `scope` at module level for HUD elements (money display, height
   indicator) that persist for the session.
2. Holds `Value<boolean>` objects for each panel's visibility (`IsShopOpen`, etc.).
3. Calls `Panel.create(isVisible, onClose)` and parents the result to the ScreenGui.
4. Uses `Fusion.Observer` on visibility values to fire telemetry events.

When adding a new panel:
1. Create the panel module in `src/client/UI/MyPanel.lua`.
2. In UIController, add a visibility value: `local IsMyPanelOpen = scope:Value(false)`.
3. Create the panel: `local myPanel = MyPanel.create(IsMyPanelOpen, function() IsMyPanelOpen:set(false) end)`.
4. Parent it: `myPanel.Parent = ScreenGui`.
5. Wire up a button or event to toggle: `IsMyPanelOpen:set(true)`.

## HUD Buttons (Small Components)

Smaller HUD components follow the same scope pattern but are simpler. They receive a
callback and return a small Frame:

```lua
function HudButton.create(onClick)
    local scope = Fusion.scoped(Fusion)
    local IsHovering = scope:Value(false)

    local BgColor = scope:Computed(function(use)
        return if use(IsHovering)
            then UITheme.Colors.HudButtonBgHover
            else UITheme.Colors.HudButtonBg
    end)

    local button = scope:New("Frame")({
        -- ... layout, icon, label
        [Children] = {
            scope:New("ImageButton")({
                BackgroundColor3 = scope:Tween(BgColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
                [Fusion.OnEvent("MouseButton1Click")] = function()
                    if onClick then onClick() end
                end,
                -- ...
            }),
        },
    })

    button.Destroying:Connect(function()
        Fusion.doCleanup(scope)
    end)

    return button
end
```

## Responsive / Mobile Layout

Some components check `UserInputService.TouchEnabled` at creation time to adjust sizes:
```lua
local isMobile = UserInputService.TouchEnabled
local ICON_SIZE = if isMobile then 36 else 50
```

Panels that need to fit on phone screens use fractional sizing with `UISizeConstraint`:
```lua
Size = UDim2.new(0.92, 0, 0.85, 0),  -- 92% width, 85% height
[Children] = {
    scope:New("UISizeConstraint")({
        MaxSize = Vector2.new(380, 600),
        MinSize = Vector2.new(220, 300),
    }),
}
```

## Cleanup Lifecycle

The cleanup rule is simple: connect `Fusion.doCleanup(scope)` to the root instance's
`Destroying` event. This tears down all Values, Computeds, Tweens, and child instances
created through that scope.

```lua
panel.Destroying:Connect(function()
    Fusion.doCleanup(scope)
end)
```

If you also have non-Fusion connections (like `RunService.Heartbeat`), disconnect them
in the same callback or track them for cleanup separately.

## Checklist for New UI Components

- [ ] Create module in `src/client/UI/`
- [ ] Use `Fusion.scoped(Fusion)` for a fresh scope in `create()`
- [ ] Use `UITheme` tokens for all colors, fonts, corners, and animations
- [ ] Add `UITheme.addTextStroke(scope, textSize)` to labels for readability
- [ ] Implement hover states with `Value<boolean>` + `Computed` + `Tween`
- [ ] Connect `Fusion.doCleanup(scope)` to `panel.Destroying`
- [ ] Wire up to UIController with a visibility `Value<boolean>` and an `onClose` callback
- [ ] Use `AutoButtonColor = false` on buttons (hover is handled manually)
- [ ] For scrollable content, use `AutomaticCanvasSize = Enum.AutomaticSize.Y`
- [ ] Use `Fusion.peek()` in event handlers (not `use()`, which is only for Computed)
