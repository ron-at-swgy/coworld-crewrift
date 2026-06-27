import
  std/[algorithm, json, os, strutils, times, uri],
  crunchy/sha256,
  curly

const
  DefaultRegion = "us-east-1"
  DefaultModel = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  DefaultPlayerName = "notsus"
  BedrockService = "bedrock"
  AwsRequestType = "aws4_request"
  StsVersion = "2011-06-15"
  StsAction = "AssumeRoleWithWebIdentity"
  MaxMetadataValueLen = 256
  BedrockTimeoutSeconds = 5.0'f32

type
  BedrockError = object of CatchableError

  ConversationMessage* = object
    role*: string
    content*: string

  AwsCredentials = object
    accessKeyId: string
    secretAccessKey: string
    sessionToken: string
    source: string

var
  bedrockRegion* = getEnv("AWS_REGION")
  bedrockModel* = getEnv("BEDROCK_MODEL")
  bedrockPlayerName* = getEnv("BEDROCK_PLAYER_NAME")
  lastUsage: string
  lastError: string
  cachedCredentials: AwsCredentials

let
  curl = newCurlPool(3)

proc fail(message: string) {.raises: [BedrockError].} =
  ## Raises one Bedrock client error.
  raise newException(BedrockError, message)

proc truthy(value: string): bool =
  ## Returns true when an environment flag is enabled.
  case value.strip().toLowerAscii()
  of "1", "true", "yes", "y", "on":
    true
  else:
    false

proc region(): string =
  ## Returns the configured AWS Region for Bedrock requests.
  result = bedrockRegion.strip()
  if result.len == 0:
    result = getEnv("AWS_DEFAULT_REGION").strip()
  if result.len == 0:
    result = DefaultRegion

proc model(): string =
  ## Returns the configured Bedrock model ID for requests.
  result = bedrockModel.strip()
  if result.len == 0:
    result = getEnv("BEDROCK_CLAUDE_MODEL_ID").strip()
  if result.len == 0:
    result = DefaultModel

proc playerName(): string =
  ## Returns the player name attached to Bedrock request metadata.
  result = bedrockPlayerName.strip()
  if result.len == 0:
    result = getEnv("COWORLD_POLICY_NAME").strip()
  if result.len == 0:
    result = DefaultPlayerName

proc byteHex(value: uint8): string =
  ## Returns one lowercase two-digit hex byte.
  value.toHex(2).toLowerAscii()

proc hex(bytes: openArray[uint8]): string =
  ## Returns a lowercase hex string for bytes.
  for b in bytes:
    result.add b.byteHex()

proc sha256Hex(data: string): string =
  ## Returns the SHA-256 digest as lowercase hex.
  data.sha256().hex()

proc metadataSafe(value: string): string =
  ## Coerces one Bedrock metadata value to the safe character set.
  for ch in value:
    if result.len >= MaxMetadataValueLen:
      break
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9',
        ' ', ':', '_', '@', '$', '#', '=', '/', '+', ',', '.', '-'}:
      result.add ch
    else:
      result.add '_'

proc metadataKeySafe(value: string): string =
  ## Coerces one Bedrock metadata key to a stable safe form.
  result = value.metadataSafe()
  if result.len == 0:
    result = "tag"

proc awsUriEncode(value: string): string =
  ## Percent-encodes one AWS URI path label.
  for ch in value:
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '.', '_', '~'}:
      result.add ch
    else:
      result.add '%'
      result.add ch.uint8.toHex(2)

proc bedrockHost(): string =
  ## Returns the Bedrock Runtime host for the selected Region.
  "bedrock-runtime." & region() & ".amazonaws.com"

proc bedrockPath(): string =
  ## Returns the REST path for a Bedrock Converse request.
  "/model/" & model().awsUriEncode() & "/converse"

proc bedrockUrl(): string =
  ## Returns the Bedrock Runtime Converse URL.
  "https://" & bedrockHost() & bedrockPath()

