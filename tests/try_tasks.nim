import
  std/[algorithm, heapqueue, os, random, strformat, strutils],
  crewrift/sim

const
  CrewCount = 6
  TasksPerCrew = 8
  TrySeed = 12345
  NoDistance = high(int) div 4
  GameDir = currentSourcePath.parentDir.parentDir

type
  SearchNode = object
    index: int
    cost: int
    score: int

  TaskInfo = object
    id: int
    task: TaskStation
    target: MapPoint
    distance: int

  Assignment = object
    tasks: seq[TaskInfo]
    total: int

proc `<`(a, b: SearchNode): bool =
  ## Orders search nodes for the A* priority queue.
  if a.score == b.score:
    a.cost > b.cost
  else:
    a.score < b.score

proc initCrewriftForTry(): SimServer =
  ## Initializes Crewrift from the repository root.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(defaultGameConfig())
  finally:
    setCurrentDir(previousDir)

proc distanceHeuristic(x, y, goalX, goalY: int): int =
  ## Returns the Manhattan distance between two map points.
  abs(x - goalX) + abs(y - goalY)

proc nearestWalkablePoint(sim: SimServer, x, y: int): MapPoint =
  ## Returns the nearest walkable map point to one pixel.
  if sim.isWalkable(x, y):
    return MapPoint(x: x, y: y)
  for radius in 1 .. max(MapWidth, MapHeight):
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        let
          px = x + dx
          py = y + dy
        if sim.isWalkable(px, py):
          return MapPoint(x: px, y: py)
  MapPoint(x: x, y: y)

proc taskCenter(task: TaskStation): MapPoint =
  ## Returns the center point of one task station.
  MapPoint(
    x: task.x + task.w div 2,
    y: task.y + task.h div 2
  )

proc astarDistance(
  sim: SimServer,
  start, goal: MapPoint
): int =
  ## Returns the shortest walkable A* distance between two map points.
  if start.x == goal.x and start.y == goal.y:
    return 0

  var
    open: HeapQueue[SearchNode]
    costs = newSeq[int](MapWidth * MapHeight)
    closed = newSeq[bool](MapWidth * MapHeight)

  for i in 0 ..< costs.len:
    costs[i] = NoDistance

  let
    startIndex = mapIndex(start.x, start.y)
    goalIndex = mapIndex(goal.x, goal.y)
    startScore = distanceHeuristic(start.x, start.y, goal.x, goal.y)

  costs[startIndex] = 0
  open.push SearchNode(
    index: startIndex,
    cost: 0,
    score: startScore
  )

  const
    OffsetX = [0, 0, -1, 1]
    OffsetY = [-1, 1, 0, 0]

  while open.len > 0:
    let current = open.pop()
    if closed[current.index]:
      continue
    closed[current.index] = true
    if current.index == goalIndex:
      return current.cost

    let
      x = current.index mod MapWidth
      y = current.index div MapWidth
    for i in 0 ..< OffsetX.len:
      let
        nx = x + OffsetX[i]
        ny = y + OffsetY[i]
      if not sim.isWalkable(nx, ny):
        continue
      let
        nextIndex = mapIndex(nx, ny)
        nextCost = current.cost + 1
      if closed[nextIndex] or nextCost >= costs[nextIndex]:
        continue
      costs[nextIndex] = nextCost
      open.push SearchNode(
        index: nextIndex,
        cost: nextCost,
        score: nextCost + distanceHeuristic(nx, ny, goal.x, goal.y)
      )

  NoDistance

proc taskInfos(sim: SimServer): seq[TaskInfo] =
  ## Computes spawn-to-task A* distances for all task stations.
  let start = sim.nearestWalkablePoint(
    sim.gameMap.home.x,
    sim.gameMap.home.y
  )
  for i, task in sim.tasks:
    let
      center = task.taskCenter()
      target = sim.nearestWalkablePoint(center.x, center.y)
      distance = sim.astarDistance(start, target)
    result.add TaskInfo(
      id: i,
      task: task,
      target: target,
      distance: distance
    )
  result.sort(
    proc(a, b: TaskInfo): int =
      result = cmp(a.distance, b.distance)
      if result == 0:
        result = cmp(a.id, b.id)
  )

