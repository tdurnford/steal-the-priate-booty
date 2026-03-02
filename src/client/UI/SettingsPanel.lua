--[[
	SettingsPanel.lua
	Settings UI Panel for player preferences.
	Displays toggles for music, SFX, and other player visibility.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Fusion = require(Packages:WaitForChild("Fusion"))
local Knit = require(Packages:WaitForChild("Knit"))
local UITheme = require(script.Parent:WaitForChild("UITheme"))

-- Fusion imports
local Children = Fusion.Children

-- Create module-level scope removed; scope is created per-call in create()

local SettingsPanel = {}

-- Constants
local PANEL_WIDTH = 320
local TOGGLE_HEIGHT = 50
local HEADER_HEIGHT = 50
local FOOTER_HEIGHT = 50

-- Settings definitions
local SETTINGS_CONFIG = {
  {
    id = "musicEnabled",
    name = "🎵 Music",
    description = "Toggle background music",
  },
  {
    id = "sfxEnabled",
    name = "🔊 Sound Effects",
    description = "Toggle game sound effects",
  },
  {
    id = "showOtherPlayers",
    name = "👥 Show Players",
    description = "Show other players in the game",
  },
}

--[[
	Creates a toggle switch component.
	@param settingId The setting identifier
	@param config Setting configuration (name, description)
	@param currentValue Fusion Value for the current setting value
	@param onToggle Callback when toggle is clicked
	@return Fusion component
]]
local function createToggleRow(
  settingId: string,
  config: { name: string, description: string },
  currentValue: Fusion.Value<boolean>,
  onToggle: (string, boolean) -> (),
  scope
)
  local IsHovering = scope:Value(false)
  local IsToggling = scope:Value(false)

  local RowBgColor = scope:Computed(function(use)
    return if use(IsHovering) then UITheme.Colors.SurfaceHover else UITheme.Colors.Surface
  end)

  local ToggleBgColor = scope:Computed(function(use)
    return if use(currentValue) then UITheme.Colors.ToggleOn else UITheme.Colors.ToggleOff
  end)

  local KnobPosition = scope:Computed(function(use)
    return if use(currentValue) then UDim2.new(1, -22, 0.5, 0) else UDim2.new(0, 4, 0.5, 0)
  end)

  return scope:New("Frame")({
    Name = "Toggle_" .. settingId,
    Size = UDim2.new(1, 0, 0, TOGGLE_HEIGHT),
    BackgroundColor3 = scope:Tween(RowBgColor, TweenInfo.new(0.15, Enum.EasingStyle.Quad)),
    BorderSizePixel = 0,

    [Children] = {
      scope:New("UICorner")({
        CornerRadius = UITheme.CornerRadius.Small,
      }),

      scope:New("UIPadding")({
        PaddingLeft = UDim.new(0, 12),
        PaddingRight = UDim.new(0, 12),
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
      }),

      -- Left side: Name and description
      scope:New("Frame")({
        Name = "LabelSection",
        Size = UDim2.new(1, -60, 1, 0),
        BackgroundTransparency = 1,

        [Children] = {
          scope:New("TextLabel")({
            Name = "Name",
            Size = UDim2.new(1, 0, 0, 18),
            Position = UDim2.new(0, 0, 0, 0),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.name,
          }),

          scope:New("TextLabel")({
            Name = "Description",
            Size = UDim2.new(1, 0, 0, 14),
            Position = UDim2.new(0, 0, 0, 18),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextMuted,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.description,
          }),
        },
      }),

      -- Right side: Toggle switch
      scope:New("TextButton")({
        Name = "ToggleButton",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.new(0, 48, 0, 26),
        BackgroundColor3 = scope:Tween(ToggleBgColor, TweenInfo.new(0.2, Enum.EasingStyle.Quad)),
        AutoButtonColor = false,
        Text = "",

        [Fusion.OnEvent("MouseButton1Click")] = function()
          if Fusion.peek(IsToggling) then
            return
          end

          IsToggling:set(true)
          local newValue = not Fusion.peek(currentValue)
          onToggle(settingId, newValue)

          -- Reset toggling state after a short delay
          task.delay(0.3, function()
            IsToggling:set(false)
          end)
        end,

        [Children] = {
          scope:New("UICorner")({
            CornerRadius = UDim.new(1, 0),
          }),

          -- Toggle knob
          scope:New("Frame")({
            Name = "Knob",
            AnchorPoint = Vector2.new(0, 0.5),
            Position = scope:Tween(KnobPosition, TweenInfo.new(0.2, Enum.EasingStyle.Quad)),
            Size = UDim2.new(0, 18, 0, 18),
            BackgroundColor3 = UITheme.Colors.ToggleKnob,

            [Children] = {
              scope:New("UICorner")({
                CornerRadius = UDim.new(1, 0),
              }),
            },
          }),
        },
      }),

      -- Hover detection
      scope:New("Frame")({
        Name = "HoverDetector",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        ZIndex = 0,

        [Fusion.OnEvent("MouseEnter")] = function()
          IsHovering:set(true)
        end,

        [Fusion.OnEvent("MouseLeave")] = function()
          IsHovering:set(false)
        end,
      }),
    },
  })
end

--[[
	Creates the main settings panel.
	@param isVisible Fusion Value controlling visibility
	@param onClose Callback when close button clicked
	@return Fusion component
]]
function SettingsPanel.create(isVisible: Fusion.Value<boolean>, onClose: () -> ())
  local scope = Fusion.scoped(Fusion)

  -- State for each setting
  local SettingsState = {
    musicEnabled = scope:Value(true),
    sfxEnabled = scope:Value(true),
    showOtherPlayers = scope:Value(true),
  }

  -- Services
  local DataService = nil

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

  -- Load settings from data
  local function loadSettings(data)
    if data and data.settings then
      if data.settings.musicEnabled ~= nil then
        SettingsState.musicEnabled:set(data.settings.musicEnabled)
      end
      if data.settings.sfxEnabled ~= nil then
        SettingsState.sfxEnabled:set(data.settings.sfxEnabled)
      end
      if data.settings.showOtherPlayers ~= nil then
        SettingsState.showOtherPlayers:set(data.settings.showOtherPlayers)
      end
    end
  end

  -- Toggle handler
  local function handleToggle(settingId: string, newValue: boolean)
    -- Update local state immediately for responsiveness
    if SettingsState[settingId] then
      SettingsState[settingId]:set(newValue)
    end

    -- Update on server
    if DataService then
      DataService:UpdateSetting(settingId, newValue)
        :andThen(function(success)
          if not success then
            -- Revert local state if server update failed
            SettingsState[settingId]:set(not newValue)
            warn("[SettingsPanel] Failed to update setting:", settingId)
          end
        end)
        :catch(function(err)
          -- Revert local state on error
          SettingsState[settingId]:set(not newValue)
          warn("[SettingsPanel] Error updating setting:", err)
        end)
    end
  end

  -- Initialize services when Knit is ready
  task.spawn(function()
    DataService = Knit.GetService("DataService")

    -- Listen for data changes
    DataService.DataChanged:Connect(function(field, value)
      if field == "settings" and type(value) == "table" then
        loadSettings({ settings = value })
      end
    end)

    -- Load initial settings
    DataService:GetData()
      :andThen(function(data)
        loadSettings(data)
      end)
      :catch(function(err)
        warn("[SettingsPanel] Failed to load settings:", err)
      end)
  end)

  -- Calculate panel height
  local contentHeight = #SETTINGS_CONFIG * (TOGGLE_HEIGHT + 8) -- toggles + spacing
  local panelHeight = HEADER_HEIGHT + contentHeight + FOOTER_HEIGHT

  -- Close button hover state
  local IsCloseHovering = scope:Value(false)
  local CloseButtonColor = scope:Computed(function(use)
    return if use(IsCloseHovering) then UITheme.Colors.CloseRedHover else UITheme.Colors.CloseRed
  end)

  local panel = scope:New("Frame")({
    Name = "SettingsPanel",
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
            Size = UDim2.new(0.7, 0, 0, 24),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextPrimary,
            TextSize = 20,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTransparency = AnimatedTransparency,
            Text = "⚙️ SETTINGS",

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

      -- Content area with toggles
      scope:New("Frame")({
        Name = "Content",
        Position = UDim2.new(0, 0, 0, HEADER_HEIGHT),
        Size = UDim2.new(1, 0, 0, contentHeight),
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
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
          }),

          -- Generate toggle rows
          createToggleRow(
            SETTINGS_CONFIG[1].id,
            SETTINGS_CONFIG[1],
            SettingsState.musicEnabled,
            handleToggle,
            scope
          ),
          createToggleRow(
            SETTINGS_CONFIG[2].id,
            SETTINGS_CONFIG[2],
            SettingsState.sfxEnabled,
            handleToggle,
            scope
          ),
          createToggleRow(
            SETTINGS_CONFIG[3].id,
            SETTINGS_CONFIG[3],
            SettingsState.showOtherPlayers,
            handleToggle,
            scope
          ),
        },
      }),

      -- Footer
      scope:New("Frame")({
        Name = "Footer",
        Position = UDim2.new(0, 0, 1, -FOOTER_HEIGHT),
        Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,

        [Children] = {
          scope:New("TextLabel")({
            Name = "Tip",
            Position = UDim2.new(0.5, 0, 0.5, 0),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Size = UDim2.new(1, -24, 0, 20),
            BackgroundTransparency = 1,
            Font = UITheme.Fonts.PRIMARY,
            TextColor3 = UITheme.Colors.TextMuted,
            TextSize = 11,
            TextTransparency = scope:Computed(function(use)
              return 0.3 + use(AnimatedTransparency) * 0.7
            end),
            Text = "💡 Settings are saved automatically",
          }),
        },
      }),
    },
  })

  panel.Destroying:Connect(function()
    Fusion.doCleanup(scope)
  end)

  return panel
end

return SettingsPanel
