--[[
  WeaponModels.lua
  Builds detailed Part-based 3D models for each cutlass weapon tier.

  Each builder creates a Tool with:
    - A "Handle" Part (the blade — carries grip position, used by animation + skin system)
    - Decorative child Parts (cross-guard, grip wrap, pommel, blade details)

  Used by GearService.createGearTool() to replace placeholder single-Part tools.
  Parts are non-anchored and Massless so they move with the Tool.

  The Handle Part remains the primary blade so that CosmeticVisualService cutlass
  skin overrides (which recolor handle.Color / handle.Material) continue to work.
]]

local WeaponModels = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Creates a decorative Part with common weapon defaults.
  @param props Table of Part properties to set
  @return Part
]]
local function makePart(props: { [string]: any }): Part
  local part = Instance.new("Part")
  part.Anchored = false
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = true
  part.Massless = true
  part.TopSurface = Enum.SurfaceType.Smooth
  part.BottomSurface = Enum.SurfaceType.Smooth

  for key, value in props do
    (part :: any)[key] = value
  end

  return part
end

--[[
  Welds a child Part to a parent Part at a given CFrame offset.
  @param child The child Part to weld
  @param parent The parent Part
  @param offset CFrame offset relative to parent
]]
local function weld(child: Part, parent: Part, offset: CFrame)
  child.CFrame = parent.CFrame * offset
  local w = Instance.new("Weld")
  w.Part0 = parent
  w.Part1 = child
  w.C0 = offset
  w.Parent = child
end

--[[
  Creates the base Tool + Handle (blade) Part.
  @param displayName Tooltip display name
  @param bladeProps Properties for the blade Handle Part
  @return (Tool, Part) The tool and its Handle (blade) part
]]
local function makeBaseTool(displayName: string, bladeProps: { [string]: any }): (Tool, Part)
  local tool = Instance.new("Tool")
  tool.Name = "Cutlass"
  tool.CanBeDropped = false
  tool.RequiresHandle = true
  tool.ToolTip = displayName

  local handle = Instance.new("Part")
  handle.Name = "Handle"
  handle.Anchored = false
  handle.CanCollide = false
  handle.Massless = true
  handle.CastShadow = true
  handle.TopSurface = Enum.SurfaceType.Smooth
  handle.BottomSurface = Enum.SurfaceType.Smooth

  for key, value in bladeProps do
    (handle :: any)[key] = value
  end

  handle.Parent = tool
  return tool, handle
end

--------------------------------------------------------------------------------
-- DRIFTWOOD (rough plank of wood — tutorial weapon)
--------------------------------------------------------------------------------

function WeaponModels.buildDriftwood(): Tool
  -- Rough, jagged wooden plank — looks like broken ship debris
  local tool, handle = makeBaseTool("Driftwood", {
    Size = Vector3.new(0.25, 0.35, 3.2),
    Color = Color3.fromRGB(120, 80, 40),
    Material = Enum.Material.Wood,
  })

  -- Splintered tip (slightly wider, angled)
  local splinter = makePart({
    Name = "Splinter",
    Size = Vector3.new(0.3, 0.4, 0.6),
    Color = Color3.fromRGB(110, 70, 35),
    Material = Enum.Material.Wood,
  })
  splinter.Parent = tool
  -- Tip of blade (positive Z in handle space)
  weld(splinter, handle, CFrame.new(0.02, 0.02, 1.7) * CFrame.Angles(0, 0, math.rad(8)))

  -- Bark strip along one side
  local bark = makePart({
    Name = "Bark",
    Size = Vector3.new(0.08, 0.38, 1.8),
    Color = Color3.fromRGB(80, 50, 25),
    Material = Enum.Material.Wood,
  })
  bark.Parent = tool
  weld(bark, handle, CFrame.new(0.14, 0, 0.2))

  -- Crude rope grip wrap
  local grip = makePart({
    Name = "Grip",
    Size = Vector3.new(0.32, 0.42, 0.8),
    Color = Color3.fromRGB(160, 140, 100),
    Material = Enum.Material.Fabric,
  })
  grip.Parent = tool
  weld(grip, handle, CFrame.new(0, 0, -1.2))

  -- Rope band 1
  local band1 = makePart({
    Name = "Band1",
    Size = Vector3.new(0.34, 0.44, 0.1),
    Color = Color3.fromRGB(140, 120, 80),
    Material = Enum.Material.Fabric,
  })
  band1.Parent = tool
  weld(band1, handle, CFrame.new(0, 0, -0.9))

  -- Rope band 2
  local band2 = makePart({
    Name = "Band2",
    Size = Vector3.new(0.34, 0.44, 0.1),
    Color = Color3.fromRGB(140, 120, 80),
    Material = Enum.Material.Fabric,
  })
  band2.Parent = tool
  weld(band2, handle, CFrame.new(0, 0, -1.5))

  return tool
