--[[
  MinimapController.lua
  Client-side Knit controller that manages the minimap HUD element (UI-005).

  Displays a circular minimap in the bottom-left corner showing:
    - Local player centered with direction arrow (up = forward)
    - Other players as white dots
    - NPCs as red dots (skeletons, phantom captains)
    - Ghost Pirates as faint red flickers only within 20 studs
    - Bounty target as skull icon (clamped to edge if out of range)
    - Active event locations as gold star marker (clamped to edge)
    - Own ship as cyan anchor icon (clamped to edge)

  The minimap rotates relative to the player's facing direction.
  M keybind toggles visibility.

  Depends on: BountyController, EventController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Knit = require(Packages:WaitForChild("Knit"))
local Fusion = require(Packages:WaitForChild("Fusion"))

local UIFolder = script.Parent.Parent:WaitForChild("UI")
local MinimapPanel = require(UIFolder:WaitForChild("MinimapPanel"))

local MinimapController = Knit.CreateController({
  Name = "MinimapController",
})

--------------------------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------------------------

local LocalPlayer = Players.LocalPlayer

local MAP_SIZE = 160
local MAP_HALF = MAP_SIZE / 2
local MAP_RANGE = 150 -- studs radius visible on minimap
local DOT_SIZE = 6
local LARGE_DOT_SIZE = 8
local ICON_SIZE = 12
local UPDATE_INTERVAL = 0.1 -- seconds between minimap refreshes
local GHOST_PIRATE_RANGE = 20 -- studs; ghost pirates only visible within this

-- Dot/icon colors
local COLOR_PLAYER = Color3.fromRGB(255, 255, 255)
local COLOR_SKELETON = Color3.fromRGB(255, 60, 60)
local COLOR_GHOST_PIRATE = Color3.fromRGB(255, 80, 80)
local COLOR_PHANTOM = Color3.fromRGB(200, 50, 255)
local COLOR_BOUNTY = Color3.fromRGB(255, 200, 50)
local COLOR_EVENT = Color3.fromRGB(255, 200, 50)
local COLOR_SHIP = Color3.fromRGB(100, 200, 255)

--------------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------------

local BountyController = nil
local EventController = nil

local FusionScope = nil
local IsVisible = nil -- Fusion.Value<boolean>
local ScreenGui = nil
local DotsContainer = nil
local TimeSinceUpdate = 0
local UpdateCounter = 0

-- Active dot instances: entityId -> { instance: Instance, lastSeen: number }
local ActiveDots = {}

--------------------------------------------------------------------------------
-- DOT MANAGEMENT
--------------------------------------------------------------------------------

--[[
  Creates a dot (circle frame) or icon (text label) instance for an entity.
  @param entityId string Unique entity identifier
  @param color Color3 Dot color
  @param size number Dot diameter in pixels
  @param isIcon boolean If true, creates a TextLabel with icon text
  @param iconText string? Icon character (required when isIcon is true)
  @return Instance
]]
local function createDotInstance(entityId, color, size, isIcon, iconText)
  if isIcon then
    local label = Instance.new("TextLabel")
    label.Name = entityId
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Size = UDim2.new(0, size, 0, size)
    label.BackgroundTransparency = 1
    label.Text = iconText or "?"
    label.TextColor3 = color
    label.TextSize = size
    label.Font = Enum.Font.GothamBold
    label.ZIndex = 5

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(0, 0, 0)
    stroke.Thickness = 1
    stroke.Transparency = 0.3
    stroke.Parent = label

    label.Parent = DotsContainer
    return label
  else
    local dot = Instance.new("Frame")
    dot.Name = entityId
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.Size = UDim2.new(0, size, 0, size)
    dot.BackgroundColor3 = color
    dot.BorderSizePixel = 0
    dot.ZIndex = 3

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = dot

    dot.Parent = DotsContainer
    return dot
  end
end

--[[
  Gets or creates a dot instance for the given entity.
  Marks it as "seen" this update so stale cleanup won't remove it.
]]
local function getOrCreateDot(entityId, color, size, isIcon, iconText)
  local entry = ActiveDots[entityId]
  if entry then
    entry.lastSeen = UpdateCounter
    return entry.instance
  end

  local instance = createDotInstance(entityId, color, size, isIcon, iconText)
  ActiveDots[entityId] = { instance = instance, lastSeen = UpdateCounter }
  return instance
end

--[[
  Destroys dot instances that were not seen during the current update.
]]
local function cleanupStaleDots()
  for id, entry in pairs(ActiveDots) do
    if entry.lastSeen ~= UpdateCounter then
      entry.instance:Destroy()
      ActiveDots[id] = nil
    end
  end
end

--[[
  Destroys all active dot instances.
]]
local function clearAllDots()
  for id, entry in pairs(ActiveDots) do
    entry.instance:Destroy()
    ActiveDots[id] = nil
  end
end

--------------------------------------------------------------------------------
-- COORDINATE TRANSFORM
--------------------------------------------------------------------------------

--[[
  Converts a world position to minimap pixel offset from center.
  Uses the player's CFrame to rotate so "up" = player's forward.
  Returns nil, nil if the entity is outside the map range.
  @param entityPos Vector3
  @param playerCFrame CFrame
  @return number? offsetX, number? offsetY
]]
local function worldToMinimap(entityPos, playerCFrame)
  local rel = playerCFrame:PointToObjectSpace(entityPos)
  -- Object space: X = right, Z = behind (negative Z = forward)
  -- Minimap: X offset = right, Y offset = down (forward = up = negative Y)
  local mx = rel.X * (MAP_HALF / MAP_RANGE)
  local my = rel.Z * (MAP_HALF / MAP_RANGE)

  local distSq = mx * mx + my * my
  local maxDist = MAP_HALF - DOT_SIZE
  if distSq > maxDist * maxDist then
    return nil, nil
  end

  return mx, my
end

--[[
  Like worldToMinimap but clamps to the circle edge instead of returning nil.
  Used for important entities (ship, events, bounty) that should always be visible.
  @return number offsetX, number offsetY, boolean wasClamped
]]
local function worldToMinimapClamped(entityPos, playerCFrame)
  local rel = playerCFrame:PointToObjectSpace(entityPos)
  local mx = rel.X * (MAP_HALF / MAP_RANGE)
  local my = rel.Z * (MAP_HALF / MAP_RANGE)

  local dist = math.sqrt(mx * mx + my * my)
  local maxDist = MAP_HALF - ICON_SIZE

  if dist > maxDist and dist > 0 then
    local scale = maxDist / dist
    return mx * scale, my * scale, true
  end

  return mx, my, false
end

--------------------------------------------------------------------------------
-- NPC TYPE DETECTION
--------------------------------------------------------------------------------

--[[
  Determines the NPC type from the model name prefix.
  @param npcModel Model
  @return string "skeleton" | "ghost_pirate" | "phantom_captain"
]]
local function getNPCType(npcModel)
  local name = npcModel.Name
  if string.find(name, "^GhostPirate_") then
    return "ghost_pirate"
  elseif string.find(name, "^PhantomCaptain_") then
    return "phantom_captain"
  end
  return "skeleton"
end

--------------------------------------------------------------------------------
-- UPDATE LOOP
--------------------------------------------------------------------------------

--[[
  Main minimap update function. Called on Heartbeat, throttled to UPDATE_INTERVAL.
]]
local function onUpdate(dt)
  TimeSinceUpdate = TimeSinceUpdate + dt
  if TimeSinceUpdate < UPDATE_INTERVAL then
    return
  end
  TimeSinceUpdate = 0
  UpdateCounter = UpdateCounter + 1

  -- Get local player position and orientation
  local character = LocalPlayer.Character
  if not character then
    clearAllDots()
    return
  end
  local hrp = character:FindFirstChild("HumanoidRootPart")
  if not hrp then
    clearAllDots()
    return
  end
  local playerCFrame = hrp.CFrame
  local playerPos = playerCFrame.Position

  -- Bounty target userId (0 if no bounty)
  local bountyUserId = 0
  if BountyController and BountyController:IsBountyActive() then
    bountyUserId = BountyController:GetBountyTargetUserId()
  end

  -- 1. Other players
  for _, player in Players:GetPlayers() do
    if player ~= LocalPlayer then
      local pChar = player.Character
      local pHrp = pChar and pChar:FindFirstChild("HumanoidRootPart")
      if pHrp then
        if player.UserId == bountyUserId then
          -- Bounty target: skull icon, clamped to edge if out of range
          local dot =
            getOrCreateDot("b_" .. player.UserId, COLOR_BOUNTY, ICON_SIZE, true, "\u{1F480}")
          local mx, my, clamped = worldToMinimapClamped(pHrp.Position, playerCFrame)
          dot.Position = UDim2.new(0.5, mx, 0.5, my)
          dot.Visible = true
          dot.TextTransparency = if clamped then 0.3 else 0
        else
          -- Normal player: white dot
          local dot = getOrCreateDot("p_" .. player.UserId, COLOR_PLAYER, DOT_SIZE, false)
          local mx, my = worldToMinimap(pHrp.Position, playerCFrame)
          if mx then
            dot.Position = UDim2.new(0.5, mx, 0.5, my)
            dot.Visible = true
          else
            dot.Visible = false
          end
        end
      end
    end
  end

  -- 2. NPCs
  local npcsFolder = workspace:FindFirstChild("NPCs")
  if npcsFolder then
    for _, npcModel in npcsFolder:GetChildren() do
      local npcHrp = npcModel:FindFirstChild("HumanoidRootPart")
      if npcHrp then
        local npcType = getNPCType(npcModel)
        local entityId = "n_" .. npcModel.Name
        local npcPos = npcHrp.Position

        if npcType == "ghost_pirate" then
          -- Only visible within 20 studs, with flicker effect
          local dist = (npcPos - playerPos).Magnitude
          if dist <= GHOST_PIRATE_RANGE then
            local dot = getOrCreateDot(entityId, COLOR_GHOST_PIRATE, DOT_SIZE - 1, false)
            local mx, my = worldToMinimap(npcPos, playerCFrame)
            -- Sine-based flicker: visible ~60% of the time
            local flicker = math.sin(tick() * 8) > -0.2
            if mx and flicker then
              dot.Position = UDim2.new(0.5, mx, 0.5, my)
              dot.Visible = true
              dot.BackgroundTransparency = 0.3
            else
              dot.Visible = false
            end
          end
          -- Outside 20 studs: no dot created, stale cleanup handles removal
        elseif npcType == "phantom_captain" then
          local dot = getOrCreateDot(entityId, COLOR_PHANTOM, LARGE_DOT_SIZE, false)
          local mx, my = worldToMinimap(npcPos, playerCFrame)
          if mx then
            dot.Position = UDim2.new(0.5, mx, 0.5, my)
            dot.Visible = true
          else
            dot.Visible = false
          end
        else
          -- Standard skeleton: red dot
          local dot = getOrCreateDot(entityId, COLOR_SKELETON, DOT_SIZE, false)
          local mx, my = worldToMinimap(npcPos, playerCFrame)
          if mx then
            dot.Position = UDim2.new(0.5, mx, 0.5, my)
            dot.Visible = true
          else
            dot.Visible = false
          end
        end
      end
    end
  end

  -- 3. Own ship (anchor icon, clamped to edge if out of range)
  local shipsFolder = workspace:FindFirstChild("DockedShips")
  if shipsFolder then
    for _, shipModel in shipsFolder:GetChildren() do
      local hull = shipModel:FindFirstChild("Hull")
      if hull and hull:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
        local dot = getOrCreateDot("ship", COLOR_SHIP, ICON_SIZE, true, "\u{2693}")
        local mx, my, clamped = worldToMinimapClamped(hull.Position, playerCFrame)
        dot.Position = UDim2.new(0.5, mx, 0.5, my)
        dot.Visible = true
        dot.TextTransparency = if clamped then 0.3 else 0
        break
      end
    end
  end

  -- 4. Active world event (gold star, clamped to edge if out of range)
  if EventController and EventController:IsEventActive() then
    local eventPos = EventController:GetActiveEventPosition()
    if eventPos then
      local dot = getOrCreateDot("event", COLOR_EVENT, ICON_SIZE, true, "\u{2B50}")
      local mx, my, clamped = worldToMinimapClamped(eventPos, playerCFrame)
      dot.Position = UDim2.new(0.5, mx, 0.5, my)
      dot.Visible = true
      dot.TextTransparency = if clamped then 0.3 else 0
    end
  end

  -- Clean up dots for entities that no longer exist
  cleanupStaleDots()
end

--------------------------------------------------------------------------------
-- KEYBIND
--------------------------------------------------------------------------------

--[[
  Toggles minimap visibility on M key press.
]]
local function onInputBegan(input, gameProcessed)
  if gameProcessed then
    return
  end
  if input.KeyCode == Enum.KeyCode.M then
    if IsVisible then
      local current = Fusion.peek(IsVisible)
      IsVisible:set(not current)
    end
  end
end

--------------------------------------------------------------------------------
-- KNIT LIFECYCLE
--------------------------------------------------------------------------------

function MinimapController:KnitInit()
  -- Create Fusion scope and mount minimap UI
  FusionScope = Fusion.scoped(Fusion)
  IsVisible = FusionScope:Value(true) -- visible by default

  ScreenGui = Instance.new("ScreenGui")
  ScreenGui.Name = "MinimapGui"
  ScreenGui.DisplayOrder = 15
  ScreenGui.ResetOnSpawn = false
  ScreenGui.IgnoreGuiInset = true
  ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

  local container, dotsFrame = MinimapPanel.create(FusionScope, IsVisible)
  container.Parent = ScreenGui
  DotsContainer = dotsFrame

  print("[MinimapController] Initialized")
end

function MinimapController:KnitStart()
  BountyController = Knit.GetController("BountyController")
  EventController = Knit.GetController("EventController")

  -- Start update loop
  RunService.Heartbeat:Connect(onUpdate)

  -- Keybind
  UserInputService.InputBegan:Connect(onInputBegan)

  print("[MinimapController] Started")
end

--[[
  Returns whether the minimap is currently visible.
  @return boolean
]]
function MinimapController:IsMinimapVisible(): boolean
  if IsVisible then
    return Fusion.peek(IsVisible)
  end
  return false
end

--[[
  Sets the minimap visibility.
  @param visible boolean
]]
function MinimapController:SetVisible(visible: boolean)
  if IsVisible then
    IsVisible:set(visible)
  end
end

return MinimapController
