import
  std/[os, strutils],
  ../src/crewrift/replays,
  ../src/crewrift/sim

type
  ExpandReplayError = object of CatchableError

const
  UsageText = "Usage: nim r tools/expand_replay.nim [replay-path]"
  GameDir = currentSourcePath().parentDir().parentDir()
  DefaultReplayPath = GameDir / "tests" / "replays" / "notsus.bitreplay"

proc fail(message: string) =
  ## Raises one replay expansion failure.
  raise newException(ExpandReplayError, message)

proc replayPathFromArgs(): string =
  ## Returns the replay path passed on the command line.
  var paths: seq[string]
  for arg in commandLineParams():
    if arg == "--":
      discard
    elif arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
  if paths.len > 1:
    fail("Expected at most one replay path.\n" & UsageText)
  if paths.len == 0:
    return DefaultReplayPath
  paths[0].absolutePath()

proc replayConfig(data: ReplayData): GameConfig =
  ## Returns the game config embedded in a replay.
  result = defaultGameConfig()
  result.update(data.configJson)

proc player(sim: SimServer, i: int): string =
  ## Returns color and username for one player.
  let p = sim.players[i]
  playerColorText(p.color) & "(" & p.address & ")"

proc playerForSlot(sim: SimServer, slotId: int): int =
  ## Returns the player index for one join slot.
  for i, player in sim.players:
    if player.joinOrder == slotId:
      return i
  -1

proc bodyPlayer(sim: SimServer, body: Body): string =
  ## Returns color and username for one body.
  let i = sim.playerForSlot(body.slotId)
  if i >= 0:
    return sim.player(i)
  playerColorText(body.color) & "(unknown)"

proc vote(sim: SimServer, i: int): string =
  ## Returns a readable vote target.
  if i == -2 or i == sim.players.len:
    return "skip"
  sim.player(i)

proc roomAt(sim: SimServer, x, y: int): int =
  ## Returns the room containing one point.
  for roomIndex, room in sim.rooms:
    if x >= room.x and x < room.x + room.w and
      y >= room.y and y < room.y + room.h:
      return roomIndex
  -1

proc roomAt(sim: SimServer, i: int): int =
  ## Returns the room containing one player.
  sim.roomAt(sim.players[i].x, sim.players[i].y)

proc roomName(sim: SimServer, i: int): string =
  ## Returns the room name for one room index.
  sim.rooms[i].name

proc roomNameAt(sim: SimServer, x, y: int): string =
  ## Returns the nearest room name for one point.
  let room = sim.roomAt(x, y)
  if room >= 0:
    return sim.roomName(room)
  var
    bestRoom = 0
    bestDistance = high(int)
  for i, room in sim.rooms:
    let
      cx = room.x + room.w div 2
      cy = room.y + room.h div 2
      distance = distSq(x, y, cx, cy)
    if distance < bestDistance:
      bestDistance = distance
      bestRoom = i
  sim.roomName(bestRoom)

proc bodyKey(body: Body): string =
  ## Returns a stable key for one body instance.
  $body.slotId & ":" & $body.x & ":" & $body.y

proc hasKey(keys: openArray[string], key: string): bool =
  ## Returns true when a key is already present.
  for item in keys:
    if item == key:
      return true
  false

proc syncPlayers(
  sim: SimServer,
  alive: var seq[bool],
  tasks: var seq[int],
  votes: var seq[int],
  rooms: var seq[int],
  rewards: var seq[int],
  killCooldowns: var seq[int],
  buttonCalls: var seq[int]
) =
  ## Adds tracking state for newly joined players.
  while alive.len < sim.players.len:
    let i = alive.len
    alive.add(sim.players[i].alive)
    tasks.add(sim.players[i].activeTask)
    votes.add(if i < sim.voteState.votes.len: sim.voteState.votes[i] else: -1)
    rooms.add(sim.roomAt(i))
    rewards.add(sim.players[i].reward)
    killCooldowns.add(sim.players[i].killCooldown)
    buttonCalls.add(sim.players[i].buttonCallsUsed)
    echo "  player ", sim.player(i), " joined"
    if rooms[i] >= 0:
      echo "  player ", sim.player(i), " entered room ",
        sim.roomName(rooms[i])

proc killerThisTick(sim: SimServer, killCooldowns: openArray[int]): int =
  ## Returns the imposter whose kill cooldown just reset.
  for i, player in sim.players:
    if i < killCooldowns.len and player.role == Imposter and
      killCooldowns[i] <= 0 and player.killCooldown > 0:
      return i
  -1

