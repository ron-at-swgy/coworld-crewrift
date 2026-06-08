import
  std/[algorithm, os, random, strformat, strutils, tables],
  pixie,
  crewrift/sim

const
  CrewCount = 8
  TasksPerCrew = 12
  TrySeed = 12345
  TaskSquareSize = 9
  NoDistance = high(int) div 4
  SpawnNode = 0
  MapSize = MapWidth * MapHeight
  GameDir = currentSourcePath.parentDir.parentDir
  ImagePath = "tmp/crewrift_try_tasks2.png"
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
  TaskInfo = object
    id: int
    node: int
    task: TaskStation
    target: MapPoint
    distance: int

  TaskMap = object
    gameMap: CrewriftMap
    tasks: seq[TaskStation]
    walkMask: seq[bool]
    mapImage: Image

  DistanceMatrix = object
    size: int
    distances: seq[int]

  RoutePlan = object
    cost: int
    order: seq[int]

  Assignment = object
    tasks: seq[TaskInfo]
    routeCost: int

  AssignmentScore = object
    duplicates: int
    spread: int
    maxCost: int
    totalCost: int

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

proc targetIndexMap(
  points: openArray[MapPoint]
): tuple[index: seq[int], count: int] =
  ## Returns map-index targets used to stop shortest-path searches early.
  result.index = newSeq[int](MapSize)
  for i in 0 ..< result.index.len:
    result.index[i] = -1
  for i, point in points:
    let index = mapIndex(point.x, point.y)
    if result.index[index] == -1:
      result.index[index] = i
      inc result.count

proc pointDistances(
  game: TaskMap,
  start: MapPoint,
  points: openArray[MapPoint],
  targets: openArray[int],
  targetCount: int,
  costs, seen, queue: var seq[int],
  stamp: int
): seq[int] =
  ## Returns exact shortest-path distances from one point to target points.
  var
    head = 0
    tail = 0
    found = 0
  let startIndex = mapIndex(start.x, start.y)
  costs[startIndex] = 0
  seen[startIndex] = stamp
  queue[tail] = startIndex
  inc tail

  template addNeighbor(index: int, nextCost: int) =
    if seen[index] != stamp and game.walkMask[index]:
      seen[index] = stamp
      costs[index] = nextCost
      queue[tail] = index
      inc tail

  while head < tail:
    let current = queue[head]
    inc head
    if targets[current] >= 0:
      inc found
      if found >= targetCount:
        break

    let
      x = current mod MapWidth
      y = current div MapWidth
      nextCost = costs[current] + 1
    if y > 0:
      addNeighbor(current - MapWidth, nextCost)
    if y + 1 < MapHeight:
      addNeighbor(current + MapWidth, nextCost)
    if x > 0:
      addNeighbor(current - 1, nextCost)
    if x + 1 < MapWidth:
      addNeighbor(current + 1, nextCost)

  result = newSeq[int](points.len)
  for i, point in points:
    let index = mapIndex(point.x, point.y)
    result[i] =
      if seen[index] == stamp:
        costs[index]
      else:
        NoDistance

proc distanceIndex(matrix: DistanceMatrix, a, b: int): int =
  ## Returns the flat matrix index for two node ids.
  a * matrix.size + b

proc distance(matrix: DistanceMatrix, a, b: int): int =
  ## Returns the cached A* distance between two node ids.
  matrix.distances[matrix.distanceIndex(a, b)]

proc taskInfos(game: TaskMap): seq[TaskInfo] =
  ## Builds task records with walkable target points.
  for i, task in game.tasks:
    let
      center = task.taskCenter()
      target = game.nearestWalkablePoint(center.x, center.y)
    result.add TaskInfo(
      id: i,
      node: i + 1,
      task: task,
      target: target,
      distance: NoDistance
    )

