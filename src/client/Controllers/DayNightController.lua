--[[
  DayNightController.lua
  Client-side day/night cycle sync.

  On start, fetches the current time from DayNightService and then tracks
  phase transitions via the PhaseChanged signal. Other controllers can
  query the current phase without a server round-trip.

  Lighting / atmosphere changes (DAYNIGHT-002) and transition banners
  (DAYNIGHT-003) will build on this controller.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local DayNightController = Knit.CreateController({
  Name = "DayNightController",
})

-- Lazy-loaded service reference
local DayNightService = nil

-- Local state (mirrors server)
local CurrentPhase: GameConfig.DayPhase = "Day"
local PhaseElapsed = 0
local PhaseDuration = GameConfig.DayNight.dayDuration

-- Client-side signal: fires (newPhase: string, previousPhase: string)
-- Other controllers can listen to this without needing a server reference.
DayNightController.PhaseChanged = Signal.new()

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns the current day/night phase.
  @return "Dawn" | "Day" | "Dusk" | "Night"
]]
function DayNightController:GetCurrentPhase(): string
  return CurrentPhase
end

--[[
  Returns true if the current phase is Night.
]]
function DayNightController:IsNight(): boolean
  return CurrentPhase == "Night"
end

--[[
  Returns true if the current phase is Day.
]]
function DayNightController:IsDay(): boolean
  return CurrentPhase == "Day"
end

--[[
  Returns true if the current phase is Dawn.
]]
function DayNightController:IsDawn(): boolean
  return CurrentPhase == "Dawn"
end

--[[
  Returns true if the current phase is Dusk.
]]
function DayNightController:IsDusk(): boolean
  return CurrentPhase == "Dusk"
end

--[[
  Returns the elapsed time within the current phase in seconds.
]]
function DayNightController:GetPhaseElapsed(): number
  return PhaseElapsed
end

--[[
  Returns the total duration of the current phase in seconds.
]]
function DayNightController:GetPhaseDuration(): number
  return PhaseDuration
end

--[[
  Returns the progress through the current phase as a fraction [0, 1).
]]
function DayNightController:GetPhaseProgress(): number
  if PhaseDuration <= 0 then
    return 0
  end
  return math.clamp(PhaseElapsed / PhaseDuration, 0, 1)
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DayNightController:KnitInit()
  print("[DayNightController] Initialized")
end

function DayNightController:KnitStart()
  DayNightService = Knit.GetService("DayNightService")

  -- Fetch initial state from server
  DayNightService:GetTimeInfo()
    :andThen(function(info)
      CurrentPhase = info.phase
      PhaseElapsed = info.phaseElapsed
      PhaseDuration = info.phaseDuration
      print(
        string.format(
          "[DayNightController] Synced — phase=%s elapsed=%.1fs/%ds",
          CurrentPhase,
          PhaseElapsed,
          PhaseDuration
        )
      )
    end)
    :catch(function(err)
      warn("[DayNightController] Failed to sync initial time:", err)
    end)

  -- Listen for phase transitions from the server
  DayNightService.PhaseChanged:Connect(function(phase: string, elapsed: number, duration: number)
    local previousPhase = CurrentPhase
    CurrentPhase = phase
    PhaseElapsed = elapsed
    PhaseDuration = duration

    -- Fire local signal so other controllers can react
    DayNightController.PhaseChanged:Fire(phase, previousPhase)

    print(string.format("[DayNightController] Phase: %s → %s", previousPhase, phase))
  end)

  print("[DayNightController] Started")
end

return DayNightController
