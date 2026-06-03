import
  std/[monotimes, net, os, osproc, strutils, times],
  bitworld/spriteprotocol,
  crewrift/replays,
  whisky

type
  ManualReplayError = object of CatchableError

  SavedEnv = object
    key: string
    value: string
    present: bool

  ManualReplayConfig = object
    runCount: int
    speed: int

const
  BotCount = 8
  DefaultSpeed = 1
  DefaultStartPort = 18080
  MaxManualSeed = 1_000_000_000
  PollMs = 100
  ReadyTimeoutMs = 10_000
  RecordTimeoutMs = 15 * 60 * 1000
  ReplayTimeoutMs = 5 * 60 * 1000
  BotUrlEnv = "COWORLD_PLAYER_WS_URL"
  LoadReplayEnv = "COGAME_LOAD_REPLAY_URI"

proc fail(message: string) {.raises: [ManualReplayError].} =
  ## Raises one manual replay test failure.
  raise newException(ManualReplayError, message)

proc requireOk(
  condition: bool,
  message: string
) =
  ## Raises when a required test condition is false.
  if not condition:
    fail(message)

proc repoDir(): string =
  ## Returns the Crewrift repository directory.
  currentSourcePath().parentDir().parentDir()

proc workspaceDir(): string =
  ## Returns the parent workspace directory.
  repoDir().parentDir()

proc bitworldDir(): string =
  ## Returns the sibling Bitworld repository directory.
  workspaceDir() / "bitworld"

proc nimExe(): string =
  ## Returns the Nim executable path.
  result = findExe("nim")
  if result.len == 0:
    fail("Could not find nim in PATH.")

proc usage(): string =
  ## Returns the command usage text.
  "Usage: nim r tests/manual_replay.nim <count> [--speed:1x|2x|3x|4x|8x|16x]"

proc parseRunCount(value: string): int =
  ## Parses one required manual replay run count.
  try:
    result = value.parseInt()
  except ValueError:
    fail("Run count must be a number.\n" & usage())
  if result <= 0:
    fail("Run count must be greater than 0.\n" & usage())

proc parseSpeed(value: string): int =
  ## Parses one live game speed multiplier.
  var text = value.strip().toLowerAscii()
  if text.endsWith("x"):
    text.setLen(text.len - 1)
  if text.len == 0:
    fail("Speed must be 1x, 2x, 3x, 4x, 8x, or 16x.\n" & usage())
  try:
    result = text.parseInt()
  except ValueError:
    fail("Speed must be 1x, 2x, 3x, 4x, 8x, or 16x.\n" & usage())
  if result notin [1, 2, 3, 4, 8, 16]:
    fail("Speed must be 1x, 2x, 3x, 4x, 8x, or 16x.\n" & usage())

proc parseManualReplayConfig(): ManualReplayConfig =
  ## Parses the manual replay command-line config.
  var
    args = commandLineParams()
    positionals: seq[string]
    i = 0
  result.speed = DefaultSpeed

  while i < args.len:
    let arg = args[i]
    if arg == "--speed":
      inc i
      if i >= args.len:
        fail("Option --speed requires a value.\n" & usage())
      result.speed = args[i].parseSpeed()
    elif arg.startsWith("--speed:"):
      result.speed = arg["--speed:".len .. ^1].parseSpeed()
    elif arg.startsWith("--speed="):
      result.speed = arg["--speed=".len .. ^1].parseSpeed()
    elif arg.startsWith("--"):
      fail("Unknown option " & arg & ".\n" & usage())
    else:
      positionals.add(arg)
    inc i

  if positionals.len != 1:
    fail(usage())
  result.runCount = positionals[0].parseRunCount()

proc normalizeSeed(seed: int): int =
  ## Returns a positive bounded game seed.
  result = seed mod MaxManualSeed
  if result <= 0:
    result += MaxManualSeed

proc firstSeed(): int =
  ## Returns the first seed for this manual test batch.
  normalizeSeed(
    int(getTime().toUnix() mod MaxManualSeed) + getCurrentProcessId()
  )

proc seedForRun(
  seed: int,
  runIndex: int
): int =
  ## Returns the seed for one manual replay run.
  normalizeSeed(seed + runIndex)

