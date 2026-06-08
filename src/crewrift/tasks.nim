import
  std/[algorithm, random]

const
  NoDistance = high(int) div 4
  SpawnNode = 0
  MaxImprovementSwaps = 64

type
  TaskRect* = object
    x*, y*, w*, h*: int

  TaskAssignment* = object
    taskIds*: seq[int]
    routeCost*: int

  TaskPoint = object
    x, y: int

  TaskInfo = object
    id: int
    node: int
    target: TaskPoint
    distance: int

  DistanceMatrix = object
    size: int
    distances: seq[int]

  Assignment = object
    tasks: seq[TaskInfo]
    routeCost: int

  AssignmentScore = object
    duplicates: int
    spread: int
    maxCost: int
    totalCost: int

proc clamp(value, low, high: int): int =
  ## Returns one value clamped to an inclusive integer range.
  min(max(value, low), high)

proc mapIndex(width, x, y: int): int {.inline.} =
  ## Returns the flat walk-mask index for one map point.
  y * width + x

proc isInside(width, height, x, y: int): bool {.inline.} =
  ## Returns true when one map point is inside the map bounds.
  x >= 0 and y >= 0 and x < width and y < height

proc isWalkable(
  walkMask: openArray[bool],
  width, height, x, y: int
): bool =
  ## Returns true when one map point is inside bounds and walkable.
  if not isInside(width, height, x, y):
    return false
  walkMask[mapIndex(width, x, y)]

proc nearestWalkablePoint(
  walkMask: openArray[bool],
  width, height, x, y: int
): TaskPoint =
  ## Returns the nearest walkable point to one map coordinate.
  if walkMask.isWalkable(width, height, x, y):
    return TaskPoint(x: x, y: y)

  for radius in 1 .. max(width, height):
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        if abs(dx) != radius and abs(dy) != radius:
          continue
        let
          px = x + dx
          py = y + dy
        if walkMask.isWalkable(width, height, px, py):
          return TaskPoint(x: px, y: py)

  TaskPoint(
    x: clamp(x, 0, width - 1),
    y: clamp(y, 0, height - 1)
  )

proc taskCenter(task: TaskRect): TaskPoint =
  ## Returns the center point of one task rectangle.
  TaskPoint(
    x: task.x + task.w div 2,
    y: task.y + task.h div 2
  )

proc targetIndexMap(
  points: openArray[TaskPoint],
  width, height: int
): tuple[index: seq[int], count: int] =
  ## Returns target map indices used to stop shortest-path search early.
  result.index = newSeq[int](width * height)
  for i in 0 ..< result.index.len:
    result.index[i] = -1
  for i, point in points:
    if not isInside(width, height, point.x, point.y):
      continue
    let index = mapIndex(width, point.x, point.y)
    if result.index[index] == -1:
      result.index[index] = i
      inc result.count

proc pointDistances(
  walkMask: openArray[bool],
  width, height: int,
  start: TaskPoint,
  points: openArray[TaskPoint],
  targets: openArray[int],
  targetCount: int,
  costs, seen, queue: var seq[int],
  stamp: int
): seq[int] =
  ## Returns exact grid distances from one point to target points.
  var
    head = 0
    tail = 0
    found = 0

  if not isInside(width, height, start.x, start.y):
    result = newSeq[int](points.len)
    for distance in result.mitems:
      distance = NoDistance
    return

  let startIndex = mapIndex(width, start.x, start.y)
  costs[startIndex] = 0
  seen[startIndex] = stamp
  queue[tail] = startIndex
  inc tail

  template addNeighbor(index: int, nextCost: int) =
    if seen[index] != stamp and walkMask[index]:
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
      x = current mod width
      y = current div width
      nextCost = costs[current] + 1
    if y > 0:
      addNeighbor(current - width, nextCost)
    if y + 1 < height:
      addNeighbor(current + width, nextCost)
    if x > 0:
      addNeighbor(current - 1, nextCost)
    if x + 1 < width:
      addNeighbor(current + 1, nextCost)

  result = newSeq[int](points.len)
  for i, point in points:
    if not isInside(width, height, point.x, point.y):
      result[i] = NoDistance
      continue
    let index = mapIndex(width, point.x, point.y)
    result[i] =
      if seen[index] == stamp:
        costs[index]
      else:
        NoDistance

