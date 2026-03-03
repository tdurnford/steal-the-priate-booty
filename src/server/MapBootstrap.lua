--[[
  MapBootstrap.lua
  Pre-Knit workspace object creation for MAP-001 (Harbor Zone Layout).

  Called by Main.server.lua BEFORE any Knit services are loaded.
  Creates all required workspace objects that services expect to find:
    - HarborZone Part (AABB safe zone for HarborService)
    - ShipDockPoints folder with 24 dock slot Parts (for ShipService)
    - HarborSpawn Part (tutorial/spawn waypoint for TutorialService)
    - ShopTrigger Part (gear/cosmetic shop area for TutorialService)
    - Visual pier structures and boundary markers

  All objects are created only if they don't already exist (idempotent).
  When Roblox Studio map assets are finalized (MAP-001 complete in Studio),
  this module can be removed — the Studio-placed objects will take precedence.
]]

local MapBootstrap = {}

--------------------------------------------------------------------------------
-- LAYOUT CONSTANTS
--------------------------------------------------------------------------------

-- Harbor center position (the harbor sits at the map "origin" area)
local HARBOR_CENTER = Vector3.new(0, 0, 0)

-- Harbor zone bounding box (generous safe zone)
local HARBOR_ZONE_SIZE = Vector3.new(300, 80, 200)

-- Ground level for the harbor
local GROUND_Y = 2

-- Dock configuration
local DOCK_SLOTS_PER_PIER = 6
local NUM_PIERS = 4
local PIER_SPACING = 60 -- studs between pier centers (X axis)
local SLOT_SPACING = 30 -- studs between dock slots along a pier (Z axis)
local PIER_WIDTH = 10 -- studs wide
local PIER_START_Z = -20 -- Z offset from harbor center where piers begin
local PIER_Y = 1 -- pier surface height

-- Special locations within harbor
local HARBOR_SPAWN_OFFSET = Vector3.new(0, 3, 50) -- near center, inland side
local SHOP_TRIGGER_OFFSET = Vector3.new(-60, 3, 60) -- west side of harbor

-- Visual constants
local PIER_COLOR = Color3.fromRGB(139, 90, 43) -- wood brown
local BOUNDARY_COLOR = Color3.fromRGB(200, 170, 100) -- sandy gold
local ZONE_TRANSPARENCY = 1 -- invisible zone part

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Creates a Part with common defaults if it doesn't already exist.
  @param parent The parent instance
  @param name Part name
  @param props Table of Part properties
  @return The Part (existing or newly created)
]]
local function ensurePart(
  parent: Instance,
  name: string,
  props: {
    size: Vector3?,
    position: Vector3?,
    cframe: CFrame?,
    color: Color3?,
    material: Enum.Material?,
    transparency: number?,
    anchored: boolean?,
    canCollide: boolean?,
    canQuery: boolean?,
    canTouch: boolean?,
  }
): BasePart
  local existing = parent:FindFirstChild(name)
  if existing and existing:IsA("BasePart") then
    return existing
  end

  local part = Instance.new("Part")
  part.Name = name
  part.Size = props.size or Vector3.new(4, 1, 4)
  if props.cframe then
    part.CFrame = props.cframe
  elseif props.position then
    part.Position = props.position
  end
  part.Color = props.color or Color3.fromRGB(128, 128, 128)
  part.Material = props.material or Enum.Material.SmoothPlastic
  part.Transparency = if props.transparency ~= nil then props.transparency else 0
  part.Anchored = if props.anchored ~= nil then props.anchored else true
  part.CanCollide = if props.canCollide ~= nil then props.canCollide else true
  part.CanQuery = if props.canQuery ~= nil then props.canQuery else true
  part.CanTouch = if props.canTouch ~= nil then props.canTouch else true
  part.Parent = parent
  return part
end

--[[
  Ensures a Folder exists as a child of the given parent.
  @param parent The parent instance
  @param name Folder name
  @return The Folder
]]
local function ensureFolder(parent: Instance, name: string): Folder
  local existing = parent:FindFirstChild(name)
  if existing and existing:IsA("Folder") then
    return existing
  end
  local folder = Instance.new("Folder")
  folder.Name = name
  folder.Parent = parent
  return folder
end

--------------------------------------------------------------------------------
-- HARBOR ZONE (invisible AABB boundary for HarborService)
--------------------------------------------------------------------------------

local function setupHarborZone()
  local center = HARBOR_CENTER + Vector3.new(0, HARBOR_ZONE_SIZE.Y / 2, 0)
  ensurePart(workspace, "HarborZone", {
    size = HARBOR_ZONE_SIZE,
    position = center,
    transparency = ZONE_TRANSPARENCY,
    canCollide = false,
    canQuery = false,
    canTouch = false,
  })
  print("[MapBootstrap] HarborZone created/verified:", HARBOR_ZONE_SIZE)
