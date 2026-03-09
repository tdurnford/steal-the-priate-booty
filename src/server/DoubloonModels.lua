--[[
  DoubloonModels.lua
  Builds detailed Part-based 3D models for doubloon pickups and coin purses.

  Provides:
    - buildPickup(position, value): Gold coin pile for ground pickups (Anchored)
    - buildPurse(tier): Coin purse for player/NPC belt attachment (non-Anchored, Massless)

  Pickup models replace the single-cylinder placeholder in DoubloonService.
  Purse models replace the single-Ball placeholder in LootVisibilityService and NPCService.

  Pickups: main Part is the root coin; child Parts are anchored siblings parented to it.
  Purses: main Part is the body; child Parts are Welded to it for physics attachment.
]]

local DoubloonModels = {}

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

--[[
  Creates an anchored decorative Part for pickups.
]]
local function makeAnchoredPart(props: { [string]: any }): Part
  local part = Instance.new("Part")
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = false
  part.TopSurface = Enum.SurfaceType.Smooth
  part.BottomSurface = Enum.SurfaceType.Smooth

  for key, value in props do
    (part :: any)[key] = value
  end

  return part
end

--[[
  Creates a non-anchored, massless decorative Part for purses.
]]
local function makePart(props: { [string]: any }): Part
  local part = Instance.new("Part")
  part.Anchored = false
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.CastShadow = false
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
]]
local function weld(child: Part, parent: Part, offset: CFrame)
  child.CFrame = parent.CFrame * offset
  local w = Instance.new("Weld")
  w.Part0 = parent
  w.Part1 = child
  w.C0 = offset
  w.Parent = child
end

--------------------------------------------------------------------------------
-- DOUBLOON PICKUP (ground coin pile)
--------------------------------------------------------------------------------

-- Gold color palette
local GOLD_BRIGHT = Color3.fromRGB(255, 200, 50)
local GOLD_DARK = Color3.fromRGB(200, 160, 30)
local GOLD_EDGE = Color3.fromRGB(220, 175, 40)

--[[
  Builds a doubloon pickup model (small pile of gold coins on the ground).

  The returned Part is the main coin; child Parts are siblings.
  Caller parents this to the Pickups folder and sets attributes as needed.

  @param position World position (ground level, Y will be adjusted)
  @param value The doubloon value (affects visual: >10 gets extra coins)
  @return Part The root coin Part with children
]]
function DoubloonModels.buildPickup(position: Vector3, value: number): Part
  -- Main coin (flat cylinder lying on ground)
  local coin = makeAnchoredPart({
    Name = "DoubloonPickup",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.15, 0.9, 0.9),
    Color = GOLD_BRIGHT,
    Material = Enum.Material.Metal,
    -- Cylinder axis is X; rotate so flat face is up
    CFrame = CFrame.new(position + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90)),
  })

  -- Coin face detail (darker inner circle on top)
  local face = makeAnchoredPart({
    Name = "CoinFace",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.04, 0.55, 0.55),
    Color = GOLD_DARK,
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(position + Vector3.new(0, 0.16, 0)) * CFrame.Angles(0, 0, math.rad(90)),
  })
  face.Parent = coin

  -- Coin edge rim (slightly wider ring)
  local rim = makeAnchoredPart({
    Name = "CoinRim",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.03, 0.95, 0.95),
    Color = GOLD_EDGE,
    Material = Enum.Material.Metal,
    CFrame = CFrame.new(position + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90)),
  })
  rim.Parent = coin

  -- Second coin (tilted, offset) for values > 5
  if value > 5 then
    local coin2 = makeAnchoredPart({
      Name = "Coin2",
      Shape = Enum.PartType.Cylinder,
      Size = Vector3.new(0.14, 0.85, 0.85),
      Color = GOLD_BRIGHT,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(position + Vector3.new(0.2, 0.12, 0.15))
        * CFrame.Angles(math.rad(12), math.rad(30), math.rad(90)),
    })
    coin2.Parent = coin
  end

  -- Third coin (stacked, angled) for values > 15
  if value > 15 then
    local coin3 = makeAnchoredPart({
      Name = "Coin3",
      Shape = Enum.PartType.Cylinder,
      Size = Vector3.new(0.13, 0.8, 0.8),
      Color = GOLD_EDGE,
      Material = Enum.Material.Metal,
      CFrame = CFrame.new(position + Vector3.new(-0.1, 0.2, -0.12))
        * CFrame.Angles(math.rad(-8), math.rad(-45), math.rad(90)),
    })
    coin3.Parent = coin
  end

  -- Gold glow (PointLight)
  local light = Instance.new("PointLight")
  light.Color = GOLD_BRIGHT
  light.Brightness = 0.5
  light.Range = 6
  light.Parent = coin

  -- Subtle sparkle particle
  local sparkle = Instance.new("ParticleEmitter")
  sparkle.Name = "Sparkle"
  sparkle.Color = ColorSequence.new(GOLD_BRIGHT)
  sparkle.Size = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.08),
    NumberSequenceKeypoint.new(1, 0),
  })
  sparkle.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.3),
    NumberSequenceKeypoint.new(1, 1),
  })
  sparkle.Lifetime = NumberRange.new(0.3, 0.6)
  sparkle.Rate = 3
  sparkle.Speed = NumberRange.new(0.2, 0.6)
  sparkle.SpreadAngle = Vector2.new(180, 180)
  sparkle.LightEmission = 1
  sparkle.Parent = coin

  return coin