proc distanceIndex(matrix: DistanceMatrix, a, b: int): int =
  ## Returns the flat matrix index for two node ids.
  a * matrix.size + b

proc distance(matrix: DistanceMatrix, a, b: int): int =
  ## Returns the cached route distance between two node ids.
  matrix.distances[matrix.distanceIndex(a, b)]

proc taskInfos(
  tasks: openArray[TaskRect],
  walkMask: openArray[bool],
  width, height: int
): seq[TaskInfo] =
  ## Builds task records with walkable target points.
  for i, task in tasks:
    let
      center = task.taskCenter()
      target = walkMask.nearestWalkablePoint(
        width,
        height,
        center.x,
        center.y
      )
    result.add TaskInfo(
      id: i,
      node: i + 1,
      target: target,
      distance: NoDistance
    )

proc buildDistanceMatrix(
  tasks: openArray[TaskInfo],
  walkMask: openArray[bool],
  width, height: int,
  start: TaskPoint
): DistanceMatrix =
  ## Computes exact spawn distances and approximate task-pair distances.
  result.size = tasks.len + 1
  result.distances = newSeq[int](result.size * result.size)

  var points = @[start]
  for task in tasks:
    points.add task.target

  let targets = targetIndexMap(points, width, height)
  var
    costs = newSeq[int](width * height)
    seen = newSeq[int](width * height)
    queue = newSeq[int](width * height)
  let spawnDistances = pointDistances(
    walkMask,
    width,
    height,
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
  ## Copies spawn distances into tasks and sorts farthest tasks first.
  for task in tasks.mitems:
    task.distance = matrix.distance(SpawnNode, task.node)
  tasks.sort(
    proc(a, b: TaskInfo): int =
      result = cmp(b.distance, a.distance)
      if result == 0:
        result = cmp(a.id, b.id)
  )

proc routeCost(
  matrix: DistanceMatrix,
  tasks: openArray[TaskInfo]
): int =
  ## Returns the approximate greedy route cost for one task list.
  if tasks.len == 0:
    return 0

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
    result += bestDistance
    currentNode = tasks[best].node

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
  ## Builds a task pool by removing or duplicating tasks to fit demand.
  doAssert tasks.len > 0
  result = @tasks
  while result.len > needed:
    result.delete(rng.rand(result.high))
  while result.len < needed:
    result.add tasks[rng.rand(tasks.high)]

proc routeCostWithTask(
  assignment: Assignment,
  matrix: DistanceMatrix,
  task: TaskInfo
): int =
  ## Returns route cost after adding one task to one assignment.
  var tasks = assignment.tasks
  tasks.add task
  matrix.routeCost(tasks)

proc pickCrew(
  assignments: openArray[Assignment],
  matrix: DistanceMatrix,
  task: TaskInfo,
  tasksPerCrew: int,
  rng: var Rand,
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
    let score = assignment.routeCostWithTask(matrix, task)
    if score < bestScore or (score == bestScore and rng.rand(1) == 0):
      result = i
      bestScore = score

proc assignGreedyRoutes(
  tasks: openArray[TaskInfo],
  matrix: DistanceMatrix,
  crewCount, tasksPerCrew: int,
  rng: var Rand
): seq[Assignment] =
  ## Assigns far tasks first by current shortest full-route cost.
  result = newSeq[Assignment](crewCount)
  var pool = tasks.makeTaskPool(crewCount * tasksPerCrew, rng)
  pool.sort(
    proc(a, b: TaskInfo): int =
      result = cmp(b.distance, a.distance)
      if result == 0:
        result = cmp(a.id, b.id)
  )

  while pool.len > 0:
    var
      poolIndex = -1
      crew = -1
    for i, task in pool:
      crew = result.pickCrew(matrix, task, tasksPerCrew, rng)
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
        allowDuplicate = true
      )
    doAssert crew >= 0
    let task = pool[poolIndex]
    result[crew].tasks.add task
    result[crew].routeCost = matrix.routeCost(result[crew].tasks)
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
  crewA, taskA, crewB, taskB: int
): AssignmentScore =
  ## Scores route fairness after one hypothetical task swap.
  var minCost = NoDistance
  for i, assignment in assignments:
    var
      tasks = assignment.tasks
      cost = assignment.routeCost
    if i == crewA:
      tasks[taskA] = assignments[crewB].tasks[taskB]
      cost = matrix.routeCost(tasks)
    elif i == crewB:
      tasks[taskB] = assignments[crewA].tasks[taskA]
      cost = matrix.routeCost(tasks)
    result.duplicates += tasks.duplicateCount()
    minCost = min(minCost, cost)
    result.maxCost = max(result.maxCost, cost)
    result.totalCost += cost
  result.spread = result.maxCost - minCost