proc printNewBodies(
  sim: SimServer,
  printed: var seq[string],
  killCooldowns: openArray[int]
): seq[int] =
  ## Prints new bodies once.
  for body in sim.bodies:
    let key = body.bodyKey()
    if printed.hasKey(key):
      continue
    let
      victim = sim.playerForSlot(body.slotId)
      killer = sim.killerThisTick(killCooldowns)
    if killer >= 0 and victim >= 0:
      echo "  player ", sim.player(killer), " killed ", sim.player(victim)
    echo "  body ", sim.bodyPlayer(body), " room ",
      sim.roomNameAt(body.x, body.y)
    printed.add(key)
    if victim >= 0:
      result.add(victim)

proc buttonUsedThisTick(
  sim: SimServer,
  buttonCalls: openArray[int]
): bool =
  ## Returns true when a button call was used this tick.
  for i, player in sim.players:
    if i < buttonCalls.len and player.buttonCallsUsed > buttonCalls[i]:
      return true

proc reporterForBody(sim: SimServer, body: Body): int =
  ## Returns the living player close enough to report one body.
  let
    bx = body.x + CollisionW div 2
    by = body.y + CollisionH div 2
    rangeSq = sim.config.reportRange * sim.config.reportRange
  for i, player in sim.players:
    if not player.alive:
      continue
    let
      px = player.x + CollisionW div 2
      py = player.y + CollisionH div 2
    if distSq(px, py, bx, by) <= rangeSq:
      return i
  -1

proc printBodyReports(sim: SimServer) =
  ## Prints bodies reported by nearby living players.
  for body in sim.bodies:
    let reporter = sim.reporterForBody(body)
    if reporter >= 0:
      echo "  player ", sim.player(reporter), " reported body ",
        sim.bodyPlayer(body), " room ", sim.roomNameAt(body.x, body.y)

proc updatePlayerCounters(
  sim: SimServer,
  killCooldowns: var seq[int],
  buttonCalls: var seq[int]
) =
  ## Copies player counters after a tick is printed.
  for i, player in sim.players:
    while killCooldowns.len <= i:
      killCooldowns.add(player.killCooldown)
    while buttonCalls.len <= i:
      buttonCalls.add(player.buttonCallsUsed)
    killCooldowns[i] = player.killCooldown
    buttonCalls[i] = player.buttonCallsUsed

proc printPlayerChanges(
  sim: SimServer,
  alive: var seq[bool],
  tasks: var seq[int],
  rooms: var seq[int],
  bodyVictims: openArray[int]
) =
  ## Prints player death, task, and room changes.
  for i, p in sim.players:
    if alive[i] and not p.alive and i notin bodyVictims:
      echo "  player ", sim.player(i), " died"
    elif not alive[i] and p.alive:
      echo "  player ", sim.player(i), " revived"
    alive[i] = p.alive

    if tasks[i] != p.activeTask:
      if p.activeTask >= 0:
        echo "  player ", sim.player(i), " started task ", p.activeTask
      tasks[i] = p.activeTask

    let room = sim.roomAt(i)
    if rooms[i] != room:
      if rooms[i] >= 0:
        echo "  player ", sim.player(i), " left room ",
          sim.roomName(rooms[i])
      if room >= 0:
        echo "  player ", sim.player(i), " entered room ",
          sim.roomName(room)
      rooms[i] = room

proc printTaskCompletions(
  sim: SimServer,
  done: var seq[seq[bool]]
) =
  ## Prints task completions since the previous tick.
  for taskIndex, task in sim.tasks:
    while done[taskIndex].len < task.completed.len:
      done[taskIndex].add(false)
    for playerIndex, completed in task.completed:
      if not done[taskIndex][playerIndex] and completed:
        var text = "  player " & sim.player(playerIndex) &
          " completed task " & $taskIndex
        if not sim.players[playerIndex].alive:
          text.add(" while dead")
        echo text
      done[taskIndex][playerIndex] = completed

proc printVotes(sim: SimServer, votes: var seq[int]) =
  ## Prints votes cast since the previous tick.
  for i, v in sim.voteState.votes:
    while votes.len <= i:
      votes.add(-1)
    if votes[i] != v:
      if v >= 0 or v == -2:
        echo "  player ", sim.player(i), " voted ", sim.vote(v)
      votes[i] = v

proc printChats(sim: SimServer, chatCount: var int) =
  ## Prints visible voting chat since the previous tick.
  if sim.chatMessages.len < chatCount:
    chatCount = 0
  for i in chatCount ..< sim.chatMessages.len:
    let chat = sim.chatMessages[i]
    for playerIndex, p in sim.players:
      if p.joinOrder == chat.slotId:
        echo "  player ", sim.player(playerIndex), " said ", repr(chat.text)
  chatCount = sim.chatMessages.len