proc intField(node: JsonNode, name: string): int =
  ## Reads one integer JSON field if present.
  if node.kind == JObject and node.hasKey(name):
    let child = node[name]
    if child.kind == JInt:
      return child.getInt()
  0

proc nodeText(node: JsonNode): string =
  ## Converts one JSON node to a metadata-safe string.
  if node.kind == JString:
    return node.getStr()
  $node

proc requestMetadata(): JsonNode =
  ## Builds the Bedrock request metadata for cost attribution.
  result = newJObject()
  let raw = getEnv("BEDROCK_REQUEST_METADATA").strip()
  if raw.len > 0:
    let parsed = parseJson(raw)
    if parsed.kind != JObject:
      fail("BEDROCK_REQUEST_METADATA must be a JSON object.")
    for key, value in parsed:
      result[key.metadataKeySafe()] = %value.nodeText().metadataSafe()
  let name = playerName().metadataSafe()
  result["player_name"] = %name
  result["bot"] = %name
  result["policy_name"] = %name

proc requestMetadataKeys*(): string =
  ## Returns the metadata keys that will be sent with Bedrock requests.
  let metadata = requestMetadata()
  for key in metadata.keys:
    if result.len > 0:
      result.add ","
    result.add key

proc conversationBody(messages: openArray[ConversationMessage]): string =
  ## Builds one Bedrock Converse JSON request body.
  var
    systemText = ""
    chat = newJArray()
  for message in messages:
    if message.role == "system":
      if systemText.len > 0:
        systemText.add "\n\n"
      systemText.add message.content
    else:
      var item = newJObject()
      item["role"] = %message.role
      item["content"] = %* [{"text": message.content}]
      chat.add item
  var inference = newJObject()
  inference["maxTokens"] = %4096
  var root = newJObject()
  if systemText.len > 0:
    root["system"] = %* [{"text": systemText}]
  root["messages"] = chat
  root["inferenceConfig"] = inference
  root["requestMetadata"] = requestMetadata()
  $root

proc xmlTag(body, name: string): string =
  ## Extracts one simple XML tag value.
  let
    openTag = "<" & name & ">"
    closeTag = "</" & name & ">"
    start = body.find(openTag)
  if start < 0:
    return ""
  let valueStart = start + openTag.len
  let stop = body.find(closeTag, valueStart)
  if stop < valueStart:
    return ""
  body[valueStart ..< stop]

proc credentialsFromEnv(): AwsCredentials =
  ## Returns static AWS credentials from the process environment.
  result.accessKeyId = getEnv("AWS_ACCESS_KEY_ID").strip()
  result.secretAccessKey = getEnv("AWS_SECRET_ACCESS_KEY").strip()
  result.sessionToken = getEnv("AWS_SESSION_TOKEN").strip()
  if result.accessKeyId.len > 0 and result.secretAccessKey.len > 0:
    result.source = "env"

proc containerAuthorization(): string =
  ## Returns the container credential authorization token if configured.
  result = getEnv("AWS_CONTAINER_AUTHORIZATION_TOKEN").strip()
  if result.len > 0:
    return
  let path = getEnv("AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE").strip()
  if path.len > 0 and fileExists(path):
    result = readFile(path).strip()

