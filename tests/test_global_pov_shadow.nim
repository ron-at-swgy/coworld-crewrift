import
  std/os,
  bitworld/spriteprotocol,
  crewrift/[global, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCrewriftForTest(config: GameConfig): SimServer =
  ## Initializes Crewrift from the game directory.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc hasShadowSprite(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when one packet updates the player shadow sprite.
  for message in messages:
    if message.kind == spkSprite and message.sprite.label == "shadow":
      return true

proc hasFullScreenPovLayer(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when the selected player PoV is sent as a full-screen layer.
  for message in messages:
    if message.kind == spkLayer and
        message.layer.layer == PovLayerId and
        message.layer.kind == FullScreenLayerType and
        message.layer.flags == 0:
      return true

proc hasViewportMapSprite(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when the selected player PoV map is viewport-sized.
  for message in messages:
    if message.kind == spkSprite and
        message.sprite.id == MapSpriteId + PovSpriteIdOffset and
        message.sprite.width == ScreenWidth and
        message.sprite.height == ScreenHeight and
        message.sprite.label == "map view":
      return true

proc hasViewportMapObject(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when the selected player PoV map starts at the viewport origin.
  for message in messages:
    if message.kind == spkObject and
        message.objectDef.id == MapObjectId + PovObjectIdOffset and
        message.objectDef.x == 0 and
        message.objectDef.y == 0 and
        message.objectDef.layer == PovLayerId and
        message.objectDef.spriteId == MapSpriteId + PovSpriteIdOffset:
      return true

proc hasDeletedObject(
  messages: openArray[SpritePacketMessage],
  objectId: int
): bool =
  ## Returns true when one packet deletes the requested object.
  for message in messages:
    if message.kind == spkDeleteObject and message.objectId == objectId:
      return true

proc hasInertPovLayer(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when the PoV layer is no longer full-screen.
  for message in messages:
    if message.kind == spkLayer and
        message.layer.layer == PovLayerId and
        message.layer.kind != FullScreenLayerType and
        message.layer.flags == 0:
      return true

proc hasInertPovViewport(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when the PoV layer has a tiny inert viewport.
  for message in messages:
    if message.kind == spkViewport and
        message.viewport.layer == PovLayerId and
        message.viewport.width == 1 and
        message.viewport.height == 1:
      return true

proc hasZoomableMapLayer(messages: openArray[SpritePacketMessage]): bool =
  ## Returns true when the global map is restored as a zoomable full-map layer.
  for message in messages:
    if message.kind == spkLayer and
        message.layer.layer == MapLayerId and
        message.layer.kind == MapLayerType and
        message.layer.flags == ZoomableLayerFlag:
      return true

proc hasFullMapViewport(
  messages: openArray[SpritePacketMessage],
  sim: SimServer
): bool =
  ## Returns true when the global map viewport has the full map size.
  for message in messages:
    if message.kind == spkViewport and
        message.viewport.layer == MapLayerId and
        message.viewport.width == sim.gameMap.width and
        message.viewport.height == sim.gameMap.height:
      return true

proc buildGlobalMessages(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState
): seq[SpritePacketMessage] =
  ## Builds and parses one global sprite packet.
  sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket()

proc spriteCenter(player: Player): tuple[x, y: int] =
  ## Returns the center of a player sprite in global map coordinates.
  (
    x: player.x - SpriteDrawOffX - 1 + (CrewSpriteSize + 2) div 2,
    y: player.y - SpriteDrawOffY - 1 + (CrewSpriteSize + 2) div 2
  )

proc clickMap(state: var GlobalViewerState, x, y: int) =
  ## Queues one map-layer click for a global viewer state.
  state.mouseLayer = MapLayerId
  state.mouseX = x
  state.mouseY = y
  state.mouseDown = false
  state.mousePressed = true
  state.mousePressLayer = MapLayerId
  state.mousePressX = x
  state.mousePressY = y

proc testSelectedPovShadowRefresh() =
  ## Tests that selected global PoV sends refreshed shadow sprites.
  var game = initCrewriftForTest(defaultGameConfig())
  let playerIndex = game.addPlayer("pov")
  game.phase = Playing

  var
    state = initGlobalViewerState()
    nextState: GlobalViewerState
  state.selectedJoinOrder = game.players[playerIndex].joinOrder
  let firstMessages = game.buildGlobalMessages(state, nextState)
  doAssert firstMessages.hasZoomableMapLayer()
  doAssert firstMessages.hasFullMapViewport(game)
  doAssert firstMessages.hasFullScreenPovLayer()
  doAssert firstMessages.hasViewportMapSprite()
  doAssert firstMessages.hasViewportMapObject()
  doAssert firstMessages.hasShadowSprite()

  state = nextState
  game.players[playerIndex].x += 8
  let view = game.playerView(playerIndex)
  discard game.usePlayerShadowMask(playerIndex, view)
  let secondMessages = game.buildGlobalMessages(state, nextState)
  doAssert secondMessages.hasShadowSprite()

proc testMapClickSelectsNearestPlayer() =
  ## Tests that map clicks select the nearest nearby player sprite.
  var game = initCrewriftForTest(defaultGameConfig())
  let
    firstIndex = game.addPlayer("first")
    secondIndex = game.addPlayer("second")
  game.phase = Playing
  game.players[firstIndex].x = 100
  game.players[firstIndex].y = 100
  game.players[secondIndex].x = 160
  game.players[secondIndex].y = 100

  let secondCenter = game.players[secondIndex].spriteCenter()
  var
    state = initGlobalViewerState()
    nextState: GlobalViewerState
  state.clickMap(secondCenter.x - 21, secondCenter.y)
  discard game.buildSpriteProtocolUpdates(state, nextState)
  doAssert nextState.selectedJoinOrder ==
    game.players[secondIndex].joinOrder

proc testSelectedPovClearsOverlayOnly() =
  ## Tests that leaving selected PoV clears only the PoV overlay.
  var game = initCrewriftForTest(defaultGameConfig())
  let playerIndex = game.addPlayer("pov")
  game.phase = Playing

  var
    state = initGlobalViewerState()
    nextState: GlobalViewerState
  state.selectedJoinOrder = game.players[playerIndex].joinOrder
  discard game.buildGlobalMessages(state, nextState)

  state = nextState
  state.selectedJoinOrder = -1
  let restoredMessages = game.buildGlobalMessages(state, nextState)
  doAssert not restoredMessages.hasZoomableMapLayer()
  doAssert not restoredMessages.hasFullScreenPovLayer()
  doAssert not restoredMessages.hasViewportMapSprite()
  doAssert restoredMessages.hasDeletedObject(MapObjectId + PovObjectIdOffset)
  doAssert restoredMessages.hasInertPovLayer()
  doAssert restoredMessages.hasInertPovViewport()

echo "Testing global PoV shadow refresh"
testSelectedPovShadowRefresh()
testMapClickSelectsNearestPlayer()
testSelectedPovClearsOverlayOnly()
echo "ok"
