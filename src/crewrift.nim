import
  std/os,
  bitworld/runtime,
  crewrift/common/protocol,
  crewrift/sim,
  crewrift/server

when isMainModule:
  let
    address = cogameHost(DefaultHost)
    port = cogamePort(DefaultPort)
    configUri = getEnv(CogameConfigUriEnv)
    saveReplayUri = getEnv(CogameSaveReplayUriEnv)
    saveScoresUri = getEnv(CogameResultsUriEnv)
    loadReplayUri = getEnv(CogameLoadReplayUriEnv)
    localReplayPath = outputPathFromCogameUri(
      saveReplayUri,
      CogameSaveReplayUriEnv,
      "crewrift_replay.bitreplay"
    )
    localScoresPath = outputPathFromCogameUri(
      saveScoresUri,
      CogameResultsUriEnv,
      "crewrift_scores.json"
    )
    loadReplayPath = pathFromCogameUri(loadReplayUri, CogameLoadReplayUriEnv)
    replayServerMode = getEnv(CogameReplayServerEnv) == "1"
    replayDownloadUrl = getEnv("REPLAY_DOWNLOAD_URL")

  var config = defaultGameConfig()
  if configUri.len > 0:
    config.update(readCogameUri(configUri, CogameConfigUriEnv))
  echo "Using map file: " & config.mapPath

  var actualLoadReplayPath = loadReplayPath
  if replayDownloadUrl.len > 0 and actualLoadReplayPath.len == 0 and
      not replayServerMode:
    echo "Downloading replay from: ", replayDownloadUrl
    actualLoadReplayPath = "/tmp/downloaded.bitreplay"
    let replayData = readCogameUri(replayDownloadUrl, "REPLAY_DOWNLOAD_URL")
    writeFile(actualLoadReplayPath, replayData)
    echo "Replay downloaded: ", replayData.len, " bytes"

  echo "starting crewrift on ", address, ":", port
  runServerLoop(
    address,
    port,
    config,
    localReplayPath,
    actualLoadReplayPath,
    localScoresPath,
    replayServerMode,
    saveReplayUri,
    saveScoresUri
  )
