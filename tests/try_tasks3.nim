import
  std/[os, random, strutils],
  pixie,
  crewrift/sim,
  crewrift/tasks as taskAssignments

const
  CrewCount = 8
  TasksPerCrew = 12
  TrySeed = 12345
  TaskSquareSize = 9
  MapSize = MapWidth * MapHeight
  GameDir = currentSourcePath.parentDir.parentDir
  ImagePath = "tmp/crewrift_try_tasks3.png"
  PathColors = [
    "#FF3B30",
    "#34C759",
    "#007AFF",
    "#FFCC00",
    "#AF52DE",
    "#5AC8FA",
    "#FF9500",
    "#FF2D55",
    "#64D2FF",
    "#BF5AF2",
    "#30D158",
    "#FFD60A"
  ]
  PathOffsets = [
    (x: -4, y: -4),
    (x: 4, y: -4),
    (x: -4, y: 4),
    (x: 4, y: 4),
    (x: 0, y: -4),
    (x: 4, y: 0),
    (x: 0, y: 4),
    (x: -4, y: 0),
    (x: -4, y: 4),
    (x: 4, y: -4),
    (x: -4, y: -4),
    (x: 4, y: 4)
  ]

type
  VisualTask = object
    id: int
    task: TaskStation
    target: MapPoint

  TaskMap = object
    gameMap: CrewriftMap
    tasks: seq[TaskStation]
    walkMask: seq[bool]
    mapImage: Image

  VisualAssignment = object
    taskIds: seq[int]
    routeOrder: seq[int]
    moduleCost: int
    routeCost: int

proc initCrewriftForTry(): TaskMap =
  ## Loads only the Crewrift map data needed by this task experiment.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    let config = defaultGameConfig()
    result.gameMap = loadCrewriftMap(config.mapPath)
    result.tasks = result.gameMap.tasks
    let layers = loadMapLayers(result.gameMap)
    result.mapImage = layers.mapImage
    result.walkMask = newSeq[bool](MapSize)
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        result.walkMask[mapIndex(x, y)] = layers.walkImage[x, y].a > 0
  finally:
    setCurrentDir(previousDir)

proc isWalkable(game: TaskMap, x, y: int): bool =
  ## Returns true when one map point is walkable.
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  game.walkMask[mapIndex(x, y)]

proc nearestWalkablePoint(game: TaskMap, x, y: int): MapPoint =
  ## Returns the nearest walkable map point to one pixel.
  if game.isWalkable(x, y):
    return MapPoint(x: x, y: y)
  for radius in 1 .. max(MapWidth, MapHeight):
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        let
          px = x + dx
          py = y + dy
        if game.isWalkable(px, py):
          return MapPoint(x: px, y: py)
  MapPoint(x: x, y: y)

proc taskCenter(task: TaskStation): MapPoint =
  ## Returns the center point of one task station.
  MapPoint(
    x: task.x + task.w div 2,
    y: task.y + task.h div 2
  )

proc taskRects(game: TaskMap): seq[taskAssignments.TaskRect] =
  ## Returns task rectangles in the format used by the production assigner.
  for task in game.tasks:
    result.add taskAssignments.TaskRect(
      x: task.x,
      y: task.y,
      w: task.w,
      h: task.h
    )

proc visualTasks(game: TaskMap): seq[VisualTask] =
  ## Returns task records with walkable drawing target points.
  for i, task in game.tasks:
    let
      center = task.taskCenter()
      target = game.nearestWalkablePoint(center.x, center.y)
    result.add VisualTask(
      id: i,
      task: task,
      target: target
    )

proc manhattan(a, b: MapPoint): int =
  ## Returns the Manhattan distance between two map points.
  abs(a.x - b.x) + abs(a.y - b.y)