end

--------------------------------------------------------------------------------
-- RUSTY CUTLASS (basic rusty sword — starter weapon)
--------------------------------------------------------------------------------

function WeaponModels.buildRustyCutlass(): Tool
  -- Tarnished, pitted metal blade with a simple guard and worn grip
  local tool, handle = makeBaseTool("Rusty Cutlass", {
    Size = Vector3.new(0.15, 0.4, 3.2),
    Color = Color3.fromRGB(130, 100, 75),
    Material = Enum.Material.Metal,
  })

  -- Blade edge (slightly thinner strip along one side — the cutting edge)
  local edge = makePart({
    Name = "BladeEdge",
    Size = Vector3.new(0.04, 0.42, 2.6),
    Color = Color3.fromRGB(150, 120, 90),
    Material = Enum.Material.Metal,
  })
  edge.Parent = tool
  weld(edge, handle, CFrame.new(-0.08, 0, 0.2))

  -- Blade tip (tapered end)
  local tip = makePart({
    Name = "BladeTip",
    Size = Vector3.new(0.12, 0.3, 0.4),
    Color = Color3.fromRGB(130, 100, 75),
    Material = Enum.Material.Metal,
  })
  tip.Parent = tool
  weld(tip, handle, CFrame.new(0, 0, 1.7) * CFrame.Angles(0, 0, math.rad(5)))

  -- Rust spots (darker patches)
  local rust1 = makePart({
    Name = "Rust1",
    Size = Vector3.new(0.16, 0.15, 0.3),
    Color = Color3.fromRGB(100, 60, 30),
    Material = Enum.Material.CorrodedMetal,
  })
  rust1.Parent = tool
  weld(rust1, handle, CFrame.new(0, 0.14, 0.5))

  local rust2 = makePart({
    Name = "Rust2",
    Size = Vector3.new(0.16, 0.12, 0.25),
    Color = Color3.fromRGB(90, 55, 25),
    Material = Enum.Material.CorrodedMetal,
  })
  rust2.Parent = tool
  weld(rust2, handle, CFrame.new(0, -0.12, 1.0))

  -- Simple cross-guard (flat metal bar)
  local guard = makePart({
    Name = "CrossGuard",
    Size = Vector3.new(0.15, 1.0, 0.2),
    Color = Color3.fromRGB(100, 80, 60),
    Material = Enum.Material.Metal,
  })
  guard.Parent = tool
  weld(guard, handle, CFrame.new(0, 0, -0.4))

  -- Worn leather grip
  local grip = makePart({
    Name = "Grip",
    Size = Vector3.new(0.22, 0.35, 0.9),
    Color = Color3.fromRGB(80, 55, 35),
    Material = Enum.Material.Fabric,
  })
  grip.Parent = tool
  weld(grip, handle, CFrame.new(0, 0, -1.05))

  -- Plain round pommel
  local pommel = makePart({
    Name = "Pommel",
    Size = Vector3.new(0.3, 0.3, 0.2),
    Color = Color3.fromRGB(90, 70, 50),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
  })
  pommel.Parent = tool
  weld(pommel, handle, CFrame.new(0, 0, -1.6))

  return tool
end

--------------------------------------------------------------------------------
-- IRON CUTLASS (cleaner iron blade — first upgrade)
--------------------------------------------------------------------------------

