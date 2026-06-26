import
  std/[heapqueue, math],
  bitworld/spriteprotocol,
  ../../../src/crewrift/sim,
  pathy

export pathy

const
  PathLookahead* = 18
  PathCursorSearch* = 64
  PathConsumeDistance* = 1
  PathDeviationLimit* = 16
  StopGoalDistance* = 64
  CoastLookaheadTicks* = 8
  CoastArrivalPadding* = 1
  SteerDeadband* = 2
  WaypointMinDistance* = SteerDeadband + 1
  WaypointBehindVelocity = 32
  MovementSlideMaxScan = 3
  PathDeltas = [
    (dx: -1, dy: 0),
    (dx: 1, dy: 0),
    (dx: 0, dy: -1),
    (dx: 0, dy: 1),
    (dx: -1, dy: -1),
    (dx: 1, dy: -1),
    (dx: -1, dy: 1),
    (dx: 1, dy: 1)
  ]
type
  MotionState* = object
    x*: int
    y*: int
    velX*: int
    velY*: int
    carryX*: int
    carryY*: int

  NavigationMap* = ref object
    width*: int
    height*: int
    config*: GameConfig
    walkMask*: seq[bool]
    passableMask*: seq[bool]
    parents: seq[int]
    costs: seq[int]
    seen: seq[int]
    closed: seq[int]
    stamp: int

  TilePathMap* = ref object
    nav*: NavigationMap
    tileSize*: int
    width*: int
    height*: int
    nodes*: seq[PathStep]
    passableMask*: seq[bool]
    parents: seq[int]
    costs: seq[int]
    seen: seq[int]
    closed: seq[int]
    stamp: int

  PathNode = object
    priority: int
    index: int

proc `<`(a, b: PathNode): bool =
  ## Orders path nodes for Nim heapqueue.
  if a.priority == b.priority:
    return a.index < b.index
  a.priority < b.priority

proc pathIndex*(nav: NavigationMap, x, y: int): int {.inline.} =
  ## Returns one flattened navigation map index.
  y * nav.width + x

proc tileIndex*(tiles: TilePathMap, x, y: int): int {.inline.} =
  ## Returns one flattened tile map index.
  y * tiles.width + x

proc inBounds*(nav: NavigationMap, x, y: int): bool {.inline.} =
  ## Returns true when a point is inside the navigation map.
  x >= 0 and y >= 0 and x < nav.width and y < nav.height

proc inBounds*(tiles: TilePathMap, x, y: int): bool {.inline.} =
  ## Returns true when a tile is inside the tile map.
  x >= 0 and y >= 0 and x < tiles.width and y < tiles.height

proc passable*(nav: NavigationMap, x, y: int): bool =
  ## Returns true when a collision-sized player can occupy a pixel.
  if not nav.inBounds(x, y):
    return false
  nav.passableMask[nav.pathIndex(x, y)]

proc passable*(tiles: TilePathMap, x, y: int): bool =
  ## Returns true when one tile has an occupiable representative point.
  if not tiles.inBounds(x, y):
    return false
  tiles.passableMask[tiles.tileIndex(x, y)]

proc initNavigationMap*(
  walkMask: openArray[bool],
  width,
  height: int,
  config: GameConfig
): NavigationMap =
  ## Builds a reusable navigation map from one walkability mask.
  doAssert walkMask.len == width * height
  new(result)
  result.width = width
  result.height = height
  result.config = config
  result.walkMask = newSeq[bool](walkMask.len)
  result.passableMask = newSeq[bool](walkMask.len)
  for i in 0 ..< walkMask.len:
    result.walkMask[i] = walkMask[i]
  for y in 0 ..< height:
    for x in 0 ..< width:
      var clear = true
      if x < 0 or y < 0 or
          x + CollisionW > width or
          y + CollisionH > height:
        clear = false
      for dy in 0 ..< CollisionH:
        for dx in 0 ..< CollisionW:
          if not clear:
            continue
          let
            px = x + dx
            py = y + dy
          if px < 0 or py < 0 or px >= width or py >= height:
            clear = false
          elif not walkMask[py * width + px]:
            clear = false
      result.passableMask[result.pathIndex(x, y)] = clear

proc initNavigationMap*(
  walkMask: openArray[bool],
  width,
  height: int
): NavigationMap =
  ## Builds a navigation map with default Crewrift movement config.
  initNavigationMap(walkMask, width, height, defaultGameConfig())

proc initNavigationMap*(
  walkMask: openArray[bool]
): NavigationMap =
  ## Builds a Crewrift-sized navigation map.
  initNavigationMap(walkMask, MapWidth, MapHeight)

proc initNavigationMap*(
  walkMask: openArray[bool],
  config: GameConfig
): NavigationMap =
  ## Builds a Crewrift-sized navigation map with one movement config.
  initNavigationMap(walkMask, MapWidth, MapHeight, config)