proc routeOrder(
  taskIds: openArray[int],
  tasks: openArray[VisualTask],
  start: MapPoint
): seq[int] =
  ## Returns a greedy nearest-neighbor route order for drawing.
  var
    remaining = @taskIds
    current = start
  while remaining.len > 0:
    var
      best = 0
      bestDistance = current.manhattan(tasks[remaining[0]].target)
    for i in 1 ..< remaining.len:
      let distance = current.manhattan(tasks[remaining[i]].target)
      if distance < bestDistance or
          (distance == bestDistance and remaining[i] < remaining[best]):
        best = i
        bestDistance = distance
    let taskId = remaining[best]
    result.add taskId
    current = tasks[taskId].target
    remaining.delete(best)

proc routeCost(
  order: openArray[int],
  tasks: openArray[VisualTask],
  start: MapPoint
): int =
  ## Returns the visual route length for one ordered task list.
  var current = start
  for taskId in order:
    result += current.manhattan(tasks[taskId].target)
    current = tasks[taskId].target

proc duplicateCount(taskIds: openArray[int]): int =
  ## Returns the number of same-task pairs in one assigned task list.
  for i in 0 ..< taskIds.len:
    for j in i + 1 ..< taskIds.len:
      if taskIds[i] == taskIds[j]:
        inc result

proc buildVisualAssignments(
  assignments: openArray[taskAssignments.TaskAssignment],
  tasks: openArray[VisualTask],
  start: MapPoint
): seq[VisualAssignment] =
  ## Builds route data from production task assignment ids.
  for assignment in assignments:
    let order = routeOrder(assignment.taskIds, tasks, start)
    result.add VisualAssignment(
      taskIds: assignment.taskIds,
      routeOrder: order,
      moduleCost: assignment.routeCost,
      routeCost: routeCost(order, tasks, start)
    )

proc roomName(task: VisualTask): string =
  ## Returns a compact room-ish name for one task.
  task.task.name.replace("Task near ", "")

proc taskLabel(task: VisualTask): string =
  ## Returns a compact display label for one task.
  $task.id & ":" & task.roomName()

proc routeLabel(
  assignment: VisualAssignment,
  tasks: openArray[VisualTask]
): string =
  ## Returns the approximate route order as a compact label.
  var labels: seq[string]
  for taskId in assignment.routeOrder:
    labels.add tasks[taskId].taskLabel()
  labels.join(" -> ")

proc scoreSpread(assignments: openArray[VisualAssignment]): int =
  ## Returns the route-cost spread across all visual assignments.
  if assignments.len == 0:
    return 0
  var
    minCost = assignments[0].routeCost
    maxCost = assignments[0].routeCost
  for assignment in assignments:
    minCost = min(minCost, assignment.routeCost)
    maxCost = max(maxCost, assignment.routeCost)
  maxCost - minCost

proc totalRoute(assignments: openArray[VisualAssignment]): int =
  ## Returns the sum of all visual route costs.
  for assignment in assignments:
    result += assignment.routeCost

proc printTaskTable(tasks: openArray[VisualTask]) =
  ## Prints all task ids and drawing target points.
  echo "Tasks"
  echo "id   target      room"
  echo "--   ----------  ----------------"
  for task in tasks:
    echo align($task.id, 2), "   ",
      align("(" & $task.target.x & "," & $task.target.y & ")", 10), "  ",
      task.roomName()

proc printAssignmentTable(
  assignments: openArray[VisualAssignment],
  tasks: openArray[VisualTask]
) =
  ## Prints one row per production task assignment.
  echo ""
  echo "Production-module assignment"
  echo "crew  path   draw   dups  approximate drawing route"
  echo "----  -----  -----  ----  -------------------------"
  for i, assignment in assignments:
    echo align($i, 4), "  ",
      align($assignment.moduleCost, 5), "  ",
      align($assignment.routeCost, 5), "  ",
      align($assignment.taskIds.duplicateCount(), 4), "  ",
      assignment.routeLabel(tasks)

  let average =
    if assignments.len > 0:
      assignments.totalRoute().float / assignments.len.float
    else:
      0.0
  echo ""
  echo "Summary"
  echo "crew: ", assignments.len
  echo "tasks per crew: ", TasksPerCrew
  echo "visual route spread: ", assignments.scoreSpread()
  echo "average visual route: ", formatFloat(average, ffDecimal, 1)
  echo "total visual route: ", assignments.totalRoute()

