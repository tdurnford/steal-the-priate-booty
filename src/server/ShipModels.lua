--[[
  ShipModels.lua
  Builds detailed Part-based 3D models for all 7 ship tiers.

  Each builder creates a Model with:
    - A "Hull" PrimaryPart (CanCollide=true, CanQuery=true, carries metadata attributes)
    - A "Mast" Part (for tiers 2+, used by CosmeticVisualService for sail/flag attachment)
    - An "OwnerLabel" BillboardGui with NameLabel + StatusLabel TextLabels
    - Decorative child Parts that give each ship a distinct pirate-themed look

  Used by ShipService.createShipModel() to replace placeholder boxes.
  All Parts are Anchored (ships are static docked objects).

  CosmeticVisualService compatibility:
    - applySail() expects "Mast" child Part (reads .Size.Y for height) + "Hull" child Part
    - applyFlag() expects "Mast" child Part (reads .Size.Y, positions at top)
    - applyHullCosmetic() expects "Hull" child Part (sets .Color / .Material)

  ShipService visual indicators (SHIP-005) compatibility:
    - updateStatusLabel() expects Hull → OwnerLabel → StatusLabel
    - updateHoldGlow() adds/removes PointLight named "HoldGlow" on Hull
    - updateHoldParticles() adds/removes ParticleEmitter named "HoldShimmer" on Hull
    - updateCoinPiles() reads Hull.Size for deck positioning offsets
]]

local ShipModels = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Creates an anchored decorative Part with common defaults.
  @param props Table of Part properties to set
  @return Part
]]
local function makePart(props: { [string]: any }): Part
  local part = Instance.new("Part")
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = true
  part.TopSurface = Enum.SurfaceType.Smooth
  part.BottomSurface = Enum.SurfaceType.Smooth

  for key, value in props do
    (part :: any)[key] = value
  end

  return part
end

--[[
  Creates an anchored decorative WedgePart with common defaults.
  Used for bow/stern tapering on ship hulls.
  @param props Table of WedgePart properties to set
  @return WedgePart
]]
local function makeWedge(props: { [string]: any }): WedgePart
  local wedge = Instance.new("WedgePart")
  wedge.Anchored = true
  wedge.CanCollide = false
  wedge.CanQuery = false
  wedge.CanTouch = false
  wedge.CastShadow = true
  wedge.TopSurface = Enum.SurfaceType.Smooth
  wedge.BottomSurface = Enum.SurfaceType.Smooth

  for key, value in props do
    (wedge :: any)[key] = value
  end

  return wedge
end

--[[
  Creates a Model with Hull PrimaryPart and OwnerLabel BillboardGui.
  @param position World position of the dock point (bottom-center of ship)
  @param ownerName Display name of the ship owner
  @param ownerUserId UserId of the ship owner
  @param slotIndex Dock slot number
  @param tierId Ship tier ID string (e.g. "rowboat", "galleon")
  @param tierName Ship tier display name (e.g. "Rowboat", "Galleon")
  @param hullProps Properties for the Hull part (must include Size)
  @return (Model, Part) The model and its Hull part
]]
local function makeBaseShip(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierId: string,
  tierName: string,
  hullProps: { [string]: any }
): (Model, Part)
  local model = Instance.new("Model")
  model.Name = "Ship_" .. ownerName .. "_Slot" .. slotIndex

  local hullSize = hullProps.Size or Vector3.new(6, 2, 10)

  local hull = Instance.new("Part")
  hull.Name = "Hull"
  hull.Anchored = true
  hull.CanCollide = true
  hull.CanQuery = true
  hull.CanTouch = false
  hull.CastShadow = true
  hull.TopSurface = Enum.SurfaceType.Smooth
  hull.BottomSurface = Enum.SurfaceType.Smooth
  hull.CFrame = CFrame.new(position + Vector3.new(0, hullSize.Y / 2, 0))

  for key, value in hullProps do
    (hull :: any)[key] = value
  end

  hull.Parent = model
  model.PrimaryPart = hull

  -- Metadata attributes (same contract as old createShipModel)
  hull:SetAttribute("ShipSlotIndex", slotIndex)
  hull:SetAttribute("ShipTierId", tierId)
  hull:SetAttribute("ShipTierName", tierName)
  hull:SetAttribute("OwnerName", ownerName)
  hull:SetAttribute("OwnerUserId", ownerUserId)

  -- Billboard GUI for owner name and status
  local billboard = Instance.new("BillboardGui")
  billboard.Name = "OwnerLabel"
  billboard.Size = UDim2.new(0, 200, 0, 70)
  billboard.StudsOffset = Vector3.new(0, hullSize.Y + 2, 0)
  billboard.AlwaysOnTop = false
  billboard.MaxDistance = 60
  billboard.Parent = hull

  local nameLabel = Instance.new("TextLabel")
  nameLabel.Name = "NameLabel"
  nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
  nameLabel.BackgroundTransparency = 1
  nameLabel.Text = ownerName .. "'s " .. tierName
  nameLabel.TextColor3 = Color3.fromRGB(255, 230, 150)
  nameLabel.TextStrokeTransparency = 0.3
  nameLabel.TextScaled = true
  nameLabel.Font = Enum.Font.GothamBold
  nameLabel.Parent = billboard

  local statusLabel = Instance.new("TextLabel")
  statusLabel.Name = "StatusLabel"
  statusLabel.Size = UDim2.new(1, 0, 0.4, 0)
  statusLabel.Position = UDim2.new(0, 0, 0.6, 0)
  statusLabel.BackgroundTransparency = 1
  statusLabel.Text = ""
  statusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
  statusLabel.TextStrokeTransparency = 0.5
  statusLabel.TextScaled = true
  statusLabel.Font = Enum.Font.GothamMedium
  statusLabel.Parent = billboard

  return model, hull
end

--[[
  Adds a vertical block mast to the model at an offset from the hull center.
  CosmeticVisualService reads mast.Size.Y for height, so mast must be a Block Part.
  @param model The ship Model
  @param hull The Hull part
  @param name Part name (primary mast must be "Mast" for cosmetic compat)
  @param xOffset X offset from hull center
  @param zOffset Z offset from hull center
  @param height Mast height in studs
  @param thickness Mast cross-section width
  @return Part The mast Part
]]
local function addMast(
  model: Model,
  hull: Part,
  name: string,
  xOffset: number,
  zOffset: number,
  height: number,
  thickness: number
): Part
  local hullPos = hull.Position
  local deckY = hullPos.Y + hull.Size.Y / 2

  local mast = makePart({
    Name = name,
    Size = Vector3.new(thickness, height, thickness),
    Color = Color3.fromRGB(100, 70, 35),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X + xOffset, deckY + height / 2, hullPos.Z + zOffset),
  })
  mast.Parent = model
  return mast
end

