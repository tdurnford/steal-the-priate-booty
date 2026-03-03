--[[
  ContainerModels.lua
  Builds detailed Part-based 3D models for each container type.

  Each builder function creates a Model with:
    - A "Body" PrimaryPart (carries metadata attributes, used for hit detection + VFX)
    - Decorative child Parts that give each container a distinct pirate-themed look

  Used by ContainerService.createContainerModel() to replace placeholder boxes.
  All Parts are Anchored (containers are static world objects).
]]

local ContainerModels = {}

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
  Creates a Model with a Body PrimaryPart at the given position.
  @param instanceId Unique container ID string
  @param bodyProps Properties for the Body part
  @param position World position (bottom-center of container)
  @return (Model, Part) The model and its Body part
]]
local function makeBaseModel(
  instanceId: string,
  bodyProps: { [string]: any },
  position: Vector3
): (Model, Part)
  local model = Instance.new("Model")
  model.Name = "Container_" .. instanceId

  local bodySize = bodyProps.Size or Vector3.new(3, 3, 3)

  local body = Instance.new("Part")
  body.Name = "Body"
  body.Anchored = true
  body.CanCollide = true
  body.CanQuery = true
  body.CanTouch = false
  body.CastShadow = true
  body.TopSurface = Enum.SurfaceType.Smooth
  body.BottomSurface = Enum.SurfaceType.Smooth
  body.CFrame = CFrame.new(position + Vector3.new(0, bodySize.Y / 2, 0))

  for key, value in bodyProps do
    (body :: any)[key] = value
  end

  body.Parent = model
  model.PrimaryPart = body

  return model, body
end

--------------------------------------------------------------------------------
-- CRATE (simple wooden crate with planks and corner posts)
--------------------------------------------------------------------------------

function ContainerModels.buildCrate(position: Vector3, instanceId: string): Model
  local model, body = makeBaseModel(instanceId, {
    Size = Vector3.new(2.8, 2.8, 2.8),
    Color = Color3.fromRGB(139, 90, 43),
    Material = Enum.Material.Wood,
  }, position)

  local center = body.Position
  local half = 1.4 -- half of 2.8

  -- 4 vertical corner posts (darker wood)
  local postColor = Color3.fromRGB(100, 60, 25)
  local postSize = Vector3.new(0.35, 3.0, 0.35)
  local offsets = {
    Vector3.new(half - 0.17, 0, half - 0.17),
    Vector3.new(-half + 0.17, 0, half - 0.17),
    Vector3.new(half - 0.17, 0, -half + 0.17),
    Vector3.new(-half + 0.17, 0, -half + 0.17),
  }
  for i, offset in offsets do
    local post = makePart({
      Name = "Post_" .. i,
      Size = postSize,
      Color = postColor,
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(center + offset),
    })
    post.Parent = model
  end

  -- Horizontal cross planks on front and back faces
  local plankColor = Color3.fromRGB(120, 75, 35)
  for _, zSign in { 1, -1 } do
    local plank = makePart({
      Name = "CrossPlank_" .. (zSign > 0 and "Front" or "Back"),
      Size = Vector3.new(2.9, 0.25, 0.15),
      Color = plankColor,
      Material = Enum.Material.Wood,
      CFrame = CFrame.new(center + Vector3.new(0, 0, zSign * (half + 0.02))),
    })
    plank.Parent = model
  end

  -- Top lid (slightly lighter, raised)
  local lid = makePart({
    Name = "Lid",
    Size = Vector3.new(2.9, 0.2, 2.9),
    Color = Color3.fromRGB(155, 105, 55),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(center + Vector3.new(0, half + 0.1, 0)),
  })
  lid.Parent = model

  -- Lid center plank (decorative seam)
  local lidSeam = makePart({
    Name = "LidSeam",
    Size = Vector3.new(0.15, 0.22, 2.9),
    Color = plankColor,
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(center + Vector3.new(0, half + 0.11, 0)),
  })
  lidSeam.Parent = model

  return model
end

--------------------------------------------------------------------------------
-- BARREL (cylindrical barrel with metal bands)
--------------------------------------------------------------------------------

