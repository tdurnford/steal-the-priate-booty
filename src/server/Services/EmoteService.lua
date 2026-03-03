--[[
  EmoteService.lua
  Server-authoritative emote playback system.

  Handles:
    - Client emote requests (validates equipped state, player state)
    - Server-side animation playback (auto-replicates to all clients)
    - Movement and combat interruption (stops emote on move/attack/ragdoll)
    - Cooldown enforcement (1s between emote attempts)
    - Auto-stop after max duration (8s)
    - Cleanup on character removal and disconnect

  Animations play on the server Animator, which Roblox replicates to all
  clients automatically. No per-client broadcasting needed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))
local CosmeticConfig = require(Shared:WaitForChild("CosmeticConfig"))

local EmoteService = Knit.CreateService({
  Name = "EmoteService",
  Client = {
    -- Client fires to request emote playback.
    -- Args: (emoteSlot: string) — "emote_1" or "emote_2"
    EmoteRequest = Knit.CreateSignal(),

    -- Server fires to client when their emote starts playing.
    -- Args: (emoteId: string)
    EmoteStarted = Knit.CreateSignal(),

    -- Server fires to client when their emote is stopped/interrupted.
    EmoteStopped = Knit.CreateSignal(),
  },
})

-- Server-side signals for inter-service communication
EmoteService.EmoteStarted = Signal.new() -- (player, emoteId)
EmoteService.EmoteStopped = Signal.new() -- (player)

-- Lazy-loaded service references (set in KnitStart)
local SessionStateService = nil
local DataService = nil

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local EMOTE_COOLDOWN = 1.0 -- seconds between emote attempts
local MAX_EMOTE_DURATION = 8.0 -- auto-stop after this many seconds
local MOVE_CHECK_INTERVAL = 0.1 -- how often to check for movement (seconds)
local MOVE_THRESHOLD = 0.1 -- MoveDirection magnitude threshold

-- Placeholder animation config per emote ID.
-- Uses the same placeholder animation ID as CombatController with different
-- speeds and looping to visually distinguish emotes. Replace with real
-- animation IDs when AUDIO-001 assets are created.
local EMOTE_ANIM_CONFIG = {
  emote_pirate_dance = {
    animationId = "rbxassetid://522635514",
    speed = 0.7,
    looped = true,
    priority = Enum.AnimationPriority.Action,
  },
  emote_laugh_taunt = {
    animationId = "rbxassetid://522635514",
    speed = 1.5,
    looped = true,
    priority = Enum.AnimationPriority.Action,
  },
  emote_coin_flip = {
    animationId = "rbxassetid://522635514",
    speed = 1.0,
    looped = false,
    priority = Enum.AnimationPriority.Action,
  },
  emote_telescope_pose = {
    animationId = "rbxassetid://522635514",
    speed = 0.3,
    looped = true,
    priority = Enum.AnimationPriority.Action,
  },
}

local FALLBACK_ANIM_CONFIG = {
  animationId = "rbxassetid://522635514",
  speed = 1.0,
  looped = false,
  priority = Enum.AnimationPriority.Action,
}

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

-- Active emotes keyed by Player.
-- Each entry: { track: AnimationTrack, emoteId: string, connections: {RBXScriptConnection}, timeoutThread: thread? }
local ActiveEmotes: {
  [Player]: {
    track: AnimationTrack,
    emoteId: string,
    connections: { RBXScriptConnection },
    timeoutThread: thread?,
  },
} =
  {}

-- Cooldown timestamps keyed by Player
local LastEmoteTime: { [Player]: number } = {}

--------------------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------------------

--[[
  Gets the Animator from a player's character.
  @param player The player
  @return Animator? or nil
]]
local function getAnimator(player: Player): Animator?
  local character = player.Character
  if not character then
    return nil
  end
  local humanoid = character:FindFirstChildOfClass("Humanoid")
  if not humanoid then
    return nil
  end
  return humanoid:FindFirstChildOfClass("Animator")