function WeaponModels.buildIronCutlass(): Tool
  -- Solid iron blade, proper sword shape with fuller groove
  local tool, handle = makeBaseTool("Iron Cutlass", {
    Size = Vector3.new(0.14, 0.42, 3.4),
    Color = Color3.fromRGB(160, 160, 165),
    Material = Enum.Material.Metal,
  })

  -- Fuller groove (recessed line along blade center — makes it look forged)
  local fuller = makePart({
    Name = "Fuller",
    Size = Vector3.new(0.04, 0.12, 2.4),
    Color = Color3.fromRGB(120, 120, 130),
    Material = Enum.Material.Metal,
  })
  fuller.Parent = tool
  weld(fuller, handle, CFrame.new(0, 0, 0.2))

  -- Blade edge
  local edge = makePart({
    Name = "BladeEdge",
    Size = Vector3.new(0.03, 0.44, 2.8),
    Color = Color3.fromRGB(180, 180, 185),
    Material = Enum.Material.Metal,
  })
  edge.Parent = tool
  weld(edge, handle, CFrame.new(-0.07, 0, 0.15))

  -- Blade tip (pointed)
  local tip = makePart({
    Name = "BladeTip",
    Size = Vector3.new(0.1, 0.28, 0.5),
    Color = Color3.fromRGB(160, 160, 165),
    Material = Enum.Material.Metal,
  })
  tip.Parent = tool
  weld(tip, handle, CFrame.new(0, 0, 1.8) * CFrame.Angles(0, 0, math.rad(3)))

  -- Cross-guard with curved ends
  local guardCenter = makePart({
    Name = "CrossGuard",
    Size = Vector3.new(0.18, 1.2, 0.22),
    Color = Color3.fromRGB(100, 100, 110),
    Material = Enum.Material.Metal,
  })
  guardCenter.Parent = tool
  weld(guardCenter, handle, CFrame.new(0, 0, -0.4))

  -- Guard end caps (small bulges)
  local guardL = makePart({
    Name = "GuardLeft",
    Size = Vector3.new(0.2, 0.2, 0.2),
    Color = Color3.fromRGB(100, 100, 110),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
  })
  guardL.Parent = tool
  weld(guardL, handle, CFrame.new(0, 0.6, -0.4))

  local guardR = makePart({
    Name = "GuardRight",
    Size = Vector3.new(0.2, 0.2, 0.2),
    Color = Color3.fromRGB(100, 100, 110),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
  })
  guardR.Parent = tool
  weld(guardR, handle, CFrame.new(0, -0.6, -0.4))

  -- Leather-wrapped grip
  local grip = makePart({
    Name = "Grip",
    Size = Vector3.new(0.24, 0.34, 0.95),
    Color = Color3.fromRGB(70, 45, 25),
    Material = Enum.Material.Fabric,
  })
  grip.Parent = tool
  weld(grip, handle, CFrame.new(0, 0, -1.05))

  -- Grip bands (leather wraps)
  for i = 1, 3 do
    local band = makePart({
      Name = "GripBand" .. i,
      Size = Vector3.new(0.26, 0.36, 0.06),
      Color = Color3.fromRGB(55, 35, 18),
      Material = Enum.Material.Fabric,
    })
    band.Parent = tool
    weld(band, handle, CFrame.new(0, 0, -0.7 - (i * 0.25)))
  end

  -- Iron pommel (flat disc)
  local pommel = makePart({
    Name = "Pommel",
    Size = Vector3.new(0.35, 0.35, 0.15),
    Color = Color3.fromRGB(110, 110, 120),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Cylinder,
  })
  pommel.Parent = tool
  weld(pommel, handle, CFrame.new(0, 0, -1.6) * CFrame.Angles(0, math.rad(90), 0))

  return tool
end

--------------------------------------------------------------------------------
-- STEEL CUTLASS (polished steel blade — mid-tier)
--------------------------------------------------------------------------------

