--[[
  BannerQueueController.lua
  Centralized top-center banner queue for server-wide announcements.

  Manages a single ScreenGui and shows banners one at a time in FIFO order.
  When a banner is already showing, new banners are queued and displayed
  sequentially after the current one fades out.

  Used by: DayNightBannerController, EventController, BountyController.

  Banner config:
    text: string         -- Main title text
    subtitle: string?    -- Optional smaller text below title
    color: Color3        -- Accent color (text, stroke)
    glowColor: Color3?   -- Gradient glow (defaults to darkened accent)
    duration: number?    -- Display time in seconds (default 5)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))
local UITheme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UITheme"))

local BannerQueueController = Knit.CreateController({
  Name = "BannerQueueController",
})

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local LocalPlayer = Players.LocalPlayer

local DEFAULT_DURATION = 5
local FADE_IN_TIME = 0.6
local FADE_OUT_TIME = 0.8

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local ScreenGui: ScreenGui? = nil
local ActiveBanner: Frame? = nil
local ActiveTweens: { Tween } = {}
local BannerQueue: { any } = {} -- array of banner config tables
local IsProcessing: boolean = false

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
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
  Removes the active banner immediately.
]]
local function clearBanner()
  cancelActiveTweens()
  if ActiveBanner then
    ActiveBanner:Destroy()
    ActiveBanner = nil
  end
end

-- Forward declaration
local processQueue

--[[
  Creates and shows a single banner, then processes the next queued banner
  after it fades out.
]]
local function showBanner(config: any)
  if not ScreenGui then
    return
  end

  clearBanner()

  local hasSubtitle = config.subtitle ~= nil and config.subtitle ~= ""
  local bannerHeight = if hasSubtitle then 80 else 60
  local bannerWidth = if hasSubtitle then 480 else 420
  local duration = config.duration or DEFAULT_DURATION
  local glowColor = config.glowColor
    or Color3.fromRGB(
      math.floor(config.color.R * 180),
      math.floor(config.color.G * 180),
      math.floor(config.color.B * 180)
    )

  -- Container frame (centered at top)
  local banner = Instance.new("Frame")
  banner.Name = "QueuedBanner"
  banner.Size = UDim2.new(0, bannerWidth, 0, bannerHeight)
  banner.Position = UDim2.new(0.5, 0, 0, 60)
  banner.AnchorPoint = Vector2.new(0.5, 0)
  banner.BackgroundColor3 = UITheme.Colors.DarkBackground
  banner.BackgroundTransparency = 1
  banner.BorderSizePixel = 0

  local corner = Instance.new("UICorner")
  corner.CornerRadius = UITheme.CornerRadius.Large
  corner.Parent = banner

  local stroke = Instance.new("UIStroke")
  stroke.Color = config.color
  stroke.Thickness = if hasSubtitle then 2.5 else 2
  stroke.Transparency = 1
  stroke.Parent = banner

  local gradient = Instance.new("UIGradient")
  gradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 0, 0)),
    ColorSequenceKeypoint.new(if hasSubtitle then 0.3 else 0.5, glowColor),
    ColorSequenceKeypoint.new(if hasSubtitle then 0.7 else 0.5, glowColor),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
  })
  gradient.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.95),
    NumberSequenceKeypoint.new(if hasSubtitle then 0.3 else 0.5, if hasSubtitle then 0.65 else 0.7),
    NumberSequenceKeypoint.new(if hasSubtitle then 0.7 else 0.5, if hasSubtitle then 0.65 else 0.7),
    NumberSequenceKeypoint.new(1, 0.95),
  })
  gradient.Parent = banner

  -- Title text
  local titleSize = if hasSubtitle then 28 else 26
  local titleLabel = Instance.new("TextLabel")
  titleLabel.Name = "TitleText"
  titleLabel.BackgroundTransparency = 1
  titleLabel.Font = UITheme.Fonts.PRIMARY
  titleLabel.TextColor3 = config.color
  titleLabel.TextTransparency = 1
  titleLabel.TextSize = titleSize
  titleLabel.Text = config.text
  titleLabel.TextXAlignment = Enum.TextXAlignment.Center
  titleLabel.TextYAlignment = Enum.TextYAlignment.Center

  if hasSubtitle then
    titleLabel.Size = UDim2.new(1, -24, 0, 36)
    titleLabel.Position = UDim2.new(0, 12, 0, 8)
  else
    titleLabel.Size = UDim2.new(1, -24, 1, 0)
    titleLabel.Position = UDim2.new(0, 12, 0, 0)
  end
  titleLabel.Parent = banner

  local titleStroke = Instance.new("UIStroke")
  titleStroke.Color = Color3.fromRGB(0, 0, 0)
  titleStroke.Thickness = UITheme.getTextStrokeThickness(titleSize)
  titleStroke.Transparency = 1
  titleStroke.Parent = titleLabel

  -- Subtitle text (optional)
  local subtitleLabel: TextLabel? = nil
  local subtitleStroke: UIStroke? = nil
  if hasSubtitle then
    subtitleLabel = Instance.new("TextLabel")
    subtitleLabel.Name = "SubtitleText"
    subtitleLabel.Size = UDim2.new(1, -24, 0, 24)
    subtitleLabel.Position = UDim2.new(0, 12, 0, 44)
    subtitleLabel.BackgroundTransparency = 1
    subtitleLabel.Font = UITheme.Fonts.SECONDARY
    subtitleLabel.TextColor3 = UITheme.Colors.TextPrimary
    subtitleLabel.TextTransparency = 1
    subtitleLabel.TextSize = 16
    subtitleLabel.Text = config.subtitle
    subtitleLabel.TextXAlignment = Enum.TextXAlignment.Center
    subtitleLabel.TextYAlignment = Enum.TextYAlignment.Center
    subtitleLabel.Parent = banner

    subtitleStroke = Instance.new("UIStroke")
    subtitleStroke.Color = Color3.fromRGB(0, 0, 0)
    subtitleStroke.Thickness = UITheme.getTextStrokeThickness(16)
    subtitleStroke.Transparency = 1
    subtitleStroke.Parent = subtitleLabel
  end

  banner.Parent = ScreenGui
  ActiveBanner = banner

  -- Fade in
  local fadeInInfo = TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

  trackTween(banner, fadeInInfo, { BackgroundTransparency = if hasSubtitle then 0.15 else 0.25 })
  trackTween(stroke, fadeInInfo, { Transparency = if hasSubtitle then 0.2 else 0.3 })
  trackTween(titleLabel, fadeInInfo, { TextTransparency = 0 })
  trackTween(titleStroke, fadeInInfo, { Transparency = 0.1 })

  if subtitleLabel and subtitleStroke then
    trackTween(subtitleLabel, fadeInInfo, { TextTransparency = 0.1 })
    trackTween(subtitleStroke, fadeInInfo, { Transparency = 0.2 })
  end

  -- Scale-in effect
  local scale = Instance.new("UIScale")
  scale.Scale = if hasSubtitle then 0.85 else 0.9
  scale.Parent = banner
  trackTween(
    scale,
    TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
    { Scale = 1 }
  )

  -- Schedule fade out, then process next in queue
  task.delay(duration, function()
    if banner.Parent == nil then
      return
    end

    local fadeOutInfo = TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    local bgFade = TweenService:Create(banner, fadeOutInfo, { BackgroundTransparency = 1 })
    local strokeFade = TweenService:Create(stroke, fadeOutInfo, { Transparency = 1 })
    local titleFade = TweenService:Create(titleLabel, fadeOutInfo, { TextTransparency = 1 })
    local titleStrokeFade = TweenService:Create(titleStroke, fadeOutInfo, { Transparency = 1 })
    local scaleOut = TweenService:Create(
      scale,
      TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
      { Scale = 1.05 }
    )

    bgFade:Play()
    strokeFade:Play()
    titleFade:Play()
    titleStrokeFade:Play()
    scaleOut:Play()

    if subtitleLabel and subtitleStroke then
      local subFade = TweenService:Create(subtitleLabel, fadeOutInfo, { TextTransparency = 1 })
      local subStrokeFade = TweenService:Create(subtitleStroke, fadeOutInfo, { Transparency = 1 })
      subFade:Play()
      subStrokeFade:Play()
    end

    bgFade.Completed:Connect(function()
      if banner.Parent then
        banner:Destroy()
      end
      if ActiveBanner == banner then
        ActiveBanner = nil
      end

      -- Process next queued banner
      processQueue()
    end)
  end)