--[[
  Adds a rectangular sail Part attached to a mast.
  @param model The ship Model
  @param mast The mast Part to attach sail to
  @param hull The Hull part (for width reference)
  @param name Sail Part name (e.g. "Sail", "Sail2")
  @param color Sail color
  @param transparency Optional transparency (default 0)
  @return Part The sail Part
]]
local function addSail(
  model: Model,
  mast: Part,
  hull: Part,
  name: string,
  color: Color3,
  transparency: number?
): Part
  local sailWidth = hull.Size.X * 0.75
  local sailHeight = mast.Size.Y * 0.5

  local sail = makePart({
    Name = name,
    Size = Vector3.new(sailWidth, sailHeight, 0.15),
    Color = color,
    Material = Enum.Material.Fabric,
    Transparency = transparency or 0,
    CFrame = mast.CFrame * CFrame.new(0, mast.Size.Y * 0.05, 0),
  })
  sail.Parent = model
  return sail
end

--[[
  Adds a horizontal yard (crossbeam) to a mast for sail rigging.
  @param model The ship Model
  @param mast The mast Part
  @param yOffset Vertical offset from mast center
  @param width Yard width
  @return Part The yard Part
]]
local function addYard(model: Model, mast: Part, yOffset: number, width: number): Part
  local yard = makePart({
    Name = "Yard",
    Size = Vector3.new(width, 0.2, 0.2),
    Color = Color3.fromRGB(90, 60, 30),
    Material = Enum.Material.Wood,
    CFrame = mast.CFrame * CFrame.new(0, yOffset, 0),
  })
  yard.Parent = model
  return yard
end

--[[
  Adds railing posts along both sides of the hull.
  @param model The ship Model
  @param hull The Hull part
  @param count Number of posts per side
  @param postHeight Height of each post
  @param color Post color
]]
local function addRailingPosts(
  model: Model,
  hull: Part,
  count: number,
  postHeight: number,
  color: Color3
)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local halfX = hullSize.X / 2
  local halfZ = hullSize.Z / 2

  for i = 1, count do
    local zFrac = (i - 0.5) / count
    local z = hullPos.Z + halfZ - zFrac * hullSize.Z

    -- Port (left) post
    local portPost = makePart({
      Name = "RailingPost",
      Size = Vector3.new(0.2, postHeight, 0.2),
      Color = color,
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(hullPos.X - halfX, deckY + postHeight / 2, z),
    })
    portPost.Parent = model

    -- Starboard (right) post
    local starPost = makePart({
      Name = "RailingPost",
      Size = Vector3.new(0.2, postHeight, 0.2),
      Color = color,
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(hullPos.X + halfX, deckY + postHeight / 2, z),
    })
    starPost.Parent = model
  end
end

--[[
  Adds gunwale rails (thin horizontal bars) along both sides of the hull top.
  @param model The ship Model
  @param hull The Hull part
  @param color Rail color
  @param railHeight Height of rail above deck
]]
local function addGunwales(model: Model, hull: Part, color: Color3, railHeight: number)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local halfX = hullSize.X / 2

  -- Port rail
  local portRail = makePart({
    Name = "Gunwale",
    Size = Vector3.new(0.15, railHeight, hullSize.Z * 0.9),
    Color = color,
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X - halfX, deckY + railHeight / 2, hullPos.Z),
  })
  portRail.Parent = model

  -- Starboard rail
  local starRail = makePart({
    Name = "Gunwale",
    Size = Vector3.new(0.15, railHeight, hullSize.Z * 0.9),
    Color = color,
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X + halfX, deckY + railHeight / 2, hullPos.Z),
  })
  starRail.Parent = model
end

--[[
  Adds bow wedge pieces to taper the front of the hull.
  Creates a pointed bow using WedgeParts on each side.
  @param model The ship Model
  @param hull The Hull part
  @param bowLength How far the bow extends forward
  @param color Hull color
  @param material Hull material
]]
local function addBow(
  model: Model,
  hull: Part,
  bowLength: number,
  color: Color3,
  material: Enum.Material
)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local halfX = hullSize.X / 2
  local bowZ = hullPos.Z - hullSize.Z / 2 - bowLength / 2

  -- Port (left) bow wedge — slope tapers from hull width to center
  local portBow = makeWedge({
    Name = "BowPort",
    Size = Vector3.new(halfX, hullSize.Y, bowLength),
    Color = color,
    Material = material,
    -- Rotate so slope faces port side, taper goes forward
    CFrame = CFrame.new(hullPos.X - halfX / 2, hullPos.Y, bowZ)
      * CFrame.Angles(0, math.rad(180), 0),
  })
  portBow.Parent = model

  -- Starboard (right) bow wedge — mirror of port
  local starBow = makeWedge({
    Name = "BowStarboard",
    Size = Vector3.new(halfX, hullSize.Y, bowLength),
    Color = color,
    Material = material,
    CFrame = CFrame.new(hullPos.X + halfX / 2, hullPos.Y, bowZ)
      * CFrame.Angles(0, math.rad(180), math.rad(180)),
  })
  starBow.Parent = model
end

--[[
  Adds a bowsprit (angled pole extending from bow).
  @param model The ship Model
  @param hull The Hull part
  @param length Bowsprit length
]]
local function addBowsprit(model: Model, hull: Part, length: number)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local bowZ = hullPos.Z - hullSize.Z / 2

  local bowsprit = makePart({
    Name = "Bowsprit",
    Size = Vector3.new(0.3, 0.3, length),
    Color = Color3.fromRGB(90, 60, 30),
    Material = Enum.Material.Wood,
    -- Angle slightly upward from the bow
    CFrame = CFrame.new(hullPos.X, deckY + 0.5, bowZ - length / 2)
      * CFrame.Angles(math.rad(-15), 0, 0),
  })
  bowsprit.Parent = model
  return bowsprit
end

--[[
  Adds a keel (thin strip running along hull bottom).
  @param model The ship Model
  @param hull The Hull part
  @param keelDepth How far below the hull the keel extends
]]
local function addKeel(model: Model, hull: Part, keelDepth: number)
  local hullPos = hull.Position
  local hullSize = hull.Size

  local keel = makePart({
    Name = "Keel",
    Size = Vector3.new(0.4, keelDepth, hullSize.Z * 1.05),
    Color = Color3.fromRGB(60, 40, 20),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X, hullPos.Y - hullSize.Y / 2 - keelDepth / 2, hullPos.Z),
  })
  keel.Parent = model
end