proc heuristic*(ax, ay, bx, by: int): int =
  ## Returns Manhattan distance between two points.
  abs(ax - bx) + abs(ay - by)

proc pathHeuristic*(ax, ay, bx, by: int): int {.inline.} =
  ## Returns the diagonal-aware distance for path search.
  max(abs(ax - bx), abs(ay - by))

proc signOf(value: int): int {.inline.} =
  ## Returns the sign of one integer.
  if value < 0:
    return -1
  if value > 0:
    return 1
  0

{.push checks: off.}

proc pathStepPassable*(
  nav: NavigationMap,
  x,
  y,
  dx,
  dy: int
): bool =
  ## Returns true when a path step can move without cutting corners.
  let
    nx = x + dx
    ny = y + dy
  if not nav.passable(nx, ny):
    return false
  if dx != 0 and dy != 0:
    if not nav.passable(x + dx, y):
      return false
    if not nav.passable(x, y + dy):
      return false
  true

proc reconstructPath(
  nav: NavigationMap,
  startIndex,
  goalIndex: int
): seq[PathStep] =
  ## Reconstructs a complete path from a parent table.
  var stepIndex = goalIndex
  while stepIndex != startIndex and stepIndex >= 0:
    result.add(PathStep(
      found: true,
      x: stepIndex mod nav.width,
      y: stepIndex div nav.width
    ))
    stepIndex = nav.parents[stepIndex]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.high - i])

proc resetSearch(nav: var NavigationMap) =
  ## Prepares the stamped A* scratch arrays for a new search.
  let area = nav.width * nav.height
  if nav.parents.len != area:
    nav.parents = newSeq[int](area)
    nav.costs = newSeq[int](area)
    nav.seen = newSeq[int](area)
    nav.closed = newSeq[int](area)
    nav.stamp = 0
  inc nav.stamp
  if nav.stamp == high(int):
    for i in 0 ..< area:
      nav.seen[i] = 0
      nav.closed[i] = 0
    nav.stamp = 1

proc findPath*(
  nav: var NavigationMap,
  startX,
  startY,
  goalX,
  goalY: int
): seq[PathStep] =
  ## Finds a complete A* pixel path between two points.
  if not nav.passable(startX, startY) or not nav.passable(goalX, goalY):
    return
  let
    startIndex = nav.pathIndex(startX, startY)
    goalIndex = nav.pathIndex(goalX, goalY)
  nav.resetSearch()
  let stamp = nav.stamp

  template touch(index: int) =
    if nav.seen[index] != stamp:
      nav.seen[index] = stamp
      nav.parents[index] = -2
      nav.costs[index] = high(int)

  var openSet: HeapQueue[PathNode]
  touch(startIndex)
  nav.parents[startIndex] = -1
  nav.costs[startIndex] = 0
  openSet.push(PathNode(
    priority: pathHeuristic(startX, startY, goalX, goalY),
    index: startIndex
  ))
  while openSet.len > 0:
    let current = openSet.pop()
    if nav.closed[current.index] == stamp:
      continue
    if current.index == goalIndex:
      return nav.reconstructPath(startIndex, goalIndex)
    nav.closed[current.index] = stamp
    let
      x = current.index mod nav.width
      y = current.index div nav.width
    for delta in PathDeltas:
      let
        nx = x + delta.dx
        ny = y + delta.dy
      if not nav.pathStepPassable(x, y, delta.dx, delta.dy):
        continue
      let nextIndex = nav.pathIndex(nx, ny)
      if nav.closed[nextIndex] == stamp:
        continue
      touch(nextIndex)
      let newCost = nav.costs[current.index] + 1
      if newCost >= nav.costs[nextIndex]:
        continue
      nav.costs[nextIndex] = newCost
      nav.parents[nextIndex] = current.index
      openSet.push(PathNode(
        priority: newCost + pathHeuristic(nx, ny, goalX, goalY),
        index: nextIndex
      ))

proc tileNode(
  nav: NavigationMap,
  x,
  y,
  size: int
): PathStep =
  ## Returns one representative passable point inside a tile.
  let
    centerX = min(nav.width - 1, x + size div 2)
    centerY = min(nav.height - 1, y + size div 2)
    maxX = min(nav.width - 1, x + size - 1)
    maxY = min(nav.height - 1, y + size - 1)
  if nav.passable(centerX, centerY):
    return PathStep(found: true, x: centerX, y: centerY)
  var bestDistance = high(int)
  for yy in y .. maxY:
    for xx in x .. maxX:
      if not nav.passable(xx, yy):
        continue
      let distance = heuristic(centerX, centerY, xx, yy)
      if distance < bestDistance:
        bestDistance = distance
        result = PathStep(found: true, x: xx, y: yy)