proc buildDistanceMatrix(
  game: TaskMap,
  start: MapPoint,
  tasks: openArray[TaskInfo]
): DistanceMatrix =
  ## Computes exact spawn distances and approximate task-pair distances.
  result.size = tasks.len + 1
  result.distances = newSeq[int](result.size * result.size)

  var points = @[start]
  for task in tasks:
    points.add task.target

  let targets = points.targetIndexMap()
  var
    costs = newSeq[int](MapSize)
    seen = newSeq[int](MapSize)
    queue = newSeq[int](MapSize)
  let spawnDistances = game.pointDistances(
    start,
    points,
    targets.index,
    targets.count,
    costs,
    seen,
    queue,
    1
  )

  for i in 0 ..< result.size:
    for j in 0 ..< result.size:
      result.distances[result.distanceIndex(i, j)] =
        if i == j:
          0
        elif i == SpawnNode:
          spawnDistances[j]
        elif j == SpawnNode:
          spawnDistances[i]
        else:
          abs(points[i].x - points[j].x) + abs(points[i].y - points[j].y)

proc applySpawnDistances(
  tasks: var seq[TaskInfo],
  matrix: DistanceMatrix
) =
  ## Copies spawn-to-task distance from the matrix into each task.
  for task in tasks.mitems:
    task.distance = matrix.distance(SpawnNode, task.node)
  tasks.sort(
    proc(a, b: TaskInfo): int =
      result = cmp(a.distance, b.distance)
      if result == 0:
        result = cmp(a.id, b.id)
  )

proc routePlan(
  matrix: DistanceMatrix,
  tasks: openArray[TaskInfo]
): RoutePlan =
  ## Approximates a route from spawn through all assigned tasks.
  if tasks.len == 0:
    return RoutePlan(cost: 0)

  var
    used = newSeq[bool](tasks.len)
    currentNode = SpawnNode
  for _ in 0 ..< tasks.len:
    var
      best = -1
      bestDistance = NoDistance
    for i, task in tasks:
      if used[i]:
        continue
      let distance = matrix.distance(currentNode, task.node)
      if best < 0 or distance < bestDistance or
          (distance == bestDistance and task.id < tasks[best].id):
        best = i
        bestDistance = distance
    doAssert best >= 0
    used[best] = true
    result.order.add best
    result.cost += bestDistance
    currentNode = tasks[best].node

proc routeCost(
  matrix: DistanceMatrix,
  tasks: openArray[TaskInfo]
): int =
  ## Returns the approximate route cost for one task list.
  matrix.routePlan(tasks).cost