function ContainerModels.buildBarrel(position: Vector3, instanceId: string): Model
  -- Cylinder axis is along X in Roblox. Size = (Length, Diameter, Diameter).
  -- Rotate 90° around Z to stand upright.
  local model, body = makeBaseModel(instanceId, {
    Size = Vector3.new(3.6, 2.2, 2.2),
    Color = Color3.fromRGB(120, 75, 35),
    Material = Enum.Material.Wood,
    Shape = Enum.PartType.Cylinder,
  }, position)

  -- Correct the CFrame: cylinder needs 90° Z rotation to stand upright
  -- Position recalculation: vertical extent is now Size.X/2 = 1.8
  body.Size = Vector3.new(3.6, 2.2, 2.2)
  body.CFrame = CFrame.new(position + Vector3.new(0, 1.8, 0)) * CFrame.Angles(0, 0, math.rad(90))

  local center = position + Vector3.new(0, 1.8, 0)

  -- Metal bands (thin cylinders around the barrel)
  local bandColor = Color3.fromRGB(80, 80, 90)
  local bandOffsets = { -1.0, 0, 1.0 } -- top, middle, bottom thirds
  for i, yOff in bandOffsets do
    local band = makePart({
      Name = "Band_" .. i,
      Size = Vector3.new(0.15, 2.35, 2.35),
      Color = bandColor,
      Material = Enum.Material.Metal,
      Shape = Enum.PartType.Cylinder,
      CFrame = CFrame.new(center + Vector3.new(0, yOff, 0)) * CFrame.Angles(0, 0, math.rad(90)),
    })
    band.Parent = model
  end

  -- Top cap (flat disc)
  local cap = makePart({
    Name = "TopCap",
    Size = Vector3.new(0.12, 2.0, 2.0),
    Color = Color3.fromRGB(100, 65, 30),
    Material = Enum.Material.Wood,
    Shape = Enum.PartType.Cylinder,
    CFrame = CFrame.new(center + Vector3.new(0, 1.8, 0)) * CFrame.Angles(0, 0, math.rad(90)),
  })
  cap.Parent = model

  return model
end

--------------------------------------------------------------------------------
-- TREASURE CHEST (ornate chest with lid, gold clasp, metal trim)
--------------------------------------------------------------------------------

function ContainerModels.buildTreasureChest(position: Vector3, instanceId: string): Model
  local model, body = makeBaseModel(instanceId, {
    Size = Vector3.new(3.2, 1.8, 2.2),
    Color = Color3.fromRGB(130, 80, 35),
    Material = Enum.Material.Wood,
  }, position)

  local center = body.Position

  -- Chest lid (domed top — use a slightly taller part, angled back)
  local lid = makePart({
    Name = "Lid",
    Size = Vector3.new(3.3, 0.9, 2.3),
    Color = Color3.fromRGB(145, 95, 45),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(center + Vector3.new(0, 1.35, 0)),
  })
  lid.Parent = model

  -- Lid ridge (rounded top accent)
  local ridge = makePart({
    Name = "LidRidge",
    Size = Vector3.new(3.3, 0.2, 0.25),
    Color = Color3.fromRGB(165, 115, 55),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(center + Vector3.new(0, 1.8, 0)),
  })
  ridge.Parent = model

  -- Gold clasp (centered on front face)
  local clasp = makePart({
    Name = "Clasp",
    Size = Vector3.new(0.5, 0.5, 0.2),
    Color = Color3.fromRGB(220, 180, 50),
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(center + Vector3.new(0, 0.6, 1.12)),
  })
  clasp.Parent = model

  -- Keyhole detail on clasp
  local keyhole = makePart({
    Name = "Keyhole",
    Size = Vector3.new(0.1, 0.2, 0.05),
    Color = Color3.fromRGB(40, 30, 20),
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(center + Vector3.new(0, 0.55, 1.24)),
  })
  keyhole.Parent = model

  -- Metal trim strips along bottom edges (front and back)
  local trimColor = Color3.fromRGB(180, 145, 50)
  for _, zSign in { 1, -1 } do
    local trim = makePart({
      Name = "BottomTrim_" .. (zSign > 0 and "Front" or "Back"),
      Size = Vector3.new(3.3, 0.15, 0.15),
      Color = trimColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(0, -0.9 + 0.07, zSign * 1.1)),
    })
    trim.Parent = model
  end

  -- Side trim strips
  for _, xSign in { 1, -1 } do
    local trim = makePart({
      Name = "SideTrim_" .. (xSign > 0 and "Right" or "Left"),
      Size = Vector3.new(0.15, 0.15, 2.3),
      Color = trimColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(xSign * 1.6, -0.9 + 0.07, 0)),
    })
    trim.Parent = model
  end

  -- Hinges on back (2 small cubes)
  local hingeColor = Color3.fromRGB(100, 90, 70)
  for _, xOff in { -0.8, 0.8 } do
    local hinge = makePart({
      Name = "Hinge",
      Size = Vector3.new(0.2, 0.25, 0.15),
      Color = hingeColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(xOff, 0.9, -1.12)),
    })
    hinge.Parent = model
  end

  return model