proc initTilePathMap*(
  nav: NavigationMap,
  tileSize = 8
): TilePathMap =
  ## Precomputes a coarse tile navigation graph from a pixel map.
  doAssert tileSize > 0
  new(result)
  result.nav = nav
  result.tileSize = tileSize
  result.width = (nav.width + tileSize - 1) div tileSize
  result.height = (nav.height + tileSize - 1) div tileSize
  let area = result.width * result.height
  result.nodes = newSeq[PathStep](area)
  result.passableMask = newSeq[bool](area)
  for tileY in 0 ..< result.height:
    for tileX in 0 ..< result.width:
      let
        x = tileX * tileSize
        y = tileY * tileSize
        index = result.tileIndex(tileX, tileY)
        node = nav.tileNode(x, y, tileSize)
      result.nodes[index] = node
      result.passableMask[index] = node.found

proc nearestTile(
  tiles: TilePathMap,
  x,
  y: int,
  radius = 16
): PathStep =
  ## Returns the nearest passable tile around a tile coordinate.
  if tiles.passable(x, y):
    return PathStep(found: true, x: x, y: y)
  var bestDistance = high(int)
  for yy in max(0, y - radius) .. min(tiles.height - 1, y + radius):
    for xx in max(0, x - radius) .. min(tiles.width - 1, x + radius):
      if not tiles.passable(xx, yy):
        continue
      let distance = heuristic(x, y, xx, yy)
      if distance < bestDistance:
        bestDistance = distance
        result = PathStep(found: true, x: xx, y: yy)

proc tileStepPassable(
  tiles: TilePathMap,
  x,
  y,
  dx,
  dy: int
): bool =
  ## Returns true when one tile step can move without cutting corners.
  let
    nx = x + dx
    ny = y + dy
  if not tiles.passable(nx, ny):
    return false
  if dx != 0 and dy != 0:
    if not tiles.passable(x + dx, y):
      return false
    if not tiles.passable(x, y + dy):
      return false
  true

proc resetSearch(tiles: var TilePathMap) =
  ## Prepares the stamped tile A* scratch arrays.
  let area = tiles.width * tiles.height
  if tiles.parents.len != area:
    tiles.parents = newSeq[int](area)
    tiles.costs = newSeq[int](area)
    tiles.seen = newSeq[int](area)
    tiles.closed = newSeq[int](area)
    tiles.stamp = 0
  inc tiles.stamp
  if tiles.stamp == high(int):
    for i in 0 ..< area:
      tiles.seen[i] = 0
      tiles.closed[i] = 0
    tiles.stamp = 1

proc reconstructPath(
  tiles: TilePathMap,
  startIndex,
  goalIndex: int
): seq[PathStep] =
  ## Reconstructs a tile path as representative pixel points.
  var stepIndex = goalIndex
  while stepIndex != startIndex and stepIndex >= 0:
    result.add(tiles.nodes[stepIndex])
    stepIndex = tiles.parents[stepIndex]
  for i in 0 ..< result.len div 2:
    swap(result[i], result[result.high - i])

proc findCoarsePath(
  tiles: var TilePathMap,
  startTileX,
  startTileY,
  goalTileX,
  goalTileY: int
): seq[PathStep] =
  ## Finds a coarse A* path between two tile points.
  let
    start = tiles.nearestTile(startTileX, startTileY)
    goal = tiles.nearestTile(goalTileX, goalTileY)
  if not start.found or not goal.found:
    return
  let
    startIndex = tiles.tileIndex(start.x, start.y)
    goalIndex = tiles.tileIndex(goal.x, goal.y)
  tiles.resetSearch()
  let stamp = tiles.stamp

  template touch(index: int) =
    if tiles.seen[index] != stamp:
      tiles.seen[index] = stamp
      tiles.parents[index] = -2
      tiles.costs[index] = high(int)

  var openSet: HeapQueue[PathNode]
  touch(startIndex)
  tiles.parents[startIndex] = -1
  tiles.costs[startIndex] = 0
  openSet.push(PathNode(
    priority: pathHeuristic(start.x, start.y, goal.x, goal.y),
    index: startIndex
  ))
  while openSet.len > 0:
    let current = openSet.pop()
    if tiles.closed[current.index] == stamp:
      continue
    if current.index == goalIndex:
      return tiles.reconstructPath(startIndex, goalIndex)
    tiles.closed[current.index] = stamp
    let
      x = current.index mod tiles.width
      y = current.index div tiles.width
    for delta in PathDeltas:
      let
        nx = x + delta.dx
        ny = y + delta.dy
      if not tiles.tileStepPassable(x, y, delta.dx, delta.dy):
        continue
      let nextIndex = tiles.tileIndex(nx, ny)
      if tiles.closed[nextIndex] == stamp:
        continue
      touch(nextIndex)
      let newCost = tiles.costs[current.index] + 1
      if newCost >= tiles.costs[nextIndex]:
        continue
      tiles.costs[nextIndex] = newCost
      tiles.parents[nextIndex] = current.index
      openSet.push(PathNode(
        priority: newCost + pathHeuristic(nx, ny, goal.x, goal.y),
        index: nextIndex
      ))