proc routeKey(tasks: openArray[TaskInfo]): uint64 =
  ## Returns a compact order-independent key for one task set.
  for task in tasks:
    result = result or (1'u64 shl uint64(task.id))

proc hasDuplicateTask(tasks: openArray[TaskInfo]): bool =
  ## Returns true when a task list repeats a station.
  for i in 0 ..< tasks.len:
    for j in i + 1 ..< tasks.len:
      if tasks[i].id == tasks[j].id:
        return true

proc cachedRouteCost(
  matrix: DistanceMatrix,
  tasks: openArray[TaskInfo],
  cache: var Table[uint64, int]
): int =
  ## Returns route cost, caching unique task sets by bit mask.
  if tasks.hasDuplicateTask():
    return matrix.routeCost(tasks)
  let key = tasks.routeKey()
  if key in cache:
    return cache[key]
  result = matrix.routeCost(tasks)
  cache[key] = result

proc hasTask(assignment: Assignment, taskId: int): bool =
  ## Returns true when an assignment already contains one task.
  for task in assignment.tasks:
    if task.id == taskId:
      return true

proc canReceive(
  assignment: Assignment,
  incomingId, outgoingIndex: int
): bool =
  ## Returns true when a swap would not duplicate a task for one crew.
  for i, task in assignment.tasks:
    if i != outgoingIndex and task.id == incomingId:
      return false
  true

proc duplicateCount(tasks: openArray[TaskInfo]): int =
  ## Returns the number of same-task pairs in one task list.
  for i in 0 ..< tasks.len:
    for j in i + 1 ..< tasks.len:
      if tasks[i].id == tasks[j].id:
        inc result

proc makeTaskPool(
  tasks: openArray[TaskInfo],
  needed: int,
  rng: var Rand
): seq[TaskInfo] =
  ## Builds the task pool by removing or duplicating tasks to fit demand.
  doAssert tasks.len > 0
  result = @tasks
  while result.len > needed:
    result.delete(rng.rand(result.high))
  while result.len < needed:
    result.add tasks[rng.rand(tasks.high)]
  result.sort(
    proc(a, b: TaskInfo): int =
      result = cmp(b.distance, a.distance)
      if result == 0:
        result = cmp(a.id, b.id)
  )

proc routeCostWithTask(
  matrix: DistanceMatrix,
  assignment: Assignment,
  task: TaskInfo,
  cache: var Table[uint64, int]
): int =
  ## Returns route cost after adding one task to one assignment.
  var tasks = assignment.tasks
  tasks.add task
  matrix.cachedRouteCost(tasks, cache)

proc pickCrew(
  assignments: openArray[Assignment],
  matrix: DistanceMatrix,
  task: TaskInfo,
  tasksPerCrew: int,
  rng: var Rand,
  cache: var Table[uint64, int],
  allowDuplicate = false
): int =
  ## Picks the crew with the lowest route after adding one task.
  result = -1
  var bestScore = NoDistance
  for i, assignment in assignments:
    if assignment.tasks.len >= tasksPerCrew:
      continue
    if not allowDuplicate and assignment.hasTask(task.id):
      continue
    let score = matrix.routeCostWithTask(assignment, task, cache)
    if score < bestScore or (score == bestScore and rng.rand(1) == 0):
      result = i
      bestScore = score

proc assignGreedyRoutes(
  tasks: openArray[TaskInfo],
  matrix: DistanceMatrix,
  crewCount, tasksPerCrew: int,
  rng: var Rand,
  cache: var Table[uint64, int]
): seq[Assignment] =
  ## Assigns far tasks first by current shortest full-route cost.
  result = newSeq[Assignment](crewCount)
  var pool = tasks.makeTaskPool(crewCount * tasksPerCrew, rng)
  while pool.len > 0:
    var
      poolIndex = -1
      crew = -1
    for i, task in pool:
      crew = result.pickCrew(matrix, task, tasksPerCrew, rng, cache)
      if crew >= 0:
        poolIndex = i
        break
    if poolIndex < 0:
      poolIndex = 0
      crew = result.pickCrew(
        matrix,
        pool[poolIndex],
        tasksPerCrew,
        rng,
        cache,
        allowDuplicate = true
      )
    doAssert crew >= 0
    let task = pool[poolIndex]
    result[crew].tasks.add task
    result[crew].routeCost = matrix.cachedRouteCost(
      result[crew].tasks,
      cache
    )
    pool.delete(poolIndex)

proc scoreAssignments(
  assignments: openArray[Assignment]
): AssignmentScore =
  ## Scores route fairness for all crew assignments.
  var minCost = NoDistance
  for assignment in assignments:
    result.duplicates += assignment.tasks.duplicateCount()
    minCost = min(minCost, assignment.routeCost)
    result.maxCost = max(result.maxCost, assignment.routeCost)
    result.totalCost += assignment.routeCost
  result.spread = result.maxCost - minCost

proc better(a, b: AssignmentScore): bool =
  ## Returns true when score a is better than score b.
  if a.duplicates != b.duplicates:
    return a.duplicates < b.duplicates
  if a.spread != b.spread:
    return a.spread < b.spread
  if a.maxCost != b.maxCost:
    return a.maxCost < b.maxCost
  a.totalCost < b.totalCost

proc scoreAfterSwap(
  assignments: openArray[Assignment],
  matrix: DistanceMatrix,
  crewA, taskA, crewB, taskB: int,
  cache: var Table[uint64, int]
): AssignmentScore =
  ## Scores route fairness after one hypothetical task swap.
  for i, assignment in assignments:
    var cost = assignment.routeCost
    var tasks = assignment.tasks
    if i == crewA:
      tasks[taskA] = assignments[crewB].tasks[taskB]
      cost = matrix.cachedRouteCost(tasks, cache)
    elif i == crewB:
      tasks[taskB] = assignments[crewA].tasks[taskA]
      cost = matrix.cachedRouteCost(tasks, cache)
    result.duplicates += tasks.duplicateCount()
    result.maxCost = max(result.maxCost, cost)
    result.totalCost += cost

  var minCost = NoDistance
  for i, assignment in assignments:
    var cost = assignment.routeCost
    if i == crewA:
      var tasks = assignment.tasks
      tasks[taskA] = assignments[crewB].tasks[taskB]
      cost = matrix.cachedRouteCost(tasks, cache)
    elif i == crewB:
      var tasks = assignment.tasks
      tasks[taskB] = assignments[crewA].tasks[taskA]
      cost = matrix.cachedRouteCost(tasks, cache)
    minCost = min(minCost, cost)
  result.spread = result.maxCost - minCost

proc improveAssignments(
  assignments: var seq[Assignment],
  matrix: DistanceMatrix,
  cache: var Table[uint64, int]
): int =
  ## Swaps tasks while the full-route fairness score improves.
  var improved = true
  while improved:
    improved = false
    var
      bestScore = assignments.scoreAssignments()
      bestCrewA = -1
      bestTaskA = -1
      bestCrewB = -1
      bestTaskB = -1
    for crewA in 0 ..< assignments.len:
      for crewB in crewA + 1 ..< assignments.len:
        for taskA in 0 ..< assignments[crewA].tasks.len:
          for taskB in 0 ..< assignments[crewB].tasks.len:
            let
              infoA = assignments[crewA].tasks[taskA]
              infoB = assignments[crewB].tasks[taskB]
            if infoA.id == infoB.id:
              continue
            if not assignments[crewA].canReceive(infoB.id, taskA):
              continue
            if not assignments[crewB].canReceive(infoA.id, taskB):
              continue
            let score = assignments.scoreAfterSwap(
              matrix,
              crewA,
              taskA,
              crewB,
              taskB,
              cache
            )
            if score.better(bestScore):
              bestScore = score
              bestCrewA = crewA
              bestTaskA = taskA
              bestCrewB = crewB
              bestTaskB = taskB
    if bestCrewA >= 0:
      let
        infoA = assignments[bestCrewA].tasks[bestTaskA]
        infoB = assignments[bestCrewB].tasks[bestTaskB]
      assignments[bestCrewA].tasks[bestTaskA] = infoB
      assignments[bestCrewB].tasks[bestTaskB] = infoA
      assignments[bestCrewA].routeCost =
        matrix.cachedRouteCost(assignments[bestCrewA].tasks, cache)
      assignments[bestCrewB].routeCost =
        matrix.cachedRouteCost(assignments[bestCrewB].tasks, cache)
      inc result
      improved = true

proc roomName(task: TaskInfo): string =
  ## Returns a compact room-ish name for one task.
  task.task.name.replace("Task near ", "")

proc taskLabel(task: TaskInfo): string =
  ## Returns a compact display label for one task.
  fmt"{task.id}:{task.distance}:{task.roomName()}"

proc routeLabel(
  matrix: DistanceMatrix,
  assignment: Assignment
): string =
  ## Returns the approximate route order as a compact label.
  let plan = matrix.routePlan(assignment.tasks)
  var labels: seq[string]
  for index in plan.order:
    labels.add assignment.tasks[index].taskLabel()
  labels.join(" -> ")

proc spawnSum(assignment: Assignment): int =
  ## Returns the sum of spawn-to-task distances for comparison.
  for task in assignment.tasks:
    result += task.distance

proc printTaskTable(tasks: openArray[TaskInfo]) =
  ## Prints all tasks sorted by spawn distance.
  echo "Tasks sorted by exact distance from spawn button"
  echo "id   dist   target      room"
  echo "--   ----   ----------  ----------------"
  for task in tasks:
    echo align($task.id, 2), "   ",
      align($task.distance, 4), "   ",
      align("(" & $task.target.x & "," & $task.target.y & ")", 10), "  ",
      task.roomName()

proc printAssignmentTable(
  matrix: DistanceMatrix,
  assignments: openArray[Assignment],
  swaps: int,
  before: AssignmentScore
) =
  ## Prints one row per crew assignment and summary totals.
  let after = assignments.scoreAssignments()
  echo ""
  echo "Full-route assignment"
  echo "crew  route  spawn  avg    approximate route order"
  echo "----  -----  -----  -----  -----------------------"
  for i, assignment in assignments:
    let avg =
      if assignment.tasks.len > 0:
        assignment.routeCost.float / assignment.tasks.len.float
      else:
        0.0
    echo align($i, 4), "  ",
      align($assignment.routeCost, 5), "  ",
      align($assignment.spawnSum(), 5), "  ",
      align(formatFloat(avg, ffDecimal, 1), 5), "  ",
      matrix.routeLabel(assignment)

  let avgRoute =
    if assignments.len > 0:
      after.totalCost.float / assignments.len.float
    else:
      0.0
  echo ""
  echo "Summary"
  echo "crew: ", assignments.len
  echo "tasks per crew: ", TasksPerCrew
  echo "improvement swaps: ", swaps
  echo "same-crew duplicate pairs: ", after.duplicates
  echo "initial route spread: ", before.spread
  echo "final route spread: ", after.spread
  echo "max route: ", after.maxCost
  echo "average route: ", formatFloat(avgRoute, ffDecimal, 1)
  echo "total route: ", after.totalCost

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
  matrix: DistanceMatrix,
  assignment: Assignment,
  start: MapPoint,
  color: string,
  offset: tuple[x, y: int]
) =
  ## Draws one crew route from spawn through its assigned tasks.
  let plan = matrix.routePlan(assignment.tasks)
  var previous = start
  ctx.strokeStyle = color
  ctx.lineWidth = 3
  for index in plan.order:
    let target = assignment.tasks[index].target
    ctx.strokeSegment(
      (previous.x + offset.x).float32,
      (previous.y + offset.y).float32,
      (target.x + offset.x).float32,
      (target.y + offset.y).float32
    )
    previous = target

