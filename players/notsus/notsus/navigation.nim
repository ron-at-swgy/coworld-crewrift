import
  ../../../src/crewrift/sim,
  pathing

export pathing

type
  Navigator* = object
    nav*: NavigationMap
    jps*: JumpPointSpace

proc ready*(navigator: Navigator): bool =
  ## Returns true when navigation data has been built.
  not navigator.nav.isNil and not navigator.jps.isNil

proc initNavigator*(
  walkMask: openArray[bool],
  config: GameConfig
): Navigator =
  ## Builds navigation and JPS+ lookup data from one walkability map.
  result.nav = initNavigationMap(walkMask, config)
  result.jps = newJumpPointSpace(newPathSpace(
    result.nav.passableMask,
    result.nav.width,
    result.nav.height,
    DiagonalPath
  ))

proc width*(navigator: Navigator): int =
  ## Returns the navigation map width in pixels.
  if navigator.nav.isNil:
    return 0
  navigator.nav.width

proc height*(navigator: Navigator): int =
  ## Returns the navigation map height in pixels.
  if navigator.nav.isNil:
    return 0
  navigator.nav.height

proc pathIndex*(navigator: Navigator, x, y: int): int {.inline.} =
  ## Returns one flattened navigation map index.
  navigator.nav.pathIndex(x, y)

proc passable*(navigator: Navigator, x, y: int): bool =
  ## Returns true when a collision-sized player can occupy a pixel.
  navigator.ready() and navigator.nav.passable(x, y)

proc walkable*(navigator: Navigator, x, y: int): bool =
  ## Returns true when one pixel is part of the walk mask.
  if not navigator.ready() or not navigator.nav.inBounds(x, y):
    return false
  navigator.nav.walkMask[navigator.nav.pathIndex(x, y)]

proc occupiable*(navigator: Navigator, x, y: int): bool =
  ## Returns true when one pixel is part of the occupiable mask.
  if not navigator.ready() or not navigator.nav.inBounds(x, y):
    return false
  navigator.nav.passableMask[navigator.nav.pathIndex(x, y)]

proc nearestPassable*(navigator: Navigator, x, y: int): PathStep =
  ## Returns the closest occupiable pixel to one requested point.
  if not navigator.ready():
    return
  navigator.nav.nearestPassable(x, y)

proc firstPassable*(navigator: Navigator): PathStep =
  ## Returns the first occupiable pixel in the map.
  if not navigator.ready():
    return
  navigator.nav.firstPassable()

proc findPath*(
  navigator: var Navigator,
  startX,
  startY,
  goalX,
  goalY: int
): seq[PathStep] =
  ## Finds a direct JPS+ path between two occupiable points.
  if not navigator.ready():
    return
  if not navigator.passable(startX, startY) or
      not navigator.passable(goalX, goalY):
    return
  navigator.jps.findPath(startX, startY, goalX, goalY)

proc pathDistance*(
  navigator: var Navigator,
  startX,
  startY,
  goalX,
  goalY: int
): int =
  ## Returns the diagonal-aware JPS+ path distance between two points.
  if startX == goalX and startY == goalY:
    return 0
  let path = navigator.findPath(startX, startY, goalX, goalY)
  if path.len == 0:
    return high(int)
  var
    x = startX
    y = startY
  for step in path:
    result += pathHeuristic(x, y, step.x, step.y)
    x = step.x
    y = step.y

proc advancePathCursor*(
  navigator: Navigator,
  path: openArray[PathStep],
  cursor,
  x,
  y: int
): int =
  ## Advances a route cursor to the best currently visible waypoint.
  if not navigator.ready():
    return cursor
  navigator.nav.advancePathCursor(path, cursor, x, y)

proc chooseSteeringPathStep*(
  navigator: Navigator,
  motion: MotionState,
  path: openArray[PathStep],
  cursor: int,
  lookahead: int = PathLookahead
): PathStep =
  ## Chooses the current steering waypoint for one route.
  if not navigator.ready():
    return
  navigator.nav.chooseSteeringPathStep(motion, path, cursor, lookahead)

proc moveTo*(
  navigator: Navigator,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a movement mask for going through a path at full speed.
  if not navigator.ready():
    return 0
  navigator.nav.moveTo(motion, path, cursor, goalX, goalY)

proc moveToAndStop*(
  navigator: Navigator,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a movement mask for reaching a point and stopping there.
  if not navigator.ready():
    return 0
  navigator.nav.moveToAndStop(motion, path, cursor, goalX, goalY)

proc momentumMoveTo*(
  navigator: Navigator,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a full-speed movement mask for path following.
  if not navigator.ready():
    return 0
  navigator.nav.momentumMoveTo(motion, path, cursor, goalX, goalY)

proc momentumMoveToAndStop*(
  navigator: Navigator,
  motion: MotionState,
  path: openArray[PathStep],
  cursor,
  goalX,
  goalY: int
): uint8 =
  ## Returns a precise movement mask for stopping at one goal.
  if not navigator.ready():
    return 0
  navigator.nav.momentumMoveToAndStop(motion, path, cursor, goalX, goalY)
