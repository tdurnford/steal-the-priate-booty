--[[
  DayNightService.lua
  Server-authoritative day/night cycle clock.

  Cycles through four phases: Dawn → Day → Dusk → Night.
  Phase durations are read from GameConfig.DayNight.

  Other server services can:
    - Query the current phase: GetCurrentPhase(), IsNight(), IsDawn(), IsDusk(), IsDay()
    - Query progress: GetPhaseProgress(), GetCycleElapsed()
    - Listen for transitions: PhaseChanged signal fires (newPhase, previousPhase)

  Clients receive:
    - PhaseChanged signal: (phase, phaseElapsed, phaseDuration)
    - Client:GetCurrentPhase(), Client:GetTimeInfo() for initial sync
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local DayNightService = Knit.CreateService({
  Name = "DayNightService",
  Client = {
    -- Fired to ALL players when the phase transitions.
    -- Args: (phase: string, phaseElapsed: number, phaseDuration: number)
    PhaseChanged = Knit.CreateSignal(),
  },
})

-- Server-side signal: fires (newPhase: string, previousPhase: string)
DayNightService.PhaseChanged = Signal.new()

--------------------------------------------------------------------------------
-- PHASE ORDER & DURATIONS
--------------------------------------------------------------------------------

-- Ordered list of phases and their durations from GameConfig
local PHASE_ORDER = { "Dawn", "Day", "Dusk", "Night" }

local PHASE_DURATIONS = {
  Dawn = GameConfig.DayNight.dawnDuration,
  Day = GameConfig.DayNight.dayDuration,
  Dusk = GameConfig.DayNight.duskDuration,
  Night = GameConfig.DayNight.nightDuration,
}

local TOTAL_CYCLE = GameConfig.DayNight.totalCycleDuration

-- Precompute the cumulative start time of each phase within a cycle
local PHASE_START = {}
do
  local cumulative = 0
  for _, phase in ipairs(PHASE_ORDER) do
    PHASE_START[phase] = cumulative
    cumulative = cumulative + PHASE_DURATIONS[phase]
  end
end

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

-- Current position within the cycle in seconds [0, TOTAL_CYCLE)
local CycleElapsed = 0

-- Current phase (derived from CycleElapsed)
local CurrentPhase: GameConfig.DayPhase = "Day"

-- Elapsed time within the current phase
local PhaseElapsed = 0

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Determines the phase and elapsed time within that phase for a given cycle time.
  @param elapsed Seconds elapsed in the cycle [0, TOTAL_CYCLE)
  @return phase, elapsedInPhase
]]
local function getPhaseFromElapsed(elapsed: number): (GameConfig.DayPhase, number)
  local acc = 0
  for _, phase in ipairs(PHASE_ORDER) do
    local duration = PHASE_DURATIONS[phase]
    if elapsed < acc + duration then
      return phase :: GameConfig.DayPhase, elapsed - acc
    end
    acc = acc + duration
  end
  -- Should not reach here, but fallback to last phase
  return "Night" :: GameConfig.DayPhase, elapsed - (acc - PHASE_DURATIONS.Night)
end

--[[
  Broadcasts phase change to all connected clients and fires server signal.
]]
local function onPhaseTransition(newPhase: GameConfig.DayPhase, previousPhase: GameConfig.DayPhase)
  -- Fire server-side signal for other services
  DayNightService.PhaseChanged:Fire(newPhase, previousPhase)

  -- Fire client signal to all connected players
  DayNightService.Client.PhaseChanged:FireAll(newPhase, 0, PHASE_DURATIONS[newPhase])

  print(string.format("[DayNightService] Phase: %s → %s", previousPhase, newPhase))
end

--------------------------------------------------------------------------------
-- PUBLIC API (server-side)
--------------------------------------------------------------------------------

--[[
  Returns the current day/night phase.
  @return "Dawn" | "Day" | "Dusk" | "Night"
]]
function DayNightService:GetCurrentPhase(): GameConfig.DayPhase
  return CurrentPhase
end

--[[
  Returns true if the current phase is Night.
]]
function DayNightService:IsNight(): boolean
  return CurrentPhase == "Night"
end

--[[
  Returns true if the current phase is Day.
]]
function DayNightService:IsDay(): boolean
  return CurrentPhase == "Day"
end

--[[
  Returns true if the current phase is Dawn.
]]
function DayNightService:IsDawn(): boolean
  return CurrentPhase == "Dawn"
end

--[[
  Returns true if the current phase is Dusk.
]]
function DayNightService:IsDusk(): boolean
  return CurrentPhase == "Dusk"
end

--[[
  Returns the progress through the current phase as a fraction [0, 1).
]]
function DayNightService:GetPhaseProgress(): number
  local duration = PHASE_DURATIONS[CurrentPhase]
  if duration <= 0 then
    return 0
  end
  return math.clamp(PhaseElapsed / duration, 0, 1)
end

--[[
  Returns the duration of the current phase in seconds.
]]
function DayNightService:GetPhaseDuration(): number
  return PHASE_DURATIONS[CurrentPhase]
end

--[[
  Returns the elapsed time within the current phase in seconds.
]]
function DayNightService:GetPhaseElapsed(): number
  return PhaseElapsed
end

--[[
  Returns the total elapsed time in the current cycle [0, TOTAL_CYCLE).
]]
function DayNightService:GetCycleElapsed(): number
  return CycleElapsed
end

--[[
  Returns the duration of a given phase by name.
  @param phase The phase name
  @return Duration in seconds, or 0 if invalid
]]
function DayNightService:GetDurationForPhase(phase: GameConfig.DayPhase): number
  return PHASE_DURATIONS[phase] or 0
end

--------------------------------------------------------------------------------
-- CLIENT-EXPOSED METHODS (read-only)
--------------------------------------------------------------------------------

--[[
  Returns the current phase name for a requesting client.
]]
function DayNightService.Client:GetCurrentPhase(_player: Player): string
  return DayNightService:GetCurrentPhase()
end

--[[
  Returns a snapshot of the current time info for initial client sync.
  @return { phase, phaseElapsed, phaseDuration, cycleElapsed, totalCycle }
]]
function DayNightService.Client:GetTimeInfo(_player: Player): {
  phase: string,
  phaseElapsed: number,
  phaseDuration: number,
  cycleElapsed: number,
  totalCycle: number,
}
  return {
    phase = CurrentPhase,
    phaseElapsed = PhaseElapsed,
    phaseDuration = PHASE_DURATIONS[CurrentPhase],
    cycleElapsed = CycleElapsed,
    totalCycle = TOTAL_CYCLE,
  }
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function DayNightService:KnitInit()
  -- Start the cycle at the beginning of Day so players join during daytime
  CycleElapsed = PHASE_START.Day
  CurrentPhase = "Day"
  PhaseElapsed = 0

  print("[DayNightService] Initialized — starting at Day phase")
end

function DayNightService:KnitStart()
  -- Run the clock on Heartbeat for consistent timing
  RunService.Heartbeat:Connect(function(dt: number)
    local previousPhase = CurrentPhase

    -- Advance cycle clock
    CycleElapsed = (CycleElapsed + dt) % TOTAL_CYCLE
    CurrentPhase, PhaseElapsed = getPhaseFromElapsed(CycleElapsed)

    -- Detect phase transitions
    if CurrentPhase ~= previousPhase then
      onPhaseTransition(CurrentPhase, previousPhase)
    end
  end)

  print("[DayNightService] Started — cycle running")
end

return DayNightService
