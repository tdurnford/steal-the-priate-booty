--[[
  EmoteController.lua
  Client-side emote input handler.

  Handles:
    - Keybinds: 1 = emote_1 slot, 2 = emote_2 slot
    - Sends emote requests to EmoteService
    - Tracks local emoting state for input gating
    - Listens to EmoteStarted/EmoteStopped from server
    - Local cooldown to prevent spam

  The server plays animations (replicated to all clients) and handles all
  validation and interruption. This controller is purely for input.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Knit = require(Packages:WaitForChild("Knit"))
local Signal = require(Packages:WaitForChild("GoodSignal"))

local EmoteController = Knit.CreateController({
  Name = "EmoteController",
})

-- Public signal for other controllers
-- Args: (emoteId: string?, isPlaying: boolean)
EmoteController.EmoteStateChanged = Signal.new()

-- Lazy-loaded references
local EmoteService = nil
local CosmeticController = nil

-- Local state
local LocalPlayer = Players.LocalPlayer
local IsEmoting = false
local CurrentEmoteId: string? = nil
local LastRequestTime = 0
local LOCAL_COOLDOWN = 0.8 -- client-side cooldown to prevent spam

-- Keybind mapping
local EMOTE_KEYBINDS = {
  [Enum.KeyCode.One] = "emote_1",
  [Enum.KeyCode.Two] = "emote_2",
}

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Returns whether the local player is currently emoting.
  @return boolean
]]
function EmoteController:IsEmoting(): boolean
  return IsEmoting
end

--[[
  Returns the current emote ID being played, or nil.
  @return string?
]]
function EmoteController:GetCurrentEmote(): string?
  return CurrentEmoteId
end

--------------------------------------------------------------------------------
-- LIFECYCLE
--------------------------------------------------------------------------------

function EmoteController:KnitInit()
  print("[EmoteController] Initializing...")
end

function EmoteController:KnitStart()
  EmoteService = Knit.GetService("EmoteService")

  local ok, ctrl = pcall(function()
    return Knit.GetController("CosmeticController")
  end)
  if ok then
    CosmeticController = ctrl
  end

  -- Listen for emote start confirmation from server
  EmoteService.EmoteStarted:Connect(function(emoteId: string)
    IsEmoting = true
    CurrentEmoteId = emoteId
    EmoteController.EmoteStateChanged:Fire(emoteId, true)
  end)

  -- Listen for emote stop from server
  EmoteService.EmoteStopped:Connect(function()
    IsEmoting = false
    CurrentEmoteId = nil
    EmoteController.EmoteStateChanged:Fire(nil, false)
  end)

  -- Clean up state on character removal (death/respawn)
  LocalPlayer.CharacterRemoving:Connect(function()
    IsEmoting = false
    CurrentEmoteId = nil
  end)

  -- Listen for emote keybinds
  UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then
      return
    end

    local emoteSlot = EMOTE_KEYBINDS[input.KeyCode]
    if not emoteSlot then
      return
    end

    -- Local cooldown check
    local now = os.clock()
    if (now - LastRequestTime) < LOCAL_COOLDOWN then
      return
    end

    -- Check if an emote is equipped in this slot
    if CosmeticController then
      local equippedId = CosmeticController:GetEquippedInSlot(emoteSlot)
      if not equippedId then
        return
      end
    end

    LastRequestTime = now

    -- Send request to server
    EmoteService.EmoteRequest:Fire(emoteSlot)
  end)

  print("[EmoteController] Started — press 1 or 2 to play equipped emotes")
end

return EmoteController
