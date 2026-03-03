--[[
  EventController.lua
  Client-side controller for world event awareness and announcement banners.

  Listens for EventService signals (EventStarted, EventEnded), shows a
  top-center announcement banner with fade-in/out animation and audio cue,
  and provides public API + local signals for other controllers (minimap, HUD).

  Banner follows the DayNightBannerController pattern: Instance.new + TweenService.

  Depends on: EventService (Knit service), SoundController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local UITheme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UITheme"))

local EventController = Knit.CreateController({
  Name = "EventController",
})

-- Local signals for UI components (minimap, HUD, etc.)
EventController.EventStarted = Signal.new() -- (eventType, position, duration)
EventController.EventEnded = Signal.new() -- (eventType)

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local LocalPlayer = Players.LocalPlayer

local FADE_IN_TIME = 0.7
local FADE_OUT_TIME = 0.9

-- Banner config per event type
local BANNER_CONFIG = {
  shipwreck = {
    title = "SHIPWRECK SPOTTED!",
    subtitle = "A wrecked ship full of treasure has appeared!",
    color = Color3.fromRGB(255, 200, 50), -- gold
    glowColor = Color3.fromRGB(200, 150, 20),
    icon = "\u{2693}", -- anchor emoji fallback
  },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local EventService = nil
local SoundController = nil
local ScreenGui: ScreenGui? = nil
local ActiveBanner: Frame? = nil
local ActiveTweens: { Tween } = {}

-- Cached active event state
local ActiveEventType: string? = nil
local ActiveEventPosition: Vector3? = nil

--------------------------------------------------------------------------------
-- BANNER HELPERS
--------------------------------------------------------------------------------

--[[
  Cancels all active banner tweens.
]]
local function cancelActiveTweens()
  for _, tween in ipairs(ActiveTweens) do
    tween:Cancel()
  end
  table.clear(ActiveTweens)
end

--[[
  Creates and plays a tween, tracking it for cancellation.
]]
local function trackTween(
  instance: Instance,
  tweenInfo: TweenInfo,
  properties: { [string]: any }
): Tween
  local tween = TweenService:Create(instance, tweenInfo, properties)
  table.insert(ActiveTweens, tween)
  tween:Play()
  return tween
end

--[[
  Removes the active banner if one exists.
]]
local function clearBanner()
  cancelActiveTweens()
  if ActiveBanner then
    ActiveBanner:Destroy()
    ActiveBanner = nil
  end
end

--[[
  Shows the event announcement banner at top-center.
  @param eventType string The event type key
]]
local function showEventBanner(eventType: string)
  local config = BANNER_CONFIG[eventType]
  if not config then
    return
  end
  if not ScreenGui then
    return
  end

  -- Clear any existing banner
  clearBanner()

  local bannerDuration = GameConfig.ShipwreckEvent.bannerDuration

  -- Container frame (centered at top, wider than day/night banner)
  local banner = Instance.new("Frame")
  banner.Name = "EventBanner"
  banner.Size = UDim2.new(0, 480, 0, 80)
  banner.Position = UDim2.new(0.5, 0, 0, 60)
  banner.AnchorPoint = Vector2.new(0.5, 0)
  banner.BackgroundColor3 = UITheme.Colors.DarkBackground
  banner.BackgroundTransparency = 1 -- start fully transparent
  banner.BorderSizePixel = 0

  local corner = Instance.new("UICorner")
  corner.CornerRadius = UITheme.CornerRadius.Large
  corner.Parent = banner

  local stroke = Instance.new("UIStroke")
  stroke.Color = config.color
  stroke.Thickness = 2.5
  stroke.Transparency = 1 -- start hidden
  stroke.Parent = banner

  -- Gradient background for atmospheric feel
  local gradient = Instance.new("UIGradient")
  gradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 0, 0)),
    ColorSequenceKeypoint.new(0.3, config.glowColor),
    ColorSequenceKeypoint.new(0.7, config.glowColor),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
  })
  gradient.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.95),
    NumberSequenceKeypoint.new(0.3, 0.65),
    NumberSequenceKeypoint.new(0.7, 0.65),
    NumberSequenceKeypoint.new(1, 0.95),
  })
  gradient.Parent = banner

  -- Title text (big, bold)
  local titleLabel = Instance.new("TextLabel")
  titleLabel.Name = "TitleText"
  titleLabel.Size = UDim2.new(1, -24, 0, 36)
  titleLabel.Position = UDim2.new(0, 12, 0, 8)
  titleLabel.BackgroundTransparency = 1
  titleLabel.Font = UITheme.Fonts.PRIMARY
  titleLabel.TextColor3 = config.color
  titleLabel.TextTransparency = 1 -- start hidden
  titleLabel.TextSize = 28
  titleLabel.Text = config.title
  titleLabel.TextXAlignment = Enum.TextXAlignment.Center
  titleLabel.TextYAlignment = Enum.TextYAlignment.Center
  titleLabel.Parent = banner

  local titleStroke = Instance.new("UIStroke")
  titleStroke.Color = Color3.fromRGB(0, 0, 0)
  titleStroke.Thickness = UITheme.getTextStrokeThickness(28)
  titleStroke.Transparency = 1 -- start hidden
  titleStroke.Parent = titleLabel

  -- Subtitle text (smaller, muted)
  local subtitleLabel = Instance.new("TextLabel")
  subtitleLabel.Name = "SubtitleText"
  subtitleLabel.Size = UDim2.new(1, -24, 0, 24)
  subtitleLabel.Position = UDim2.new(0, 12, 0, 44)
  subtitleLabel.BackgroundTransparency = 1
  subtitleLabel.Font = UITheme.Fonts.SECONDARY
  subtitleLabel.TextColor3 = UITheme.Colors.TextPrimary
  subtitleLabel.TextTransparency = 1 -- start hidden
  subtitleLabel.TextSize = 16
  subtitleLabel.Text = config.subtitle
  subtitleLabel.TextXAlignment = Enum.TextXAlignment.Center
  subtitleLabel.TextYAlignment = Enum.TextYAlignment.Center
  subtitleLabel.Parent = banner

  local subtitleStroke = Instance.new("UIStroke")
  subtitleStroke.Color = Color3.fromRGB(0, 0, 0)
  subtitleStroke.Thickness = UITheme.getTextStrokeThickness(16)
  subtitleStroke.Transparency = 1 -- start hidden
  subtitleStroke.Parent = subtitleLabel

  banner.Parent = ScreenGui
  ActiveBanner = banner

  -- Fade in
  local fadeInInfo = TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

  trackTween(banner, fadeInInfo, { BackgroundTransparency = 0.15 })
  trackTween(stroke, fadeInInfo, { Transparency = 0.2 })
  trackTween(titleLabel, fadeInInfo, { TextTransparency = 0 })
  trackTween(titleStroke, fadeInInfo, { Transparency = 0.1 })
  trackTween(subtitleLabel, fadeInInfo, { TextTransparency = 0.1 })
  trackTween(subtitleStroke, fadeInInfo, { Transparency = 0.2 })

  -- Scale-in effect
  local scale = Instance.new("UIScale")
  scale.Scale = 0.85
  scale.Parent = banner
  trackTween(
    scale,
    TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
    { Scale = 1 }
  )

  -- Schedule fade out
  task.delay(bannerDuration, function()
    if banner.Parent == nil then
      return
    end

    local fadeOutInfo = TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    local bgFade = TweenService:Create(banner, fadeOutInfo, { BackgroundTransparency = 1 })
    local strokeFade = TweenService:Create(stroke, fadeOutInfo, { Transparency = 1 })
    local titleFade = TweenService:Create(titleLabel, fadeOutInfo, { TextTransparency = 1 })
    local titleStrokeFade = TweenService:Create(titleStroke, fadeOutInfo, { Transparency = 1 })
    local subFade = TweenService:Create(subtitleLabel, fadeOutInfo, { TextTransparency = 1 })
    local subStrokeFade = TweenService:Create(subtitleStroke, fadeOutInfo, { Transparency = 1 })
    local scaleOut = TweenService:Create(
      scale,
      TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
      { Scale = 1.05 }
    )

    bgFade:Play()
    strokeFade:Play()
    titleFade:Play()
    titleStrokeFade:Play()
    subFade:Play()
    subStrokeFade:Play()
    scaleOut:Play()

    bgFade.Completed:Connect(function()
      if banner.Parent then
        banner:Destroy()
      end
      if ActiveBanner == banner then
        ActiveBanner = nil
      end
    end)
  end)