proc scoreAmount(amount: int): string =
  ## Returns a readable score amount.
  if amount > 0:
    "+" & $amount
  else:
    $amount

proc printScoreLine(
  sim: SimServer,
  playerIndex,
  amount: int,
  reason: string
) =
  ## Prints one score change line.
  echo "  score player ", sim.player(playerIndex), " ",
    scoreAmount(amount), " (for ", reason, ")"

proc printPositiveScore(sim: SimServer, playerIndex, amount: int): int =
  ## Prints non-win score changes and returns the win count.
  var remaining = amount
  result = remaining div WinReward
  remaining = remaining mod WinReward
  while remaining >= KillReward:
    sim.printScoreLine(playerIndex, KillReward, "killing")
    remaining -= KillReward
  while remaining >= TaskReward:
    sim.printScoreLine(playerIndex, TaskReward, "completing task")
    remaining -= TaskReward

proc printNegativeScore(sim: SimServer, playerIndex, amount: int) =
  ## Prints negative score changes as known penalty parts.
  var remaining = amount
  while remaining <= VoteTimeoutPenalty:
    sim.printScoreLine(
      playerIndex,
      VoteTimeoutPenalty,
      "failing to vote or skip"
    )
    remaining -= VoteTimeoutPenalty
  while remaining <= StuckPenalty:
    sim.printScoreLine(playerIndex, StuckPenalty, "standing still")
    remaining -= StuckPenalty

proc printScoreChanges(sim: SimServer, rewards: var seq[int]) =
  ## Prints player score changes since the previous tick.
  var wins = newSeq[int](sim.players.len)
  for i, player in sim.players:
    while rewards.len <= i:
      rewards.add(player.reward)
    let amount = player.reward - rewards[i]
    if amount != 0:
      if amount > 0:
        wins[i] = sim.printPositiveScore(i, amount)
      else:
        sim.printNegativeScore(i, amount)
      rewards[i] = player.reward
  for i, count in wins:
    for _ in 0 ..< count:
      sim.printScoreLine(i, WinReward, "winning")

proc expandReplay(path: string) =
  ## Prints one readable replay timeline.
  if not fileExists(path):
    fail("Replay file does not exist: " & path)

  setCurrentDir(GameDir)

  let data = loadReplay(path)
  var
    sim = initSimServer(data.replayConfig())
    replay = initReplayPlayer(data)
    alive: seq[bool]
    tasks: seq[int]
    votes: seq[int]
    rooms: seq[int]
    rewards: seq[int]
    killCooldowns: seq[int]
    buttonCalls: seq[int]
    printedBodies: seq[string]
    done: seq[seq[bool]]
    chatCount = 0
    phase = sim.phase

  sim.gameEventLoggingEnabled = false
  for task in sim.tasks:
    done.add(task.completed)
  replay.looping = false
  replay.mismatchQuit = true

  echo "replay ", path
  while replay.playing:
    echo "tick ", sim.tickCount + 1
    try:
      replay.stepReplay(sim)
    except ReplayError:
      echo "  hash failed"
      fail("hash failed")

    if phase != sim.phase:
      echo "  phase ", $sim.phase
      if sim.phase == Voting and not sim.buttonUsedThisTick(buttonCalls):
        sim.printBodyReports()
      phase = sim.phase

    sim.syncPlayers(
      alive,
      tasks,
      votes,
      rooms,
      rewards,
      killCooldowns,
      buttonCalls
    )
    let bodyVictims = sim.printNewBodies(printedBodies, killCooldowns)
    for victim in bodyVictims:
      if victim < alive.len:
        alive[victim] = sim.players[victim].alive
    sim.printPlayerChanges(alive, tasks, rooms, bodyVictims)
    sim.printTaskCompletions(done)
    sim.printVotes(votes)
    sim.printChats(chatCount)
    sim.printScoreChanges(rewards)
    sim.updatePlayerCounters(killCooldowns, buttonCalls)

  echo "done"

when isMainModule:
  try:
    expandReplay(replayPathFromArgs())
  except ExpandReplayError as e:
    if e.msg != "hash failed":
      stderr.writeLine("expand_replay failed: " & e.msg)
    quit(1)
  except ReplayError as e:
    stderr.writeLine("expand_replay replay error: " & e.msg)
    quit(1)
  except CrewriftError as e:
    stderr.writeLine("expand_replay sim error: " & e.msg)
    quit(1)