proc stopProcess(
  process: var Process,
  label: string
) {.raises: [].} =
  ## Stops one child process if it is still running.
  if process.isNil:
    return
  try:
    if process.peekExitCode() == -1:
      echo "Stopping ", label, "."
      process.terminate()
      for _ in 0 ..< 20:
        if process.peekExitCode() != -1:
          break
        sleep(PollMs)
      if process.peekExitCode() == -1:
        process.kill()
  except CatchableError:
    discard
  try:
    process.close()
  except CatchableError:
    discard
  process = nil

proc saveEnv(keys: openArray[string]): seq[SavedEnv] =
  ## Saves the current values for a set of environment variables.
  for key in keys:
    result.add SavedEnv(
      key: key,
      value: getEnv(key),
      present: existsEnv(key)
    )

proc clearEnv(keys: openArray[string]) =
  ## Clears a set of environment variables for child process isolation.
  for key in keys:
    delEnv(key)

proc restoreEnv(saved: openArray[SavedEnv]) =
  ## Restores environment variables saved by saveEnv.
  for item in saved:
    if item.present:
      putEnv(item.key, item.value)
    else:
      delEnv(item.key)

proc waitForExit(
  process: Process,
  label: string,
  timeoutMs: int
): int =
  ## Waits for one child process to finish within a timeout.
  let startedAt = getMonoTime()
  while (getMonoTime() - startedAt).inMilliseconds < timeoutMs:
    result = process.peekExitCode()
    if result != -1:
      return
    sleep(PollMs)
  fail(label & " timed out after " & $(timeoutMs div 1000) & " seconds.")

proc tcpPortOpen(port: int): bool =
  ## Returns true when a localhost TCP port accepts a connection.
  var socket: Socket
  try:
    socket = newSocket()
    socket.connect("127.0.0.1", Port(port))
    result = true
  except CatchableError:
    result = false
  if not socket.isNil:
    try:
      socket.close()
    except CatchableError:
      discard

proc firstOpenPort(startPort: int): int =
  ## Returns the first unused localhost TCP port at or above startPort.
  result = startPort
  while result <= 65535:
    if not tcpPortOpen(result):
      return
    inc result
  fail("Could not find an open localhost TCP port.")

proc waitForServerReady(
  process: Process,
  port: int
) =
  ## Waits until the replay server accepts TCP connections.
  let startedAt = getMonoTime()
  while (getMonoTime() - startedAt).inMilliseconds < ReadyTimeoutMs:
    let exitCode = process.peekExitCode()
    if exitCode != -1:
      fail("Replay server exited before ready with code " & $exitCode & ".")
    if tcpPortOpen(port):
      return
    sleep(PollMs)
  fail("Timed out waiting for replay server on port " & $port & ".")

proc replayOutputPath(
  runIndex: int,
  seed: int
): string =
  ## Returns a unique replay artifact path for one manual run.
  repoDir() / "out" / "manual_replays" /
    (
      "crewrift-manual-" & $getCurrentProcessId() &
        "-run-" & $(runIndex + 1) & "-seed-" & $seed & ".bitreplay"
    )

proc runQuickReplayRecord(
  replayPath: string,
  seed: int,
  speed: int
) =
  ## Records one full eight-bot game through quick_run.
  let
    quickRunPath = bitworldDir() / "tools" / "quick_run.nim"
    config = "{\"maxGames\":1,\"seed\":" & $seed &
      ",\"speed\":" & $speed & "}"
    port = firstOpenPort(DefaultStartPort)
    botUrl = "ws://127.0.0.1:" & $port & "/player"
    args = @[
      "r",
      quickRunPath,
      "coworld-crewrift",
      "--port:" & $port,
      "--bots:notsus:" & $BotCount,
      "--save-replay:" & replayPath,
      "--config:" & config
    ]

  createDir(replayPath.parentDir())
  if fileExists(replayPath):
    removeFile(replayPath)

  echo "Recording seed ", seed, " at ", speed, "x on port ", port, ": ",
    replayPath
  let cleanKeys = [BotUrlEnv, LoadReplayEnv]
  let savedEnv = saveEnv(cleanKeys)
  clearEnv([LoadReplayEnv])
  putEnv(BotUrlEnv, botUrl)
  var process: Process
  try:
    process = startProcess(
      nimExe(),
      workingDir = workspaceDir(),
      args = args,
      options = {poParentStreams}
    )
    try:
      let exitCode = process.waitForExit("quick_run record", RecordTimeoutMs)
      if exitCode != 0:
        fail("quick_run record exited with code " & $exitCode & ".")
    finally:
      process.stopProcess("quick_run record")
  finally:
    restoreEnv(savedEnv)

  requireOk(fileExists(replayPath), "Replay file was not created.")
  requireOk(getFileSize(replayPath) > 0, "Replay file is empty.")

