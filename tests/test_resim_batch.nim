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

    # The fixture is a completed crew win; the engine's authoritative outcome
    # (not the score heuristic) must say so.
    check summary["outcome"].getStr() == "crew"

    # The authoritative outcome and the +100-winner count agree.
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

proc names(paths: seq[string]): seq[string] =
  ## Reduces enumerated paths to their base names for order-sensitive checks.
  for path in paths:
    result.add path.extractFilename

proc collect(args: seq[string], recursive: bool): seq[string] =
  ## Materializes the replayPaths iterator so a whole run can be asserted on.
  for path in replayPaths(args, recursive):
    result.add path

suite "resim batch path enumeration":
  # A throwaway tree: two top-level replays, one nested, and a decoy that must
  # never be picked up. Empty files are enough -- enumeration never opens them.
  let root = getTempDir() / "resim_batch_enum_test"
  removeDir(root)
  createDir(root / "sub")
  writeFile(root / "gameB" & ".bitreplay", "")
  writeFile(root / "gameA" & ".bitreplay", "")
  writeFile(root / "sub" / "gameC.bitreplay", "")
  writeFile(root / "notes.txt", "")

  test "flat directory yields only top-level replays, sorted":
    check collect(@[root], recursive = false).names == @["gameA.bitreplay",
      "gameB.bitreplay"]

  test "recursive directory yields the whole subtree, sorted":
    check collect(@[root], recursive = true).names == @["gameA.bitreplay",
      "gameB.bitreplay", "gameC.bitreplay"]

  test "non-replay files are ignored":
    check "notes.txt" notin collect(@[root], recursive = true).names

  test "explicit file arguments pass through unchanged":
    let file = root / "gameA.bitreplay"
    check collect(@[file], recursive = false) == @[file]

  test "files and directories mix in argument order":
    let loose = root / "gameA.bitreplay"
    check collect(@[loose, root / "sub"], recursive = false) ==
      @[loose, root / "sub" / "gameC.bitreplay"]

  removeDir(root)

suite "resim batch argument parsing":
  test "collects positional files with recursion off by default":
    let parsed = parseArgs(@["a.bitreplay", "runs"])
    check parsed.recursive == false
    check parsed.files == @["a.bitreplay", "runs"]

  test "-r and --recursive enable recursion in any position":
    check parseArgs(@["-r", "runs"]).recursive
    check parseArgs(@["runs", "--recursive"]).recursive
    check parseArgs(@["runs", "--recursive"]).files == @["runs"]

  test "an unknown option is rejected instead of treated as a file":
    expect ArgError:
      discard parseArgs(@["--bogus", "runs"])