end

--------------------------------------------------------------------------------
-- REINFORCED TRUNK (heavy, metal-banded trunk with corner reinforcements)
--------------------------------------------------------------------------------

function ContainerModels.buildReinforcedTrunk(position: Vector3, instanceId: string): Model
  local model, body = makeBaseModel(instanceId, {
    Size = Vector3.new(3.6, 2.6, 2.6),
    Color = Color3.fromRGB(85, 65, 40),
    Material = Enum.Material.Wood,
  }, position)

  local center = body.Position
  local hx, hy, hz = 1.8, 1.3, 1.3

  -- Heavy iron bands (3 horizontal, spanning front and back)
  local bandColor = Color3.fromRGB(70, 70, 80)
  local bandYs = { -0.6, 0.0, 0.6 }
  for i, yOff in bandYs do
    -- Front band
    local frontBand = makePart({
      Name = "FrontBand_" .. i,
      Size = Vector3.new(3.8, 0.2, 0.12),
      Color = bandColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(0, yOff, hz + 0.02)),
    })
    frontBand.Parent = model

    -- Back band
    local backBand = makePart({
      Name = "BackBand_" .. i,
      Size = Vector3.new(3.8, 0.2, 0.12),
      Color = bandColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(0, yOff, -hz - 0.02)),
    })
    backBand.Parent = model
  end

  -- Side bands (vertical straps)
  for _, xSign in { 1, -1 } do
    local sideBand = makePart({
      Name = "SideBand_" .. (xSign > 0 and "R" or "L"),
      Size = Vector3.new(0.12, 2.8, 2.7),
      Color = bandColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(xSign * (hx + 0.02), 0, 0)),
    })
    sideBand.Parent = model
  end

  -- 8 corner reinforcements (metal cubes)
  local cornerColor = Color3.fromRGB(60, 60, 70)
  local cornerSize = Vector3.new(0.4, 0.4, 0.4)
  for _, xS in { 1, -1 } do
    for _, yS in { 1, -1 } do
      for _, zS in { 1, -1 } do
        local corner = makePart({
          Name = "Corner",
          Size = cornerSize,
          Color = cornerColor,
          Material = Enum.Material.Metal,
          CFrame = CFrame.new(
            center + Vector3.new(xS * (hx - 0.1), yS * (hy - 0.1), zS * (hz - 0.1))
          ),
        })
        corner.Parent = model
      end
    end
  end

  -- Front lock plate
  local lockPlate = makePart({
    Name = "LockPlate",
    Size = Vector3.new(0.8, 0.8, 0.15),
    Color = Color3.fromRGB(80, 80, 90),
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(center + Vector3.new(0, 0, hz + 0.06)),
  })
  lockPlate.Parent = model

  -- Lock ring
  local lockRing = makePart({
    Name = "LockRing",
    Size = Vector3.new(0.3, 0.3, 0.3),
    Color = Color3.fromRGB(90, 90, 100),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
    CFrame = CFrame.new(center + Vector3.new(0, -0.1, hz + 0.15)),
  })
  lockRing.Parent = model

  -- Side handles
  for _, zSign in { 1, -1 } do
    local handle = makePart({
      Name = "Handle_" .. (zSign > 0 and "Front" or "Back"),
      Size = Vector3.new(0.6, 0.15, 0.15),
      Color = Color3.fromRGB(70, 70, 80),
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + Vector3.new(hx + 0.1, 0.3, zSign * 0.6)),
    })
    handle.Parent = model
  end

  -- Flat lid with rivets
  local lid = makePart({
    Name = "Lid",
    Size = Vector3.new(3.7, 0.15, 2.7),
    Color = Color3.fromRGB(75, 60, 40),
    Material = Enum.Material.Wood,
    CFrame = CFrame.new(center + Vector3.new(0, hy + 0.07, 0)),
  })
  lid.Parent = model

  -- Lid rivets (small balls on lid)
  local rivetColor = Color3.fromRGB(90, 90, 100)
  local rivetPositions = {
    Vector3.new(-1.4, 0, -0.9),
    Vector3.new(1.4, 0, -0.9),
    Vector3.new(-1.4, 0, 0.9),
    Vector3.new(1.4, 0, 0.9),
  }
  for i, rp in rivetPositions do
    local rivet = makePart({
      Name = "Rivet_" .. i,
      Size = Vector3.new(0.15, 0.15, 0.15),
      Color = rivetColor,
      Material = Enum.Material.Metal,
      Shape = Enum.PartType.Ball,
      CFrame = CFrame.new(center + Vector3.new(rp.X, hy + 0.15, rp.Z)),
    })
    rivet.Parent = model
  end

  return model