function WeaponModels.buildSteelCutlass(): Tool
  -- Gleaming polished steel, slight curve, refined craftsmanship
  local tool, handle = makeBaseTool("Steel Cutlass", {
    Size = Vector3.new(0.12, 0.44, 3.6),
    Color = Color3.fromRGB(200, 200, 210),
    Material = Enum.Material.Metal,
  })

  -- Fuller groove (polished)
  local fuller = makePart({
    Name = "Fuller",
    Size = Vector3.new(0.03, 0.14, 2.6),
    Color = Color3.fromRGB(170, 170, 185),
    Material = Enum.Material.Metal,
  })
  fuller.Parent = tool
  weld(fuller, handle, CFrame.new(0, 0, 0.2))

  -- Sharp edge (polished bright)
  local edge = makePart({
    Name = "BladeEdge",
    Size = Vector3.new(0.025, 0.46, 3.0),
    Color = Color3.fromRGB(220, 220, 230),
    Material = Enum.Material.Metal,
  })
  edge.Parent = tool
  weld(edge, handle, CFrame.new(-0.06, 0, 0.1))

  -- Blade tip
  local tip = makePart({
    Name = "BladeTip",
    Size = Vector3.new(0.08, 0.26, 0.5),
    Color = Color3.fromRGB(210, 210, 220),
    Material = Enum.Material.Metal,
  })
  tip.Parent = tool
  weld(tip, handle, CFrame.new(0, 0, 1.9) * CFrame.Angles(0, 0, math.rad(2)))

  -- Brass cross-guard (wider, curved, ornamental)
  local guard = makePart({
    Name = "CrossGuard",
    Size = Vector3.new(0.2, 1.4, 0.25),
    Color = Color3.fromRGB(180, 155, 60),
    Material = Enum.Material.Metal,
  })
  guard.Parent = tool
  weld(guard, handle, CFrame.new(0, 0, -0.4))

  -- Guard flourishes (curved tips)
  local guardTipL = makePart({
    Name = "GuardTipL",
    Size = Vector3.new(0.18, 0.18, 0.3),
    Color = Color3.fromRGB(180, 155, 60),
    Material = Enum.Material.Metal,
  })
  guardTipL.Parent = tool
  weld(guardTipL, handle, CFrame.new(0, 0.7, -0.3) * CFrame.Angles(math.rad(20), 0, 0))

  local guardTipR = makePart({
    Name = "GuardTipR",
    Size = Vector3.new(0.18, 0.18, 0.3),
    Color = Color3.fromRGB(180, 155, 60),
    Material = Enum.Material.Metal,
  })
  guardTipR.Parent = tool
  weld(guardTipR, handle, CFrame.new(0, -0.7, -0.3) * CFrame.Angles(math.rad(-20), 0, 0))

  -- Knuckle bow (curved guard extension connecting to pommel)
  local knuckleBow = makePart({
    Name = "KnuckleBow",
    Size = Vector3.new(0.1, 0.12, 1.2),
    Color = Color3.fromRGB(180, 155, 60),
    Material = Enum.Material.Metal,
  })
  knuckleBow.Parent = tool
  weld(knuckleBow, handle, CFrame.new(0, 0.55, -1.0) * CFrame.Angles(math.rad(8), 0, 0))

  -- Fine leather grip with brass fittings
  local grip = makePart({
    Name = "Grip",
    Size = Vector3.new(0.24, 0.32, 1.0),
    Color = Color3.fromRGB(55, 35, 18),
    Material = Enum.Material.Fabric,
  })
  grip.Parent = tool
  weld(grip, handle, CFrame.new(0, 0, -1.1))

  -- Brass grip rings
  for i = 1, 4 do
    local ring = makePart({
      Name = "GripRing" .. i,
      Size = Vector3.new(0.26, 0.34, 0.04),
      Color = Color3.fromRGB(180, 155, 60),
      Material = Enum.Material.Metal,
    })
    ring.Parent = tool
    weld(ring, handle, CFrame.new(0, 0, -0.7 - (i * 0.22)))
  end

  -- Steel pommel (octagonal feel via ball)
  local pommel = makePart({
    Name = "Pommel",
    Size = Vector3.new(0.38, 0.38, 0.2),
    Color = Color3.fromRGB(180, 155, 60),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
  })
  pommel.Parent = tool
  weld(pommel, handle, CFrame.new(0, 0, -1.7))

  return tool
end

--------------------------------------------------------------------------------
-- CAPTAIN'S SABER (ornate saber with elegant guard — high-tier)
--------------------------------------------------------------------------------

