--[[
  EventController.lua
  Client-side controller for world event awareness and announcement banners.

  Listens for EventService signals (EventStarted, EventEnded), shows a
  top-center announcement banner with fade-in/out animation and audio cue,
  and provides public API + local signals for other controllers (minimap, HUD).

  For loot surge events, creates a glowing zone highlight in the world that
  marks the active surge area (visible to all players).

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
  },
  loot_surge = {
    title = "LOOT SURGE!",
    subtitle = "A zone is overflowing with treasure — 3x spawns, 2x yield!",
    color = Color3.fromRGB(50, 255, 120), -- bright green
    glowColor = Color3.fromRGB(20, 180, 60),
  },
}

-- Zone highlight colors for loot surge
local SURGE_HIGHLIGHT_COLOR = Color3.fromRGB(50, 255, 120)
local SURGE_BEACON_COLOR = Color3.fromRGB(100, 255, 150)

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

-- Loot surge zone highlight
local SurgeHighlightModel: Model? = nil

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

  -- Use event-specific banner duration, falling back to shipwreck default
  local bannerDuration
  if eventType == "loot_surge" then
    bannerDuration = GameConfig.LootSurgeEvent.bannerDuration
  else
    bannerDuration = GameConfig.ShipwreckEvent.bannerDuration
  end

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
-- SURGE ZONE HIGHLIGHT
--------------------------------------------------------------------------------

--[[
  Removes the surge zone highlight model.
]]
local function clearSurgeHighlight()
  if SurgeHighlightModel and SurgeHighlightModel.Parent then
    SurgeHighlightModel:Destroy()
  end
  SurgeHighlightModel = nil
end

--[[
  Creates a glowing zone highlight for the loot surge event.
  The highlight is a semi-transparent cylinder/boundary with particles
  and a beacon visible from afar.
  @param position Vector3 Center of the zone
  @param zoneSize Vector3 Size of the zone Part
]]
local function createSurgeHighlight(position: Vector3, zoneSize: Vector3)
  clearSurgeHighlight()

  local model = Instance.new("Model")
  model.Name = "LootSurgeHighlight"

  -- Ground boundary ring: a flat cylinder marking the zone edge
  local boundary = Instance.new("Part")
  boundary.Name = "Boundary"
  boundary.Shape = Enum.PartType.Cylinder
  -- Cylinder is oriented along X axis, so we rotate it to be flat
  boundary.Size = Vector3.new(1, math.max(zoneSize.X, zoneSize.Z), math.max(zoneSize.X, zoneSize.Z))
  boundary.CFrame = CFrame.new(position + Vector3.new(0, 0.5, 0))
    * CFrame.Angles(0, 0, math.rad(90))
  boundary.Anchored = true
  boundary.CanCollide = false
  boundary.CanQuery = false
  boundary.CanTouch = false
  boundary.Material = Enum.Material.Neon
  boundary.Color = SURGE_HIGHLIGHT_COLOR
  boundary.Transparency = 0.85
  boundary.CastShadow = false
  boundary.Parent = model

  -- Gold particle emitter on the boundary
  local particles = Instance.new("ParticleEmitter")
  particles.Color = ColorSequence.new(SURGE_HIGHLIGHT_COLOR, SURGE_BEACON_COLOR)
  particles.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.5),
    NumberSequenceKeypoint.new(0.5, 1.5),
    NumberSequenceKeypoint.new(1, 0),
  })
  particles.Lifetime = NumberRange.new(2, 4)
  particles.Rate = 15
  particles.Speed = NumberRange.new(2, 5)
  particles.SpreadAngle = Vector2.new(180, 180)
  particles.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(0.5, 0.5),
    NumberSequenceKeypoint.new(1, 1),
  })
  particles.Parent = boundary

  -- Beacon column (vertical glow visible from afar)
  local beacon = Instance.new("Part")
  beacon.Name = "Beacon"
  beacon.Shape = Enum.PartType.Cylinder
  beacon.Size = Vector3.new(200, 4, 4) -- tall narrow column
  beacon.CFrame = CFrame.new(position + Vector3.new(0, 100, 0)) * CFrame.Angles(0, 0, math.rad(90))
  beacon.Anchored = true
  beacon.CanCollide = false
  beacon.CanQuery = false
  beacon.CanTouch = false
  beacon.Material = Enum.Material.Neon
  beacon.Color = SURGE_HIGHLIGHT_COLOR
  beacon.Transparency = 0.7
  beacon.CastShadow = false
  beacon.Parent = model

  local beaconLight = Instance.new("PointLight")
  beaconLight.Color = SURGE_HIGHLIGHT_COLOR
  beaconLight.Brightness = 2
  beaconLight.Range = 80
  beaconLight.Parent = beacon

  -- Billboard label visible from distance
  local billboard = Instance.new("BillboardGui")
  billboard.Name = "SurgeLabel"
  billboard.Size = UDim2.new(0, 250, 0, 50)
  billboard.StudsOffset = Vector3.new(0, 25, 0)
  billboard.AlwaysOnTop = true
  billboard.MaxDistance = 500
  billboard.Parent = boundary

  local label = Instance.new("TextLabel")
  label.Name = "Label"
  label.Size = UDim2.new(1, 0, 1, 0)
  label.BackgroundTransparency = 1
  label.Text = "LOOT SURGE"
  label.TextColor3 = SURGE_HIGHLIGHT_COLOR
  label.Font = Enum.Font.FredokaOne
  label.TextSize = 24
  label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
  label.TextStrokeTransparency = 0.2
  label.Parent = billboard

  model.Parent = workspace

  SurgeHighlightModel = model
end

--------------------------------------------------------------------------------
-- EVENT HANDLERS
--------------------------------------------------------------------------------

--[[
  Handles a new world event starting.
  @param eventType string
  @param position Vector3
  @param duration number
  @param zoneSize Vector3? (only for loot_surge)
]]
local function onEventStarted(
  eventType: string,
  position: Vector3,
  duration: number,
  zoneSize: Vector3?
)
  ActiveEventType = eventType
  ActiveEventPosition = position

  -- Show announcement banner
  showEventBanner(eventType)

  -- Play announcement sound
  if SoundController then
    SoundController:PlayEventAnnouncementSound()
  end

  -- Create zone highlight for loot surge
  if eventType == "loot_surge" and zoneSize then
    createSurgeHighlight(position, zoneSize)
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

  -- Clean up surge highlight
  if eventType == "loot_surge" then
    clearSurgeHighlight()
  end

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
  EventService.EventStarted:Connect(
    function(eventType: string, position: Vector3, duration: number, zoneSize: Vector3?)
      onEventStarted(eventType, position, duration, zoneSize)
    end
  )

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

        -- Reconstruct zoneSize for loot surge late-join
        local zoneSize = nil
        if
          eventInfo.eventType == "loot_surge"
          and type(eventInfo.zoneSize) == "table"
          and #eventInfo.zoneSize == 3
        then
          zoneSize =
            Vector3.new(eventInfo.zoneSize[1], eventInfo.zoneSize[2], eventInfo.zoneSize[3])
        end

        onEventStarted(eventInfo.eventType, pos, eventInfo.remainingTime or 0, zoneSize)
      end
    end)
    :catch(function(err)
      warn("[EventController] Failed to get active event:", err)
    end)

  print("[EventController] Started")
end

return EventController