--[[
  Adds a stern cabin structure.
  @param model The ship Model
  @param hull The Hull part
  @param cabinWidth Width of the cabin
  @param cabinHeight Height of the cabin above deck
  @param cabinDepth Depth (Z extent) of the cabin
  @param color Wall color
  @param material Wall material
]]
local function addCabin(
  model: Model,
  hull: Part,
  cabinWidth: number,
  cabinHeight: number,
  cabinDepth: number,
  color: Color3,
  material: Enum.Material
)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local cabinZ = hullPos.Z + hullSize.Z / 2 - cabinDepth / 2

  -- Cabin walls
  local cabin = makePart({
    Name = "Cabin",
    Size = Vector3.new(cabinWidth, cabinHeight, cabinDepth),
    Color = color,
    Material = material,
    CFrame = CFrame.new(hullPos.X, deckY + cabinHeight / 2, cabinZ),
  })
  cabin.Parent = model

  -- Cabin roof (slightly wider and longer)
  local roof = makePart({
    Name = "CabinRoof",
    Size = Vector3.new(cabinWidth + 0.5, 0.3, cabinDepth + 0.5),
    Color = Color3.fromRGB(80, 50, 25),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X, deckY + cabinHeight + 0.15, cabinZ),
  })
  roof.Parent = model

  return cabin
end

--[[
  Adds cabin windows (small colored rectangles on the stern face).
  @param model The ship Model
  @param hull The Hull part
  @param windowCount Number of windows
  @param windowY Y position of windows above deck
  @param cabinDepth Depth of the cabin for Z positioning
]]
local function addCabinWindows(
  model: Model,
  hull: Part,
  windowCount: number,
  windowY: number,
  cabinDepth: number
)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local sternZ = hullPos.Z + hullSize.Z / 2 - cabinDepth + 0.01
  local totalWidth = hullSize.X * 0.6
  local spacing = totalWidth / (windowCount + 1)

  for i = 1, windowCount do
    local xOff = -totalWidth / 2 + i * spacing
    local window = makePart({
      Name = "Window",
      Size = Vector3.new(0.6, 0.5, 0.05),
      Color = Color3.fromRGB(200, 220, 255),
      Material = Enum.Material.SmoothPlastic,
      Transparency = 0.3,
      CFrame = CFrame.new(hullPos.X + xOff, deckY + windowY, sternZ),
    })
    window.Parent = model
  end
end

--[[
  Adds cannon port rectangles along both sides of the hull.
  @param model The ship Model
  @param hull The Hull part
  @param count Number of cannon ports per side
  @param color Port hole color (dark)
]]
local function addCannonPorts(model: Model, hull: Part, count: number, color: Color3)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local halfX = hullSize.X / 2
  local halfZ = hullSize.Z / 2

  for i = 1, count do
    local zFrac = (i - 0.5) / count
    local z = hullPos.Z + halfZ * 0.8 - zFrac * hullSize.Z * 0.8

    -- Port side
    local portHole = makePart({
      Name = "CannonPort",
      Size = Vector3.new(0.05, 0.6, 0.6),
      Color = color,
      Material = Enum.Material.SmoothPlastic,
      CFrame = CFrame.new(hullPos.X - halfX + 0.01, hullPos.Y, z),
    })
    portHole.Parent = model

    -- Starboard side
    local starHole = makePart({
      Name = "CannonPort",
      Size = Vector3.new(0.05, 0.6, 0.6),
      Color = color,
      Material = Enum.Material.SmoothPlastic,
      CFrame = CFrame.new(hullPos.X + halfX - 0.01, hullPos.Y, z),
    })
    starHole.Parent = model
  end
end

--[[
  Adds a crow's nest platform to a mast.
  @param model The ship Model
  @param mast The mast Part
  @param yOffset Y offset from mast center (positive = above center)
  @param radius Nest platform radius
]]
local function addCrowsNest(model: Model, mast: Part, yOffset: number, radius: number)
  -- Platform disc
  local platform = makePart({
    Name = "CrowsNest",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.3, radius * 2, radius * 2),
    Color = Color3.fromRGB(80, 55, 30),
    Material = Enum.Material.Wood,
    CFrame = mast.CFrame * CFrame.new(0, yOffset, 0) * CFrame.Angles(0, 0, math.rad(90)),
  })
  platform.Parent = model

  -- Rim ring (torus approximation with 4 thin railing Parts)
  local rimHeight = 0.8
  local rimPositions = {
    CFrame.new(radius, rimHeight / 2, 0),
    CFrame.new(-radius, rimHeight / 2, 0),
    CFrame.new(0, rimHeight / 2, radius),
    CFrame.new(0, rimHeight / 2, -radius),
  }

  for _, offset in rimPositions do
    local rimPost = makePart({
      Name = "NestRim",
      Size = Vector3.new(0.15, rimHeight, 0.15),
      Color = Color3.fromRGB(80, 55, 30),
      Material = Enum.Material.Wood,
      CFrame = mast.CFrame * CFrame.new(0, yOffset + 0.15, 0) * offset,
    })
    rimPost.Parent = model
  end
end

--[[
  Adds deck planking lines (thin dark strips on deck surface for visual detail).
  @param model The ship Model
  @param hull The Hull part
  @param count Number of plank lines
]]
local function addDeckPlanks(model: Model, hull: Part, count: number)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2 + 0.01
  local spacing = hullSize.X / (count + 1)

  for i = 1, count do
    local xOff = -hullSize.X / 2 + i * spacing
    local plank = makePart({
      Name = "DeckPlank",
      Size = Vector3.new(0.05, 0.02, hullSize.Z * 0.85),
      Color = Color3.fromRGB(60, 40, 20),
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(hullPos.X + xOff, deckY, hullPos.Z),
    })
    plank.Parent = model
  end
end

--[[
  Adds gold trim strips along the hull top edges.
  @param model The ship Model
  @param hull The Hull part
]]
local function addGoldTrim(model: Model, hull: Part)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local topY = hullPos.Y + hullSize.Y / 2
  local halfX = hullSize.X / 2
  local goldColor = Color3.fromRGB(255, 200, 50)

  -- Port side trim
  local portTrim = makePart({
    Name = "GoldTrim",
    Size = Vector3.new(0.1, 0.15, hullSize.Z),
    Color = goldColor,
    Material = Enum.Material.SmoothPlastic,
    Reflectance = 0.4,
    CFrame = CFrame.new(hullPos.X - halfX, topY, hullPos.Z),
  })
  portTrim.Parent = model

  -- Starboard side trim
  local starTrim = makePart({
    Name = "GoldTrim",
    Size = Vector3.new(0.1, 0.15, hullSize.Z),
    Color = goldColor,
    Material = Enum.Material.SmoothPlastic,
    Reflectance = 0.4,
    CFrame = CFrame.new(hullPos.X + halfX, topY, hullPos.Z),
  })
  starTrim.Parent = model
end

