# Crewrift

![Crewrift](docs/crewrift.png)

Crewrift is a Coworld social-deduction game. Crewmates complete tasks, report bodies, chat during meetings, and vote out
suspects. Imposters blend in, use cooldown-limited kills, vent around the map, and survive the vote.

This README is the game-owned guide. It explains how Crewrift works, what a player process must do, how to use or modify
the bundled `notsus` baseline, and what game-specific mistakes to check first. The Softmax league guide owns Docker,
`coworld download`, policy upload, league submission, placement matches, standings, logs, and replays:

<https://softmax.com/play_crewrift.md>

## Public Docs

The uploaded Coworld manifest points at these public documents:

| Purpose | Owner | URL |
| --- | --- | --- |
| Crewrift game README | Crewrift | <https://github.com/Metta-AI/coworld-crewrift/blob/master/README.md> |
| Player protocol | Bitworld | <https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md> |
| Global/replay protocol | Bitworld | <https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md> |
| Softmax play guide | Softmax | <https://softmax.com/play_crewrift.md> |

Keep game rules, strategy, game-specific player guidance, and FAQs in this README. Keep Softmax account setup, Coworld
CLI installation, policy upload, and tournament submission instructions in the Softmax play guide.

## Crewrift Rules

Crewrift runs an eight-player match by default. Most slots are crew. A smaller number are imposters.

Crew wins by:

- completing all assigned tasks; or
- voting out every imposter.

Imposters win by:

- reducing crew to parity; or
- delaying crew long enough that the episode ends before crew can recover.

Each player sees the game through the Sprite v1 player protocol. The game also writes results with per-slot scores, role,
win/loss, task counts, kill counts, report counts, and voting statistics.

### Starting The Game

Players connect and wait until the configured roster is ready. When the game starts, each player receives either a crew
or imposter role.

### Being A Crewmate

Crewmates start near the emergency button. They receive task locations, move to task stations, press A, and stand still
until the task progress bar completes. Moving interrupts task progress.

Useful crew behavior:

- move toward task stations instead of wandering;
- stay close enough to other crew to create witnesses;
- report nearby bodies;
- use emergency button calls sparingly;
- vote only when the evidence is strong enough to justify the risk.

Voting out another crewmate can lose the game, so crew policies should prefer evidence-grounded votes over random
accusations.

### Being An Imposter

Imposters should look like crewmates until a good kill is available. Their kill progress bar fills over time. When it is
ready, an imposter can stand next to a victim and press A to kill. Imposters can also use vents to move faster and hide,
but implausible vent movement is suspicious.

Useful imposter behavior:

- blend in by moving like a task-seeking crewmate;
- avoid kills when another player is visibly nearby;
- leave bodies quickly after a kill;
- use vents when the resulting movement can plausibly avoid detection;
- vote against crew when it helps move the game toward parity.

### Voting

Bodies and emergency button calls start meetings. During a meeting, players can chat and vote. A player can vote for a
suspect or skip. Once a vote is cast, it cannot be changed.

Vote timing matters. A policy that waits too long may lose the chance to vote and can take a score penalty for not voting
or skipping.

### Scoring

The game scores players based on their performance:

- winning the game: +100 points;
- completing a task: +1 point;
- killing a crewmate: +10 points;
- not voting and not skipping votes: -10 points;
- standing still while holding tasks: -1 point every 10 seconds.

The win reward dominates, but task, kill, vote, and stuck penalties are useful training signals.

## Player Runtime

In hosted and local Coworld episodes, the runner starts one game container and one policy container per player slot. Each
policy container receives a complete player websocket URL:

```text
COWORLD_PLAYER_WS_URL=ws://<game-service>:8080/player?slot=<slot>&token=<token>
```

Connect to that URL exactly as supplied. The runner owns slot assignment and token generation. Do not hardcode a slot,
guess a token, or connect to a local Crewrift server in a policy image you plan to submit.

The player websocket uses Sprite v1:

- Player protocol: <https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md>
- Global/replay viewer protocol: <https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md>

A player can be written in any language as long as its container starts the player process, connects to
`COWORLD_PLAYER_WS_URL`, reads Sprite updates, sends valid Sprite input packets, keeps the control loop responsive, and
exits when the episode ends.

## Policy Starting Points

Choose one of three paths:

1. **Use the stock baseline.** The uploaded Coworld includes a bundled `notsus` image. Use it to verify that the game
   package runs locally and to inspect a working replay before writing code.
2. **Improve `notsus`.** Copy or fork `players/notsus`. This is the best route when you want working Sprite parsing,
   movement, task targeting, and voting logic before adding your own strategy.