function WeaponModels.buildCaptainsSaber(): Tool
  -- Elegant curved saber with gold fittings and ivory grip
  local tool, handle = makeBaseTool("Captain's Saber", {
    Size = Vector3.new(0.1, 0.46, 3.8),
    Color = Color3.fromRGB(210, 210, 220),
    Material = Enum.Material.Metal,
  })

  -- Polished fuller
  local fuller = makePart({
    Name = "Fuller",
    Size = Vector3.new(0.025, 0.16, 2.8),
    Color = Color3.fromRGB(180, 180, 195),
    Material = Enum.Material.Metal,
  })
  fuller.Parent = tool
  weld(fuller, handle, CFrame.new(0, 0, 0.2))

  -- Razor edge
  local edge = makePart({
    Name = "BladeEdge",
    Size = Vector3.new(0.02, 0.48, 3.2),
    Color = Color3.fromRGB(230, 230, 240),
    Material = Enum.Material.Metal,
  })
  edge.Parent = tool
  weld(edge, handle, CFrame.new(-0.05, 0, 0.1))

  -- Elegant curved tip
  local tip = makePart({
    Name = "BladeTip",
    Size = Vector3.new(0.07, 0.24, 0.6),
    Color = Color3.fromRGB(220, 220, 230),
    Material = Enum.Material.Metal,
  })
  tip.Parent = tool
  weld(tip, handle, CFrame.new(-0.02, 0, 2.0) * CFrame.Angles(0, 0, math.rad(4)))

  -- Gold blade accent line near guard
  local bladeAccent = makePart({
    Name = "BladeAccent",
    Size = Vector3.new(0.11, 0.2, 0.5),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.Metal,
  })
  bladeAccent.Parent = tool
  weld(bladeAccent, handle, CFrame.new(0, 0, -0.1))

  -- Elaborate gold cross-guard with cup shape
  local guardMain = makePart({
    Name = "CrossGuard",
    Size = Vector3.new(0.22, 1.6, 0.3),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.Metal,
  })
  guardMain.Parent = tool
  weld(guardMain, handle, CFrame.new(0, 0, -0.45))

  -- Guard filigree (decorative curls)
  local filigreeL = makePart({
    Name = "FiligreeL",
    Size = Vector3.new(0.15, 0.15, 0.4),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.Metal,
  })
  filigreeL.Parent = tool
  weld(filigreeL, handle, CFrame.new(0, 0.8, -0.35) * CFrame.Angles(math.rad(25), 0, 0))

  local filigreeR = makePart({
    Name = "FiligreeR",
    Size = Vector3.new(0.15, 0.15, 0.4),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.Metal,
  })
  filigreeR.Parent = tool
  weld(filigreeR, handle, CFrame.new(0, -0.8, -0.35) * CFrame.Angles(math.rad(-25), 0, 0))

  -- Full knuckle bow (gold, curved)
  local knuckleBow = makePart({
    Name = "KnuckleBow",
    Size = Vector3.new(0.1, 0.14, 1.3),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.Metal,
  })
  knuckleBow.Parent = tool
  weld(knuckleBow, handle, CFrame.new(0, 0.6, -1.05) * CFrame.Angles(math.rad(10), 0, 0))

  -- Ivory grip (white/cream colored)
  local grip = makePart({
    Name = "Grip",
    Size = Vector3.new(0.24, 0.3, 1.05),
    Color = Color3.fromRGB(240, 230, 210),
    Material = Enum.Material.SmoothPlastic,
  })
  grip.Parent = tool
  weld(grip, handle, CFrame.new(0, 0, -1.15))

  -- Gold wire wrap on grip
  for i = 1, 5 do
    local wire = makePart({
      Name = "GripWire" .. i,
      Size = Vector3.new(0.26, 0.32, 0.03),
      Color = Color3.fromRGB(255, 200, 50),
      Material = Enum.Material.Metal,
    })
    wire.Parent = tool
    weld(wire, handle, CFrame.new(0, 0, -0.75 - (i * 0.19)))
  end

  -- Ornate gold pommel with jewel
  local pommel = makePart({
    Name = "Pommel",
    Size = Vector3.new(0.4, 0.4, 0.22),
    Color = Color3.fromRGB(255, 200, 50),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
  })
  pommel.Parent = tool
  weld(pommel, handle, CFrame.new(0, 0, -1.8))

  -- Ruby jewel inset in pommel
  local jewel = makePart({
    Name = "PommelJewel",
    Size = Vector3.new(0.14, 0.14, 0.14),
    Color = Color3.fromRGB(200, 30, 30),
    Material = Enum.Material.Neon,
    Shape = Enum.PartType.Ball,
  })
  jewel.Parent = tool
  weld(jewel, handle, CFrame.new(0, 0, -1.92))

  -- Subtle gold glow
  local light = Instance.new("PointLight")
  light.Name = "CaptainGlow"
  light.Color = Color3.fromRGB(255, 200, 50)
  light.Brightness = 0.3
  light.Range = 4
  light.Parent = handle

  return tool