end

--[[
  Stops the active emote for a player if one is playing.
  Cleans up animation track, connections, and timeout thread.
  @param player The player whose emote to stop
  @param silent If true, don't fire EmoteStopped signal (for cleanup)
]]
local function stopEmote(player: Player, silent: boolean?)
  local emoteState = ActiveEmotes[player]
  if not emoteState then
    return
  end

  -- Stop the animation track
  if emoteState.track then
    emoteState.track:Stop(0.2)
  end

  -- Disconnect all event connections
  for _, conn in emoteState.connections do
    conn:Disconnect()
  end

  -- Cancel timeout thread
  if emoteState.timeoutThread then
    task.cancel(emoteState.timeoutThread)
  end

  local emoteId = emoteState.emoteId
  ActiveEmotes[player] = nil

  if not silent then
    -- Notify the client
    EmoteService.Client.EmoteStopped:Fire(player)
    -- Fire server signal
    EmoteService.EmoteStopped:Fire(player)
  end

  print(string.format("[EmoteService] %s stopped emote %s", player.Name, emoteId))
end

--[[
  Checks if a player is in a valid state to play an emote.
  @param player The player to check
  @return (boolean, string?) — can emote, optional reason
]]
local function canEmote(player: Player): (boolean, string?)
  if not player.Character then
    return false, "No character"
  end

  local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
  if not humanoid or humanoid.Health <= 0 then
    return false, "Dead or no humanoid"
  end

  if not SessionStateService then
    return false, "Session state not available"
  end

  -- Check session state for blocking conditions
  local state = SessionStateService:GetState(player)
  if not state then
    return false, "No session state"
  end

  if state.isRagdolling then
    return false, "Ragdolling"
  end

  if state.isBlocking then
    return false, "Blocking"
  end

  if state.isDashing then
    return false, "Dashing"
  end

  if state.tutorialActive then
    return false, "In tutorial"
  end

  if state.isQuicksandTrapped then
    return false, "Quicksand trapped"
  end

  -- Check cooldown
  local now = os.clock()
  local lastTime = LastEmoteTime[player]
  if lastTime and (now - lastTime) < EMOTE_COOLDOWN then
    return false, "Cooldown"
  end

  return true, nil
end

--------------------------------------------------------------------------------
-- EMOTE REQUEST HANDLER
--------------------------------------------------------------------------------