proc pixelSegment(
  tiles: var TilePathMap,
  startX,
  startY,
  goalX,
  goalY: int
): tuple[found: bool, path: seq[PathStep]] =
  ## Finds one exact pixel connector segment.
  if startX == goalX and startY == goalY:
    return (found: true, path: @[])
  result.path = tiles.nav.findPath(startX, startY, goalX, goalY)
  result.found = result.path.len > 0

proc appendPath(
  path: var seq[PathStep],
  segment: openArray[PathStep]
) =
  ## Appends one path segment while avoiding duplicate joins.
  for step in segment:
    if path.len > 0 and
        path[path.high].x == step.x and
        path[path.high].y == step.y:
      continue
    path.add(step)

proc findTilePath*(
  tiles: var TilePathMap,
  startX,
  startY,
  goalX,
  goalY: int
): seq[PathStep] =
  ## Finds a hybrid path using pixel connectors and coarse tile A*.
  let
    rawStartX = clamp(startX div tiles.tileSize, 0, tiles.width - 1)
    rawStartY = clamp(startY div tiles.tileSize, 0, tiles.height - 1)
    rawGoalX = clamp(goalX div tiles.tileSize, 0, tiles.width - 1)
    rawGoalY = clamp(goalY div tiles.tileSize, 0, tiles.height - 1)
    start = tiles.nearestTile(rawStartX, rawStartY)
    goal = tiles.nearestTile(rawGoalX, rawGoalY)
  if not start.found or not goal.found:
    return tiles.nav.findPath(startX, startY, goalX, goalY)

  let
    startIndex = tiles.tileIndex(start.x, start.y)
    goalIndex = tiles.tileIndex(goal.x, goal.y)
  if startIndex == goalIndex:
    return tiles.nav.findPath(startX, startY, goalX, goalY)

  let
    startNode = tiles.nodes[startIndex]
    goalNode = tiles.nodes[goalIndex]
  var pre = tiles.pixelSegment(
    startX,
    startY,
    startNode.x,
    startNode.y
  )
  if not pre.found:
    return tiles.nav.findPath(startX, startY, goalX, goalY)

  let coarse = tiles.findCoarsePath(start.x, start.y, goal.x, goal.y)
  if coarse.len == 0:
    return tiles.nav.findPath(startX, startY, goalX, goalY)

  var post = tiles.pixelSegment(
    goalNode.x,
    goalNode.y,
    goalX,
    goalY
  )
  if not post.found:
    return tiles.nav.findPath(startX, startY, goalX, goalY)

  result.appendPath(pre.path)
  result.appendPath(coarse)
  result.appendPath(post.path)

proc findPath*(
  tiles: var TilePathMap,
  startX,
  startY,
  goalX,
  goalY: int
): seq[PathStep] =
  ## Finds a hybrid tile path between two pixel points.
  tiles.findTilePath(startX, startY, goalX, goalY)

{.pop.}

proc nearestPassable*(
  nav: NavigationMap,
  x,
  y: int,
  radius = 96
): PathStep =
  ## Returns the nearest passable point around a requested point.
  if nav.passable(x, y):
    return PathStep(found: true, x: x, y: y)
  var bestDistance = high(int)
  for yy in max(0, y - radius) .. min(nav.height - 1, y + radius):
    for xx in max(0, x - radius) .. min(nav.width - 1, x + radius):
      if not nav.passable(xx, yy):
        continue
      let distance = heuristic(x, y, xx, yy)
      if distance < bestDistance:
        bestDistance = distance
        result = PathStep(found: true, x: xx, y: yy)

proc firstPassable*(nav: NavigationMap): PathStep =
  ## Returns the first passable point in map scan order.
  for y in 0 ..< nav.height:
    for x in 0 ..< nav.width:
      if nav.passable(x, y):
        return PathStep(found: true, x: x, y: y)

proc advancePathCursor*(
  path: openArray[PathStep],
  cursor,
  x,
  y: int
): int =
  ## Advances the path cursor to the closest nearby path point.
  if path.len == 0:
    return 0
  result = min(max(0, cursor), path.high)
  var bestDistance = high(int)
  for i in result .. min(path.high, result + PathCursorSearch):
    let distance = heuristic(x, y, path[i].x, path[i].y)
    if distance < bestDistance:
      bestDistance = distance
      result = i
  while result < path.high and
      heuristic(x, y, path[result].x, path[result].y) <=
        PathConsumeDistance:
    inc result

