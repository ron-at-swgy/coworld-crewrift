import
  std/[json, os, unittest],
  ../tools/resim_batch

const
  GameDir = currentSourcePath.parentDir.parentDir
  NotsusReplayPath = GameDir / "tests" / "replays" / "notsus.bitreplay"

suite "resim batch summary":
  test "summarizes the notsus fixture replay":
    let summary = summarize(NotsusReplayPath)

    # Schema envelope + top-level fields the cr-analysis pipeline consumes.
    check summary["schema_version"].getStr() == "crewrift-resim/v1"
    check summary["episode"].getStr() == "notsus"
    check summary["tick_count"].getInt() > 0
    check summary["outcome"].getStr() in ["crew", "imposter", "draw", "unknown"]
    check summary.hasKey("n_winners")

    # A clean, version-matched re-sim validates the per-tick hash the whole way.
    check summary["hash_failed"].getBool() == false
    check summary["fail_tick"].getInt() == -1

    # Outcome and the +100-winner count agree.
    let nWinners = summary["n_winners"].getInt()
    case summary["outcome"].getStr()
    of "draw": check nWinners == 0
    of "imposter": check nWinners in 1 .. 2
    of "crew": check nWinners >= 3
    else: discard

    # Per-slot rows are present and well-formed.
    let slots = summary["slots"]
    check slots.len > 0
    for _, slot in slots:
      for key in ["score", "tasks", "kills", "votes_player", "votes_skip"]:
        check slot[key].kind == JInt
      check slot["won"].kind == JBool