end

--------------------------------------------------------------------------------
-- CAPTAIN'S VAULT (elaborate vault with gold accents and ornamentation)
--------------------------------------------------------------------------------

function ContainerModels.buildCaptainsVault(position: Vector3, instanceId: string): Model
  local model, body = makeBaseModel(instanceId, {
    Size = Vector3.new(4.0, 3.0, 3.0),
    Color = Color3.fromRGB(160, 120, 50),
    Material = Enum.Material.Wood,
  }, position)

  local center = body.Position
  local hx, hy, hz = 2.0, 1.5, 1.5

  -- Gold trim along all 12 edges
  local goldColor = Color3.fromRGB(230, 190, 50)
  local edgeThickness = 0.18

  -- Vertical edges (4)
  for _, xS in { 1, -1 } do
    for _, zS in { 1, -1 } do
      local edge = makePart({
        Name = "VEdge",
        Size = Vector3.new(edgeThickness, 3.1, edgeThickness),
        Color = goldColor,
        Material = Enum.Material.Metal,
        CFrame = CFrame.new(center + Vector3.new(xS * (hx - 0.05), 0, zS * (hz - 0.05))),
      })
      edge.Parent = model
    end
  end

  -- Horizontal edges along X (top and bottom, front and back = 4)
  for _, yS in { 1, -1 } do
    for _, zS in { 1, -1 } do
      local edge = makePart({
        Name = "HEdgeX",
        Size = Vector3.new(4.1, edgeThickness, edgeThickness),
        Color = goldColor,
        Material = Enum.Material.Metal,
        CFrame = CFrame.new(center + Vector3.new(0, yS * (hy - 0.05), zS * (hz - 0.05))),
      })
      edge.Parent = model
    end
  end

  -- Horizontal edges along Z (top and bottom, left and right = 4)
  for _, yS in { 1, -1 } do
    for _, xS in { 1, -1 } do
      local edge = makePart({
        Name = "HEdgeZ",
        Size = Vector3.new(edgeThickness, edgeThickness, 3.1),
        Color = goldColor,
        Material = Enum.Material.Metal,
        CFrame = CFrame.new(center + Vector3.new(xS * (hx - 0.05), yS * (hy - 0.05), 0)),
      })
      edge.Parent = model
    end
  end

  -- Ornate front panel (gold inlay)
  local frontPanel = makePart({
    Name = "FrontPanel",
    Size = Vector3.new(2.0, 1.8, 0.1),
    Color = Color3.fromRGB(200, 160, 40),
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(center + Vector3.new(0, 0, hz + 0.02)),
  })
  frontPanel.Parent = model

  -- Lock mechanism (elaborate disc + keyhole)
  local lockDisc = makePart({
    Name = "LockDisc",
    Size = Vector3.new(0.6, 0.6, 0.6),
    Color = goldColor,
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
    CFrame = CFrame.new(center + Vector3.new(0, 0, hz + 0.12)),
  })
  lockDisc.Parent = model

  local keyhole = makePart({
    Name = "Keyhole",
    Size = Vector3.new(0.08, 0.25, 0.1),
    Color = Color3.fromRGB(30, 20, 10),
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(center + Vector3.new(0, -0.05, hz + 0.25)),
  })
  keyhole.Parent = model

  -- Skull decoration above lock (skull = ball, jaw = small part)
  local skull = makePart({
    Name = "SkullDeco",
    Size = Vector3.new(0.5, 0.5, 0.5),
    Color = Color3.fromRGB(240, 230, 200),
    Material = Enum.Material.SmoothPlastic,
    Shape = Enum.PartType.Ball,
    CFrame = CFrame.new(center + Vector3.new(0, 0.8, hz + 0.1)),
  })
  skull.Parent = model

  -- Crossbones behind skull (two thin angled parts)
  for _, angle in { 45, -45 } do
    local bone = makePart({
      Name = "Crossbone",
      Size = Vector3.new(0.8, 0.1, 0.1),
      Color = Color3.fromRGB(240, 230, 200),
      Material = Enum.Material.SmoothPlastic,
      CFrame = CFrame.new(center + Vector3.new(0, 0.8, hz + 0.05))
        * CFrame.Angles(0, 0, math.rad(angle)),
    })
    bone.Parent = model
  end

  -- Jewel accents on front (2 small colored balls)
  local jewelColors = {
    Color3.fromRGB(200, 30, 30), -- ruby
    Color3.fromRGB(30, 100, 200), -- sapphire
  }
  local jewelOffsets = { Vector3.new(-0.6, 0, hz + 0.08), Vector3.new(0.6, 0, hz + 0.08) }
  for i, jc in jewelColors do
    local jewel = makePart({
      Name = "Jewel_" .. i,
      Size = Vector3.new(0.18, 0.18, 0.18),
      Color = jc,
      Material = Enum.Material.Neon,
      Shape = Enum.PartType.Ball,
      CFrame = CFrame.new(center + jewelOffsets[i]),
    })
    jewel.Parent = model
  end

  -- Ornate top with raised center
  local topPlate = makePart({
    Name = "TopPlate",
    Size = Vector3.new(3.0, 0.15, 2.0),
    Color = goldColor,
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(center + Vector3.new(0, hy + 0.07, 0)),
  })
  topPlate.Parent = model

  return model