--[[
  Adds a simple figurehead at the bow.
  @param model The ship Model
  @param hull The Hull part
  @param color Figurehead color
  @param figureType "simple" | "dragon" | "phantom"
]]
local function addFigurehead(model: Model, hull: Part, color: Color3, figureType: string)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local bowZ = hullPos.Z - hullSize.Z / 2

  if figureType == "dragon" then
    -- Dragon head (angular wedge + horn Parts)
    local head = makePart({
      Name = "Figurehead",
      Size = Vector3.new(1.2, 1.5, 2.0),
      Color = color,
      Material = Enum.Material.SmoothPlastic,
      CFrame = CFrame.new(hullPos.X, deckY + 0.5, bowZ - 2.0) * CFrame.Angles(math.rad(-20), 0, 0),
    })
    head.Parent = model

    -- Dragon jaw (smaller wedge below)
    local jaw = makeWedge({
      Name = "DragonJaw",
      Size = Vector3.new(0.8, 0.5, 1.5),
      Color = color,
      Material = Enum.Material.SmoothPlastic,
      CFrame = CFrame.new(hullPos.X, deckY - 0.1, bowZ - 2.5)
        * CFrame.Angles(math.rad(10), math.rad(180), 0),
    })
    jaw.Parent = model

    -- Horns
    for _, side in { -1, 1 } do
      local horn = makePart({
        Name = "DragonHorn",
        Size = Vector3.new(0.15, 1.0, 0.15),
        Color = Color3.fromRGB(200, 180, 120),
        Material = Enum.Material.SmoothPlastic,
        CFrame = CFrame.new(hullPos.X + side * 0.4, deckY + 1.8, bowZ - 1.5)
          * CFrame.Angles(math.rad(-30), 0, math.rad(side * 15)),
      })
      horn.Parent = model
    end

    -- Dragon eyes (neon)
    for _, side in { -1, 1 } do
      local eye = makePart({
        Name = "DragonEye",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(0.25, 0.25, 0.25),
        Color = Color3.fromRGB(255, 50, 0),
        Material = Enum.Material.Neon,
        CFrame = CFrame.new(hullPos.X + side * 0.35, deckY + 0.9, bowZ - 2.8),
      })
      eye.Parent = model
    end
  elseif figureType == "phantom" then
    -- Ghostly skull figurehead
    local skull = makePart({
      Name = "Figurehead",
      Shape = Enum.PartType.Ball,
      Size = Vector3.new(1.8, 2.0, 1.8),
      Color = Color3.fromRGB(140, 160, 200),
      Material = Enum.Material.Neon,
      Transparency = 0.3,
      CFrame = CFrame.new(hullPos.X, deckY + 0.5, bowZ - 1.8),
    })
    skull.Parent = model

    -- Eye sockets (dark)
    for _, side in { -1, 1 } do
      local eyeSocket = makePart({
        Name = "SkullEye",
        Shape = Enum.PartType.Ball,
        Size = Vector3.new(0.4, 0.4, 0.4),
        Color = Color3.fromRGB(50, 80, 150),
        Material = Enum.Material.Neon,
        CFrame = CFrame.new(hullPos.X + side * 0.35, deckY + 0.8, bowZ - 2.5),
      })
      eyeSocket.Parent = model
    end
  else
    -- Simple figurehead (carved bust)
    local bust = makePart({
      Name = "Figurehead",
      Size = Vector3.new(0.8, 1.2, 1.5),
      Color = color,
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(hullPos.X, deckY, bowZ - 1.2) * CFrame.Angles(math.rad(-25), 0, 0),
    })
    bust.Parent = model
  end
end

--[[
  Adds a raised stern platform (poop deck).
  @param model The ship Model
  @param hull The Hull part
  @param riseHeight How high the platform is above the main deck
  @param depth How far forward from stern the raised section goes
  @param color Platform color
  @param material Platform material
]]
local function addSternPlatform(
  model: Model,
  hull: Part,
  riseHeight: number,
  depth: number,
  color: Color3,
  material: Enum.Material
)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local deckY = hullPos.Y + hullSize.Y / 2
  local sternZ = hullPos.Z + hullSize.Z / 2 - depth / 2

  local platform = makePart({
    Name = "SternPlatform",
    Size = Vector3.new(hullSize.X * 0.95, riseHeight, depth),
    Color = color,
    Material = material,
    CFrame = CFrame.new(hullPos.X, deckY + riseHeight / 2, sternZ),
  })
  platform.Parent = model
end

--------------------------------------------------------------------------------
-- TIER 1: ROWBOAT (tiny dinghy, one oar, sad)
--------------------------------------------------------------------------------

local ROWBOAT_HULL_SIZE = Vector3.new(6, 2, 10)
local ROWBOAT_COLOR = Color3.fromRGB(139, 90, 43)

local function buildRowboat(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull =
    makeBaseShip(position, ownerName, ownerUserId, slotIndex, "rowboat", tierName, {
      Size = ROWBOAT_HULL_SIZE,
      Color = ROWBOAT_COLOR,
      Material = Enum.Material.Wood,
    })

  local hullPos = hull.Position
  local deckY = hullPos.Y + hull.Size.Y / 2

  -- Bow taper (small, stubby)
  addBow(model, hull, 2.0, ROWBOAT_COLOR, Enum.Material.Wood)

  -- Two bench seats (cross planks)
  for _, zOff in { -1.5, 1.5 } do
    local bench = makePart({
      Name = "Bench",
      Size = Vector3.new(ROWBOAT_HULL_SIZE.X * 0.8, 0.2, 0.6),
      Color = Color3.fromRGB(120, 80, 35),
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(hullPos.X, deckY + 0.1, hullPos.Z + zOff),
    })
    bench.Parent = model
  end

  -- Single oar (long thin Part resting on gunwale)
  local oarShaft = makePart({
    Name = "OarShaft",
    Size = Vector3.new(0.15, 0.15, 8),
    Color = Color3.fromRGB(100, 70, 35),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X + ROWBOAT_HULL_SIZE.X / 2 - 0.5, deckY + 0.4, hullPos.Z)
      * CFrame.Angles(0, 0, math.rad(10)),
  })
  oarShaft.Parent = model

  -- Oar blade (flat wide end)
  local oarBlade = makePart({
    Name = "OarBlade",
    Size = Vector3.new(0.8, 0.1, 1.5),
    Color = Color3.fromRGB(100, 70, 35),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(hullPos.X + ROWBOAT_HULL_SIZE.X / 2 + 0.5, deckY - 0.2, hullPos.Z - 3.5)
      * CFrame.Angles(0, 0, math.rad(10)),
  })
  oarBlade.Parent = model

  -- Simple gunwale rim
  addGunwales(model, hull, Color3.fromRGB(110, 75, 35), 0.4)

  -- Keel
  addKeel(model, hull, 0.5)

  -- A few deck plank lines
  addDeckPlanks(model, hull, 3)

  return model
end

--------------------------------------------------------------------------------
-- TIER 2: SLOOP (small single-masted, patchy sails, worn wood)
--------------------------------------------------------------------------------

