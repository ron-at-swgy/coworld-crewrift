## Batched CrewRift replay re-simulator.
##
## Re-uses the game's expander (`tools/expand_replay.nim`) to re-simulate each
## replay path given on argv and emit ONE compact JSON line per replay -- the
## game outcome plus per-slot {score, tasks, kills, votes} -- with no per-tick
## text. Re-sim runs at CPU speed, so one process handles many replays fast;
## shard the file list across cores for parallelism.
##
## The league server denies episode-results for episodes you did not run, so a
## deterministic re-sim from the recorded inputs is the only way to recover an
## episode's outcome and scores. Everything below is derived from the events
## `expandReplayTimeline` already synthesizes; only the per-slot aggregation and
## the team-outcome rule are added here.
##
## Run:
##   nim r tools/resim_batch.nim <replay1> <replay2> ...
## One JSON object per line is written to stdout.

import
  std/[json, os, sets, tables],
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
  # Win-type from the count of +100 (WinReward) recipients: 6 crew vs 2 imposters,
  # so >=3 => crew win, 1..2 => imposter win, 0 => draw (time limit / nobody won).
  # A hash-failed re-sim ran against a mismatched game version -- its totals are
  # not trustworthy, so the outcome is reported as unknown.
  let outcome =
    if tl.hashFailed: "unknown"
    elif nWinners == 0: "draw"
    elif nWinners >= 3: "crew"
    else: "imposter"

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

when isMainModule:
  for path in commandLineParams():
    try:
      echo $summarize(path)
    except CatchableError as e:
      echo $(%*{"episode": path.splitFile.name, "error": e.msg})