proc replayTickFromPacket(packet: string): int =
  ## Reads the replay tick label from one sprite packet.
  var bytes: seq[uint8]
  packet.blobToBytes(bytes)
  try:
    for message in bytes.parseSpritePacket():
      if message.kind == spkSprite and
        message.sprite.label.startsWith("replay tick "):
        try:
          return message.sprite.label["replay tick ".len .. ^1].parseInt()
        except ValueError:
          discard
  except SpriteProtocolError:
    discard
  -1

proc sendReplayCommands(
  ws: WebSocket,
  commands: string
) =
  ## Sends replay transport commands through the global websocket.
  ws.send(blobFromSpriteChat(commands), BinaryMessage)

proc verifyReplayServer(
  replayPath: string,
  maxTick: int
) =
  ## Runs the replay server and watches it reach the final recorded tick.
  let
    port = firstOpenPort(DefaultStartPort)
    args = @[
      "r",
      "src/crewrift.nim",
      "--host:127.0.0.1",
      "--port:" & $port,
      "--load-replay:" & replayPath,
      "--mismatch-quit"
    ]
    url = "ws://127.0.0.1:" & $port & "/global"

  echo "Starting replay server on port ", port, "."
  var process = startProcess(
    nimExe(),
    workingDir = repoDir(),
    args = args,
    options = {poParentStreams}
  )

  var ws: WebSocket
  try:
    process.waitForServerReady(port)
    echo "Connecting global verifier: ", url
    ws = newWebSocket(url)
    ws.sendReplayCommands("r8")

    let startedAt = getMonoTime()
    var lastTick = -1
    while (getMonoTime() - startedAt).inMilliseconds < ReplayTimeoutMs:
      let exitCode = process.peekExitCode()
      if exitCode != -1:
        fail(
          "Replay server exited before completion with code " &
            $exitCode & ". Last observed tick was " & $lastTick & "."
        )

      let message = ws.receiveMessage(1000)
      if message.isNone:
        continue
      case message.get().kind
      of BinaryMessage:
        let tick = message.get().data.replayTickFromPacket()
        if tick >= 0:
          lastTick = max(lastTick, tick)
          if lastTick >= maxTick:
            echo "Replay reached tick ", lastTick, " of ", maxTick, "."
            return
      of Ping:
        ws.send(message.get().data, Pong)
      of TextMessage, Pong:
        discard

    fail(
      "Timed out waiting for replay completion. Last observed tick was " &
        $lastTick & " of " & $maxTick & "."
    )
  finally:
    if not ws.isNil:
      ws.close()
    process.stopProcess("replay server")

proc runManualReplay(
  runIndex: int,
  runCount: int,
  seed: int,
  speed: int
) =
  ## Records and verifies one full Crewrift replay run.
  let replayPath = replayOutputPath(runIndex, seed)
  echo "Manual replay run ", runIndex + 1, " of ", runCount, "."
  replayPath.runQuickReplayRecord(seed, speed)

  let data = loadReplay(replayPath)
  requireOk(data.joins.len == BotCount, "Expected exactly 8 replay joins.")
  requireOk(data.hashes.len > 0, "Replay has no tick hashes.")

  let maxTick = int(data.hashes[^1].tick)
  echo "Replay seed: ", seed
  echo "Replay joins: ", data.joins.len
  echo "Replay chats: ", data.chats.len
  echo "Replay hashes: ", data.hashes.len
  echo "Replay max tick: ", maxTick

  verifyReplayServer(replayPath, maxTick)
  echo "Manual replay test passed: ", replayPath

proc runManualReplays() =
  ## Runs the requested number of manual replay checks.
  let
    config = parseManualReplayConfig()
    seed = firstSeed()

  echo "Manual replay live speed: ", config.speed, "x."
  for i in 0 ..< config.runCount:
    runManualReplay(
      i,
      config.runCount,
      seed.seedForRun(i),
      config.speed
    )
  echo "Manual replay batch passed: ", config.runCount, " runs."

try:
  runManualReplays()
except CatchableError as e:
  stderr.writeLine("manual_replay failed: " & e.msg)
  quit(1)