proc choosePathStep*(
  path: openArray[PathStep],
  cursor: int,
  lookahead = PathLookahead
): PathStep =
  ## Returns a short lookahead waypoint from the current path.
  if path.len == 0:
    return
  let
    start = min(max(0, cursor), path.high)
    index = min(path.high, start + max(0, lookahead))
  path[index]

proc linePassable*(
  nav: NavigationMap,
  ax,
  ay,
  bx,
  by: int
): bool =
  ## Returns true when a straight path segment stays walkable.
  if not nav.passable(ax, ay):
    return false
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return nav.passable(bx, by)
  var
    previousX = ax
    previousY = ay
  for i in 1 .. steps:
    let
      x = ax + int(round(float(dx) * float(i) / float(steps)))
      y = ay + int(round(float(dy) * float(i) / float(steps)))
      stepX = x - previousX
      stepY = y - previousY
    if stepX == 0 and stepY == 0:
      continue
    if abs(stepX) > 1 or abs(stepY) > 1:
      return false
    if not nav.pathStepPassable(previousX, previousY, stepX, stepY):
      return false
    previousX = x
    previousY = y
  true

proc advancePathCursor*(
  nav: NavigationMap,
  path: openArray[PathStep],
  cursor,
  x,
  y: int
): int =
  ## Advances the cursor without skipping a needed corner point.
  if path.len == 0:
    return 0
  let
    start = min(max(0, cursor), path.high)
    stop = min(path.high, start + PathCursorSearch)
  for i in countdown(stop, start):
    if nav.linePassable(x, y, path[i].x, path[i].y):
      return i
  result = advancePathCursor(path, cursor, x, y)
  while result > 0 and not nav.linePassable(
      x,
      y,
      path[result].x,
      path[result].y
    ):
    let previous = path[result - 1]
    if not nav.linePassable(x, y, previous.x, previous.y):
      break
    dec result

proc choosePathStep*(
  nav: NavigationMap,
  motion: MotionState,
  path: openArray[PathStep],
  cursor: int,
  lookahead = PathLookahead
): PathStep =
  ## Returns the furthest visible waypoint from the current path window.
  if path.len == 0:
    return
  let
    start = min(max(0, cursor), path.high)
    stop = min(path.high, start + max(0, lookahead))
  for i in countdown(stop, start):
    if i < path.high and
        pathHeuristic(motion.x, motion.y, path[i].x, path[i].y) <
          WaypointMinDistance:
      continue
    if nav.linePassable(motion.x, motion.y, path[i].x, path[i].y):
      return path[i]
  for i in start .. stop:
    if i == path.high or
        pathHeuristic(motion.x, motion.y, path[i].x, path[i].y) >=
          WaypointMinDistance:
      return path[i]
  path[stop]

proc coastDistance*(config: GameConfig, velocity: int): int =
  ## Returns how many pixels current velocity will carry without input.
  var
    speed = abs(velocity)
    carry = 0
  for _ in 0 ..< CoastLookaheadTicks:
    if speed <= 0:
      break
    carry += speed
    while carry >= config.motionScale:
      inc result
      carry -= config.motionScale
    speed = (speed * config.frictionNum) div config.frictionDen
    if speed < config.stopThreshold:
      speed = 0

proc coastPixels*(config: GameConfig, velocity, carry: int): int =
  ## Returns signed pixels current velocity and carry will coast.
  var
    speed = velocity
    pending = carry
  for _ in 0 ..< CoastLookaheadTicks:
    if speed == 0:
      break
    pending += speed
    while pending >= config.motionScale:
      inc result
      pending -= config.motionScale
    while pending <= -config.motionScale:
      dec result
      pending += config.motionScale
    speed = (speed * config.frictionNum) div config.frictionDen
    if abs(speed) < config.stopThreshold:
      speed = 0

proc coastDistance*(velocity: int): int =
  ## Returns how many pixels current velocity will carry without input.
  coastDistance(defaultGameConfig(), velocity)

proc shouldCoast*(
  config: GameConfig,
  delta,
  velocity,
  carry: int
): bool =
  ## Returns true when existing velocity should stop near the target.
  if delta == 0 or velocity == 0:
    return false
  if (delta > 0 and velocity < 0) or
      (delta < 0 and velocity > 0):
    return false
  let
    distance = abs(delta)
    pixels = coastPixels(config, velocity, carry)
  if pixels == 0:
    return false
  if (delta > 0 and pixels < 0) or
      (delta < 0 and pixels > 0):
    return false
  let
    stopDistance = abs(pixels)
  if stopDistance == 0:
    return false
  let
    minDistance = max(0, stopDistance - CoastArrivalPadding)
    maxDistance = stopDistance + CoastArrivalPadding
  distance >= minDistance and distance <= maxDistance