end

--------------------------------------------------------------------------------
-- EVENT HANDLERS
--------------------------------------------------------------------------------

--[[
  Handles a new world event starting.
  @param eventType string
  @param position Vector3
  @param duration number
]]
local function onEventStarted(eventType: string, position: Vector3, duration: number)
  ActiveEventType = eventType
  ActiveEventPosition = position

  -- Show announcement banner
  showEventBanner(eventType)

  -- Play announcement sound (reuse dusk horn — dramatic, attention-grabbing)
  if SoundController then
    SoundController:PlayEventAnnouncementSound()
  end

  -- Fire local signal
  EventController.EventStarted:Fire(eventType, position, duration)

  print(
    string.format(
      "[EventController] Event started: %s at (%.0f, %.0f, %.0f)",
      eventType,
      position.X,
      position.Y,
      position.Z
    )
  )
end

--[[
  Handles a world event ending.
  @param eventType string
]]
local function onEventEnded(eventType: string)
  ActiveEventType = nil
  ActiveEventPosition = nil

  -- Fire local signal
  EventController.EventEnded:Fire(eventType)

  print(string.format("[EventController] Event ended: %s", eventType))
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns whether a world event is currently active.
  @return boolean
]]
function EventController:IsEventActive(): boolean
  return ActiveEventType ~= nil
end

--[[
  Returns the current active event type, or nil.
  @return string?
]]
function EventController:GetActiveEventType(): string?
  return ActiveEventType
end

--[[
  Returns the position of the active event, or nil.
  @return Vector3?
]]
function EventController:GetActiveEventPosition(): Vector3?
  return ActiveEventPosition
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function EventController:KnitInit()
  -- Create ScreenGui for event banners
  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "EventBannerGui"
  ScreenGui.ResetOnSpawn = false
  ScreenGui.DisplayOrder = 105 -- above day/night banners (100)
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[EventController] Initialized")
end

function EventController:KnitStart()
  EventService = Knit.GetService("EventService")
  SoundController = Knit.GetController("SoundController")

  -- Listen for event signals from server
  EventService.EventStarted:Connect(function(eventType: string, position: Vector3, duration: number)
    onEventStarted(eventType, position, duration)
  end)

  EventService.EventEnded:Connect(function(eventType: string)
    onEventEnded(eventType)
  end)

  -- Late-join sync: check if an event is already active
  EventService:GetActiveEvent()
    :andThen(function(eventInfo)
      if
        eventInfo
        and type(eventInfo.eventType) == "string"
        and type(eventInfo.position) == "table"
        and #eventInfo.position == 3
      then
        local pos = Vector3.new(eventInfo.position[1], eventInfo.position[2], eventInfo.position[3])
        onEventStarted(eventInfo.eventType, pos, eventInfo.remainingTime or 0)
      end
    end)
    :catch(function(err)
      warn("[EventController] Failed to get active event:", err)
    end)

  print("[EventController] Started")
end

return EventController