end

--------------------------------------------------------------------------------
-- CURSED CHEST (eerie purple chest with chains and skull lock)
--------------------------------------------------------------------------------

function ContainerModels.buildCursedChest(position: Vector3, instanceId: string): Model
  local model, body = makeBaseModel(instanceId, {
    Size = Vector3.new(3.2, 1.8, 2.2),
    Color = Color3.fromRGB(60, 25, 80),
    Material = Enum.Material.SmoothPlastic,
  }, position)

  local center = body.Position
  local hx, hz = 1.6, 1.1

  -- Chest lid (dark, slightly translucent)
  local lid = makePart({
    Name = "Lid",
    Size = Vector3.new(3.3, 0.8, 2.3),
    Color = Color3.fromRGB(50, 20, 70),
    Material = Enum.Material.SmoothPlastic,
    CFrame = CFrame.new(center + Vector3.new(0, 1.3, 0)),
  })
  lid.Parent = model

  -- Lid ridge
  local ridge = makePart({
    Name = "LidRidge",
    Size = Vector3.new(3.3, 0.15, 0.2),
    Color = Color3.fromRGB(80, 35, 110),
    Material = Enum.Material.Neon,
    CFrame = CFrame.new(center + Vector3.new(0, 1.7, 0)),
  })
  ridge.Parent = model

  -- Chain wrapping (thin Parts crossing diagonally)
  local chainColor = Color3.fromRGB(50, 50, 55)
  local chainDefs = {
    -- Front face diagonal chains
    {
      pos = Vector3.new(0, 0.3, hz + 0.03),
      size = Vector3.new(2.8, 0.12, 0.12),
      angle = CFrame.Angles(0, 0, math.rad(25)),
    },
    {
      pos = Vector3.new(0, 0.3, hz + 0.03),
      size = Vector3.new(2.8, 0.12, 0.12),
      angle = CFrame.Angles(0, 0, math.rad(-25)),
    },
    -- Back face diagonal chains
    {
      pos = Vector3.new(0, 0.3, -hz - 0.03),
      size = Vector3.new(2.8, 0.12, 0.12),
      angle = CFrame.Angles(0, 0, math.rad(25)),
    },
    {
      pos = Vector3.new(0, 0.3, -hz - 0.03),
      size = Vector3.new(2.8, 0.12, 0.12),
      angle = CFrame.Angles(0, 0, math.rad(-25)),
    },
    -- Top horizontal chain
    {
      pos = Vector3.new(0, 0.95, 0),
      size = Vector3.new(3.4, 0.12, 0.12),
      angle = CFrame.Angles(0, math.rad(90), 0),
    },
  }
  for i, cd in chainDefs do
    local chain = makePart({
      Name = "Chain_" .. i,
      Size = cd.size,
      Color = chainColor,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(center + cd.pos) * cd.angle,
    })
    chain.Parent = model
  end

  -- Skull lock (centered on front)
  local skull = makePart({
    Name = "SkullLock",
    Size = Vector3.new(0.45, 0.45, 0.45),
    Color = Color3.fromRGB(200, 190, 170),
    Material = Enum.Material.SmoothPlastic,
    Shape = Enum.PartType.Ball,
    CFrame = CFrame.new(center + Vector3.new(0, 0.5, hz + 0.1)),
  })
  skull.Parent = model

  -- Skull eyes (2 tiny neon purple balls)
  for _, xOff in { -0.1, 0.1 } do
    local eye = makePart({
      Name = "SkullEye",
      Size = Vector3.new(0.08, 0.08, 0.08),
      Color = Color3.fromRGB(160, 50, 220),
      Material = Enum.Material.Neon,
      Shape = Enum.PartType.Ball,
      CFrame = CFrame.new(center + Vector3.new(xOff, 0.55, hz + 0.3)),
    })
    eye.Parent = model
  end

  -- Eerie rune accents on sides (small neon strips)
  local runeColor = Color3.fromRGB(120, 40, 180)
  local runePositions = {
    { pos = Vector3.new(hx + 0.02, 0.2, -0.3), size = Vector3.new(0.05, 0.6, 0.08) },
    { pos = Vector3.new(hx + 0.02, 0.2, 0.3), size = Vector3.new(0.05, 0.4, 0.08) },
    { pos = Vector3.new(-hx - 0.02, 0.2, -0.3), size = Vector3.new(0.05, 0.6, 0.08) },
    { pos = Vector3.new(-hx - 0.02, 0.2, 0.3), size = Vector3.new(0.05, 0.4, 0.08) },
  }
  for i, rune in runePositions do
    local runePart = makePart({
      Name = "Rune_" .. i,
      Size = rune.size,
      Color = runeColor,
      Material = Enum.Material.Neon,
      CFrame = CFrame.new(center + rune.pos),
    })
    runePart.Parent = model
  end

  return model
end

--------------------------------------------------------------------------------
-- PUBLIC BUILD API
--------------------------------------------------------------------------------

-- Maps container type IDs to builder functions
local BUILDERS = {
  crate = ContainerModels.buildCrate,
  barrel = ContainerModels.buildBarrel,
  treasure_chest = ContainerModels.buildTreasureChest,
  reinforced_trunk = ContainerModels.buildReinforcedTrunk,
  captains_vault = ContainerModels.buildCaptainsVault,
  cursed_chest = ContainerModels.buildCursedChest,
}

--[[
  Builds a detailed container model for the given type.
  Falls back to a simple box if the type has no builder.
  @param containerTypeId The container type ID (e.g. "crate", "barrel")
  @param position World position (bottom-center of container)
  @param instanceId Unique container instance ID string
  @return Model The built container model
]]
function ContainerModels.build(
  containerTypeId: string,
  position: Vector3,
  instanceId: string
): Model?
  local builder = BUILDERS[containerTypeId]
  if builder then
    return builder(position, instanceId)
  end
  return nil
end

return ContainerModels