proc hasTask(assignment: Assignment, taskId: int): bool =
  ## Returns true when an assignment already contains one task.
  for task in assignment.tasks:
    if task.id == taskId:
      return true

proc trimBand(
  band: var seq[TaskInfo],
  crewCount: int,
  rng: var Rand
) =
  ## Randomly removes task entries until the band fits one crew round.
  while band.len > crewCount:
    band.delete(rng.rand(band.high))

proc fillBand(
  band: var seq[TaskInfo],
  source: openArray[TaskInfo],
  crewCount: int,
  rng: var Rand
) =
  ## Randomly duplicates task entries until the band fits one crew round.
  doAssert source.len > 0
  while band.len < crewCount:
    band.add source[rng.rand(source.high)]

proc pickCrew(
  assignments: openArray[Assignment],
  used: openArray[bool],
  task: TaskInfo,
  rng: var Rand
): int =
  ## Picks the lowest-total unused crew, avoiding duplicate tasks if possible.
  var
    best = -1
    bestScore = NoDistance
  for i in 0 ..< assignments.len:
    if used[i]:
      continue
    var score = assignments[i].total
    if assignments[i].hasTask(task.id):
      score += NoDistance div 2
    if score < bestScore or (score == bestScore and rng.rand(1) == 0):
      best = i
      bestScore = score
  doAssert best >= 0
  best

proc assignFairly(
  tasks: openArray[TaskInfo],
  crewCount, tasksPerCrew: int,
  rng: var Rand
): seq[Assignment] =
  ## Assigns sorted tasks so every crew has a similar total spawn distance.
  doAssert crewCount > 0
  doAssert tasksPerCrew >= 0
  doAssert tasks.len > 0

  result = newSeq[Assignment](crewCount)
  var cursor = 0
  for round in 0 ..< tasksPerCrew:
    var band: seq[TaskInfo]
    while cursor < tasks.len and band.len < crewCount:
      band.add tasks[cursor]
      inc cursor

    let source =
      if band.len > 0:
        band
      else:
        @tasks
    band.trimBand(crewCount, rng)
    band.fillBand(source, crewCount, rng)
    band.sort(
      proc(a, b: TaskInfo): int =
        result = cmp(b.distance, a.distance)
        if result == 0:
          result = cmp(a.id, b.id)
    )

    var used = newSeq[bool](crewCount)
    for task in band:
      let crew = result.pickCrew(used, task, rng)
      used[crew] = true
      result[crew].tasks.add task
      result[crew].total += task.distance

proc assignmentSpread(assignments: openArray[Assignment]): int =
  ## Returns the difference between the highest and lowest crew totals.
  var
    minTotal = NoDistance
    maxTotal = 0
  for assignment in assignments:
    minTotal = min(minTotal, assignment.total)
    maxTotal = max(maxTotal, assignment.total)
  maxTotal - minTotal

proc canReceive(
  assignment: Assignment,
  incomingId, outgoingIndex: int
): bool =
  ## Returns true when a swap would not duplicate a task for one crew.
  for i, task in assignment.tasks:
    if i != outgoingIndex and task.id == incomingId:
      return false
  true

proc spreadAfterSwap(
  assignments: openArray[Assignment],
  crewA, taskA, crewB, taskB: int
): int =
  ## Returns the crew-total spread after one hypothetical task swap.
  var
    minTotal = NoDistance
    maxTotal = 0
  for i, assignment in assignments:
    var total = assignment.total
    if i == crewA:
      total =
        total -
        assignment.tasks[taskA].distance +
        assignments[crewB].tasks[taskB].distance
    elif i == crewB:
      total =
        total -
        assignment.tasks[taskB].distance +
        assignments[crewA].tasks[taskA].distance
    minTotal = min(minTotal, total)
    maxTotal = max(maxTotal, total)
  maxTotal - minTotal