proc shouldCoast*(config: GameConfig, delta, velocity: int): bool =
  ## Returns true when existing velocity should stop near the target.
  shouldCoast(config, delta, velocity, 0)

proc shouldCoast*(delta, velocity: int): bool =
  ## Returns true when existing velocity should stop near the target.
  shouldCoast(defaultGameConfig(), delta, velocity)

proc shouldBrake*(
  config: GameConfig,
  delta,
  velocity,
  carry: int
): bool =
  ## Returns true when existing velocity would carry past the target.
  if delta > 0 and velocity > 0:
    return coastPixels(config, velocity, carry) >
      delta + CoastArrivalPadding
  if delta < 0 and velocity < 0:
    return -coastPixels(config, velocity, carry) >
      -delta + CoastArrivalPadding
  false

proc shouldBrake*(config: GameConfig, delta, velocity: int): bool =
  ## Returns true when existing velocity would carry past the target.
  shouldBrake(config, delta, velocity, 0)

proc shouldBrake*(delta, velocity: int): bool =
  ## Returns true when existing velocity would carry past the target.
  shouldBrake(defaultGameConfig(), delta, velocity)

proc preciseAxisMask*(
  config: GameConfig,
  delta,
  velocity,
  carry: int,
  negativeMask,
  positiveMask: uint8
): uint8 =
  ## Returns exact final-approach steering with coasting.
  if delta > 0:
    if shouldCoast(config, delta, velocity, carry):
      return 0
    if shouldBrake(config, delta, velocity, carry):
      return negativeMask
    return positiveMask
  if delta < 0:
    if shouldCoast(config, delta, velocity, carry):
      return 0
    if shouldBrake(config, delta, velocity, carry):
      return positiveMask
    return negativeMask
  let drift = coastPixels(config, velocity, carry)
  if drift > 0:
    return negativeMask
  if drift < 0:
    return positiveMask
  0

proc preciseAxisMask*(
  config: GameConfig,
  delta,
  velocity: int,
  negativeMask,
  positiveMask: uint8
): uint8 =
  ## Returns exact final-approach steering with coasting.
  preciseAxisMask(
    config,
    delta,
    velocity,
    0,
    negativeMask,
    positiveMask
  )

proc preciseAxisMask*(
  delta,
  velocity: int,
  negativeMask,
  positiveMask: uint8
): uint8 =
  ## Returns exact final-approach steering with coasting.
  preciseAxisMask(
    defaultGameConfig(),
    delta,
    velocity,
    negativeMask,
    positiveMask
  )

proc directAxisMask(
  delta: int,
  negativeMask,
  positiveMask: uint8
): uint8 =
  ## Returns simple steering without final stop braking.
  if delta > 0:
    return positiveMask
  if delta < 0:
    return negativeMask
  0

proc dampedAxisMask*(
  config: GameConfig,
  delta,
  velocity,
  carry: int,
  negativeMask,
  positiveMask: uint8
): uint8 =
  ## Returns coast-aware steering for a perpendicular lane error.
  if delta > SteerDeadband or delta < -SteerDeadband:
    return preciseAxisMask(
      config,
      delta,
      velocity,
      carry,
      negativeMask,
      positiveMask
    )
  let drift = coastPixels(config, velocity, carry)
  if drift > SteerDeadband:
    return negativeMask
  if drift < -SteerDeadband:
    return positiveMask
  0

proc waypointMask*(
  config: GameConfig,
  motion: MotionState,
  waypoint: PathStep
): uint8 =
  ## Converts a path waypoint into a steering mask.
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - motion.x
    dy = waypoint.y - motion.y
  result = result or directAxisMask(dx, ButtonLeft, ButtonRight)
  result = result or directAxisMask(dy, ButtonUp, ButtonDown)

proc waypointMask*(motion: MotionState, waypoint: PathStep): uint8 =
  ## Converts a path waypoint into a steering mask.
  waypointMask(defaultGameConfig(), motion, waypoint)

proc laneWaypointMask*(
  config: GameConfig,
  motion: MotionState,
  waypoint: PathStep
): uint8 =
  ## Converts a waypoint into fast lane-following steering.
  if not waypoint.found:
    return 0
  let
    dx = waypoint.x - motion.x
    dy = waypoint.y - motion.y
  if abs(dx) > abs(dy):
    result = result or directAxisMask(dx, ButtonLeft, ButtonRight)
    result = result or dampedAxisMask(
      config,
      dy,
      motion.velY,
      motion.carryY,
      ButtonUp,
      ButtonDown
    )
  elif abs(dy) > abs(dx):
    result = result or dampedAxisMask(
      config,
      dx,
      motion.velX,
      motion.carryX,
      ButtonLeft,
      ButtonRight
    )
    result = result or directAxisMask(dy, ButtonUp, ButtonDown)
  else:
    result = waypointMask(config, motion, waypoint)