3. **Start from scratch.** Implement Sprite v1 directly in the language you prefer. Use `notsus` only as a protocol and
   behavior reference.

The `notsus` source is intentionally public and lives in this repo:

- `players/notsus/notsus.nim`: player entrypoint and strategy loop.
- `players/notsus/notsus/protocols.nim`: Sprite update parsing and input encoding.
- `players/notsus/notsus/votereader.nim`: meeting and vote cursor parsing.
- `players/notsus/Dockerfile`: Linux image for the baseline player.

## Policy Strategy

A useful Crewrift policy does more than move randomly. Start with small, observable improvements:

- keep a current map position and target;
- move toward visible task stations as crew;
- report nearby bodies;
- remember who was nearby before a meeting;
- vote consistently from evidence instead of always skipping;
- as imposter, avoid kills when another player is visibly nearby;
- as imposter, use vents only when the resulting movement is plausible;
- keep LLM calls asynchronous or bounded so the policy still sends timely actions.

The strongest early policies usually win by staying connected, moving consistently, completing tasks, voting before the
timer expires, and avoiding obviously suspicious imposter behavior.

## Policy FAQ

### Can I Submit The Bundled `notsus` Image Unchanged?

Use `notsus` first as a baseline for local verification. The Softmax play guide explains the current upload and
submission flow if you want to submit any image to a league.

### What Should I Copy From `notsus`?

Copy the Sprite protocol handling before copying the strategy. A policy that decodes observations and sends valid input
packets reliably is easier to improve than a clever policy with a fragile websocket loop.

### How Does My Policy Know Its Slot?

Read the `slot` query parameter from `COWORLD_PLAYER_WS_URL`. Do not guess it. The runner may assign any submitted policy
to any slot.

### How Does Voting Work?

During meetings, the visual state changes to a voting screen. `notsus` parses the vote cursor and vote cells from Sprite
objects. If your actions do nothing during voting, compare your input encoding and vote-screen detection with
`players/notsus/notsus/votereader.nim`.

### What Should I Inspect After A Bad Episode?

Start with the replay and policy logs from the Softmax or local Coworld run. For Crewrift-specific failures, check:

- whether the policy ever connected to `COWORLD_PLAYER_WS_URL`;
- whether it kept sending valid Sprite input packets;
- whether it moved toward task or body markers;
- whether it voted before the timer expired;
- whether imposter kills happened in visible, suspicious locations;
- whether LLM or network calls blocked the control loop.

## Source Development

The remaining sections are for Crewrift source development. They are useful for changing game mechanics, debugging the
reference player, or preparing a new Coworld release. They are not required for normal Softmax league participation.

### Run Locally Without Docker

Run the game entirely locally when changing source code. First, install Nim and sync the lock file. Nimby is the
recommended local Nim installer:

```sh
nimby use 2.2.10
nimby sync -g nimby.lock
```

Build and run the game with the repository config:

```sh
COGAME_HOST=0.0.0.0 \
COGAME_PORT=2000 \
COGAME_CONFIG_URI=file://$PWD/config.json \
nim r src/crewrift.nim
```

Useful config fields:

- `minPlayers`: number of players required before the game starts.
- `imposterCount`: number of imposters.
- `tasksPerPlayer`: number of tasks assigned to each crewmate.
- `killCooldownTicks`: kill cooldown.
- `voteTimerTicks`: voting duration in ticks. At 24 FPS, 6000 ticks is 250 seconds.
- `buttonCalls`: emergency button calls allowed per player.
- `mapPath`: resource map file to load. The default is `data/croatoan.resources`.

Build the example bot:

```sh
nim c players/notsus/notsus.nim
```

Run eight bots in parallel. The source build writes the binary to `players/notsus/notsus.out`. The repo config assigns
slots 0 through 7 to `player1` through `player8` with matching `0xBADA55_*` tokens.

```sh
for i in 0 1 2 3 4 5 6 7; do
  token="0xBADA55_$i"
  url="ws://localhost:2000/player?slot=$i&token=$token"
  COWORLD_PLAYER_WS_URL="$url" ./players/notsus/notsus.out &
done
wait
```

Then monitor the game with the global viewer at <http://localhost:2000/client/global>. You can also run seven bots and
one human player by opening a configured player URL in a browser, for example:

```text
http://localhost:2000/client/player?slot=0&token=0xBADA55_0
```

For a one-player source-level test:

```sh
nim r src/crewrift.nim --address:0.0.0.0 --port:2000 --config:'{"minPlayers":1,"imposterCount":0,"tasksPerPlayer":1}'
```

Then run `notsus` in another shell:

```sh
COWORLD_PLAYER_WS_URL='ws://localhost:2000/player?slot=0&token=' \
nim r players/notsus/notsus.nim -- --name notsus
```

### Run Locally With Docker

Use the public Softmax images when you want to run the source repo config without compiling Nim locally. These commands
use `config.json` and do not build new images.

Create a local Docker network:

```sh
docker network create crewrift-local || true
```

Run the game server:

```sh
docker run --rm -d \
  --name crewrift-server \
  --network crewrift-local \
  -p 2000:2000 \
  -v "$PWD/config.json:/workspace/crewrift/config.json:ro" \
  -e COGAME_HOST=0.0.0.0 \
  -e COGAME_PORT=2000 \
  -e COGAME_CONFIG_URI=file:///workspace/crewrift/config.json \
  public.ecr.aws/s3j4p9s7/treeform/games/crewrift:latest
```

Run eight `notsus` bots in parallel:

```sh
for i in 0 1 2 3 4 5 6 7
do
  token="0xBADA55_$i"
  url="ws://crewrift-server:2000/player?slot=$i&token=$token"
  docker run --rm -d \
    --name "crewrift-bot-$i" \
    --network crewrift-local \
    -e COWORLD_PLAYER_WS_URL="$url" \
    public.ecr.aws/s3j4p9s7/treeform/players/notsus:latest
done
```

Then monitor the game with the global viewer at <http://localhost:2000/client/global>.

To stop the local Docker run:

```sh
docker rm -f crewrift-server 2>/dev/null || true
for i in 0 1 2 3 4 5 6 7
do
  docker rm -f "crewrift-bot-$i" 2>/dev/null || true
done
```

### Runner Environment

Coworld runners configure file URIs with environment variables. Command-line flags override these values when both are
set.

| Variable | Meaning |
| --- | --- |
| `COGAME_HOST` | Host address to bind |
| `COGAME_PORT` | Port to bind |
| `COGAME_CONFIG_URI` | URI for the config JSON file |
| `COGAME_RESULTS_URI` | URI where final scores are written |
| `COGAME_SAVE_REPLAY_URI` | Optional URI where a replay is written |
| `COGAME_LOAD_REPLAY_URI` | Optional URI for a replay to load |

Results are written when `maxGames` is set to 1 or higher.

```sh
COGAME_HOST=0.0.0.0 \
COGAME_PORT=2000 \
COGAME_CONFIG_URI=file://$PWD/config.json \
COGAME_RESULTS_URI=file://$PWD/scores.json \
COGAME_SAVE_REPLAY_URI=file://$PWD/run.bitreplay \
nim r src/crewrift.nim
```

### Browser Clients

The game container serves these routes:

- Player: `http://localhost:2000/client/player?slot=0&token=...`
- Global viewer: `http://localhost:2000/client/global`
- Replay viewer: `http://localhost:2000/client/replay`
- Admin panel: `http://localhost:2000/client/admin`
- Rewards: `http://localhost:2000/client/rewards`

The clients connect to the game-owned websocket routes on the same host: `/player`, `/global`, `/replay`, `/admin`, and
`/reward`.

### Map Files

The default map is `data/croatoan.resources`. It controls task stations, vents, and room names. It is paired with
`data/croatoan.aseprite`, whose layers provide the map, walkability, and walls. Map images currently need to be
`1235x659`.

Use a different map by changing `mapPath` in `config.json`.
Then run the server with the same config command:

```sh
COGAME_HOST=0.0.0.0 \
COGAME_PORT=2000 \
COGAME_CONFIG_URI=file://$PWD/config.json \
nim r src/crewrift.nim
```

### Coworld Releases

Production Coworld releases are owned by the Metta repository's canonical `worlds/crewrift` entry. From a Metta checkout,
point the build contexts at the source checkouts and run the shared uploader:

```sh
GAME_CONTEXT=/path/to/coworld-crewrift \
PLAYER_CONTEXT=/path/to/coworld-crewrift \
REPORTER_CONTEXT=/path/to/reporters/reporters \
GRADER_CONTEXT=/path/to/graders \
DIAGNOSER_CONTEXT=/path/to/diagnosers/diagnosers/crewrift/crewrift_diagnoser \
OPTIMIZER_CONTEXT=/path/to/optimizers \
COMMISSIONER_CONTEXT=/path/to/commissioners \
worlds/upload.sh crewrift <version>
```

The uploader builds the game and bundled `notsus` images, materializes the manifest, runs certification, and uploads the
new Coworld package.

Crewrift serves hosted replay viewers from the game image itself; there is no separate replay-viewer S3 bundle to
upload.

### Tests

Run the source test suite from the repository root:

```sh
nim r tests/tests.nim
```
