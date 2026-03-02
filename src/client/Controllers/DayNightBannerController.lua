--[[
  DayNightBannerController.lua
  Client-side day/night phase transition banners and audio cues.

  On Dusk: shows "Night is falling..." banner + deep horn blast SFX.
  On Dawn: shows "Dawn breaks. The island rests." banner + bell chime SFX.
  Banners appear at top center, fade in/out, and auto-dismiss after
  GameConfig.DayNight.bannerDuration seconds.

  Depends on: DayNightController, SoundController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local UITheme = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UITheme"))

local DayNightBannerController = Knit.CreateController({
  Name = "DayNightBannerController",
})

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local LocalPlayer = Players.LocalPlayer

local BANNER_DURATION = GameConfig.DayNight.bannerDuration -- 5 seconds
local FADE_IN_TIME = 0.6
local FADE_OUT_TIME = 0.8

-- Banner text and colors per phase
local BANNER_CONFIG = {
  Dusk = {
    text = "Night is falling...",
    color = Color3.fromRGB(255, 160, 80), -- warm orange
    glowColor = Color3.fromRGB(200, 100, 40),
    icon = "\u{1F319}", -- crescent moon (fallback; actual icon via ImageLabel)
  },
  Dawn = {
    text = "Dawn breaks. The island rests.",
    color = Color3.fromRGB(255, 220, 120), -- golden sunrise
    glowColor = Color3.fromRGB(255, 180, 60),
    icon = "\u{2600}", -- sun (fallback; actual icon via ImageLabel)
  },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local DayNightController = nil
local SoundController = nil
local ScreenGui: ScreenGui? = nil
local ActiveBanner: Frame? = nil
local ActiveTweens: { Tween } = {}

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
  @param instance The instance to tween
  @param tweenInfo TweenInfo configuration
  @param properties Target property values
  @return Tween
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
  Plays the phase transition sound effect.
  Uses SoundController's sfxEnabled check via play2DSound pattern.
  @param phase "Dawn" | "Dusk"
]]
local function playTransitionSound(phase: string)
  if SoundController then
    SoundController:PlayPhaseTransitionSound(phase)
  end
end

--[[
  Creates and shows a banner for the given phase.
  @param phase "Dawn" | "Dusk"
]]
local function showBanner(phase: string)
  local config = BANNER_CONFIG[phase]
  if not config then
    return
  end
  if not ScreenGui then
    return
  end

  -- Clear any existing banner
  clearBanner()

  -- Container frame (centered at top)
  local banner = Instance.new("Frame")
  banner.Name = "DayNightBanner"
  banner.Size = UDim2.new(0, 420, 0, 60)
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
  stroke.Thickness = 2
  stroke.Transparency = 1 -- start hidden
  stroke.Parent = banner

  -- Gradient background for atmospheric feel
  local gradient = Instance.new("UIGradient")
  gradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 0, 0)),
    ColorSequenceKeypoint.new(0.5, config.glowColor),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
  })
  gradient.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.95),
    NumberSequenceKeypoint.new(0.5, 0.7),
    NumberSequenceKeypoint.new(1, 0.95),
  })
  gradient.Parent = banner

  -- Banner text
  local textLabel = Instance.new("TextLabel")
  textLabel.Name = "BannerText"
  textLabel.Size = UDim2.new(1, -24, 1, 0)
  textLabel.Position = UDim2.new(0, 12, 0, 0)
  textLabel.BackgroundTransparency = 1
  textLabel.Font = UITheme.Fonts.PRIMARY
  textLabel.TextColor3 = config.color
  textLabel.TextTransparency = 1 -- start hidden
  textLabel.TextSize = 26
  textLabel.Text = config.text
  textLabel.TextXAlignment = Enum.TextXAlignment.Center
  textLabel.TextYAlignment = Enum.TextYAlignment.Center
  textLabel.Parent = banner

  -- Text stroke for readability
  local textStroke = Instance.new("UIStroke")
  textStroke.Color = Color3.fromRGB(0, 0, 0)
  textStroke.Thickness = UITheme.getTextStrokeThickness(26)
  textStroke.Transparency = 1 -- start hidden
  textStroke.Parent = textLabel

  banner.Parent = ScreenGui
  ActiveBanner = banner

  -- Fade in
  local fadeInInfo = TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

  trackTween(banner, fadeInInfo, { BackgroundTransparency = 0.25 })
  trackTween(stroke, fadeInInfo, { Transparency = 0.3 })
  trackTween(textLabel, fadeInInfo, { TextTransparency = 0 })
  trackTween(textStroke, fadeInInfo, { Transparency = 0.1 })

  -- Subtle scale-in effect via UIScale
  local scale = Instance.new("UIScale")
  scale.Scale = 0.9
  scale.Parent = banner
  trackTween(scale, TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
    Scale = 1,
  })

  -- Schedule fade out
  task.delay(BANNER_DURATION, function()
    if banner.Parent == nil then
      return
    end

    local fadeOutInfo = TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    local bgFade = TweenService:Create(banner, fadeOutInfo, { BackgroundTransparency = 1 })
    local strokeFade = TweenService:Create(stroke, fadeOutInfo, { Transparency = 1 })
    local textFade = TweenService:Create(textLabel, fadeOutInfo, { TextTransparency = 1 })
    local textStrokeFade = TweenService:Create(textStroke, fadeOutInfo, { Transparency = 1 })
    local scaleOut = TweenService:Create(
      scale,
      TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
      { Scale = 1.05 }
    )

    bgFade:Play()
    strokeFade:Play()
    textFade:Play()
    textStrokeFade:Play()
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
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Manually trigger a phase banner (useful for testing).
  @param phase "Dawn" | "Dusk"
]]
function DayNightBannerController:ShowBanner(phase: string)
  showBanner(phase)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DayNightBannerController:KnitInit()
  -- Create ScreenGui for banners
  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "DayNightBannerGui"
  ScreenGui.ResetOnSpawn = false
  ScreenGui.DisplayOrder = 100 -- above most UI
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  print("[DayNightBannerController] Initialized")
end

function DayNightBannerController:KnitStart()
  DayNightController = Knit.GetController("DayNightController")
  SoundController = Knit.GetController("SoundController")

  -- Listen for phase transitions — show banners for Dawn and Dusk only
  DayNightController.PhaseChanged:Connect(function(newPhase: string, _previousPhase: string)
    if BANNER_CONFIG[newPhase] then
      showBanner(newPhase)
      playTransitionSound(newPhase)
      print(string.format("[DayNightBannerController] Showing banner: %s", newPhase))
    end
  end)

  print("[DayNightBannerController] Started")
end

return DayNightBannerController