end

--------------------------------------------------------------------------------
-- COIN PURSE — SMALL (50-199 doubloons)
--------------------------------------------------------------------------------

--[[
  Builds a small coin purse: modest brown leather pouch with drawstring.
  Non-anchored, Massless — caller Welds to character/NPC.

  @return Part The purse body Part with child decorations
]]
local function buildSmallPurse(): Part
  -- Main body: slightly flattened brown sphere (pouch shape)
  local body = makePart({
    Name = "CoinPurse",
    Shape = Enum.PartType.Ball,
    Size = Vector3.new(0.55, 0.5, 0.55),
    Color = Color3.fromRGB(139, 90, 43),
    Material = Enum.Material.Fabric,
  })

  -- Drawstring top (thin cylinder ring)
  local drawstring = makePart({
    Name = "Drawstring",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.35, 0.35),
    Color = Color3.fromRGB(100, 65, 30),
    Material = Enum.Material.Fabric,
  })
  drawstring.Parent = body
  -- Position at top of pouch, flat ring
  weld(drawstring, body, CFrame.new(0, 0.22, 0) * CFrame.Angles(0, 0, math.rad(90)))

  -- Tie-off knot (small ball at top)
  local knot = makePart({
    Name = "Knot",
    Shape = Enum.PartType.Ball,
    Size = Vector3.new(0.12, 0.12, 0.12),
    Color = Color3.fromRGB(110, 70, 35),
    Material = Enum.Material.Fabric,
  })
  knot.Parent = body
  weld(knot, body, CFrame.new(0, 0.3, 0))

  -- Bottom seam (darker strip)
  local seam = makePart({
    Name = "Seam",
    Size = Vector3.new(0.56, 0.04, 0.08),
    Color = Color3.fromRGB(100, 60, 25),
    Material = Enum.Material.Fabric,
  })
  seam.Parent = body
  weld(seam, body, CFrame.new(0, -0.15, 0))

  return body
end

--------------------------------------------------------------------------------
-- COIN PURSE — MEDIUM (200-499 doubloons)
--------------------------------------------------------------------------------

--[[
  Builds a medium coin purse: larger dark-gold pouch with coins peeking out.
  Non-anchored, Massless — caller Welds to character/NPC.

  @return Part The purse body Part with child decorations
]]
local function buildMediumPurse(): Part
  -- Main body: larger dark gold sphere
  local body = makePart({
    Name = "CoinPurse",
    Shape = Enum.PartType.Ball,
    Size = Vector3.new(0.75, 0.7, 0.75),
    Color = Color3.fromRGB(184, 134, 11),
    Material = Enum.Material.Fabric,
  })

  -- Drawstring top (slightly wider)
  local drawstring = makePart({
    Name = "Drawstring",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.45, 0.45),
    Color = Color3.fromRGB(120, 80, 30),
    Material = Enum.Material.Fabric,
  })
  drawstring.Parent = body
  weld(drawstring, body, CFrame.new(0, 0.28, 0) * CFrame.Angles(0, 0, math.rad(90)))

  -- Tie-off knot
  local knot = makePart({
    Name = "Knot",
    Shape = Enum.PartType.Ball,
    Size = Vector3.new(0.14, 0.14, 0.14),
    Color = Color3.fromRGB(140, 95, 25),
    Material = Enum.Material.Fabric,
  })
  knot.Parent = body
  weld(knot, body, CFrame.new(0.05, 0.36, 0))

  -- Coin peeking out #1 (visible from drawstring opening)
  local peekCoin1 = makePart({
    Name = "PeekCoin1",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.25, 0.25),
    Color = GOLD_BRIGHT,
    Material = Enum.Material.Metal,
  })
  peekCoin1.Parent = body
  weld(peekCoin1, body, CFrame.new(0.08, 0.3, 0.05) * CFrame.Angles(math.rad(20), 0, math.rad(90)))

  -- Coin peeking out #2
  local peekCoin2 = makePart({
    Name = "PeekCoin2",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.22, 0.22),
    Color = GOLD_EDGE,
    Material = Enum.Material.Metal,
  })
  peekCoin2.Parent = body
  weld(
    peekCoin2,
    body,
    CFrame.new(-0.06, 0.32, -0.04) * CFrame.Angles(math.rad(-15), math.rad(30), math.rad(90))
  )

  -- Belt loop strap (thin bar across back)
  local strap = makePart({
    Name = "Strap",
    Size = Vector3.new(0.08, 0.3, 0.04),
    Color = Color3.fromRGB(100, 65, 25),
    Material = Enum.Material.Fabric,
  })
  strap.Parent = body
  weld(strap, body, CFrame.new(0, 0.1, -0.35))

  return body