proc improveAssignments(assignments: var seq[Assignment]): int =
  ## Swaps assigned tasks while the total-distance spread improves.
  var improved = true
  while improved:
    improved = false
    var
      bestSpread = assignments.assignmentSpread()
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
            let spread = assignments.spreadAfterSwap(
              crewA,
              taskA,
              crewB,
              taskB
            )
            if spread < bestSpread:
              bestSpread = spread
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
      assignments[bestCrewA].total =
        assignments[bestCrewA].total - infoA.distance + infoB.distance
      assignments[bestCrewB].total =
        assignments[bestCrewB].total - infoB.distance + infoA.distance
      inc result
      improved = true

proc roomName(task: TaskInfo): string =
  ## Returns a compact room-ish name for one task.
  task.task.name.replace("Task near ", "")

proc taskLabel(task: TaskInfo): string =
  ## Returns a compact display label for one assigned task.
  fmt"{task.id}:{task.distance}:{task.roomName()}"

proc printTaskTable(tasks: openArray[TaskInfo]) =
  ## Prints all tasks sorted by spawn distance.
  echo "Tasks sorted by A* distance from spawn button"
  echo "id   dist   target      room"
  echo "--   ----   ----------  ----------------"
  for task in tasks:
    echo align($task.id, 2), "   ",
      align($task.distance, 4), "   ",
      align("(" & $task.target.x & "," & $task.target.y & ")", 10), "  ",
      task.roomName()

proc printAssignmentTable(
  assignments: openArray[Assignment],
  swaps: int
) =
  ## Prints one row per crew assignment.
  var
    minTotal = NoDistance
    maxTotal = 0
    total = 0
  echo ""
  echo "Fair assignment"
  echo "crew  total  avg    task ids, distances, and rooms"
  echo "----  -----  -----  -----------------------------"
  for i, assignment in assignments:
    minTotal = min(minTotal, assignment.total)
    maxTotal = max(maxTotal, assignment.total)
    total += assignment.total
    var labels: seq[string]
    for task in assignment.tasks:
      labels.add task.taskLabel()
    let avg =
      if assignment.tasks.len > 0:
        assignment.total.float / assignment.tasks.len.float
      else:
        0.0
    echo align($i, 4), "  ",
      align($assignment.total, 5), "  ",
      align(formatFloat(avg, ffDecimal, 1), 5), "  ",
      labels.join(", ")

  let avgTotal =
    if assignments.len > 0:
      total.float / assignments.len.float
    else:
      0.0
  echo ""
  echo "Summary"
  echo "crew: ", assignments.len
  echo "tasks per crew: ", TasksPerCrew
  echo "improvement swaps: ", swaps
  echo "min total: ", minTotal
  echo "max total: ", maxTotal
  echo "spread: ", maxTotal - minTotal
  echo "average total: ", formatFloat(avgTotal, ffDecimal, 1)

let
  game = initCrewriftForTry()
  start = game.nearestWalkablePoint(
    game.gameMap.home.x,
    game.gameMap.home.y
  )

var
  rng = initRand(TrySeed)
  tasks = game.taskInfos()
  assignments = tasks.assignFairly(CrewCount, TasksPerCrew, rng)
  swaps = assignments.improveAssignments()

echo "Crewrift task assignment try"
echo "seed: ", TrySeed
echo "spawn button: (", game.gameMap.home.x, ",", game.gameMap.home.y, ")"
echo "walkable start: (", start.x, ",", start.y, ")"
echo "tasks: ", tasks.len
echo "crew: ", CrewCount
echo "tasks per crew: ", TasksPerCrew
echo ""
tasks.printTaskTable()
assignments.printAssignmentTable(swaps)