end

--[[
  Processes the next banner in the queue. If the queue is empty,
  marks processing as complete.
]]
processQueue = function()
  if #BannerQueue == 0 then
    IsProcessing = false
    return
  end

  local nextConfig = table.remove(BannerQueue, 1)
  showBanner(nextConfig)
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Queues a banner for display. If no banner is currently showing,
  displays immediately. Otherwise, queues for sequential display.

  @param config table with fields:
    text: string         -- Required. Main title text.
    subtitle: string?    -- Optional subtitle below title.
    color: Color3        -- Required. Accent color for text and stroke.
    glowColor: Color3?   -- Optional gradient glow color.
    duration: number?    -- Display duration in seconds (default 5).
]]
function BannerQueueController:ShowBanner(config)
  if not config or not config.text or not config.color then
    warn("[BannerQueueController] ShowBanner requires text and color")
    return
  end

  if IsProcessing then
    table.insert(BannerQueue, config)
  else
    IsProcessing = true
    showBanner(config)
  end
end

--[[
  Returns whether a banner is currently being displayed.
  @return boolean
]]
function BannerQueueController:IsBannerActive(): boolean
  return ActiveBanner ~= nil
end

--[[
  Returns the number of banners waiting in the queue.
  @return number
]]
function BannerQueueController:GetQueueLength(): number
  return #BannerQueue
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function BannerQueueController:KnitInit()
  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "BannerQueueGui"
  ScreenGui.ResetOnSpawn = false
  ScreenGui.DisplayOrder = 110 -- above all other banners
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[BannerQueueController] Initialized")
end

function BannerQueueController:KnitStart()
  print("[BannerQueueController] Started")
end

return BannerQueueController