proc laneWaypointMask*(motion: MotionState, waypoint: PathStep): uint8 =
  ## Converts a waypoint into fast lane-following steering.
  laneWaypointMask(defaultGameConfig(), motion, waypoint)

proc waypointBehindMotion*(
  motion: MotionState,
  waypoint: PathStep
): bool =
  ## Returns true when a waypoint is behind current momentum.
  if not waypoint.found:
    return false
  if abs(motion.velX) + abs(motion.velY) < WaypointBehindVelocity:
    return false
  let
    dx = waypoint.x - motion.x
    dy = waypoint.y - motion.y
  dx * motion.velX + dy * motion.velY < 0

proc precisePointMask(
  config: GameConfig,
  motion: MotionState,
  x,
  y: int
): uint8 =
  ## Returns exact steering for one nearby point.
  result = result or preciseAxisMask(
    config,
    x - motion.x,
    motion.velX,
    motion.carryX,
    ButtonLeft,
    ButtonRight
  )
  result = result or preciseAxisMask(
    config,
    y - motion.y,
    motion.velY,
    motion.carryY,
    ButtonUp,
    ButtonDown
  )

proc closeToGoal(
  motion: MotionState,
  goalX,
  goalY: int
): bool =
  ## Returns true when final stopping should target the goal directly.
  pathHeuristic(motion.x, motion.y, goalX, goalY) <= StopGoalDistance

proc chooseSteeringPathStep*(
  nav: NavigationMap,
  motion: MotionState,
  path: openArray[PathStep],
  cursor: int,
  lookahead = PathLookahead
): PathStep =
  ## Returns a path waypoint that asks for real steering input.
  if path.len == 0:
    return
  let
    start = min(max(0, cursor), path.high)
    stop = min(path.high, start + max(0, lookahead))
  for i in countdown(stop, start):
    if i < path.high and
        pathHeuristic(motion.x, motion.y, path[i].x, path[i].y) <
          WaypointMinDistance:
      continue
    if not nav.linePassable(motion.x, motion.y, path[i].x, path[i].y):
      continue
    let mask = laneWaypointMask(nav.config, motion, path[i])
    if mask != 0 or i == path.high:
      return path[i]
  for i in start .. path.high:
    let mask = laneWaypointMask(nav.config, motion, path[i])
    if mask != 0 or i == path.high:
      return path[i]
  path[stop]