--[[
  Handles a client's emote request.
  @param player The requesting player
  @param emoteSlot The emote slot field ("emote_1" or "emote_2")
]]
local function handleEmoteRequest(player: Player, emoteSlot: string)
  -- Validate slot argument
  if type(emoteSlot) ~= "string" then
    return
  end

  if emoteSlot ~= "emote_1" and emoteSlot ~= "emote_2" then
    return
  end

  -- If already emoting, stop the current emote first
  if ActiveEmotes[player] then
    stopEmote(player)
  end

  -- Check player state
  local canPlay, reason = canEmote(player)
  if not canPlay then
    return
  end

  -- Check if an emote is equipped in the requested slot
  local data = DataService:GetData(player)
  if not data then
    return
  end

  local emoteId = data.equippedCosmetics[emoteSlot]
  if not emoteId then
    return
  end

  -- Verify the emote exists in config
  local emoteDef = CosmeticConfig.getById(emoteId)
  if not emoteDef or emoteDef.slot ~= "emote" then
    return
  end

  -- Get the animator
  local animator = getAnimator(player)
  if not animator then
    return
  end

  -- Get animation config
  local animConfig = EMOTE_ANIM_CONFIG[emoteId] or FALLBACK_ANIM_CONFIG

  -- Load and play animation
  local animation = Instance.new("Animation")
  animation.AnimationId = animConfig.animationId
  local track = animator:LoadAnimation(animation)
  track.Priority = animConfig.priority
  track.Looped = animConfig.looped
  track:Play(0.2, 1, animConfig.speed)
  animation:Destroy()

  -- Set cooldown
  LastEmoteTime[player] = os.clock()

  -- Build cleanup connections
  local connections: { RBXScriptConnection } = {}

  -- Movement interruption: check MoveDirection on Heartbeat
  local lastMoveCheck = os.clock()
  local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
  if humanoid then
    table.insert(
      connections,
      RunService.Heartbeat:Connect(function()
        local now = os.clock()
        if (now - lastMoveCheck) < MOVE_CHECK_INTERVAL then
          return
        end
        lastMoveCheck = now

        if not humanoid or not humanoid.Parent then
          stopEmote(player)
          return
        end

        if humanoid.MoveDirection.Magnitude > MOVE_THRESHOLD then
          stopEmote(player)
        end
      end)
    )

    -- Jump interruption via StateChanged
    table.insert(
      connections,
      humanoid.StateChanged:Connect(function(_old, new)
        if new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall then
          stopEmote(player)
        end
      end)
    )
  end

  -- Animation finished (non-looped emotes)
  if not animConfig.looped then
    table.insert(
      connections,
      track.Stopped:Connect(function()
        stopEmote(player)
      end)
    )
  end

  -- Auto-stop timeout
  local timeoutThread = task.delay(MAX_EMOTE_DURATION, function()
    stopEmote(player)
  end)

  -- Store active emote state
  ActiveEmotes[player] = {
    track = track,
    emoteId = emoteId,
    connections = connections,
    timeoutThread = timeoutThread,
  }

  -- Notify client and server
  EmoteService.Client.EmoteStarted:Fire(player, emoteId)
  EmoteService.EmoteStarted:Fire(player, emoteId)

  print(
    string.format(
      "[EmoteService] %s playing emote %s from slot %s",
      player.Name,
      emoteId,
      emoteSlot
    )
  )
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Checks if a player is currently playing an emote.
  @param player The player to check
  @return boolean
]]
function EmoteService:IsPlayerEmoting(player: Player): boolean
  return ActiveEmotes[player] ~= nil
end

--[[
  Stops a player's active emote. Called by other services when combat
  or state changes should interrupt the emote.
  @param player The player whose emote to stop
]]
function EmoteService:StopEmote(player: Player)
  stopEmote(player)
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function EmoteService:KnitInit()
  print("[EmoteService] Initializing...")
end

function EmoteService:KnitStart()
  SessionStateService = Knit.GetService("SessionStateService")
  DataService = Knit.GetService("DataService")

  -- Listen for emote requests from clients
  EmoteService.Client.EmoteRequest:Connect(handleEmoteRequest)

  -- Interrupt emote on ragdoll, block, dash, or any combat state change
  if SessionStateService then
    SessionStateService.StateChanged:Connect(
      function(player: Player, fieldName: string, newValue: any)
        if not ActiveEmotes[player] then
          return
        end

        -- Interrupt on any combat state that conflicts with emoting
        if fieldName == "isRagdolling" and newValue == true then
          stopEmote(player)
        elseif fieldName == "isBlocking" and newValue == true then
          stopEmote(player)
        elseif fieldName == "isDashing" and newValue == true then
          stopEmote(player)
        elseif fieldName == "isQuicksandTrapped" and newValue == true then
          stopEmote(player)
        end
      end
    )
  end

  -- Clean up on character removal (death/respawn)
  Players.PlayerAdded:Connect(function(player: Player)
    player.CharacterRemoving:Connect(function()
      stopEmote(player, true)
    end)
  end)

  -- Also connect for players already in the game
  for _, player in Players:GetPlayers() do
    player.CharacterRemoving:Connect(function()
      stopEmote(player, true)
    end)
  end

  -- Clean up on disconnect
  Players.PlayerRemoving:Connect(function(player: Player)
    stopEmote(player, true)
    LastEmoteTime[player] = nil
  end)

  print("[EmoteService] Started — emotes play server-side and replicate to all clients")
end

return EmoteService
