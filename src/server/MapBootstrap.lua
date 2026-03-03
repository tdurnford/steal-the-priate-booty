--[[
  MapBootstrap.lua
  Pre-Knit workspace object creation for MAP-001 (Harbor Zone Layout),
  MAP-002 (Tutorial Beach Area), MAP-003 (NPC Spawn Zone Definitions),
  MAP-004 (Container Spawn Point Placement), and MAP-005 (Hazard Placement).

  Called by Main.server.lua BEFORE any Knit services are loaded.
  Creates all required workspace objects that services expect to find:
    - HarborZone Part (AABB safe zone for HarborService)
    - ShipDockPoints folder with 24 dock slot Parts (for ShipService)
    - HarborSpawn Part (tutorial/spawn waypoint for TutorialService)
    - ShopTrigger Part (gear/cosmetic shop area for TutorialService)
    - Visual pier structures and boundary markers
    - TutorialBeach Part (spawn + orientation for TutorialService)
    - Beach terrain, shipwreck debris, path to Harbor
    - DangerZones folder with AABB Parts (for DangerZoneService)
    - NPCSpawnPoints folder with zone+type spawn markers (for NPCService)
    - PatrolWaypoints folder with ordered zone waypoints (for NPCService)
    - ContainerSpawnPoints folder with zone-tagged markers (for ContainerService)
    - VolcanicVents folder with vent Parts (for VolcanicVentService)
    - QuicksandPatches folder with patch Parts (for QuicksandService)
    - TidalSurgeZones folder with zone Parts (for TidalSurgeService)
    - RogueWaveZones folder with zone Parts (for RogueWaveService)

  All objects are created only if they don't already exist (idempotent).
  When Roblox Studio map assets are finalized, this module can be removed
  — the Studio-placed objects will take precedence.
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
-- TUTORIAL BEACH CONSTANTS (MAP-002)
--------------------------------------------------------------------------------

-- Beach position — southeast of harbor, matches TutorialService DEFAULT_TUTORIAL_POSITION
local BEACH_CENTER = Vector3.new(200, 2, 200)

-- Beach dimensions
local BEACH_SIZE = Vector3.new(80, 1, 60) -- main sandy area
local BEACH_WATER_DEPTH = -2 -- Y offset for water line

-- The TutorialBeach part faces toward the harbor so TutorialService's
-- CFrame.LookVector points from spawn toward driftwood/crate/harbor
local BEACH_LOOK_TARGET = HARBOR_CENTER

-- Shipwreck debris offset from beach center (washed ashore, at water's edge)
local WRECK_OFFSET = Vector3.new(15, -1, 20)

-- Path from beach to harbor: we place a series of ground patches
local PATH_WIDTH = 8
local PATH_SEGMENT_COUNT = 6 -- ground segments between beach and harbor

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
-- TUTORIAL BEACH SPAWN MARKER (MAP-002)
--------------------------------------------------------------------------------

--[[
  Creates the TutorialBeach Part that TutorialService uses to determine:
    - Spawn position (Part.Position + 0,3,0)
    - Forward direction (Part.CFrame.LookVector → toward driftwood/harbor)
  Also creates the TutorialSkeletonSpawn marker near the crate area.
]]
local function setupTutorialBeach()
  -- TutorialBeach marker — invisible Part with oriented CFrame
  local beachPos = BEACH_CENTER + Vector3.new(0, 3, 0) -- slightly above ground
  local lookTarget = Vector3.new(BEACH_LOOK_TARGET.X, beachPos.Y, BEACH_LOOK_TARGET.Z)

  local beachPart = ensurePart(workspace, "TutorialBeach", {
    size = Vector3.new(8, 1, 8),
    transparency = ZONE_TRANSPARENCY,
    canCollide = false,
    canQuery = false,
    canTouch = false,
  })
  -- Set CFrame so LookVector points toward harbor
  beachPart.CFrame = CFrame.new(beachPos, lookTarget)

  -- TutorialSkeletonSpawn — marker for where the tutorial skeleton appears
  -- Positioned ~20 studs forward and 5 studs to the side from spawn
  -- (matches TutorialService's skeleton spawn: forward * 20 + Vector3.new(5, 0, 0))
  local forward = (lookTarget - beachPos).Unit
  local skeletonPos = beachPos + forward * 20 + Vector3.new(5, 0, -2)
  ensurePart(workspace, "TutorialSkeletonSpawn", {
    size = Vector3.new(4, 1, 4),
    position = skeletonPos,
    transparency = ZONE_TRANSPARENCY,
    canCollide = false,
    canQuery = false,
    canTouch = false,
  })

  print("[MapBootstrap] TutorialBeach at", beachPos, "facing harbor")
end

--------------------------------------------------------------------------------
-- TUTORIAL BEACH TERRAIN (MAP-002)
--------------------------------------------------------------------------------

--[[
  Creates the physical beach environment: sand ground, water edge, rocks,
  shipwreck debris, and atmospheric props. All visible to other players.
]]
local function setupBeachTerrain()
  local beachFolder = ensureFolder(workspace, "TutorialBeachArea")

  if #beachFolder:GetChildren() > 0 then
    print("[MapBootstrap] TutorialBeachArea already populated, skipping")
    return
  end

  -- Main sandy beach ground
  ensurePart(beachFolder, "BeachSand", {
    size = BEACH_SIZE,
    position = BEACH_CENTER,
    color = Color3.fromRGB(230, 210, 160),
    material = Enum.Material.Sand,
  })

  -- Wet sand near water's edge (darker, closer to water)
  ensurePart(beachFolder, "WetSand", {
    size = Vector3.new(BEACH_SIZE.X, 0.5, 15),
    position = BEACH_CENTER + Vector3.new(0, -0.3, BEACH_SIZE.Z / 2 - 5),
    color = Color3.fromRGB(180, 160, 120),
    material = Enum.Material.Sand,
  })

  -- Shallow water plane at the beach edge
  local waterPart = ensurePart(beachFolder, "ShallowWater", {
    size = Vector3.new(BEACH_SIZE.X + 40, 1, 30),
    position = BEACH_CENTER + Vector3.new(0, BEACH_WATER_DEPTH, BEACH_SIZE.Z / 2 + 10),
    color = Color3.fromRGB(30, 120, 180),
    material = Enum.Material.Water,
    transparency = 0.3,
    canCollide = false,
  })
  -- Water doesn't need query/touch
  waterPart.CanQuery = false
  waterPart.CanTouch = false

  -- Grassy area behind the beach (transition to island interior)
  ensurePart(beachFolder, "BeachGrass", {
    size = Vector3.new(BEACH_SIZE.X - 10, 1, 25),
    position = BEACH_CENTER + Vector3.new(0, 0.3, -BEACH_SIZE.Z / 2 - 10),
    color = Color3.fromRGB(80, 140, 50),
    material = Enum.Material.Grass,
  })

  -- Rocky outcrop on the east side of the beach
  ensurePart(beachFolder, "Rock_1", {
    size = Vector3.new(8, 5, 6),
    position = BEACH_CENTER + Vector3.new(35, 2, 10),
    color = Color3.fromRGB(100, 95, 85),
    material = Enum.Material.Slate,
  })
  ensurePart(beachFolder, "Rock_2", {
    size = Vector3.new(5, 3, 4),
    position = BEACH_CENTER + Vector3.new(32, 1, 5),
    color = Color3.fromRGB(90, 85, 75),
    material = Enum.Material.Slate,
  })

  -- Rocks on the west side
  ensurePart(beachFolder, "Rock_3", {
    size = Vector3.new(6, 4, 5),
    position = BEACH_CENTER + Vector3.new(-33, 1.5, 15),
    color = Color3.fromRGB(95, 90, 80),
    material = Enum.Material.Slate,
  })

  -- Palm tree trunks (simple cylinders) — 3 palm trees
  local palmPositions = {
    BEACH_CENTER + Vector3.new(-20, 0, -15),
    BEACH_CENTER + Vector3.new(15, 0, -20),
    BEACH_CENTER + Vector3.new(-10, 0, -25),
  }
  for i, palmPos in palmPositions do
    -- Trunk
    ensurePart(beachFolder, "PalmTrunk_" .. i, {
      size = Vector3.new(2, 14, 2),
      cframe = CFrame.new(palmPos + Vector3.new(0, 7, 0))
        * CFrame.Angles(0, 0, math.rad(5 * (i % 2 == 0 and 1 or -1))),
      color = Color3.fromRGB(120, 85, 40),
      material = Enum.Material.Wood,
    })
    -- Canopy (flattened sphere)
    ensurePart(beachFolder, "PalmCanopy_" .. i, {
      size = Vector3.new(10, 3, 10),
      position = palmPos + Vector3.new(0, 15, 0),
      color = Color3.fromRGB(40, 120, 30),
      material = Enum.Material.Grass,
      canCollide = false,
    })
  end

  print("[MapBootstrap] Created tutorial beach terrain")
end

--------------------------------------------------------------------------------
-- SHIPWRECK DEBRIS (MAP-002)
--------------------------------------------------------------------------------

--[[
  Creates shipwreck debris props at the water's edge of the tutorial beach.
  Sells the "washed ashore" narrative for new players.
]]
local function setupShipwreckDebris()
  local debrisFolder = ensureFolder(workspace, "TutorialShipwreck")

  if #debrisFolder:GetChildren() > 0 then
    print("[MapBootstrap] TutorialShipwreck already populated, skipping")
    return
  end

  local wreckPos = BEACH_CENTER + WRECK_OFFSET

  -- Broken hull section (the main wreck piece, half-submerged)
  ensurePart(debrisFolder, "BrokenHull", {
    size = Vector3.new(12, 5, 20),
    cframe = CFrame.new(wreckPos + Vector3.new(0, 1, 0))
      * CFrame.Angles(0, math.rad(35), math.rad(15)),
    color = Color3.fromRGB(80, 55, 30),
    material = Enum.Material.Wood,
  })

  -- Broken mast lying on the sand
  ensurePart(debrisFolder, "BrokenMast", {
    size = Vector3.new(1.5, 1.5, 18),
    cframe = CFrame.new(wreckPos + Vector3.new(-8, 0.5, -5))
      * CFrame.Angles(0, math.rad(60), math.rad(5)),
    color = Color3.fromRGB(100, 70, 35),
    material = Enum.Material.Wood,
  })

  -- Torn sail (flat fabric)
  ensurePart(debrisFolder, "TornSail", {
    size = Vector3.new(8, 0.2, 6),
    cframe = CFrame.new(wreckPos + Vector3.new(-5, 0.3, -8))
      * CFrame.Angles(0, math.rad(20), math.rad(3)),
    color = Color3.fromRGB(200, 185, 150),
    material = Enum.Material.Fabric,
    canCollide = false,
  })

  -- Scattered planks
  local plankOffsets = {
    { x = -12, z = -3, rot = 45 },
    { x = 5, z = -10, rot = -20 },
    { x = -3, z = 8, rot = 70 },
    { x = 10, z = 5, rot = -55 },
    { x = -8, z = 12, rot = 10 },
  }
  for i, plank in plankOffsets do
    ensurePart(debrisFolder, "Plank_" .. i, {
      size = Vector3.new(0.5, 0.3, 4),
      cframe = CFrame.new(wreckPos + Vector3.new(plank.x, 0.2, plank.z))
        * CFrame.Angles(0, math.rad(plank.rot), 0),
      color = Color3.fromRGB(110, 75, 35),
      material = Enum.Material.Wood,
      canCollide = false,
    })
  end

  -- Rope coil
  ensurePart(debrisFolder, "RopeCoil", {
    size = Vector3.new(2, 0.5, 2),
    position = wreckPos + Vector3.new(-6, 0.3, 3),
    color = Color3.fromRGB(160, 140, 90),
    material = Enum.Material.Fabric,
    canCollide = false,
  })

  print("[MapBootstrap] Created shipwreck debris at tutorial beach")
end

--------------------------------------------------------------------------------
-- BEACH-TO-HARBOR PATH (MAP-002)
--------------------------------------------------------------------------------

--[[
  Creates a visible dirt/grass path from the tutorial beach to the harbor.
  Players follow this path during step 6 of the tutorial (with compass).
  Torches along the path provide night visibility.
]]
local function setupBeachToHarborPath()
  local pathFolder = ensureFolder(workspace, "TutorialPath")

  if #pathFolder:GetChildren() > 0 then
    print("[MapBootstrap] TutorialPath already populated, skipping")
    return
  end

  local startPos = BEACH_CENTER + Vector3.new(0, 0, -BEACH_SIZE.Z / 2 - 10)
  local endPos = HARBOR_CENTER + Vector3.new(0, GROUND_Y, HARBOR_ZONE_SIZE.Z / 2)

  -- Create path ground segments (lerp from beach to harbor)
  for i = 0, PATH_SEGMENT_COUNT - 1 do
    local t = i / PATH_SEGMENT_COUNT
    local segPos = startPos:Lerp(endPos, t + 0.5 / PATH_SEGMENT_COUNT)
    -- Add slight natural curve offset
    local curveOffset = math.sin(t * math.pi) * 15
    segPos = segPos + Vector3.new(curveOffset, 0, 0)

    -- Alternate dirt and grass for natural look
    local isDirt = i % 2 == 0
    ensurePart(pathFolder, "PathSeg_" .. (i + 1), {
      size = Vector3.new(PATH_WIDTH, 0.5, (endPos - startPos).Magnitude / PATH_SEGMENT_COUNT + 4),
      position = segPos,
      color = isDirt and Color3.fromRGB(140, 110, 60) or Color3.fromRGB(90, 130, 55),
      material = isDirt and Enum.Material.Ground or Enum.Material.Grass,
    })
  end

  -- Torches along the path (one per 2 segments, alternating sides)
  local torchesFolder = ensureFolder(workspace, "Torches")
  local pathTorchCount = math.floor(PATH_SEGMENT_COUNT / 2)
  for i = 1, pathTorchCount do
    local t = i / (pathTorchCount + 1)
    local torchPos = startPos:Lerp(endPos, t)
    local curveOffset = math.sin(t * math.pi) * 15
    -- Alternate sides
    local side = (i % 2 == 0) and 1 or -1
    torchPos = torchPos + Vector3.new(curveOffset + side * (PATH_WIDTH / 2 + 3), 0, 0)

    local post = ensurePart(torchesFolder, "PathTorch_" .. i, {
      size = Vector3.new(1, 8, 1),
      position = torchPos + Vector3.new(0, 4, 0),
      color = Color3.fromRGB(80, 50, 25),
      material = Enum.Material.Wood,
    })

    local light = Instance.new("PointLight")
    light.Name = "TorchLight"
    light.Color = Color3.fromRGB(255, 180, 80)
    light.Brightness = 1.5
    light.Range = 25
    light.Parent = post

    local fire = Instance.new("Fire")
    fire.Size = 3
    fire.Heat = 5
    fire.Color = Color3.fromRGB(255, 150, 50)
    fire.SecondaryColor = Color3.fromRGB(255, 80, 20)
    fire.Parent = post
  end

  -- Simple signpost at the start of the path pointing to Harbor
  local signPos = startPos + Vector3.new(PATH_WIDTH / 2 + 2, 0, 5)
  ensurePart(pathFolder, "Signpost", {
    size = Vector3.new(1, 6, 1),
    position = signPos + Vector3.new(0, 3, 0),
    color = Color3.fromRGB(100, 70, 35),
    material = Enum.Material.Wood,
  })

  -- Sign board
  local signBoard = ensurePart(pathFolder, "SignBoard", {
    size = Vector3.new(4, 1.5, 0.3),
    position = signPos + Vector3.new(0, 5.5, 0),
    color = Color3.fromRGB(120, 85, 40),
    material = Enum.Material.Wood,
  })

  -- Sign text
  local surfaceGui = Instance.new("SurfaceGui")
  surfaceGui.Name = "SignGui"
  surfaceGui.Face = Enum.NormalId.Front
  surfaceGui.Parent = signBoard

  local label = Instance.new("TextLabel")
  label.Name = "SignLabel"
  label.Size = UDim2.fromScale(1, 1)
  label.BackgroundTransparency = 1
  label.Text = "HARBOR  -->"
  label.TextColor3 = Color3.fromRGB(240, 220, 160)
  label.TextScaled = true
  label.Font = Enum.Font.GothamBold
  label.Parent = surfaceGui

  print("[MapBootstrap] Created beach-to-harbor path with", pathTorchCount, "torches")
end

--------------------------------------------------------------------------------
-- NPC ZONE CONSTANTS (MAP-003)
--------------------------------------------------------------------------------

-- Zone definitions: center, size, and NPC types.
-- Danger zones (skull_cave, volcano, deep_jungle) double as DangerZoneService
-- AABB boundaries. Watchtower and pirate_town are NPC-only zones.
--
-- Island layout (top-down, harbor at origin):
--   NW: Skull Cave (-300, -5, -150)   — underground cave, skeleton-heavy
--   N:  Volcano (0, 30, -400)         — elevated volcanic area, mixed NPCs
--   NE: Watchtower (350, 15, -200)    — ruined lookout, skeletons
--   SW: Deep Jungle (-200, 3, 150)    — dense vegetation, ghost pirate territory
--   E:  Pirate Town (250, 3, -50)     — ruins outside harbor, lighter skeleton presence
--   SE: Tutorial Beach (200, 2, 200)  — already placed by MAP-002

local NPC_ZONES = {
  skull_cave = {
    center = Vector3.new(-300, -5, -150),
    size = Vector3.new(180, 60, 160), -- large cave system
    isDangerZone = true,
    spawnPoints = {
      { offset = Vector3.new(0, 5, 0), npcType = "skeleton" },
      { offset = Vector3.new(-40, 5, 30), npcType = "skeleton" },
      { offset = Vector3.new(30, 5, -40), npcType = "skeleton" },
      { offset = Vector3.new(-20, 5, -50), npcType = "skeleton" },
      { offset = Vector3.new(50, 5, 20), npcType = "ghost_pirate" },
    },
    waypoints = {
      { offset = Vector3.new(-60, 5, -40), order = 1 },
      { offset = Vector3.new(-20, 5, 50), order = 2 },
      { offset = Vector3.new(40, 5, 30), order = 3 },
      { offset = Vector3.new(60, 5, -20), order = 4 },
      { offset = Vector3.new(10, 5, -60), order = 5 },
    },
  },
  volcano = {
    center = Vector3.new(0, 30, -400),
    size = Vector3.new(200, 80, 200), -- tall volcanic region
    isDangerZone = true,
    spawnPoints = {
      { offset = Vector3.new(-30, 0, 20), npcType = "skeleton" },
      { offset = Vector3.new(40, -5, -30), npcType = "skeleton" },
      { offset = Vector3.new(-50, -10, -50), npcType = "skeleton" },
      { offset = Vector3.new(20, 0, 60), npcType = "ghost_pirate" },
      { offset = Vector3.new(-60, -10, 40), npcType = "ghost_pirate" },
    },
    waypoints = {
      { offset = Vector3.new(-70, -5, -60), order = 1 },
      { offset = Vector3.new(-40, 0, 50), order = 2 },
      { offset = Vector3.new(50, -5, 40), order = 3 },
      { offset = Vector3.new(70, -10, -30), order = 4 },
      { offset = Vector3.new(0, 0, -70), order = 5 },
    },
  },
  deep_jungle = {
    center = Vector3.new(-200, 3, 150),
    size = Vector3.new(180, 40, 180), -- dense jungle area
    isDangerZone = true,
    spawnPoints = {
      { offset = Vector3.new(20, 0, -30), npcType = "skeleton" },
      { offset = Vector3.new(-40, 0, 40), npcType = "ghost_pirate" },
      { offset = Vector3.new(50, 0, 50), npcType = "ghost_pirate" },
      { offset = Vector3.new(-60, 0, -20), npcType = "skeleton" },
      { offset = Vector3.new(0, 0, 60), npcType = "ghost_pirate" },
    },
    waypoints = {
      { offset = Vector3.new(-50, 0, -50), order = 1 },
      { offset = Vector3.new(40, 0, -40), order = 2 },
      { offset = Vector3.new(60, 0, 30), order = 3 },
      { offset = Vector3.new(-30, 0, 60), order = 4 },
      { offset = Vector3.new(-60, 0, 10), order = 5 },
    },
  },
  watchtower = {
    center = Vector3.new(350, 15, -200),
    size = Vector3.new(140, 50, 140), -- ruined tower grounds
    isDangerZone = false,
    spawnPoints = {
      { offset = Vector3.new(0, 0, 0), npcType = "skeleton" },
      { offset = Vector3.new(-30, -5, 20), npcType = "skeleton" },
      { offset = Vector3.new(30, -5, -30), npcType = "skeleton" },
      { offset = Vector3.new(-20, 0, -40), npcType = "skeleton" },
    },
    waypoints = {
      { offset = Vector3.new(-40, -5, -30), order = 1 },
      { offset = Vector3.new(30, -5, -40), order = 2 },
      { offset = Vector3.new(40, 0, 20), order = 3 },
      { offset = Vector3.new(-30, 0, 40), order = 4 },
    },
  },
  pirate_town = {
    center = Vector3.new(250, 3, -50),
    size = Vector3.new(120, 30, 120), -- town outskirts
    isDangerZone = false,
    spawnPoints = {
      { offset = Vector3.new(-20, 0, 20), npcType = "skeleton" },
      { offset = Vector3.new(30, 0, -20), npcType = "skeleton" },
      { offset = Vector3.new(-10, 0, -40), npcType = "skeleton" },
    },
    waypoints = {
      { offset = Vector3.new(-30, 0, -30), order = 1 },
      { offset = Vector3.new(30, 0, -20), order = 2 },
      { offset = Vector3.new(20, 0, 30), order = 3 },
      { offset = Vector3.new(-30, 0, 20), order = 4 },
    },
  },
}

--------------------------------------------------------------------------------
-- DANGER ZONES (MAP-003 — AABB Parts for DangerZoneService)
--------------------------------------------------------------------------------

--[[
  Creates the DangerZones folder with invisible AABB Parts for each danger zone.
  Part names must match GameConfig.DangerZones IDs (skull_cave, volcano, deep_jungle).
  DangerZoneService scans this folder at init to build its zone lookup table.
]]
local function setupDangerZones()
  local folder = ensureFolder(workspace, "DangerZones")

  if #folder:GetChildren() > 0 then
    print("[MapBootstrap] DangerZones already populated, skipping")
    return
  end

  local count = 0
  for zoneId, zoneDef in NPC_ZONES do
    if zoneDef.isDangerZone then
      local center = zoneDef.center + Vector3.new(0, zoneDef.size.Y / 2, 0)
      ensurePart(folder, zoneId, {
        size = zoneDef.size,
        position = center,
        transparency = ZONE_TRANSPARENCY,
        canCollide = false,
        canQuery = false,
        canTouch = false,
      })
      count += 1
    end
  end

  print("[MapBootstrap] Created", count, "danger zone boundary Parts")
end

--------------------------------------------------------------------------------
-- NPC SPAWN POINTS (MAP-003 — for NPCService spawn manager)
--------------------------------------------------------------------------------

--[[
  Creates the NPCSpawnPoints folder with Parts for each spawn location.
  Each Part has attributes:
    - Zone (string): zone ID for leash/patrol association
    - NPCType (string): "skeleton" or "ghost_pirate"
  NPCService reads these at init to build its spawn point tables.
]]
local function setupNPCSpawnPoints()
  local folder = ensureFolder(workspace, "NPCSpawnPoints")

  -- Check if spawn points already exist (from Studio or prior run)
  local existingCount = 0
  for _, child in folder:GetChildren() do
    if child:IsA("BasePart") and child:GetAttribute("Zone") then
      existingCount += 1
    end
  end
  if existingCount > 0 then
    print("[MapBootstrap] NPCSpawnPoints already has", existingCount, "points, skipping")
    return
  end

  local totalCount = 0
  for zoneId, zoneDef in NPC_ZONES do
    for i, sp in zoneDef.spawnPoints do
      local pos = zoneDef.center + sp.offset
      local part = ensurePart(folder, zoneId .. "_spawn_" .. i, {
        size = Vector3.new(3, 1, 3),
        position = pos,
        transparency = ZONE_TRANSPARENCY,
        canCollide = false,
        canQuery = false,
        canTouch = false,
      })
      part:SetAttribute("Zone", zoneId)
      part:SetAttribute("NPCType", sp.npcType)
      totalCount += 1
    end
  end

  print("[MapBootstrap] Created", totalCount, "NPC spawn points across", 5, "zones")
end

--------------------------------------------------------------------------------
-- PATROL WAYPOINTS (MAP-003 — for NPCService SimplePath patrol)
--------------------------------------------------------------------------------

--[[
  Creates the PatrolWaypoints folder with Parts for each patrol location.
  Each Part has attributes:
    - Zone (string): zone ID to group waypoints by zone
    - Order (number): sort order for sequential patrol routes
  NPCService reads these at init. NPCs patrol between waypoints in their zone.
  Waypoints are placed within zone boundaries and outside harbor safe zone.
]]
local function setupPatrolWaypoints()
  local folder = ensureFolder(workspace, "PatrolWaypoints")

  if #folder:GetChildren() > 0 then
    print("[MapBootstrap] PatrolWaypoints already populated, skipping")
    return
  end

  local totalCount = 0
  for zoneId, zoneDef in NPC_ZONES do
    for i, wp in zoneDef.waypoints do
      local pos = zoneDef.center + wp.offset
      local part = ensurePart(folder, zoneId .. "_wp_" .. i, {
        size = Vector3.new(2, 1, 2),
        position = pos,
        transparency = ZONE_TRANSPARENCY,
        canCollide = false,
        canQuery = false,
        canTouch = false,
      })
      part:SetAttribute("Zone", zoneId)
      part:SetAttribute("Order", wp.order)
      totalCount += 1
    end
  end

  print("[MapBootstrap] Created", totalCount, "patrol waypoints across", 5, "zones")
end

--------------------------------------------------------------------------------
-- CONTAINER SPAWN POINTS (MAP-004 — for ContainerService)
--------------------------------------------------------------------------------

--[[
  Container spawn point placement across the map.
  ContainerService scans workspace.ContainerSpawnPoints for BasePart children.

  Key behavior:
    - Regular containers spawn at ANY unoccupied point (weighted random type)
    - Cursed Chests (night-only) spawn ONLY at points with Zone = "danger"
    - Zone attribute is used for Cursed Chest filtering, not container type selection

  Distribution strategy:
    - Danger zones (skull_cave, volcano, deep_jungle): Zone = "danger"
      Higher risk, but also where Cursed Chests appear at night
    - Non-danger zones (watchtower, pirate_town): zone name as Zone
      Medium risk areas with skeleton-only enemies
    - Paths and neutral areas: Zone = "path"
      Low risk, common crate/barrel territory
    - Beach outskirts: Zone = "beach"
      Easy pickings near the tutorial area

  ~45 total spawn points supports the 20 active container cap with good
  rotation variety. At any given time, ~55% of points are unoccupied,
  ensuring spawns can always find available locations.
]]

-- Spawn points within NPC zones (offsets from zone center)
local ZONE_CONTAINER_SPAWNS = {
  skull_cave = {
    -- Deep cave chambers — high-value territory
    Vector3.new(-50, 5, -30),
    Vector3.new(-10, 5, 40),
    Vector3.new(35, 5, -20),
    Vector3.new(-30, 5, -60),
    Vector3.new(60, 5, 10),
    Vector3.new(15, 5, 55),
  },
  volcano = {
    -- Slopes and crater rim — treacherous terrain
    Vector3.new(-40, -5, 50),
    Vector3.new(50, -10, -40),
    Vector3.new(-60, -10, -30),
    Vector3.new(30, 0, 70),
    Vector3.new(0, 0, -65),
    Vector3.new(-70, -5, 20),
  },
  deep_jungle = {
    -- Jungle clearings and vine tunnels
    Vector3.new(30, 0, -50),
    Vector3.new(-50, 0, 30),
    Vector3.new(60, 0, 40),
    Vector3.new(-40, 0, -40),
    Vector3.new(10, 0, 65),
    Vector3.new(-65, 0, -10),
  },
  watchtower = {
    -- Ruined tower grounds and approaches
    Vector3.new(-10, -5, -20),
    Vector3.new(25, 0, 30),
    Vector3.new(-35, -5, 10),
    Vector3.new(40, -5, -40),
    Vector3.new(0, 0, 50),
  },
  pirate_town = {
    -- Market stalls, alleys, tavern area
    Vector3.new(-25, 0, 15),
    Vector3.new(20, 0, -30),
    Vector3.new(35, 0, 20),
    Vector3.new(-10, 0, -45),
    Vector3.new(-40, 0, -10),
  },
}

-- Spawn points in neutral/path areas (absolute positions)
-- NOTE: Harbor safe zone is X:[-150,150] Z:[-100,100] — all points must be outside
local PATH_CONTAINER_SPAWNS = {
  -- Harbor approach — just outside the safe zone boundaries
  { name = "harbor_approach_1", position = Vector3.new(-165, 3, -30) },
  { name = "harbor_approach_2", position = Vector3.new(165, 3, -50) },
  { name = "harbor_approach_3", position = Vector3.new(-100, 3, 115) },
  { name = "harbor_approach_4", position = Vector3.new(60, 3, -120) },

  -- Crossroads between zones
  { name = "crossroad_nw", position = Vector3.new(-180, 3, -40) },
  { name = "crossroad_ne", position = Vector3.new(200, 5, -140) },
  { name = "crossroad_sw", position = Vector3.new(-155, 3, 60) },
  { name = "crossroad_n", position = Vector3.new(-100, 10, -280) },
  { name = "crossroad_e", position = Vector3.new(300, 5, -120) },
}

-- Beach/coastal spawn points (absolute positions)
local BEACH_CONTAINER_SPAWNS = {
  { name = "beach_cove_1", position = Vector3.new(160, 3, 160) },
  { name = "beach_cove_2", position = Vector3.new(240, 3, 140) },
  { name = "beach_shore_1", position = Vector3.new(180, 3, 230) },
}

--[[
  Creates the ContainerSpawnPoints folder with Parts for each spawn location.
  Each Part has a Zone attribute:
    - "danger" for skull_cave, volcano, deep_jungle (Cursed Chest eligible)
    - Zone name for watchtower, pirate_town
    - "path" for crossroads/harbor approach
    - "beach" for coastal areas
  ContainerService reads this folder at KnitInit().
]]
local function setupContainerSpawnPoints()
  local folder = ensureFolder(workspace, "ContainerSpawnPoints")

  -- Check if spawn points already exist (from Studio or prior run)
  local existingCount = 0
  for _, child in folder:GetChildren() do
    if child:IsA("BasePart") then
      existingCount += 1
    end
  end
  if existingCount > 0 then
    print("[MapBootstrap] ContainerSpawnPoints already has", existingCount, "points, skipping")
    return
  end

  local totalCount = 0

  -- Zone-based container spawn points
  for zoneId, offsets in ZONE_CONTAINER_SPAWNS do
    local zoneDef = NPC_ZONES[zoneId]
    if not zoneDef then
      warn("[MapBootstrap] Unknown zone for container spawns:", zoneId)
      continue
    end

    -- Danger zones get Zone="danger" so ContainerService can spawn Cursed Chests there
    local zoneAttr = if zoneDef.isDangerZone then "danger" else zoneId

    for i, offset in offsets do
      local pos = zoneDef.center + offset
      local part = ensurePart(folder, zoneId .. "_container_" .. i, {
        size = Vector3.new(4, 1, 4),
        position = pos,
        transparency = ZONE_TRANSPARENCY,
        canCollide = false,
        canQuery = false,
        canTouch = false,
      })
      part:SetAttribute("Zone", zoneAttr)
      totalCount += 1
    end
  end

  -- Path/crossroad container spawn points
  for _, sp in PATH_CONTAINER_SPAWNS do
    local part = ensurePart(folder, sp.name, {
      size = Vector3.new(4, 1, 4),
      position = sp.position,
      transparency = ZONE_TRANSPARENCY,
      canCollide = false,
      canQuery = false,
      canTouch = false,
    })
    part:SetAttribute("Zone", "path")
    totalCount += 1
  end

  -- Beach container spawn points
  for _, sp in BEACH_CONTAINER_SPAWNS do
    local part = ensurePart(folder, sp.name, {
      size = Vector3.new(4, 1, 4),
      position = sp.position,
      transparency = ZONE_TRANSPARENCY,
      canCollide = false,
      canQuery = false,
      canTouch = false,
    })
    part:SetAttribute("Zone", "beach")
    totalCount += 1
  end

  -- Summary
  local dangerCount = 0
  for zoneId, zoneDef in NPC_ZONES do
    if zoneDef.isDangerZone and ZONE_CONTAINER_SPAWNS[zoneId] then
      dangerCount += #ZONE_CONTAINER_SPAWNS[zoneId]
    end
  end

  print(
    "[MapBootstrap] Created",
    totalCount,
    "container spawn points ("
      .. dangerCount
      .. " danger zone, "
      .. (totalCount - dangerCount)
      .. " non-danger)"
  )
end

--------------------------------------------------------------------------------
-- VOLCANIC VENTS (MAP-005 — for VolcanicVentService)
--------------------------------------------------------------------------------

--[[
  Volcanic vent locations: 6 vents across 3 zones.
  Each vent is a BasePart defining the eruption zone (AABB).
  VolcanicVentService loads these from workspace.VolcanicVents.

  Placement rationale:
    - 3 on Volcano slopes (primary hazard zone)
    - 1 at Skull Cave entrance (gateway danger)
    - 2 in Deep Jungle (scattered through dense areas)
  All placed outside Harbor safe zone.
]]
local VOLCANIC_VENT_DEFS = {
  -- Volcano slopes (3 vents): spread across the volcanic region
  {
    name = "Vent_VolcanoNorth",
    position = Vector3.new(-30, 25, -440), -- north slope
    size = Vector3.new(12, 3, 12),
  },
  {
    name = "Vent_VolcanoEast",
    position = Vector3.new(60, 20, -380), -- east slope, lower
    size = Vector3.new(10, 3, 10),
  },
  {
    name = "Vent_VolcanoSouth",
    position = Vector3.new(20, 15, -320), -- south slope, near path
    size = Vector3.new(14, 3, 14),
  },

  -- Skull Cave entrance (1 vent): just outside the cave mouth
  {
    name = "Vent_SkullCaveEntrance",
    position = Vector3.new(-220, 0, -110), -- east side of skull_cave, near approach
    size = Vector3.new(10, 3, 10),
  },

  -- Deep Jungle (2 vents): hidden among vegetation
  {
    name = "Vent_JungleSouth",
    position = Vector3.new(-230, 3, 200), -- southern edge of jungle
    size = Vector3.new(11, 3, 11),
  },
  {
    name = "Vent_JungleCenter",
    position = Vector3.new(-180, 3, 130), -- central jungle clearing
    size = Vector3.new(10, 3, 10),
  },
}

local function setupVolcanicVents()
  local folder = ensureFolder(workspace, "VolcanicVents")

  if #folder:GetChildren() > 0 then
    print("[MapBootstrap] VolcanicVents already populated, skipping")
    return
  end

  for _, def in VOLCANIC_VENT_DEFS do
    ensurePart(folder, def.name, {
      size = def.size,
      position = def.position,
      color = Color3.fromRGB(80, 40, 20), -- dark volcanic brown
      material = Enum.Material.CrackedLava,
      transparency = 0,
      canCollide = true,
    })
  end

  print("[MapBootstrap] Created", #VOLCANIC_VENT_DEFS, "volcanic vent Parts")
end

--------------------------------------------------------------------------------
-- QUICKSAND PATCHES (MAP-005 — for QuicksandService)
--------------------------------------------------------------------------------

--[[
  Quicksand patch locations: 5 patches along jungle paths.
  Each patch is a BasePart defining the quicksand zone (AABB).
  QuicksandService loads these from workspace.QuicksandPatches.
  Only 2-3 are active at once; patches cycle active/dormant.

  Placement rationale:
    - Along paths between Deep Jungle, Pirate Town, and Skull Cave
    - On jungle trails and clearings
    - Not near Harbor safe zone or tutorial beach
]]
local QUICKSAND_PATCH_DEFS = {
  -- Deep Jungle → Pirate Town path (outside harbor safe zone X:±150, Z:±100)
  {
    name = "Quicksand_JunglePath1",
    position = Vector3.new(-160, 2, 120), -- between deep_jungle and harbor outskirts
    size = Vector3.new(16, 1, 14),
  },
  {
    name = "Quicksand_JunglePath2",
    position = Vector3.new(160, 2, 80), -- east side, pirate_town approach
    size = Vector3.new(14, 1, 12),
  },

  -- Deep Jungle interior
  {
    name = "Quicksand_JungleInterior",
    position = Vector3.new(-240, 2, 180), -- inside deep jungle
    size = Vector3.new(18, 1, 16),
  },

  -- Deep Jungle → Skull Cave path
  {
    name = "Quicksand_JungleToCave",
    position = Vector3.new(-260, 0, 10), -- between deep_jungle and skull_cave
    size = Vector3.new(14, 1, 14),
  },

  -- Skull Cave → Watchtower wilderness
  {
    name = "Quicksand_Wilderness",
    position = Vector3.new(80, 2, -120), -- wilderness between zones
    size = Vector3.new(16, 1, 12),
  },
}

local function setupQuicksandPatches()
  local folder = ensureFolder(workspace, "QuicksandPatches")

  if #folder:GetChildren() > 0 then
    print("[MapBootstrap] QuicksandPatches already populated, skipping")
    return
  end

  for _, def in QUICKSAND_PATCH_DEFS do
    ensurePart(folder, def.name, {
      size = def.size,
      position = def.position,
      color = Color3.fromRGB(194, 178, 128), -- sandy tan
      material = Enum.Material.Sand,
      transparency = 0,
      canCollide = true,
    })
  end

  print("[MapBootstrap] Created", #QUICKSAND_PATCH_DEFS, "quicksand patch Parts")
end

--------------------------------------------------------------------------------
-- TIDAL SURGE ZONES (MAP-005 — for TidalSurgeService)
--------------------------------------------------------------------------------

--[[
  Tidal surge zone locations: 3 zones on beach/coastal areas.
  Each zone is a BasePart whose AABB defines the flood area.
  The Part's LookVector must point INLAND (direction the surge pushes players).
  TidalSurgeService loads these from workspace.TidalSurgeZones.

  Placement rationale:
    - Tutorial Beach south coast (water is on the +Z edge)
    - East coastline (between tutorial beach and harbor waterfront)
    - West coastline (near deep jungle coast)
  All outside Harbor safe zone. LookVector oriented toward map center.
]]
local TIDAL_SURGE_ZONE_DEFS = {
  -- Tutorial Beach area: water on +Z side, inland is -Z (toward harbor)
  {
    name = "TidalSurge_SouthBeach",
    position = Vector3.new(200, 2, 240),
    size = Vector3.new(80, 6, 30), -- 80 wide along coast, 30 deep flood zone
    -- CFrame faces -Z (inland toward harbor from the south beach)
    lookTarget = Vector3.new(200, 2, 200), -- inland direction
  },

  -- East coastline: between tutorial beach and harbor, water on +X side
  {
    name = "TidalSurge_EastCoast",
    position = Vector3.new(340, 2, 50),
    size = Vector3.new(30, 6, 70), -- narrow flood strip, long along coast
    lookTarget = Vector3.new(300, 2, 50), -- inland toward map center (-X)
  },

  -- West coastline: near deep jungle, water on -X side
  {
    name = "TidalSurge_WestCoast",
    position = Vector3.new(-350, 2, 100),
    size = Vector3.new(30, 6, 70), -- narrow flood strip
    lookTarget = Vector3.new(-310, 2, 100), -- inland toward map center (+X)
  },
}

local function setupTidalSurgeZones()
  local folder = ensureFolder(workspace, "TidalSurgeZones")

  if #folder:GetChildren() > 0 then
    print("[MapBootstrap] TidalSurgeZones already populated, skipping")
    return
  end

  for _, def in TIDAL_SURGE_ZONE_DEFS do
    -- Build CFrame looking from zone position toward the inland target
    local cf = CFrame.lookAt(def.position, def.lookTarget)
    ensurePart(folder, def.name, {
      size = def.size,
      cframe = cf,
      color = Color3.fromRGB(70, 130, 180), -- steel blue (water)
      material = Enum.Material.SmoothPlastic,
      transparency = 0.7,
      canCollide = false,
      canQuery = false,
      canTouch = false,
    })
  end

  print("[MapBootstrap] Created", #TIDAL_SURGE_ZONE_DEFS, "tidal surge zone Parts")
end

--------------------------------------------------------------------------------
-- ROGUE WAVE ZONES (MAP-005 — for RogueWaveService)
--------------------------------------------------------------------------------

--[[
  Rogue wave zone locations: 3 zones on exposed coastlines.
  Each zone is a BasePart whose AABB defines the wave impact area.
  The Part's LookVector must point INLAND (direction the wave pushes players).
  RogueWaveService loads these from workspace.RogueWaveZones.
  Rogue waves are night-only and more powerful than tidal surges.

  Placement rationale:
    - Southern exposed coastline (wide open beach)
    - Northeast coastline (near watchtower, cliffs)
    - Northwest coastline (near skull cave, rocky shore)
  All outside Harbor safe zone. Larger zones than tidal surges for dramatic effect.
]]
local ROGUE_WAVE_ZONE_DEFS = {
  -- South coast: wide exposed beach (covers more than tidal surge zone)
  {
    name = "RogueWave_SouthCoast",
    position = Vector3.new(120, 2, 280),
    size = Vector3.new(120, 8, 40), -- very wide impact zone
    lookTarget = Vector3.new(120, 2, 240), -- inland (-Z)
  },

  -- Northeast coast: near watchtower cliffs
  {
    name = "RogueWave_NECoast",
    position = Vector3.new(400, 2, -250),
    size = Vector3.new(40, 8, 100), -- along the coastline
    lookTarget = Vector3.new(360, 2, -250), -- inland (-X)
  },

  -- Northwest coast: near skull cave, rocky shore
  {
    name = "RogueWave_NWCoast",
    position = Vector3.new(-380, 2, -200),
    size = Vector3.new(40, 8, 100), -- along the coastline
    lookTarget = Vector3.new(-340, 2, -200), -- inland (+X)
  },
}

local function setupRogueWaveZones()
  local folder = ensureFolder(workspace, "RogueWaveZones")

  if #folder:GetChildren() > 0 then
    print("[MapBootstrap] RogueWaveZones already populated, skipping")
    return
  end

  for _, def in ROGUE_WAVE_ZONE_DEFS do
    -- Build CFrame looking from zone position toward the inland target
    local cf = CFrame.lookAt(def.position, def.lookTarget)
    ensurePart(folder, def.name, {
      size = def.size,
      cframe = cf,
      color = Color3.fromRGB(30, 80, 140), -- deep ocean blue
      material = Enum.Material.SmoothPlastic,
      transparency = 0.7,
      canCollide = false,
      canQuery = false,
      canTouch = false,
    })
  end

  print("[MapBootstrap] Created", #ROGUE_WAVE_ZONE_DEFS, "rogue wave zone Parts")
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Sets up all workspace objects for all map features.
  Called from Main.server.lua before Knit services are loaded.
  Idempotent — safe to call multiple times.
]]
function MapBootstrap.setup()
  print("[MapBootstrap] Setting up map layout (MAP-001 through MAP-005)...")

  -- MAP-001: Harbor zone
  setupHarborZone()
  setupDockSlots()
  setupPierVisuals()
  setupBoundaryMarkers()
  setupSpecialLocations()
  setupHarborGround()
  setupTorches()

  -- MAP-002: Tutorial beach
  setupTutorialBeach()
  setupBeachTerrain()
  setupShipwreckDebris()
  setupBeachToHarborPath()

  -- MAP-003: NPC spawn zones
  setupDangerZones()
  setupNPCSpawnPoints()
  setupPatrolWaypoints()

  -- MAP-004: Container spawn points
  setupContainerSpawnPoints()

  -- MAP-005: Hazard placement
  setupVolcanicVents()
  setupQuicksandPatches()
  setupTidalSurgeZones()
  setupRogueWaveZones()

  print("[MapBootstrap] Map layout setup complete")
end

return MapBootstrap