proc improveAssignments(
  assignments: var seq[Assignment],
  matrix: DistanceMatrix
) =
  ## Swaps tasks while the full-route fairness score improves.
  var
    improved = true
    swapCount = 0
  while improved and swapCount < MaxImprovementSwaps:
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
              taskB
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
        matrix.routeCost(assignments[bestCrewA].tasks)
      assignments[bestCrewB].routeCost =
        matrix.routeCost(assignments[bestCrewB].tasks)
      improved = true
      inc swapCount

proc assignmentIds(assignment: Assignment): seq[int] =
  ## Returns task ids assigned to one crew member.
  for task in assignment.tasks:
    result.add task.id

proc taskAssignment(assignment: Assignment): TaskAssignment =
  ## Returns exported assignment details for one crew member.
  TaskAssignment(
    taskIds: assignment.assignmentIds(),
    routeCost: assignment.routeCost
  )

proc assignTaskDetails*(
  tasks: openArray[TaskRect],
  walkMask: openArray[bool],
  width, height: int,
  homeX, homeY: int,
  crewCount, tasksPerCrew: int,
  rng: var Rand
): seq[TaskAssignment] =
  ## Assigns balanced task details to crewmates using loaded map data.
  doAssert width > 0
  doAssert height > 0
  doAssert walkMask.len >= width * height
  doAssert crewCount >= 0
  doAssert tasksPerCrew >= 0

  result = newSeq[TaskAssignment](crewCount)
  if crewCount == 0 or tasksPerCrew == 0 or tasks.len == 0:
    return

  let start = walkMask.nearestWalkablePoint(width, height, homeX, homeY)
  var infos = taskInfos(tasks, walkMask, width, height)
  let matrix = buildDistanceMatrix(infos, walkMask, width, height, start)
  infos.applySpawnDistances(matrix)

  var assignments = assignGreedyRoutes(
    infos,
    matrix,
    crewCount,
    tasksPerCrew,
    rng
  )
  assignments.improveAssignments(matrix)
  for i, assignment in assignments:
    result[i] = assignment.taskAssignment()

proc assignTasks*(
  tasks: openArray[TaskRect],
  walkMask: openArray[bool],
  width, height: int,
  homeX, homeY: int,
  crewCount, tasksPerCrew: int,
  rng: var Rand
): seq[seq[int]] =
  ## Assigns balanced task ids to crewmates using loaded map data.
  let assignments = assignTaskDetails(
    tasks,
    walkMask,
    width,
    height,
    homeX,
    homeY,
    crewCount,
    tasksPerCrew,
    rng
  )
  for assignment in assignments:
    result.add assignment.taskIds
