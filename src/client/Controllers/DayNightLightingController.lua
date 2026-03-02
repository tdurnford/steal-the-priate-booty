--[[
  DayNightLightingController.lua
  Client-side lighting & atmosphere transitions for the day/night cycle.

  Listens to DayNightController.PhaseChanged and tweens Lighting, Atmosphere,
  and ColorCorrection properties to match each phase. Dawn and Dusk are
  gradual 30-second transitions; Day and Night snap to their target quickly.

  Night reduces visibility to ~60 studs via fog.
  Torches/lanterns under workspace.Torches glow at night.

  Depends on: DayNightController (must be loaded first by Knit).
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local DayNightLightingController = Knit.CreateController({
  Name = "DayNightLightingController",
})

--------------------------------------------------------------------------------
-- LIGHTING PRESETS
--------------------------------------------------------------------------------

-- Each preset defines the target values for Lighting and Atmosphere properties.
-- Dawn/Dusk are transitional; Day and Night are the two "rest" states.

local PRESETS = {
  Day = {
    -- Lighting
    ClockTime = 14, -- 2 PM
    Brightness = 2,
    Ambient = Color3.fromRGB(140, 140, 140),
    OutdoorAmbient = Color3.fromRGB(128, 128, 128),
    FogEnd = 10000, -- effectively no fog
    FogColor = Color3.fromRGB(192, 216, 240),
    -- Atmosphere
    AtmosphereDensity = 0.3,
    AtmosphereOffset = 0,
    AtmosphereColor = Color3.fromRGB(199, 199, 199),
    AtmosphereDecay = Color3.fromRGB(92, 100, 120),
    AtmosphereGlare = 0,
    AtmosphereHaze = 0,
    -- ColorCorrection
    CCBrightness = 0,
    CCContrast = 0.05,
    CCSaturation = 0.1,
    CCTintColor = Color3.fromRGB(255, 255, 255),
  },
  Dawn = {
    ClockTime = 6.5, -- 6:30 AM
    Brightness = 1.2,
    Ambient = Color3.fromRGB(90, 80, 90),
    OutdoorAmbient = Color3.fromRGB(100, 90, 80),
    FogEnd = 2000,
    FogColor = Color3.fromRGB(200, 170, 140),
    AtmosphereDensity = 0.35,
    AtmosphereOffset = 0.1,
    AtmosphereColor = Color3.fromRGB(230, 180, 130),
    AtmosphereDecay = Color3.fromRGB(120, 90, 70),
    AtmosphereGlare = 0.2,
    AtmosphereHaze = 1,
    CCBrightness = 0,
    CCContrast = 0.08,
    CCSaturation = 0.15,
    CCTintColor = Color3.fromRGB(255, 240, 220),
  },
  Dusk = {
    ClockTime = 17.5, -- 5:30 PM
    Brightness = 1,
    Ambient = Color3.fromRGB(80, 60, 80),
    OutdoorAmbient = Color3.fromRGB(90, 70, 70),
    FogEnd = 1500,
    FogColor = Color3.fromRGB(140, 100, 100),
    AtmosphereDensity = 0.4,
    AtmosphereOffset = 0.15,
    AtmosphereColor = Color3.fromRGB(200, 130, 100),
    AtmosphereDecay = Color3.fromRGB(100, 60, 60),
    AtmosphereGlare = 0.3,
    AtmosphereHaze = 1.5,
    CCBrightness = -0.02,
    CCContrast = 0.1,
    CCSaturation = 0.2,
    CCTintColor = Color3.fromRGB(255, 210, 190),
  },
  Night = {
    ClockTime = 0, -- midnight
    Brightness = 0.2,
    Ambient = Color3.fromRGB(30, 30, 50),
    OutdoorAmbient = Color3.fromRGB(20, 20, 45),
    FogEnd = GameConfig.DayNight.nightViewRadius, -- ~60 studs
    FogColor = Color3.fromRGB(15, 15, 30),
    AtmosphereDensity = 0.5,
    AtmosphereOffset = 0.25,
    AtmosphereColor = Color3.fromRGB(40, 40, 80),
    AtmosphereDecay = Color3.fromRGB(20, 20, 50),
    AtmosphereGlare = 0,
    AtmosphereHaze = 2.5,
    CCBrightness = -0.05,
    CCContrast = 0.15,
    CCSaturation = -0.1,
    CCTintColor = Color3.fromRGB(180, 180, 230),
  },
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local DayNightController = nil -- set in KnitStart

-- Tween duration for gradual transitions (Dawn/Dusk) vs snap transitions
local TRANSITION_DURATION = {
  Dawn = GameConfig.DayNight.dawnDuration, -- 30s
  Day = 3, -- quick snap from Dawn→Day
  Dusk = GameConfig.DayNight.duskDuration, -- 30s
  Night = 3, -- quick snap from Dusk→Night
}

-- Active tweens (so we can cancel them on a new transition)
local ActiveTweens: { Tween } = {}

-- References to Atmosphere and ColorCorrectionEffect (created if missing)
local AtmosphereEffect: Atmosphere? = nil
local ColorCorrectionEffect: ColorCorrectionEffect? = nil

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Cancels all active lighting tweens.
]]
local function cancelActiveTweens()
  for _, tween in ipairs(ActiveTweens) do
    tween:Cancel()
  end
  table.clear(ActiveTweens)
end

--[[
  Ensures an Atmosphere instance exists under Lighting.
  @return Atmosphere
]]
local function ensureAtmosphere(): Atmosphere
  if AtmosphereEffect then
    return AtmosphereEffect
  end
  AtmosphereEffect = Lighting:FindFirstChildOfClass("Atmosphere")
  if not AtmosphereEffect then
    AtmosphereEffect = Instance.new("Atmosphere")
    AtmosphereEffect.Parent = Lighting
  end
  return AtmosphereEffect :: Atmosphere
end

--[[
  Ensures a ColorCorrectionEffect instance exists under Lighting.
  @return ColorCorrectionEffect
]]
local function ensureColorCorrection(): ColorCorrectionEffect
  if ColorCorrectionEffect then
    return ColorCorrectionEffect
  end
  ColorCorrectionEffect = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
  if not ColorCorrectionEffect then
    ColorCorrectionEffect = Instance.new("ColorCorrectionEffect")
    ColorCorrectionEffect.Name = "DayNightCC"
    ColorCorrectionEffect.Parent = Lighting
  end
  return ColorCorrectionEffect :: ColorCorrectionEffect
end

--[[
  Creates and starts a tween, adding it to the ActiveTweens list.
  @param instance The instance to tween
  @param duration Tween duration in seconds
  @param properties Property table
]]
local function tweenInstance(instance: Instance, duration: number, properties: { [string]: any })
  local info = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
  local tween = TweenService:Create(instance, info, properties)
  table.insert(ActiveTweens, tween)
  tween:Play()
end

--[[
  Applies a lighting preset by tweening all properties over the given duration.
  @param phase The target phase name
]]
local function applyPreset(phase: string)
  local preset = PRESETS[phase]
  if not preset then
    warn("[DayNightLightingController] Unknown phase:", phase)
    return
  end

  cancelActiveTweens()

  local duration = TRANSITION_DURATION[phase] or 3
  local atmo = ensureAtmosphere()
  local cc = ensureColorCorrection()

  -- Tween Lighting properties
  tweenInstance(Lighting, duration, {
    ClockTime = preset.ClockTime,
    Brightness = preset.Brightness,
    Ambient = preset.Ambient,
    OutdoorAmbient = preset.OutdoorAmbient,
    FogEnd = preset.FogEnd,
    FogColor = preset.FogColor,
  })

  -- Tween Atmosphere
  tweenInstance(atmo, duration, {
    Density = preset.AtmosphereDensity,
    Offset = preset.AtmosphereOffset,
    Color = preset.AtmosphereColor,
    Decay = preset.AtmosphereDecay,
    Glare = preset.AtmosphereGlare,
    Haze = preset.AtmosphereHaze,
  })

  -- Tween ColorCorrection
  tweenInstance(cc, duration, {
    Brightness = preset.CCBrightness,
    Contrast = preset.CCContrast,
    Saturation = preset.CCSaturation,
    TintColor = preset.CCTintColor,
  })
end

--[[
  Applies a preset instantly (no tween), used for initial sync.
  @param phase The target phase name
]]
local function applyPresetInstant(phase: string)
  local preset = PRESETS[phase]
  if not preset then
    return
  end

  local atmo = ensureAtmosphere()
  local cc = ensureColorCorrection()

  Lighting.ClockTime = preset.ClockTime
  Lighting.Brightness = preset.Brightness
  Lighting.Ambient = preset.Ambient
  Lighting.OutdoorAmbient = preset.OutdoorAmbient
  Lighting.FogEnd = preset.FogEnd
  Lighting.FogColor = preset.FogColor

  atmo.Density = preset.AtmosphereDensity
  atmo.Offset = preset.AtmosphereOffset
  atmo.Color = preset.AtmosphereColor
  atmo.Decay = preset.AtmosphereDecay
  atmo.Glare = preset.AtmosphereGlare
  atmo.Haze = preset.AtmosphereHaze

  cc.Brightness = preset.CCBrightness
  cc.Contrast = preset.CCContrast
  cc.Saturation = preset.CCSaturation
  cc.TintColor = preset.CCTintColor
end

--------------------------------------------------------------------------------
-- TORCH / LANTERN MANAGEMENT
--------------------------------------------------------------------------------

-- Tags or folder for light sources that toggle with night
local TORCH_FOLDER_NAME = "Torches"

--[[
  Sets the Enabled state of all PointLight/SpotLight instances found under
  workspace.Torches (if it exists). Also toggles any Fire or ParticleEmitter
  children to match.
  @param enabled Whether torches should be lit
]]
local function setTorchesEnabled(enabled: boolean)
  local torchFolder = Workspace:FindFirstChild(TORCH_FOLDER_NAME)
  if not torchFolder then
    return
  end

  for _, torch in ipairs(torchFolder:GetDescendants()) do
    if torch:IsA("PointLight") or torch:IsA("SpotLight") then
      torch.Enabled = enabled
    elseif torch:IsA("Fire") or torch:IsA("ParticleEmitter") then
      torch.Enabled = enabled
    end
  end
end

--[[
  Determines if torches should be active for a given phase.
  Torches light up during Dusk and Night, turn off at Dawn and Day.
  @param phase The current phase
  @return boolean
]]
local function shouldTorchesBeActive(phase: string): boolean
  return phase == "Night" or phase == "Dusk"
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the lighting preset table for a given phase.
  Useful for other controllers that want to read lighting values.
  @param phase "Dawn" | "Day" | "Dusk" | "Night"
  @return Preset table or nil
]]
function DayNightLightingController:GetPreset(phase: string): { [string]: any }?
  return PRESETS[phase]
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DayNightLightingController:KnitInit()
  -- Ensure post-processing effects exist early
  ensureAtmosphere()
  ensureColorCorrection()
  print("[DayNightLightingController] Initialized")
end

function DayNightLightingController:KnitStart()
  DayNightController = Knit.GetController("DayNightController")

  -- Apply the current phase instantly (no tween) for initial sync
  local currentPhase = DayNightController:GetCurrentPhase()
  applyPresetInstant(currentPhase)
  setTorchesEnabled(shouldTorchesBeActive(currentPhase))

  print(
    string.format(
      "[DayNightLightingController] Initial phase: %s — lighting applied",
      currentPhase
    )
  )

  -- Listen for phase transitions and tween to the new preset
  DayNightController.PhaseChanged:Connect(function(newPhase: string, _previousPhase: string)
    applyPreset(newPhase)
    setTorchesEnabled(shouldTorchesBeActive(newPhase))
    print(string.format("[DayNightLightingController] Transitioning to: %s", newPhase))
  end)

  print("[DayNightLightingController] Started")
end

return DayNightLightingController