proc credentialsFromContainer(): AwsCredentials =
  ## Returns AWS credentials from the container credential endpoint.
  var url = getEnv("AWS_CONTAINER_CREDENTIALS_FULL_URI").strip()
  if url.len == 0:
    let relative = getEnv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI").strip()
    if relative.len > 0:
      url = "http://169.254.170.2" & relative
  if url.len == 0:
    return
  var headers: seq[(string, string)]
  let token = containerAuthorization()
  if token.len > 0:
    headers.add ("Authorization", token)
  let response = curl.get(url, headers, timeout = 2.0'f32)
  if response.code != 200:
    fail("Container credentials returned HTTP " & $response.code & ".")
  let data = parseJson(response.body)
  result.accessKeyId = data{"AccessKeyId"}.getStr().strip()
  result.secretAccessKey = data{"SecretAccessKey"}.getStr().strip()
  result.sessionToken = data{"Token"}.getStr().strip()
  if result.accessKeyId.len > 0 and result.secretAccessKey.len > 0:
    result.source = "container"

proc stsBody(roleArn, sessionName, token: string): string =
  ## Builds one STS AssumeRoleWithWebIdentity form body.
  let pairs = [
    ("Action", StsAction),
    ("Version", StsVersion),
    ("RoleArn", roleArn),
    ("RoleSessionName", sessionName),
    ("WebIdentityToken", token),
    ("DurationSeconds", "3600")
  ]
  for pair in pairs:
    if result.len > 0:
      result.add '&'
    result.add encodeUrl(pair[0])
    result.add '='
    result.add encodeUrl(pair[1])

proc credentialsFromWebIdentity(): AwsCredentials =
  ## Returns AWS credentials from IRSA web identity.
  let
    roleArn = getEnv("AWS_ROLE_ARN").strip()
    tokenPath = getEnv("AWS_WEB_IDENTITY_TOKEN_FILE").strip()
  if roleArn.len == 0 or tokenPath.len == 0:
    return
  if not fileExists(tokenPath):
    fail("AWS_WEB_IDENTITY_TOKEN_FILE does not exist.")
  let sessionName =
    if getEnv("AWS_ROLE_SESSION_NAME").strip().len > 0:
      getEnv("AWS_ROLE_SESSION_NAME").strip()
    else:
      "notsus-bedrock"
  let body = stsBody(roleArn, sessionName, readFile(tokenPath).strip())
  let endpoint = "https://sts." & region() & ".amazonaws.com/"
  let response = curl.post(
    endpoint,
    @[("Content-Type", "application/x-www-form-urlencoded")],
    body,
    timeout = 4.0'f32
  )
  if response.code != 200:
    fail("STS web identity returned HTTP " & $response.code & ".")
  result.accessKeyId = response.body.xmlTag("AccessKeyId").strip()
  result.secretAccessKey = response.body.xmlTag("SecretAccessKey").strip()
  result.sessionToken = response.body.xmlTag("SessionToken").strip()
  if result.accessKeyId.len > 0 and result.secretAccessKey.len > 0:
    result.source = "web-identity"

proc resolveCredentials(): AwsCredentials =
  ## Resolves AWS credentials through the hosted Bedrock credential chain.
  if cachedCredentials.accessKeyId.len > 0:
    return cachedCredentials
  result = credentialsFromEnv()
  if result.source.len == 0:
    result = credentialsFromContainer()
  if result.source.len == 0:
    result = credentialsFromWebIdentity()
  if result.source.len == 0:
    fail("No AWS credentials found for Bedrock.")
  cachedCredentials = result

proc credentialSignalText*(): string =
  ## Returns the first configured AWS credential source name.
  if getEnv("AWS_ACCESS_KEY_ID").strip().len > 0 and
      getEnv("AWS_SECRET_ACCESS_KEY").strip().len > 0:
    return "env"
  if getEnv("AWS_CONTAINER_CREDENTIALS_FULL_URI").strip().len > 0 or
      getEnv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI").strip().len > 0:
    return "container"
  if getEnv("AWS_ROLE_ARN").strip().len > 0 and
      getEnv("AWS_WEB_IDENTITY_TOKEN_FILE").strip().len > 0:
    return "web-identity"
  if getEnv("USE_BEDROCK").truthy() or
      getEnv("CREWBORG_USE_BEDROCK").truthy() or
      getEnv("CLAUDE_CODE_USE_BEDROCK").truthy():
    return "use-bedrock"

proc hasAwsCredentialSignal*(): bool =
  ## Returns true if Bedrock is enabled or AWS credentials look available.
  credentialSignalText().len > 0

proc canonicalHeaders(
  headers: openArray[(string, string)]
): tuple[text: string, signed: string] =
  ## Builds canonical headers and the signed header list.
  var sorted = @headers
  sorted.sort(
    proc(a, b: (string, string)): int =
      cmp(a[0], b[0])
  )
  for header in sorted:
    result.text.add header[0]
    result.text.add ':'
    result.text.add header[1].strip()
    result.text.add '\n'
    if result.signed.len > 0:
      result.signed.add ';'
    result.signed.add header[0]

proc signingKey(secretKey, dateStamp, regionName: string): array[32, uint8] =
  ## Returns the AWS SigV4 signing key.
  let dateKey = hmacSha256("AWS4" & secretKey, dateStamp)
  let regionKey = hmacSha256(dateKey, regionName)
  let serviceKey = hmacSha256(regionKey, BedrockService)
  hmacSha256(serviceKey, AwsRequestType)

proc signedHeaders(
  credentials: AwsCredentials,
  body: string,
  nowUtc: DateTime
): seq[(string, string)] =
  ## Builds AWS SigV4 headers for one Bedrock request.
  let
    dateStamp = nowUtc.format("yyyyMMdd")
    amzDate = nowUtc.format("yyyyMMdd'T'HHmmss'Z'")
    bodyHash = body.sha256Hex()
  var headers = @[
    ("content-type", "application/json"),
    ("host", bedrockHost()),
    ("x-amz-content-sha256", bodyHash),
    ("x-amz-date", amzDate)
  ]
  if credentials.sessionToken.len > 0:
    headers.add ("x-amz-security-token", credentials.sessionToken)
  let canonical = canonicalHeaders(headers)
  let scope = dateStamp & "/" & region() & "/" & BedrockService & "/" &
    AwsRequestType
  let canonicalRequest = "POST\n" & bedrockPath() & "\n\n" &
    canonical.text & "\n" & canonical.signed & "\n" & bodyHash
  let stringToSign = "AWS4-HMAC-SHA256\n" & amzDate & "\n" & scope &
    "\n" & canonicalRequest.sha256Hex()
  let signature = hmacSha256(
    signingKey(credentials.secretAccessKey, dateStamp, region()),
    stringToSign
  ).hex()
  let authorization = "AWS4-HMAC-SHA256 Credential=" &
    credentials.accessKeyId & "/" & scope &
    ", SignedHeaders=" & canonical.signed &
    ", Signature=" & signature
  headers.add ("authorization", authorization)
  result = headers

proc parseReply(body: string): string =
  ## Extracts output text from one Bedrock Converse response body.
  let data = parseJson(body)
  if data.hasKey("usage"):
    let usage = data["usage"]
    lastUsage = "input=" & $usage.intField("inputTokens") &
      " output=" & $usage.intField("outputTokens") &
      " cache_read=" & $usage.intField("cacheReadInputTokens") &
      " cache_write=" & $usage.intField("cacheWriteInputTokens")
  else:
    lastUsage = ""
  let content = data["output"]["message"]["content"]
  for part in content:
    if part.kind == JObject and part.hasKey("text"):
      result.add part["text"].getStr()

proc lastUsageText*(): string =
  ## Returns compact usage text for the previous Bedrock call.
  lastUsage

proc lastErrorText*(): string =
  ## Returns the previous Bedrock call error if any.
  lastError

proc talkToAI*(messages: var seq[ConversationMessage]): string =
  ## Sends messages to Bedrock Converse and returns the reply text.
  lastUsage = ""
  lastError = ""
  try:
    let
      body = conversationBody(messages)
      credentials = resolveCredentials()
      response = curl.post(
        bedrockUrl(),
        signedHeaders(credentials, body, now().utc),
        body,
        timeout = BedrockTimeoutSeconds
      )
    if response.code != 200:
      fail("Bedrock Converse returned HTTP " & $response.code & ".")
    result = response.body.parseReply()
    messages.add ConversationMessage(role: "assistant", content: result)
  except CatchableError as error:
    lastError = error.msg
    echo "ERROR: notsus Bedrock Converse failed: ", error.msg