local SLOOP_HULL_SIZE = Vector3.new(8, 4, 16)
local SLOOP_COLOR = Color3.fromRGB(160, 100, 50)

local function buildSloop(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull = makeBaseShip(position, ownerName, ownerUserId, slotIndex, "sloop", tierName, {
    Size = SLOOP_HULL_SIZE,
    Color = SLOOP_COLOR,
    Material = Enum.Material.Wood,
  })

  -- Bow taper
  addBow(model, hull, 3.0, SLOOP_COLOR, Enum.Material.Wood)

  -- Keel
  addKeel(model, hull, 1.0)

  -- Single mast (named "Mast" for CosmeticVisualService)
  local mastHeight = SLOOP_HULL_SIZE.Y * 2
  local mast = addMast(model, hull, "Mast", 0, -1.0, mastHeight, 0.5)

  -- Patchy sail (off-white, slightly worn)
  addSail(model, mast, hull, "Sail", Color3.fromRGB(220, 210, 185), 0)

  -- Yard crossbeam
  addYard(model, mast, mastHeight * 0.3, SLOOP_HULL_SIZE.X * 0.7)

  -- Gunwales
  addGunwales(model, hull, Color3.fromRGB(130, 85, 40), 0.6)

  -- Railing posts
  addRailingPosts(model, hull, 4, 1.0, Color3.fromRGB(130, 85, 40))

  -- Small stern platform
  addSternPlatform(model, hull, 0.5, 3.0, SLOOP_COLOR, Enum.Material.Wood)

  -- Deck planks
  addDeckPlanks(model, hull, 4)

  -- Bowsprit
  addBowsprit(model, hull, 3.0)

  return model
end

--------------------------------------------------------------------------------
-- TIER 3: SCHOONER (two masts, cleaner hull, small cabin)
--------------------------------------------------------------------------------

local SCHOONER_HULL_SIZE = Vector3.new(10, 5, 20)
local SCHOONER_COLOR = Color3.fromRGB(130, 80, 40)

local function buildSchooner(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull =
    makeBaseShip(position, ownerName, ownerUserId, slotIndex, "schooner", tierName, {
      Size = SCHOONER_HULL_SIZE,
      Color = SCHOONER_COLOR,
      Material = Enum.Material.Wood,
    })

  -- Bow taper
  addBow(model, hull, 4.0, SCHOONER_COLOR, Enum.Material.Wood)

  -- Keel
  addKeel(model, hull, 1.2)

  -- Main mast (named "Mast" for cosmetic compat)
  local mainMastHeight = SCHOONER_HULL_SIZE.Y * 2.2
  local mainMast = addMast(model, hull, "Mast", 0, -2.0, mainMastHeight, 0.6)
  addSail(model, mainMast, hull, "Sail", Color3.fromRGB(230, 220, 195), 0)
  addYard(model, mainMast, mainMastHeight * 0.3, SCHOONER_HULL_SIZE.X * 0.7)

  -- Fore mast (secondary)
  local foreMastHeight = SCHOONER_HULL_SIZE.Y * 1.8
  local foreMast = addMast(model, hull, "Mast2", 0, -7.0, foreMastHeight, 0.5)
  addSail(model, foreMast, hull, "Sail2", Color3.fromRGB(230, 220, 195), 0)
  addYard(model, foreMast, foreMastHeight * 0.3, SCHOONER_HULL_SIZE.X * 0.6)

  -- Small cabin at stern
  addCabin(
    model,
    hull,
    SCHOONER_HULL_SIZE.X * 0.7,
    2.5,
    4.0,
    Color3.fromRGB(110, 70, 35),
    Enum.Material.Wood
  )

  -- Gunwales and railing
  addGunwales(model, hull, Color3.fromRGB(110, 70, 35), 0.8)
  addRailingPosts(model, hull, 5, 1.2, Color3.fromRGB(110, 70, 35))

  -- Bowsprit
  addBowsprit(model, hull, 4.0)

  -- Deck planks
  addDeckPlanks(model, hull, 5)

  return model
end

--------------------------------------------------------------------------------
-- TIER 4: BRIGANTINE (three masts, carved railings, larger deck)
--------------------------------------------------------------------------------

local BRIGANTINE_HULL_SIZE = Vector3.new(12, 6, 24)
local BRIGANTINE_COLOR = Color3.fromRGB(100, 70, 35)

local function buildBrigantine(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull =
    makeBaseShip(position, ownerName, ownerUserId, slotIndex, "brigantine", tierName, {
      Size = BRIGANTINE_HULL_SIZE,
      Color = BRIGANTINE_COLOR,
      Material = Enum.Material.Wood,
    })

  -- Bow taper
  addBow(model, hull, 5.0, BRIGANTINE_COLOR, Enum.Material.Wood)

  -- Keel
  addKeel(model, hull, 1.5)

  -- Main mast (cosmetic-compatible)
  local mainMastHeight = BRIGANTINE_HULL_SIZE.Y * 2.5
  local mainMast = addMast(model, hull, "Mast", 0, -2.0, mainMastHeight, 0.7)
  addSail(model, mainMast, hull, "Sail", Color3.fromRGB(240, 230, 200), 0)
  addYard(model, mainMast, mainMastHeight * 0.3, BRIGANTINE_HULL_SIZE.X * 0.75)
  addYard(model, mainMast, mainMastHeight * 0.1, BRIGANTINE_HULL_SIZE.X * 0.5)

  -- Fore mast
  local foreMastHeight = BRIGANTINE_HULL_SIZE.Y * 2.0
  local foreMast = addMast(model, hull, "Mast2", 0, -8.0, foreMastHeight, 0.6)
  addSail(model, foreMast, hull, "Sail2", Color3.fromRGB(240, 230, 200), 0)
  addYard(model, foreMast, foreMastHeight * 0.3, BRIGANTINE_HULL_SIZE.X * 0.6)

  -- Mizzen mast (rear)
  local mizzenHeight = BRIGANTINE_HULL_SIZE.Y * 1.6
  local mizzen = addMast(model, hull, "Mast3", 0, 6.0, mizzenHeight, 0.5)
  addSail(model, mizzen, hull, "Sail3", Color3.fromRGB(240, 230, 200), 0)
  addYard(model, mizzen, mizzenHeight * 0.3, BRIGANTINE_HULL_SIZE.X * 0.5)

  -- Cabin at stern
  addCabin(
    model,
    hull,
    BRIGANTINE_HULL_SIZE.X * 0.75,
    3.0,
    5.0,
    Color3.fromRGB(85, 58, 28),
    Enum.Material.Wood
  )
  addCabinWindows(model, hull, 3, 1.5, 5.0)

  -- Stern platform
  addSternPlatform(model, hull, 1.0, 6.0, BRIGANTINE_COLOR, Enum.Material.Wood)

  -- Gunwales and railing
  addGunwales(model, hull, Color3.fromRGB(85, 58, 28), 1.0)
  addRailingPosts(model, hull, 6, 1.5, Color3.fromRGB(85, 58, 28))

  -- Bowsprit
  addBowsprit(model, hull, 5.0)

  -- Simple figurehead
  addFigurehead(model, hull, Color3.fromRGB(85, 58, 28), "simple")

  -- Crow's nest on main mast
  addCrowsNest(model, mainMast, mainMastHeight * 0.35, 1.2)

  -- Deck planks
  addDeckPlanks(model, hull, 6)

  return model
end

--------------------------------------------------------------------------------
-- TIER 5: GALLEON (massive, gold trim, ornate figurehead, multiple decks)
--------------------------------------------------------------------------------

local GALLEON_HULL_SIZE = Vector3.new(14, 8, 30)
local GALLEON_COLOR = Color3.fromRGB(80, 55, 30)

local function buildGalleon(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull =
    makeBaseShip(position, ownerName, ownerUserId, slotIndex, "galleon", tierName, {
      Size = GALLEON_HULL_SIZE,
      Color = GALLEON_COLOR,
      Material = Enum.Material.Wood,
    })

  -- Bow taper
  addBow(model, hull, 6.0, GALLEON_COLOR, Enum.Material.Wood)

  -- Keel
  addKeel(model, hull, 2.0)

  -- Gold trim along hull edges
  addGoldTrim(model, hull)

  -- Main mast (cosmetic-compatible)
  local mainMastHeight = GALLEON_HULL_SIZE.Y * 2.8
  local mainMast = addMast(model, hull, "Mast", 0, -3.0, mainMastHeight, 0.8)
  addSail(model, mainMast, hull, "Sail", Color3.fromRGB(245, 235, 210), 0)
  addYard(model, mainMast, mainMastHeight * 0.35, GALLEON_HULL_SIZE.X * 0.8)
  addYard(model, mainMast, mainMastHeight * 0.1, GALLEON_HULL_SIZE.X * 0.6)

  -- Fore mast
  local foreMastHeight = GALLEON_HULL_SIZE.Y * 2.3
  local foreMast = addMast(model, hull, "Mast2", 0, -10.0, foreMastHeight, 0.7)
  addSail(model, foreMast, hull, "Sail2", Color3.fromRGB(245, 235, 210), 0)
  addYard(model, foreMast, foreMastHeight * 0.35, GALLEON_HULL_SIZE.X * 0.65)

  -- Mizzen mast
  local mizzenHeight = GALLEON_HULL_SIZE.Y * 2.0
  local mizzen = addMast(model, hull, "Mast3", 0, 7.0, mizzenHeight, 0.6)
  addSail(model, mizzen, hull, "Sail3", Color3.fromRGB(245, 235, 210), 0)
  addYard(model, mizzen, mizzenHeight * 0.3, GALLEON_HULL_SIZE.X * 0.5)

  -- Raised stern castle
  addSternPlatform(model, hull, 2.0, 8.0, GALLEON_COLOR, Enum.Material.Wood)

  -- Large stern cabin
  addCabin(
    model,
    hull,
    GALLEON_HULL_SIZE.X * 0.8,
    4.0,
    6.0,
    Color3.fromRGB(65, 45, 25),
    Enum.Material.Wood
  )
  addCabinWindows(model, hull, 4, 2.0, 6.0)

  -- Cannon ports
  addCannonPorts(model, hull, 5, Color3.fromRGB(30, 25, 20))

  -- Gunwales and ornate railing
  addGunwales(model, hull, Color3.fromRGB(65, 45, 25), 1.2)
  addRailingPosts(model, hull, 8, 1.8, Color3.fromRGB(65, 45, 25))

  -- Bowsprit
  addBowsprit(model, hull, 7.0)

  -- Ornate figurehead
  addFigurehead(model, hull, Color3.fromRGB(200, 160, 80), "simple")

  -- Crow's nest on main mast
  addCrowsNest(model, mainMast, mainMastHeight * 0.38, 1.5)

  -- Deck planks
  addDeckPlanks(model, hull, 7)

  -- Subtle gold accent PointLight
  local goldGlow = Instance.new("PointLight")
  goldGlow.Name = "TierGlow"
  goldGlow.Color = Color3.fromRGB(255, 200, 50)
  goldGlow.Brightness = 0.5
  goldGlow.Range = 15
  goldGlow.Parent = hull

  return model
end

--------------------------------------------------------------------------------
-- TIER 6: WAR GALLEON (flagship, glowing gold accents, dragon figurehead)
--------------------------------------------------------------------------------

local WAR_GALLEON_HULL_SIZE = Vector3.new(16, 9, 34)
local WAR_GALLEON_COLOR = Color3.fromRGB(60, 40, 25)

local function buildWarGalleon(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull =
    makeBaseShip(position, ownerName, ownerUserId, slotIndex, "war_galleon", tierName, {
      Size = WAR_GALLEON_HULL_SIZE,
      Color = WAR_GALLEON_COLOR,
      Material = Enum.Material.Wood,
    })

  -- Bow taper
  addBow(model, hull, 7.0, WAR_GALLEON_COLOR, Enum.Material.Wood)

  -- Keel
  addKeel(model, hull, 2.5)

  -- Gold trim along hull edges
  addGoldTrim(model, hull)

  -- Additional gold band along mid-hull
  local hullPos = hull.Position
  local hullSize = hull.Size
  local midBand = makePart({
    Name = "GoldBand",
    Size = Vector3.new(0.1, 0.3, hullSize.Z),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.SmoothPlastic,
    Reflectance = 0.5,
    CFrame = CFrame.new(hullPos.X - hullSize.X / 2, hullPos.Y, hullPos.Z),
  })
  midBand.Parent = model
  local midBand2 = makePart({
    Name = "GoldBand",
    Size = Vector3.new(0.1, 0.3, hullSize.Z),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.SmoothPlastic,
    Reflectance = 0.5,
    CFrame = CFrame.new(hullPos.X + hullSize.X / 2, hullPos.Y, hullPos.Z),
  })
  midBand2.Parent = model

  -- Main mast (cosmetic-compatible)
  local mainMastHeight = WAR_GALLEON_HULL_SIZE.Y * 3.0
  local mainMast = addMast(model, hull, "Mast", 0, -4.0, mainMastHeight, 0.9)
  addSail(model, mainMast, hull, "Sail", Color3.fromRGB(245, 235, 210), 0)
  addYard(model, mainMast, mainMastHeight * 0.35, WAR_GALLEON_HULL_SIZE.X * 0.8)
  addYard(model, mainMast, mainMastHeight * 0.15, WAR_GALLEON_HULL_SIZE.X * 0.6)
  addYard(model, mainMast, mainMastHeight * -0.05, WAR_GALLEON_HULL_SIZE.X * 0.45)

  -- Fore mast
  local foreMastHeight = WAR_GALLEON_HULL_SIZE.Y * 2.5
  local foreMast = addMast(model, hull, "Mast2", 0, -12.0, foreMastHeight, 0.8)
  addSail(model, foreMast, hull, "Sail2", Color3.fromRGB(245, 235, 210), 0)
  addYard(model, foreMast, foreMastHeight * 0.35, WAR_GALLEON_HULL_SIZE.X * 0.7)
  addYard(model, foreMast, foreMastHeight * 0.1, WAR_GALLEON_HULL_SIZE.X * 0.5)

  -- Mizzen mast
  local mizzenHeight = WAR_GALLEON_HULL_SIZE.Y * 2.2
  local mizzen = addMast(model, hull, "Mast3", 0, 8.0, mizzenHeight, 0.7)
  addSail(model, mizzen, hull, "Sail3", Color3.fromRGB(245, 235, 210), 0)
  addYard(model, mizzen, mizzenHeight * 0.3, WAR_GALLEON_HULL_SIZE.X * 0.55)

  -- Raised stern castle (taller)
  addSternPlatform(model, hull, 2.5, 9.0, WAR_GALLEON_COLOR, Enum.Material.Wood)

  -- Grand stern cabin
  addCabin(
    model,
    hull,
    WAR_GALLEON_HULL_SIZE.X * 0.85,
    5.0,
    7.0,
    Color3.fromRGB(50, 32, 18),
    Enum.Material.Wood
  )
  addCabinWindows(model, hull, 5, 2.5, 7.0)

  -- Cannon ports (more than galleon)
  addCannonPorts(model, hull, 7, Color3.fromRGB(25, 20, 15))

  -- Ornate railing
  addGunwales(model, hull, Color3.fromRGB(50, 32, 18), 1.4)
  addRailingPosts(model, hull, 10, 2.0, Color3.fromRGB(50, 32, 18))

  -- Bowsprit
  addBowsprit(model, hull, 8.0)

  -- Dragon figurehead
  addFigurehead(model, hull, Color3.fromRGB(200, 160, 50), "dragon")

  -- Crow's nests on main and fore masts
  addCrowsNest(model, mainMast, mainMastHeight * 0.4, 1.8)
  addCrowsNest(model, foreMast, foreMastHeight * 0.38, 1.3)

  -- Deck planks
  addDeckPlanks(model, hull, 8)

  -- Gold glow PointLight
  local goldGlow = Instance.new("PointLight")
  goldGlow.Name = "TierGlow"
  goldGlow.Color = Color3.fromRGB(255, 200, 50)
  goldGlow.Brightness = 1.5
  goldGlow.Range = 30
  goldGlow.Parent = hull

  -- Gold shimmer particles
  local shimmer = Instance.new("ParticleEmitter")
  shimmer.Name = "TierShimmer"
  shimmer.Color = ColorSequence.new(Color3.fromRGB(255, 215, 50))
  shimmer.Size = NumberSequence.new(0.15, 0)
  shimmer.Lifetime = NumberRange.new(1.0, 2.0)
  shimmer.Rate = 5
  shimmer.Speed = NumberRange.new(0.3, 1.0)
  shimmer.SpreadAngle = Vector2.new(180, 180)
  shimmer.Transparency = NumberSequence.new(0.3, 1)
  shimmer.LightEmission = 0.6
  shimmer.Parent = hull

  return model
end

--------------------------------------------------------------------------------
-- TIER 7: GHOST SHIP (spectral glow, phantom sails, ethereal particle effects)
--------------------------------------------------------------------------------

local GHOST_SHIP_HULL_SIZE = Vector3.new(16, 9, 34)
local GHOST_SHIP_COLOR = Color3.fromRGB(120, 140, 180)
local GHOST_GLOW_COLOR = Color3.fromRGB(100, 180, 255)

local function buildGhostShip(
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number,
  tierName: string
): Model
  local model, hull =
    makeBaseShip(position, ownerName, ownerUserId, slotIndex, "ghost_ship", tierName, {
      Size = GHOST_SHIP_HULL_SIZE,
      Color = GHOST_SHIP_COLOR,
      Material = Enum.Material.Neon,
      Transparency = 0.35,
    })

  local ghostMaterial = Enum.Material.Neon
  local ghostTransparency = 0.4

  -- Bow taper (spectral)
  addBow(model, hull, 7.0, GHOST_SHIP_COLOR, ghostMaterial)
  -- Make bow pieces semi-transparent
  for _, child in model:GetChildren() do
    if child.Name == "BowPort" or child.Name == "BowStarboard" then
      child.Transparency = ghostTransparency
    end
  end

  -- Keel (ghostly)
  local hullPos = hull.Position
  local hullSize = hull.Size
  local keel = makePart({
    Name = "Keel",
    Size = Vector3.new(0.4, 2.5, hullSize.Z * 1.05),
    Color = Color3.fromRGB(100, 120, 160),
    Material = ghostMaterial,
    Transparency = ghostTransparency,
    CFrame = CFrame.new(hullPos.X, hullPos.Y - hullSize.Y / 2 - 1.25, hullPos.Z),
  })
  keel.Parent = model

  -- Main mast (cosmetic-compatible, ghostly)
  local mainMastHeight = GHOST_SHIP_HULL_SIZE.Y * 3.0
  local mainMast = addMast(model, hull, "Mast", 0, -4.0, mainMastHeight, 0.9)
  mainMast.Color = Color3.fromRGB(100, 120, 160)
  mainMast.Material = ghostMaterial
  mainMast.Transparency = ghostTransparency

  -- Tattered phantom sails (semi-transparent, eerie)
  addSail(model, mainMast, hull, "Sail", Color3.fromRGB(140, 170, 220), 0.5)

  addYard(model, mainMast, mainMastHeight * 0.35, GHOST_SHIP_HULL_SIZE.X * 0.8)
  addYard(model, mainMast, mainMastHeight * 0.15, GHOST_SHIP_HULL_SIZE.X * 0.6)

  -- Fore mast
  local foreMastHeight = GHOST_SHIP_HULL_SIZE.Y * 2.5
  local foreMast = addMast(model, hull, "Mast2", 0, -12.0, foreMastHeight, 0.8)
  foreMast.Color = Color3.fromRGB(100, 120, 160)
  foreMast.Material = ghostMaterial
  foreMast.Transparency = ghostTransparency

  addSail(model, foreMast, hull, "Sail2", Color3.fromRGB(140, 170, 220), 0.5)
  addYard(model, foreMast, foreMastHeight * 0.35, GHOST_SHIP_HULL_SIZE.X * 0.7)

  -- Mizzen mast
  local mizzenHeight = GHOST_SHIP_HULL_SIZE.Y * 2.2
  local mizzen = addMast(model, hull, "Mast3", 0, 8.0, mizzenHeight, 0.7)
  mizzen.Color = Color3.fromRGB(100, 120, 160)
  mizzen.Material = ghostMaterial
  mizzen.Transparency = ghostTransparency

  addSail(model, mizzen, hull, "Sail3", Color3.fromRGB(140, 170, 220), 0.5)
  addYard(model, mizzen, mizzenHeight * 0.3, GHOST_SHIP_HULL_SIZE.X * 0.55)

  -- Make all yards ghostly
  for _, child in model:GetChildren() do
    if child.Name == "Yard" then
      child.Color = Color3.fromRGB(100, 120, 160)
      child.Material = ghostMaterial
      child.Transparency = ghostTransparency
    end
  end

  -- Ghostly stern structure
  local sternZ = hullPos.Z + hullSize.Z / 2 - 4.0
  local sternCabin = makePart({
    Name = "Cabin",
    Size = Vector3.new(hullSize.X * 0.8, 5.0, 7.0),
    Color = Color3.fromRGB(100, 120, 160),
    Material = ghostMaterial,
    Transparency = ghostTransparency,
    CFrame = CFrame.new(hullPos.X, hullPos.Y + hullSize.Y / 2 + 2.5, sternZ),
  })
  sternCabin.Parent = model

  -- Ghost railing
  addGunwales(model, hull, Color3.fromRGB(100, 120, 160), 1.4)
  -- Make gunwales ghostly
  for _, child in model:GetChildren() do
    if child.Name == "Gunwale" then
      child.Material = ghostMaterial
      child.Transparency = ghostTransparency
    end
  end

  -- Cannon ports (dark, eerie)
  addCannonPorts(model, hull, 6, Color3.fromRGB(50, 60, 90))
  for _, child in model:GetChildren() do
    if child.Name == "CannonPort" then
      child.Material = Enum.Material.Neon
      child.Color = Color3.fromRGB(50, 80, 150)
      child.Transparency = 0.3
    end
  end

  -- Bowsprit
  addBowsprit(model, hull, 8.0)
  local bowsprit = model:FindFirstChild("Bowsprit")
  if bowsprit then
    bowsprit.Color = Color3.fromRGB(100, 120, 160)
    bowsprit.Material = ghostMaterial
    bowsprit.Transparency = ghostTransparency
  end

  -- Phantom skull figurehead
  addFigurehead(model, hull, GHOST_GLOW_COLOR, "phantom")

  -- Spectral glow PointLight
  local spectralGlow = Instance.new("PointLight")
  spectralGlow.Name = "TierGlow"
  spectralGlow.Color = GHOST_GLOW_COLOR
  spectralGlow.Brightness = 2
  spectralGlow.Range = 40
  spectralGlow.Parent = hull

  -- Ethereal fog/wisp ParticleEmitter
  local wisps = Instance.new("ParticleEmitter")
  wisps.Name = "TierShimmer"
  wisps.Color = ColorSequence.new(GHOST_GLOW_COLOR)
  wisps.Size = NumberSequence.new(0.5, 0)
  wisps.Lifetime = NumberRange.new(1.5, 3)
  wisps.Rate = 8
  wisps.Speed = NumberRange.new(0.5, 1.5)
  wisps.SpreadAngle = Vector2.new(180, 180)
  wisps.Transparency = NumberSequence.new(0.4, 1)
  wisps.LightEmission = 1.0
  wisps.Parent = hull

  -- Ghost fire on deck (small neon Parts flickering via particles)
  local deckY = hullPos.Y + hullSize.Y / 2
  local ghostFirePositions = {
    Vector3.new(-3, deckY + 0.5, hullPos.Z - 5),
    Vector3.new(3, deckY + 0.5, hullPos.Z + 2),
    Vector3.new(0, deckY + 0.5, hullPos.Z - 8),
  }

  for i, firePos in ghostFirePositions do
    local firePart = makePart({
      Name = "GhostFire_" .. i,
      Shape = Enum.PartType.Ball,
      Size = Vector3.new(0.6, 0.6, 0.6),
      Color = Color3.fromRGB(80, 150, 255),
      Material = Enum.Material.Neon,
      Transparency = 0.4,
      CFrame = CFrame.new(hullPos.X + firePos.X - hullPos.X, firePos.Y, firePos.Z),
    })
    firePart.Parent = model

    -- Fire particle effect
    local fireParticles = Instance.new("ParticleEmitter")
    fireParticles.Color =
      ColorSequence.new(Color3.fromRGB(80, 150, 255), Color3.fromRGB(150, 200, 255))
    fireParticles.Size = NumberSequence.new(0.3, 0)
    fireParticles.Lifetime = NumberRange.new(0.5, 1.0)
    fireParticles.Rate = 6
    fireParticles.Speed = NumberRange.new(1, 3)
    fireParticles.SpreadAngle = Vector2.new(15, 15)
    fireParticles.Transparency = NumberSequence.new(0.2, 1)
    fireParticles.LightEmission = 1.0
    fireParticles.Parent = firePart
  end

  -- Crow's nest on main mast (ghostly)
  addCrowsNest(model, mainMast, mainMastHeight * 0.4, 1.8)
  for _, child in model:GetChildren() do
    if child.Name == "CrowsNest" or child.Name == "NestRim" then
      child.Color = Color3.fromRGB(100, 120, 160)
      child.Material = ghostMaterial
      child.Transparency = ghostTransparency
    end
  end

  return model
end

--------------------------------------------------------------------------------
-- BUILDER REGISTRY
--------------------------------------------------------------------------------

local BUILDERS = {
  rowboat = buildRowboat,
  sloop = buildSloop,
  schooner = buildSchooner,
  brigantine = buildBrigantine,
  galleon = buildGalleon,
  war_galleon = buildWarGalleon,
  ghost_ship = buildGhostShip,
}

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--[[
  Builds a detailed ship model for the given tier.
  @param tierId Ship tier ID string (e.g. "rowboat", "galleon", "ghost_ship")
  @param tierName Ship tier display name (e.g. "Rowboat", "Galleon")
  @param position World position of the dock point (bottom-center of ship)
  @param ownerName Display name of the ship owner
  @param ownerUserId UserId of the ship owner
  @param slotIndex Dock slot number
  @return Model or nil if tierId has no builder
]]
function ShipModels.build(
  tierId: string,
  tierName: string,
  position: Vector3,
  ownerName: string,
  ownerUserId: number,
  slotIndex: number
): Model?
  local builder = BUILDERS[tierId]
  if not builder then
    return nil
  end
  return builder(position, ownerName, ownerUserId, slotIndex, tierName)
end

return ShipModels