end

--------------------------------------------------------------------------------
-- DOCK SLOTS (ShipDockPoints for ShipService)
--------------------------------------------------------------------------------

local function setupDockSlots()
  local folder = ensureFolder(workspace, "ShipDockPoints")

  -- Check if slots already exist
  local existingSlots = 0
  for _, child in folder:GetChildren() do
    if child:IsA("BasePart") and child:GetAttribute("SlotIndex") then
      existingSlots += 1
    end
  end
  if existingSlots >= 24 then
    print("[MapBootstrap] ShipDockPoints already has", existingSlots, "slots, skipping")
    return
  end

  -- Clear any partial setup
  folder:ClearAllChildren()

  -- Calculate pier starting X position (center the pier group)
  local totalPierWidth = (NUM_PIERS - 1) * PIER_SPACING
  local startX = HARBOR_CENTER.X - totalPierWidth / 2

  local slotIndex = 0
  for pierIdx = 0, NUM_PIERS - 1 do
    local pierX = startX + pierIdx * PIER_SPACING

    for slotIdx = 0, DOCK_SLOTS_PER_PIER - 1 do
      slotIndex += 1
      local slotZ = HARBOR_CENTER.Z + PIER_START_Z - slotIdx * SLOT_SPACING
      local slotPos = Vector3.new(pierX, PIER_Y + 1, slotZ)

      local slotPart = ensurePart(folder, "DockSlot_" .. slotIndex, {
        size = Vector3.new(2, 1, 2),
        position = slotPos,
        color = Color3.fromRGB(255, 215, 0),
        material = Enum.Material.Neon,
        transparency = 0.8,
        canCollide = false,
        canQuery = false,
        canTouch = false,
      })
      slotPart:SetAttribute("SlotIndex", slotIndex)
    end
  end

  print("[MapBootstrap] Created", slotIndex, "dock slots across", NUM_PIERS, "piers")
end

--------------------------------------------------------------------------------
-- PIER VISUALS (walkable wooden piers extending from shore)
--------------------------------------------------------------------------------

local function setupPierVisuals()
  local piersFolder = ensureFolder(workspace, "HarborPiers")

  -- Check if piers already exist
  if #piersFolder:GetChildren() >= NUM_PIERS then
    print("[MapBootstrap] HarborPiers already populated, skipping")
    return
  end

  piersFolder:ClearAllChildren()

  local totalPierWidth = (NUM_PIERS - 1) * PIER_SPACING
  local startX = HARBOR_CENTER.X - totalPierWidth / 2
  local pierLength = DOCK_SLOTS_PER_PIER * SLOT_SPACING + 20 -- extra for walkway

  for pierIdx = 0, NUM_PIERS - 1 do
    local pierX = startX + pierIdx * PIER_SPACING
    local pierCenterZ = HARBOR_CENTER.Z
      + PIER_START_Z
      - (DOCK_SLOTS_PER_PIER - 1) * SLOT_SPACING / 2

    -- Main pier platform
    ensurePart(piersFolder, "Pier_" .. (pierIdx + 1), {
      size = Vector3.new(PIER_WIDTH, 1, pierLength),
      position = Vector3.new(pierX, PIER_Y, pierCenterZ),
      color = PIER_COLOR,
      material = Enum.Material.Wood,
      transparency = 0,
    })

    -- Pier posts (supports underneath)
    for postIdx = 0, 2 do
      local postZ = HARBOR_CENTER.Z + PIER_START_Z - postIdx * (pierLength / 3)
      ensurePart(piersFolder, "PierPost_" .. (pierIdx + 1) .. "_" .. (postIdx + 1), {
        size = Vector3.new(2, 6, 2),
        position = Vector3.new(pierX, PIER_Y - 3, postZ),
        color = Color3.fromRGB(100, 65, 30),
        material = Enum.Material.Wood,
        transparency = 0,
      })
    end
  end

  -- Connecting boardwalk along the shore (connects all piers)
  local boardwalkX = HARBOR_CENTER.X
  local boardwalkWidth = totalPierWidth + PIER_WIDTH + 20
  ensurePart(piersFolder, "Boardwalk", {
    size = Vector3.new(boardwalkWidth, 1, 15),
    position = Vector3.new(boardwalkX, PIER_Y, HARBOR_CENTER.Z + PIER_START_Z + 10),
    color = PIER_COLOR,
    material = Enum.Material.Wood,
    transparency = 0,
  })

  print("[MapBootstrap] Created pier visuals for", NUM_PIERS, "piers + boardwalk")
end

--------------------------------------------------------------------------------
-- HARBOR BOUNDARY MARKERS (visual indicators of safe zone edge)
--------------------------------------------------------------------------------