proc drawTaskAssignmentImage(
  game: TaskMap,
  matrix: DistanceMatrix,
  tasks: openArray[TaskInfo],
  assignments: openArray[Assignment],
  start: MapPoint,
  path: string
) =
  ## Writes a visual map of tasks and crew assignment paths.
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
    ctx.drawRoute(matrix, assignment, start, color, offset)

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

var
  rng = initRand(TrySeed)
  tasks = game.taskInfos()
  matrix = game.buildDistanceMatrix(start, tasks)
  routeCache: Table[uint64, int]

tasks.applySpawnDistances(matrix)
var assignments = tasks.assignGreedyRoutes(
  matrix,
  CrewCount,
  TasksPerCrew,
  rng,
  routeCache
)
let before = assignments.scoreAssignments()
let swaps = assignments.improveAssignments(matrix, routeCache)

echo "Crewrift full-route task assignment try"
echo "seed: ", TrySeed
echo "spawn button: (", game.gameMap.home.x, ",", game.gameMap.home.y, ")"
echo "walkable start: (", start.x, ",", start.y, ")"
echo "tasks: ", tasks.len
echo "crew: ", CrewCount
echo "tasks per crew: ", TasksPerCrew
echo "distance matrix nodes: ", matrix.size
echo "task-pair distances: Manhattan approximation"
echo "route cache entries: ", routeCache.len
echo "visual output: ", ImagePath
echo ""
tasks.printTaskTable()
matrix.printAssignmentTable(assignments, swaps, before)
game.drawTaskAssignmentImage(
  matrix,
  tasks,
  assignments,
  start,
  ImagePath
)
