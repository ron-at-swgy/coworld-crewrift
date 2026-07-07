## Batched CrewRift replay re-simulator.
##
## Re-uses the game's expander (`tools/expand_replay.nim`) to re-simulate each
## replay and emit ONE compact JSON line per replay -- the game outcome plus
## per-slot {score, tasks, kills, votes} -- with no per-tick text. Replays are
## processed sequentially in a single thread.
##
## The league server denies episode-results for episodes you did not run, so a
## deterministic re-sim from the recorded inputs is the only way to recover an
## episode's outcome and scores. The team outcome comes straight from the
## re-simulated engine (`ReplayTimeline.outcome`); only the per-slot score/
## task/kill/vote aggregation is added here, over the events
## `expandReplayTimeline` already synthesizes.
##
## Run:
##   nim r tools/resim_batch.nim [-r|--recursive] [files...]
## Each entry in [files...] is a replay file or a directory. Directories expand
## to their `*.bitreplay` files -- flat (top level only) by default, or the
## whole subtree with -r/--recursive. Passing a directory instead of thousands
## of paths sidesteps the shell's argument-length limit. One JSON object per
## line is written to stdout.

import
  std/[algorithm, json, os, sets, tables],
  ../src/crewrift/replays,   # loadReplay, ReplayData
  ../src/crewrift/sim,       # WinReward
  expand_replay             # expandReplayTimeline, ReplayEvent, ReplayEventKind, ReplayTimeline

const SchemaVersion = "crewrift-resim/v1"

proc summarize*(path: string): JsonNode =
  ## Re-simulates one replay and returns its outcome/score summary as JSON.
  let data = loadReplay(path)
  let tl = expandReplayTimeline(data)

  var score, tasks, kills, votesPlayer, votesSkip = initTable[int, int]()
  var winners = initHashSet[int]()
  var slotsSeen = initHashSet[int]()

  for ev in tl.events:
    if ev.actorSlot < 0:
      continue
    slotsSeen.incl ev.actorSlot
    case ev.kind
    of Score:
      score[ev.actorSlot] = score.getOrDefault(ev.actorSlot) + ev.scoreAmount
      if ev.scoreAmount == WinReward:
        winners.incl ev.actorSlot
    of CompletedTask:
      tasks[ev.actorSlot] = tasks.getOrDefault(ev.actorSlot) + 1
    of Kill:
      kills[ev.actorSlot] = kills.getOrDefault(ev.actorSlot) + 1
    of VoteCast:
      if ev.voteSkip:
        votesSkip[ev.actorSlot] = votesSkip.getOrDefault(ev.actorSlot) + 1
      else:
        votesPlayer[ev.actorSlot] = votesPlayer.getOrDefault(ev.actorSlot) + 1
    else:
      discard

  let nWinners = winners.len
  # Team result is the engine's authoritative end state, surfaced by the shared
  # ReplayTimeline.outcome helper (in expand_replay); n_winners is reported only
  # as a cross-check, not the source of truth.
  let outcome = tl.outcome()

  var slots = newJObject()
  for s in slotsSeen:
    slots[$s] = %*{
      "score": score.getOrDefault(s),
      "tasks": tasks.getOrDefault(s),
      "kills": kills.getOrDefault(s),
      "votes_player": votesPlayer.getOrDefault(s),
      "votes_skip": votesSkip.getOrDefault(s),
      "won": s in winners,
    }

  result = %*{
    "schema_version": SchemaVersion,
    "episode": path.splitFile.name,
    "tick_count": tl.tickCount,
    "outcome": outcome,
    "n_winners": nWinners,
    "hash_failed": tl.hashFailed,
    # Tick where the per-tick state hash first drifted from the recording (the
    # re-sim stops there); -1 when it validated clean to the end.
    "fail_tick": if tl.hashFailed: tl.failTick else: -1,
    "slots": slots,
  }

const ReplayExt = ".bitreplay"

iterator replayPaths*(args: seq[string], recursive: bool): string =
  ## Yields the replays to summarize. A directory argument expands to its
  ## `*.bitreplay` files -- the whole subtree when `recursive`, otherwise just
  ## the top level -- sorted for stable output; any other argument is yielded
  ## unchanged and summarized as a file path.
  for arg in args:
    if dirExists(arg):
      var found: seq[string]
      if recursive:
        for path in walkDirRec(arg):
          if path.splitFile.ext == ReplayExt:
            found.add path
      else:
        for path in walkFiles(arg / ("*" & ReplayExt)):
          found.add path
      found.sort()
      for path in found:
        yield path
    else:
      yield arg

type ArgError* = object of CatchableError

proc parseArgs*(args: seq[string]): tuple[recursive: bool, files: seq[string]] =
  ## Splits argv into the --recursive flag and the positional file/dir list.
  ## Raises ArgError on an unrecognized `-option`.
  for arg in args:
    case arg
    of "-r", "--recursive":
      result.recursive = true
    else:
      if arg.len > 0 and arg[0] == '-':
        raise newException(ArgError, "unknown option: " & arg)
      result.files.add arg

when isMainModule:
  let parsed =
    try:
      parseArgs(commandLineParams())
    except ArgError as e:
      stderr.writeLine("resim_batch: " & e.msg)
      quit(1)
  for path in replayPaths(parsed.files, parsed.recursive):
    try:
      echo $summarize(path)
    except CatchableError as e:
      echo $(%*{"episode": path.splitFile.name, "error": e.msg})