local function setupBoundaryMarkers()
  local markersFolder = ensureFolder(workspace, "HarborBoundaryMarkers")

  if #markersFolder:GetChildren() > 0 then
    print("[MapBootstrap] HarborBoundaryMarkers already populated, skipping")
    return
  end

  -- Place marker posts at the corners and midpoints of the harbor zone
  local halfX = HARBOR_ZONE_SIZE.X / 2
  local halfZ = HARBOR_ZONE_SIZE.Z / 2
  local markerPositions = {
    -- Corners
    { x = halfX, z = halfZ, name = "NE" },
    { x = -halfX, z = halfZ, name = "NW" },
    { x = halfX, z = -halfZ, name = "SE" },
    { x = -halfX, z = -halfZ, name = "SW" },
    -- Midpoints of each edge
    { x = 0, z = halfZ, name = "N" },
    { x = 0, z = -halfZ, name = "S" },
    { x = halfX, z = 0, name = "E" },
    { x = -halfX, z = 0, name = "W" },
  }

  for _, marker in markerPositions do
    local pos = HARBOR_CENTER + Vector3.new(marker.x, GROUND_Y, marker.z)

    -- Tall post
    local post = ensurePart(markersFolder, "Marker_" .. marker.name, {
      size = Vector3.new(2, 12, 2),
      position = pos + Vector3.new(0, 6, 0),
      color = BOUNDARY_COLOR,
      material = Enum.Material.Wood,
      transparency = 0,
    })

    -- Lantern on top
    local lantern = Instance.new("PointLight")
    lantern.Name = "Lantern"
    lantern.Color = Color3.fromRGB(255, 200, 100)
    lantern.Brightness = 1
    lantern.Range = 20
    lantern.Parent = post
  end

  print("[MapBootstrap] Created", #markerPositions, "boundary markers")
end

--------------------------------------------------------------------------------
-- SPECIAL LOCATIONS (HarborSpawn, ShopTrigger)
--------------------------------------------------------------------------------

local function setupSpecialLocations()
  -- HarborSpawn — where players arrive (tutorial step 6-7 target, general respawn)
  local spawnPos = HARBOR_CENTER + HARBOR_SPAWN_OFFSET
  local spawnPart = ensurePart(workspace, "HarborSpawn", {
    size = Vector3.new(8, 1, 8),
    position = spawnPos,
    color = Color3.fromRGB(100, 200, 255),
    material = Enum.Material.Neon,
    transparency = 0.7,
    canCollide = false,
    canQuery = false,
    canTouch = false,
  })
  -- Orient toward the docks (facing -Z toward the piers)
  spawnPart.CFrame = CFrame.new(spawnPos, spawnPos + Vector3.new(0, 0, -1))
  print("[MapBootstrap] HarborSpawn at", spawnPos)

  -- ShopTrigger — shop area for gear/cosmetic purchases
  local shopPos = HARBOR_CENTER + SHOP_TRIGGER_OFFSET
  ensurePart(workspace, "ShopTrigger", {
    size = Vector3.new(20, 10, 20),
    position = shopPos,
    color = Color3.fromRGB(255, 215, 0),
    material = Enum.Material.Neon,
    transparency = 0.9,
    canCollide = false,
    canQuery = false,
    canTouch = false,
  })

  -- Shop building placeholder (a small structure)
  local shopFolder = ensureFolder(workspace, "ShopBuilding")
  if #shopFolder:GetChildren() == 0 then
    -- Floor
    ensurePart(shopFolder, "ShopFloor", {
      size = Vector3.new(18, 1, 18),
      position = shopPos + Vector3.new(0, -4, 0),
      color = PIER_COLOR,
      material = Enum.Material.Wood,
    })
    -- Back wall
    ensurePart(shopFolder, "ShopWall", {
      size = Vector3.new(18, 8, 1),
      position = shopPos + Vector3.new(0, 0, -9),
      color = Color3.fromRGB(160, 120, 70),
      material = Enum.Material.Wood,
    })
    -- Counter
    ensurePart(shopFolder, "ShopCounter", {
      size = Vector3.new(12, 3, 2),
      position = shopPos + Vector3.new(0, -2.5, -4),
      color = Color3.fromRGB(120, 80, 40),
      material = Enum.Material.Wood,
    })
    -- Sign above counter
    local sign = ensurePart(shopFolder, "ShopSign", {
      size = Vector3.new(10, 2, 0.5),
      position = shopPos + Vector3.new(0, 3, -8.5),
      color = Color3.fromRGB(30, 30, 30),
      material = Enum.Material.SmoothPlastic,
    })
    -- Add a SurfaceGui with shop name
    local surfaceGui = Instance.new("SurfaceGui")
    surfaceGui.Name = "SignGui"
    surfaceGui.Face = Enum.NormalId.Front
    surfaceGui.Parent = sign

    local label = Instance.new("TextLabel")
    label.Name = "ShopLabel"
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Text = "PIRATE OUTFITTER"
    label.TextColor3 = Color3.fromRGB(255, 215, 0)
    label.TextScaled = true
    label.Font = Enum.Font.GothamBold
    label.Parent = surfaceGui
  end
  print("[MapBootstrap] ShopTrigger at", shopPos)
end

--------------------------------------------------------------------------------
-- HARBOR GROUND (basic ground platform for the harbor area)
--------------------------------------------------------------------------------

local function setupHarborGround()
  local groundFolder = ensureFolder(workspace, "HarborGround")

  if #groundFolder:GetChildren() > 0 then
    print("[MapBootstrap] HarborGround already populated, skipping")
    return
  end

  -- Main harbor ground (cobblestone/stone dock area)
  ensurePart(groundFolder, "MainGround", {
    size = Vector3.new(HARBOR_ZONE_SIZE.X - 20, 2, HARBOR_ZONE_SIZE.Z * 0.4),
    position = HARBOR_CENTER + Vector3.new(0, GROUND_Y - 1, HARBOR_ZONE_SIZE.Z * 0.2),
    color = Color3.fromRGB(150, 140, 130),
    material = Enum.Material.Cobblestone,
  })

  -- Sandy shore area (transition between land and docks)
  ensurePart(groundFolder, "Shore", {
    size = Vector3.new(HARBOR_ZONE_SIZE.X - 20, 1, 30),
    position = HARBOR_CENTER + Vector3.new(0, GROUND_Y - 1.5, PIER_START_Z + 15),
    color = Color3.fromRGB(210, 190, 140),
    material = Enum.Material.Sand,
  })

  print("[MapBootstrap] Created harbor ground surfaces")
end

--------------------------------------------------------------------------------
-- TORCHES (light sources for DayNightLightingController)
--------------------------------------------------------------------------------

local function setupTorches()
  local torchesFolder = ensureFolder(workspace, "Torches")

  if #torchesFolder:GetChildren() > 0 then
    print("[MapBootstrap] Torches already populated, skipping")
    return
  end

  -- Place torches along the boardwalk and at key locations
  local torchPositions = {
    HARBOR_CENTER + Vector3.new(-80, GROUND_Y + 6, PIER_START_Z + 10),
    HARBOR_CENTER + Vector3.new(-40, GROUND_Y + 6, PIER_START_Z + 10),
    HARBOR_CENTER + Vector3.new(0, GROUND_Y + 6, PIER_START_Z + 10),
    HARBOR_CENTER + Vector3.new(40, GROUND_Y + 6, PIER_START_Z + 10),
    HARBOR_CENTER + Vector3.new(80, GROUND_Y + 6, PIER_START_Z + 10),
    -- Near shop
    HARBOR_CENTER
      + SHOP_TRIGGER_OFFSET
      + Vector3.new(-10, 4, 0),
    HARBOR_CENTER + SHOP_TRIGGER_OFFSET + Vector3.new(10, 4, 0),
    -- Near harbor spawn
    HARBOR_CENTER
      + HARBOR_SPAWN_OFFSET
      + Vector3.new(-8, 4, 0),
    HARBOR_CENTER + HARBOR_SPAWN_OFFSET + Vector3.new(8, 4, 0),
  }

  for i, pos in torchPositions do
    -- Torch post
    local post = ensurePart(torchesFolder, "Torch_" .. i, {
      size = Vector3.new(1, 8, 1),
      position = pos,
      color = Color3.fromRGB(80, 50, 25),
      material = Enum.Material.Wood,
    })

    -- Flame light
    local light = Instance.new("PointLight")
    light.Name = "TorchLight"
    light.Color = Color3.fromRGB(255, 180, 80)
    light.Brightness = 1.5
    light.Range = 30
    light.Parent = post

    -- Fire effect
    local fire = Instance.new("Fire")
    fire.Size = 3
    fire.Heat = 5
    fire.Color = Color3.fromRGB(255, 150, 50)
    fire.SecondaryColor = Color3.fromRGB(255, 80, 20)
    fire.Parent = post
  end

  print("[MapBootstrap] Created", #torchPositions, "torches")
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Sets up all Harbor zone workspace objects.
  Called from Main.server.lua before Knit services are loaded.
  Idempotent — safe to call multiple times.
]]
function MapBootstrap.setup()
  print("[MapBootstrap] Setting up Harbor zone layout (MAP-001)...")

  setupHarborZone()
  setupDockSlots()
  setupPierVisuals()
  setupBoundaryMarkers()
  setupSpecialLocations()
  setupHarborGround()
  setupTorches()

  print("[MapBootstrap] Harbor zone setup complete")
end

return MapBootstrap