proc drawSquare(
  ctx: Context,
  point: MapPoint,
  size: int,
  fillStyle,
  strokeStyle: string
) =
  ## Draws one square centered on a map point.
  let
    half = size div 2
    x = (point.x - half).float32
    y = (point.y - half).float32
    width = size.float32
  ctx.fillStyle = fillStyle
  ctx.fillRect(x, y, width, width)
  ctx.strokeStyle = strokeStyle
  ctx.lineWidth = 1
  ctx.strokeRect(x, y, width, width)

proc drawRoute(
  ctx: Context,
  assignment: VisualAssignment,
  tasks: openArray[VisualTask],
  start: MapPoint,
  color: string,
  offset: tuple[x, y: int]
) =
  ## Draws one crew route from spawn through its assigned tasks.
  var previous = start
  ctx.strokeStyle = color
  ctx.lineWidth = 3
  for taskId in assignment.routeOrder:
    let target = tasks[taskId].target
    ctx.strokeSegment(
      (previous.x + offset.x).float32,
      (previous.y + offset.y).float32,
      (target.x + offset.x).float32,
      (target.y + offset.y).float32
    )
    previous = target

proc drawTaskAssignmentImage(
  game: TaskMap,
  tasks: openArray[VisualTask],
  assignments: openArray[VisualAssignment],
  start: MapPoint,
  path: string
) =
  ## Writes a visual map of production task assignments.
  let dir = path.parentDir()
  if dir.len > 0:
    createDir(dir)
  let image = newImage(game.mapImage.width, game.mapImage.height)
  var ctx = newContext(image)
  ctx.fillStyle = rgba(7, 8, 12, 255)
  ctx.fillRect(0, 0, image.width.float32, image.height.float32)
  image.draw(game.mapImage)

  for i, assignment in assignments:
    let
      color = PathColors[i mod PathColors.len]
      offset = PathOffsets[i mod PathOffsets.len]
    ctx.globalAlpha = 0.8
    ctx.drawRoute(assignment, tasks, start, color, offset)

  ctx.globalAlpha = 1
  for task in tasks:
    ctx.drawSquare(
      task.target,
      TaskSquareSize,
      "#FFFFFF",
      "#111111"
    )
  ctx.drawSquare(start, TaskSquareSize + 4, "#000000", "#FFFFFF")
  image.writeFile(path)

let
  game = initCrewriftForTry()
  start = game.nearestWalkablePoint(
    game.gameMap.home.x,
    game.gameMap.home.y
  )
  tasks = game.visualTasks()

var rng = initRand(TrySeed)
let
  rects = game.taskRects()
  assigned = taskAssignments.assignTaskDetails(
    rects,
    game.walkMask,
    MapWidth,
    MapHeight,
    game.gameMap.home.x,
    game.gameMap.home.y,
    CrewCount,
    TasksPerCrew,
    rng
  )
  assignments = buildVisualAssignments(assigned, tasks, start)

echo "Crewrift production task assignment try"
echo "seed: ", TrySeed
echo "spawn button: (", game.gameMap.home.x, ",", game.gameMap.home.y, ")"
echo "walkable start: (", start.x, ",", start.y, ")"
echo "tasks: ", tasks.len
echo "crew: ", CrewCount
echo "tasks per crew: ", TasksPerCrew
echo "assignment source: crewrift/tasks.assignTaskDetails"
echo "visual output: ", ImagePath
echo ""
tasks.printTaskTable()
assignments.printAssignmentTable(tasks)
game.drawTaskAssignmentImage(
  tasks,
  assignments,
  start,
  ImagePath
)