end

--------------------------------------------------------------------------------
-- COIN PURSE — LARGE (500+ doubloons)
--------------------------------------------------------------------------------

--[[
  Builds a large overflowing coin purse: bulging sack with coins spilling out.
  Non-anchored, Massless — caller Welds to character/NPC.

  @return Part The purse body Part with child decorations
]]
local function buildLargePurse(): Part
  -- Main body: large bright gold sphere (stretched = bulging)
  local body = makePart({
    Name = "CoinPurse",
    Shape = Enum.PartType.Ball,
    Size = Vector3.new(0.95, 0.9, 0.95),
    Color = Color3.fromRGB(200, 155, 30),
    Material = Enum.Material.Fabric,
  })

  -- Open top (darker ring — sack is overflowing, not tied shut)
  local opening = makePart({
    Name = "Opening",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.08, 0.55, 0.55),
    Color = Color3.fromRGB(120, 80, 25),
    Material = Enum.Material.Fabric,
  })
  opening.Parent = body
  weld(opening, body, CFrame.new(0, 0.35, 0) * CFrame.Angles(0, 0, math.rad(90)))

  -- Gold fill visible inside opening
  local goldFill = makePart({
    Name = "GoldFill",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.05, 0.4, 0.4),
    Color = GOLD_BRIGHT,
    Material = Enum.Material.Metal,
  })
  goldFill.Parent = body
  weld(goldFill, body, CFrame.new(0, 0.33, 0) * CFrame.Angles(0, 0, math.rad(90)))

  -- Overflowing coin #1 (large, tilted out)
  local spillCoin1 = makePart({
    Name = "SpillCoin1",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.07, 0.3, 0.3),
    Color = GOLD_BRIGHT,
    Material = Enum.Material.Metal,
  })
  spillCoin1.Parent = body
  weld(
    spillCoin1,
    body,
    CFrame.new(0.2, 0.38, 0.1) * CFrame.Angles(math.rad(35), math.rad(15), math.rad(90))
  )

  -- Overflowing coin #2
  local spillCoin2 = makePart({
    Name = "SpillCoin2",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.28, 0.28),
    Color = GOLD_EDGE,
    Material = Enum.Material.Metal,
  })
  spillCoin2.Parent = body
  weld(
    spillCoin2,
    body,
    CFrame.new(-0.15, 0.4, -0.08) * CFrame.Angles(math.rad(-25), math.rad(-40), math.rad(90))
  )

  -- Overflowing coin #3 (falling out the side)
  local spillCoin3 = makePart({
    Name = "SpillCoin3",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.26, 0.26),
    Color = GOLD_BRIGHT,
    Material = Enum.Material.Metal,
  })
  spillCoin3.Parent = body
  weld(
    spillCoin3,
    body,
    CFrame.new(0.35, 0.1, 0.15) * CFrame.Angles(math.rad(60), math.rad(20), math.rad(90))
  )

  -- Fallen coin (hanging below, about to drop)
  local fallenCoin = makePart({
    Name = "FallenCoin",
    Shape = Enum.PartType.Cylinder,
    Size = Vector3.new(0.06, 0.24, 0.24),
    Color = GOLD_DARK,
    Material = Enum.Material.Metal,
  })
  fallenCoin.Parent = body
  weld(fallenCoin, body, CFrame.new(0.15, -0.4, 0.2) * CFrame.Angles(math.rad(80), 0, math.rad(90)))

  -- Belt loop strap (thicker for heavy sack)
  local strap = makePart({
    Name = "Strap",
    Size = Vector3.new(0.1, 0.4, 0.06),
    Color = Color3.fromRGB(100, 65, 25),
    Material = Enum.Material.Fabric,
  })
  strap.Parent = body
  weld(strap, body, CFrame.new(0, 0.15, -0.45))

  -- Reinforcement patch (the sack is straining)
  local patch = makePart({
    Name = "Patch",
    Size = Vector3.new(0.3, 0.25, 0.05),
    Color = Color3.fromRGB(160, 110, 35),
    Material = Enum.Material.Fabric,
  })
  patch.Parent = body
  weld(patch, body, CFrame.new(0.2, -0.1, 0.45))

  return body
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

-- Maps purse tier names to builder functions
local PURSE_BUILDERS = {
  small = buildSmallPurse,
  medium = buildMediumPurse,
  large = buildLargePurse,
}

--[[
  Builds a coin purse model for the given tier.
  @param tier "small" | "medium" | "large"
  @return Part The purse root Part, or nil if invalid tier
]]
function DoubloonModels.buildPurse(tier: string): Part?
  local builder = PURSE_BUILDERS[tier]
  if builder then
    return builder()
  end
  return nil
end

return DoubloonModels