proc moveTo*(
  config: GameConfig,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a fast movement mask that does not require stopping at the goal.
  let waypoint = choosePathStep(path, cursor)
  if waypoint.found:
    return waypointMask(config, motion, waypoint)
  result = result or directAxisMask(goalX - motion.x, ButtonLeft, ButtonRight)
  result = result or directAxisMask(goalY - motion.y, ButtonUp, ButtonDown)

proc moveToAndStop*(
  config: GameConfig,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a movement mask that tries to stop at the final goal.
  let
    close = path.len == 0 or motion.closeToGoal(goalX, goalY)
    waypoint = choosePathStep(path, cursor)
  if close:
    result = precisePointMask(config, motion, goalX, goalY)
  elif waypoint.found:
    result = waypointMask(config, motion, waypoint)

proc moveTo*(
  nav: NavigationMap,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a fast movement mask using the navigation config.
  let waypoint = nav.chooseSteeringPathStep(motion, path, cursor)
  if waypoint.found:
    return laneWaypointMask(nav.config, motion, waypoint)
  result = result or directAxisMask(goalX - motion.x, ButtonLeft, ButtonRight)
  result = result or directAxisMask(goalY - motion.y, ButtonUp, ButtonDown)

proc moveToAndStop*(
  nav: NavigationMap,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a stopping movement mask using the navigation config.
  let
    close = path.len == 0 or (
      motion.closeToGoal(goalX, goalY) and
      nav.linePassable(motion.x, motion.y, goalX, goalY)
    )
    waypoint = nav.chooseSteeringPathStep(motion, path, cursor)
  if close:
    result = precisePointMask(nav.config, motion, goalX, goalY)
  elif waypoint.found:
    result = laneWaypointMask(nav.config, motion, waypoint)

proc moveTo*(
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a fast movement mask using default Crewrift config.
  moveTo(defaultGameConfig(), motion, path, cursor, goalX, goalY)

proc moveToAndStop*(
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a stopping movement mask using default Crewrift config.
  moveToAndStop(defaultGameConfig(), motion, path, cursor, goalX, goalY)

proc slideScanRadius(config: GameConfig, carry, velocity: int): int =
  ## Returns the perpendicular scan radius for blocked movement.
  let
    pending = abs(carry) div config.motionScale
    speed = (abs(velocity) + config.motionScale - 1) div
      config.motionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

proc canSlideHorizontal(
  nav: NavigationMap,
  x,
  y,
  step,
  offset: int
): bool =
  ## Returns true when a horizontal step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not nav.passable(x, y + slideStep * i):
      return false
  nav.passable(x + step, y + offset)

proc canSlideVertical(
  nav: NavigationMap,
  x,
  y,
  step,
  offset: int
): bool =
  ## Returns true when a vertical step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not nav.passable(x + slideStep * i, y):
      return false
  nav.passable(x + offset, y + step)

proc trySlideOffset(
  nav: NavigationMap,
  motion: var MotionState,
  step,
  offset: int,
  horizontal: bool
): bool =
  ## Tries one candidate slide offset for a blocked movement step.
  if horizontal:
    if not nav.canSlideHorizontal(motion.x, motion.y, step, offset):
      return false
    motion.x += step
    motion.y += offset
  else:
    if not nav.canSlideVertical(motion.x, motion.y, step, offset):
      return false
    motion.x += offset
    motion.y += step
  true

proc trySlideMove(
  nav: NavigationMap,
  motion: var MotionState,
  step,
  radius,
  preferredSlide: int,
  horizontal: bool
): bool =
  ## Tries nearby slide offsets for one blocked movement step.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if nav.trySlideOffset(
        motion,
        step,
        preferred * distance,
        horizontal
      ):
        return true
      if nav.trySlideOffset(
        motion,
        step,
        -preferred * distance,
        horizontal
      ):
        return true
    else:
      if nav.trySlideOffset(motion, step, -distance, horizontal):
        return true
      if nav.trySlideOffset(motion, step, distance, horizontal):
        return true
  false

proc applyMomentumAxis(
  nav: NavigationMap,
  motion: var MotionState,
  carry: var int,
  velocity,
  preferredSlide: int,
  horizontal: bool
) =
  ## Applies one fixed-point movement axis with collision sliding.
  carry += velocity
  while abs(carry) >= nav.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: motion.x + step else: motion.x
      ny = if horizontal: motion.y else: motion.y + step
    if nav.passable(nx, ny):
      if horizontal:
        motion.x = nx
      else:
        motion.y = ny
      carry -= step * nav.config.motionScale
    else:
      let radius = slideScanRadius(nav.config, carry, velocity)
      if nav.trySlideMove(motion, step, radius, preferredSlide, horizontal):
        carry -= step * nav.config.motionScale
      else:
        carry = 0
        break

proc stepMotion*(nav: NavigationMap, motion: var MotionState, mask: uint8) =
  ## Applies one Crewrift-style movement tick to the motion state.
  var
    inputX = 0
    inputY = 0
  if (mask and ButtonLeft) != 0:
    dec inputX
  if (mask and ButtonRight) != 0:
    inc inputX
  if (mask and ButtonUp) != 0:
    dec inputY
  if (mask and ButtonDown) != 0:
    inc inputY

  if inputX != 0:
    motion.velX = clamp(
      motion.velX + inputX * nav.config.accel,
      -nav.config.maxSpeed,
      nav.config.maxSpeed
    )
  else:
    motion.velX =
      (motion.velX * nav.config.frictionNum) div nav.config.frictionDen
    if abs(motion.velX) < nav.config.stopThreshold:
      motion.velX = 0

  if inputY != 0:
    motion.velY = clamp(
      motion.velY + inputY * nav.config.accel,
      -nav.config.maxSpeed,
      nav.config.maxSpeed
    )
  else:
    motion.velY =
      (motion.velY * nav.config.frictionNum) div nav.config.frictionDen
    if abs(motion.velY) < nav.config.stopThreshold:
      motion.velY = 0

  let
    preferredSlideY =
      if inputY != 0:
        inputY
      else:
        signOf(motion.velY)
    preferredSlideX =
      if inputX != 0:
        inputX
      else:
        signOf(motion.velX)
  nav.applyMomentumAxis(
    motion,
    motion.carryX,
    motion.velX,
    preferredSlideY,
    true
  )
  nav.applyMomentumAxis(
    motion,
    motion.carryY,
    motion.velY,
    preferredSlideX,
    false
  )

proc momentumMoveTo*(
  nav: NavigationMap,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a fast movement mask for path following.
  nav.moveTo(motion, path, cursor, goalX, goalY)

proc momentumMoveToAndStop*(
  nav: NavigationMap,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a precise stopping movement mask.
  nav.moveToAndStop(motion, path, cursor, goalX, goalY)