end

--------------------------------------------------------------------------------
-- LEGENDARY BLADE (glowing golden blade — top-tier, unmistakable)
--------------------------------------------------------------------------------

function WeaponModels.buildLegendaryBlade(): Tool
  -- Imposing golden-edged blade with ethereal glow and particle effects
  local tool, handle = makeBaseTool("Legendary Blade", {
    Size = Vector3.new(0.14, 0.52, 4.2),
    Color = Color3.fromRGB(255, 210, 80),
    Material = Enum.Material.Neon,
  })

  -- Inner blade core (darker metal visible through neon glow)
  local core = makePart({
    Name = "BladeCore",
    Size = Vector3.new(0.1, 0.36, 3.6),
    Color = Color3.fromRGB(220, 180, 60),
    Material = Enum.Material.Metal,
  })
  core.Parent = tool
  weld(core, handle, CFrame.new(0, 0, 0.1))

  -- Blade edge glow (bright neon edge)
  local edgeGlow = makePart({
    Name = "BladeEdgeGlow",
    Size = Vector3.new(0.03, 0.54, 3.6),
    Color = Color3.fromRGB(255, 230, 120),
    Material = Enum.Material.Neon,
  })
  edgeGlow.Parent = tool
  weld(edgeGlow, handle, CFrame.new(-0.07, 0, 0.1))

  -- Blade spine glow
  local spineGlow = makePart({
    Name = "BladeSpineGlow",
    Size = Vector3.new(0.03, 0.54, 3.6),
    Color = Color3.fromRGB(255, 230, 120),
    Material = Enum.Material.Neon,
  })
  spineGlow.Parent = tool
  weld(spineGlow, handle, CFrame.new(0.07, 0, 0.1))

  -- Rune engravings (glowing symbols along blade)
  for i = 1, 4 do
    local rune = makePart({
      Name = "Rune" .. i,
      Size = Vector3.new(0.15, 0.08, 0.15),
      Color = Color3.fromRGB(255, 255, 200),
      Material = Enum.Material.Neon,
    })
    rune.Parent = tool
    weld(rune, handle, CFrame.new(0, 0.18, 0.3 + (i * 0.7)))
  end

  -- Dramatic blade tip
  local tip = makePart({
    Name = "BladeTip",
    Size = Vector3.new(0.1, 0.3, 0.7),
    Color = Color3.fromRGB(255, 230, 100),
    Material = Enum.Material.Neon,
  })
  tip.Parent = tool
  weld(tip, handle, CFrame.new(0, 0, 2.2) * CFrame.Angles(0, 0, math.rad(3)))

  -- Elaborate cross-guard with dragon/serpent wing motif
  local guardMain = makePart({
    Name = "CrossGuard",
    Size = Vector3.new(0.24, 1.8, 0.35),
    Color = Color3.fromRGB(200, 170, 40),
    Material = Enum.Material.Metal,
  })
  guardMain.Parent = tool
  weld(guardMain, handle, CFrame.new(0, 0, -0.5))

  -- Guard wing left (upswept)
  local wingL = makePart({
    Name = "GuardWingL",
    Size = Vector3.new(0.18, 0.2, 0.5),
    Color = Color3.fromRGB(200, 170, 40),
    Material = Enum.Material.Metal,
  })
  wingL.Parent = tool
  weld(wingL, handle, CFrame.new(0, 0.9, -0.35) * CFrame.Angles(math.rad(30), 0, 0))

  -- Guard wing right (upswept)
  local wingR = makePart({
    Name = "GuardWingR",
    Size = Vector3.new(0.18, 0.2, 0.5),
    Color = Color3.fromRGB(200, 170, 40),
    Material = Enum.Material.Metal,
  })
  wingR.Parent = tool
  weld(wingR, handle, CFrame.new(0, -0.9, -0.35) * CFrame.Angles(math.rad(-30), 0, 0))

  -- Guard center jewel (emerald)
  local guardJewel = makePart({
    Name = "GuardJewel",
    Size = Vector3.new(0.22, 0.22, 0.22),
    Color = Color3.fromRGB(50, 255, 100),
    Material = Enum.Material.Neon,
    Shape = Enum.PartType.Ball,
  })
  guardJewel.Parent = tool
  weld(guardJewel, handle, CFrame.new(0, 0, -0.5))

  -- Gold knuckle bow
  local knuckleBow = makePart({
    Name = "KnuckleBow",
    Size = Vector3.new(0.12, 0.16, 1.4),
    Color = Color3.fromRGB(200, 170, 40),
    Material = Enum.Material.Metal,
  })
  knuckleBow.Parent = tool
  weld(knuckleBow, handle, CFrame.new(0, 0.65, -1.1) * CFrame.Angles(math.rad(10), 0, 0))

  -- Royal grip (deep purple velvet)
  local grip = makePart({
    Name = "Grip",
    Size = Vector3.new(0.26, 0.32, 1.1),
    Color = Color3.fromRGB(80, 30, 100),
    Material = Enum.Material.Fabric,
  })
  grip.Parent = tool
  weld(grip, handle, CFrame.new(0, 0, -1.2))

  -- Gold wire wrap
  for i = 1, 5 do
    local wire = makePart({
      Name = "GripWire" .. i,
      Size = Vector3.new(0.28, 0.34, 0.03),
      Color = Color3.fromRGB(255, 200, 50),
      Material = Enum.Material.Metal,
    })
    wire.Parent = tool
    weld(wire, handle, CFrame.new(0, 0, -0.8 - (i * 0.2)))
  end

  -- Large ornate pommel
  local pommel = makePart({
    Name = "Pommel",
    Size = Vector3.new(0.45, 0.45, 0.25),
    Color = Color3.fromRGB(200, 170, 40),
    Material = Enum.Material.Metal,
    Shape = Enum.PartType.Ball,
  })
  pommel.Parent = tool
  weld(pommel, handle, CFrame.new(0, 0, -1.85))

  -- Pommel jewel (sapphire)
  local pommelJewel = makePart({
    Name = "PommelJewel",
    Size = Vector3.new(0.16, 0.16, 0.16),
    Color = Color3.fromRGB(30, 80, 255),
    Material = Enum.Material.Neon,
    Shape = Enum.PartType.Ball,
  })
  pommelJewel.Parent = tool
  weld(pommelJewel, handle, CFrame.new(0, 0, -1.98))

  -- Strong golden glow
  local light = Instance.new("PointLight")
  light.Name = "LegendaryGlow"
  light.Color = Color3.fromRGB(255, 200, 50)
  light.Brightness = 1.2
  light.Range = 10
  light.Parent = handle

  -- Gold particle trail
  local particles = Instance.new("ParticleEmitter")
  particles.Name = "LegendaryParticles"
  particles.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 230, 100)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 180, 30)),
  })
  particles.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.15),
    NumberSequenceKeypoint.new(1, 0),
  })
  particles.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  particles.Lifetime = NumberRange.new(0.4, 0.8)
  particles.Rate = 15
  particles.Speed = NumberRange.new(0.5, 1.5)
  particles.SpreadAngle = Vector2.new(30, 30)
  particles.LightEmission = 1
  particles.Parent = handle

  return tool
end

--------------------------------------------------------------------------------
-- BUILDER REGISTRY
--------------------------------------------------------------------------------

local BUILDERS = {
  driftwood = WeaponModels.buildDriftwood,
  rusty_cutlass = WeaponModels.buildRustyCutlass,
  iron_cutlass = WeaponModels.buildIronCutlass,
  steel_cutlass = WeaponModels.buildSteelCutlass,
  captains_saber = WeaponModels.buildCaptainsSaber,
  legendary_blade = WeaponModels.buildLegendaryBlade,
}

--[[
  Builds a detailed weapon Tool for the given gear ID.
  @param gearId The gear type ID (e.g. "rusty_cutlass")
  @return Tool instance, or nil if no builder exists for the ID
]]
function WeaponModels.build(gearId: string): Tool?
  local builder = BUILDERS[gearId]
  if builder then
    return builder()
  end
  return nil
end

return WeaponModels
