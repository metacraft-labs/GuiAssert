## GuiAssert Appium WebDriver client
##
## A pure-Nim WebDriver client speaking the W3C/Appium HTTP wire protocol
## directly via `std/httpclient`.  We intentionally keep the dependency
## footprint minimal — the only requirements are `std/httpclient` and
## `std/json`, both of which ship with stock Nim.
##
## ### Why a from-scratch client?
##
## We need to drive three independent windows on macOS (CodeTracer
## Electron, Terminal.app, VS Code) from within the same Nim recorder
## process.  Existing Appium clients are shipped as Java, Python, or
## JavaScript libraries — pulling any of those into the recorder would
## explode the toolchain.  A few hundred lines of HTTP-over-JSON suffice
## for the small command surface we actually use.
##
## ### Protocol references
##
##   * W3C WebDriver spec — https://www.w3.org/TR/webdriver2/
##   * Appium HTTP API   — https://appium.io/docs/en/2.0/intro/
##   * Appium mac2 driver — https://github.com/appium/appium-mac2-driver
##
## All endpoints below are exercised against `127.0.0.1:4723` by
## default — Appium's stock port — but every entry point accepts a
## custom `serverUrl`.
##
## ### Selector strategies
##
## The Appium mac2 driver exposes four strategies that we use here:
##
##   * `accessibility id` — matches the macOS accessibility identifier
##     property of an element (most reliable for AppKit apps).
##   * `class chain`      — Apple's class-chain syntax inherited from
##     XCUITest, e.g. `**/XCUIElementTypeButton[`name == "Save"`]`.
##   * `xpath`            — slow but flexible.
##   * `predicate string` — NSPredicate syntax over element attributes.
##
## Callers pass these strings verbatim as the `strategy` argument; we
## forward them in the W3C request body's `using` field.

import std/[httpclient, json, options, strutils, net]

type
  AppiumError* = object of CatchableError
    ## Raised on transport failures, non-2xx HTTP responses, or
    ## semantic errors decoded from the WebDriver wire format.

  AppiumCapabilities* = object
    ## Subset of W3C `alwaysMatch` capabilities and Appium-specific
    ## capability vendor keys needed to launch / attach to mac2,
    ## Chromium-on-Electron, and Terminal sessions.
    automationName*: string
      ## "Mac2" for macOS native apps, "Chromium" for Electron over CDP.
    bundleId*: Option[string]
      ## macOS bundle identifier, e.g. "com.apple.Terminal".
    app*: Option[string]
      ## Absolute path to a `.app` bundle or an executable.
    arguments*: seq[string]
      ## Process arguments forwarded to the launched app.
    chromedriverExecutable*: Option[string]
      ## Used by the Chromium driver to point at a matching
      ## chromedriver binary.
    debuggerAddress*: Option[string]
      ## For attaching to an Electron app: `host:port` of the existing
      ## CDP debugger endpoint (`--remote-debugging-port=...`).

  AppiumSession* = ref object
    ## Live WebDriver session: a server base URL plus a session id
    ## returned by `newSession`.  When `sessionId` is empty the session
    ## has been terminated.
    serverUrl*: string
    sessionId*: string
    automationName*: string
    client*: HttpClient
      ## Reused per request so we keep one TCP connection open.

const
  DefaultAppiumServerUrl* = "http://127.0.0.1:4723"

# ---------------------------------------------------------------------------
# Capability construction
# ---------------------------------------------------------------------------

proc toAlwaysMatch*(caps: AppiumCapabilities): JsonNode =
  ## Render the capabilities into the W3C `alwaysMatch` shape, using the
  ## `appium:` vendor prefix on all non-standard keys per the spec.
  ##
  ## Exposed for testing — callers do not normally need this.
  result = newJObject()
  if caps.automationName.len > 0:
    result["appium:automationName"] = newJString(caps.automationName)
  if caps.bundleId.isSome:
    result["appium:bundleId"] = newJString(caps.bundleId.get)
  if caps.app.isSome:
    result["appium:app"] = newJString(caps.app.get)
  if caps.arguments.len > 0:
    let arr = newJArray()
    for a in caps.arguments:
      arr.add newJString(a)
    result["appium:arguments"] = arr
  if caps.chromedriverExecutable.isSome:
    result["appium:chromedriverExecutable"] =
      newJString(caps.chromedriverExecutable.get)
  if caps.debuggerAddress.isSome:
    # Chromium driver expects `goog:chromeOptions.debuggerAddress`.
    let chromeOpts = newJObject()
    chromeOpts["debuggerAddress"] = newJString(caps.debuggerAddress.get)
    result["goog:chromeOptions"] = chromeOpts
  # The W3C-compliant `platformName` must be in the top level (no prefix).
  if caps.automationName.toLowerAscii() == "mac2":
    result["platformName"] = newJString("mac")
  elif caps.automationName.toLowerAscii() == "chromium":
    result["platformName"] = newJString("mac")

proc newSessionRequestBody*(caps: AppiumCapabilities): JsonNode =
  ## The full request body for POST /session.  Kept public for test
  ## introspection without forcing the test to talk to a real server.
  let alwaysMatch = caps.toAlwaysMatch()
  result = %* {
    "capabilities": {
      "alwaysMatch": alwaysMatch,
      "firstMatch": [newJObject()]
    }
  }

# ---------------------------------------------------------------------------
# Transport helpers
# ---------------------------------------------------------------------------

proc decodeWireError(status: HttpCode, body: string): string =
  ## Convert an HTTP error response into a human-readable message.
  ## The W3C wire format puts errors under `value.error` and
  ## `value.message`; if the body isn't JSON we just include it.
  try:
    let j = parseJson(body)
    if j.hasKey("value") and j["value"].kind == JObject:
      let v = j["value"]
      let kind =
        if v.hasKey("error"): v["error"].getStr else: "(no error code)"
      let msg =
        if v.hasKey("message"): v["message"].getStr else: ""
      return "[" & $status & "] " & kind & ": " & msg
  except CatchableError:
    discard
  return "[" & $status & "] " & body

proc methodFromName(name: string): HttpMethod =
  case name.toUpperAscii()
  of "GET":    HttpGet
  of "POST":   HttpPost
  of "DELETE": HttpDelete
  of "PUT":    HttpPut
  of "PATCH":  HttpPatch
  else:        HttpGet

proc requestJson(s: AppiumSession, methodName, urlSuffix: string,
                  body: JsonNode = nil): JsonNode =
  ## Issue an HTTP request to the Appium server and return the parsed
  ## response value (the contents of the wire format's `value` field).
  ## Raises `AppiumError` on any transport / protocol failure.
  let url = s.serverUrl & urlSuffix
  let payload = if body == nil: "" else: $body
  var headers = newHttpHeaders({"Content-Type": "application/json"})
  let httpMethod = methodFromName(methodName)
  let response =
    try:
      s.client.request(url, httpMethod = httpMethod, body = payload,
                       headers = headers)
    except CatchableError as e:
      raise newException(AppiumError,
        "transport failure (" & methodName & " " & url & "): " & e.msg)
  let respBody = response.body
  if not response.code.is2xx:
    raise newException(AppiumError,
      decodeWireError(response.code, respBody))
  if respBody.len == 0:
    return newJObject()
  try:
    let parsed = parseJson(respBody)
    if parsed.hasKey("value"):
      return parsed["value"]
    return parsed
  except JsonParsingError as e:
    raise newException(AppiumError,
      "malformed JSON response from " & url & ": " & e.msg & " | body=" & respBody)

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------

proc newAppiumSession*(serverUrl: string,
                       caps: AppiumCapabilities): AppiumSession =
  ## Open a new WebDriver session against `serverUrl` using `caps`.
  ## The returned session owns an HTTP client and must be released via
  ## `terminateSession` when callers are done.
  result = AppiumSession(
    serverUrl: serverUrl.strip(trailing = true, chars = {'/'}),
    sessionId: "",
    automationName: caps.automationName,
    client: newHttpClient(),
  )
  let body = newSessionRequestBody(caps)
  let value = result.requestJson("POST", "/session", body)
  # The W3C response shape is `{value: {sessionId: "...", capabilities: {...}}}`.
  # Some Appium versions place sessionId directly under `value`.
  if value.kind == JObject and value.hasKey("sessionId"):
    result.sessionId = value["sessionId"].getStr
  elif value.kind == JObject and value.hasKey("session_id"):
    result.sessionId = value["session_id"].getStr
  else:
    raise newException(AppiumError,
      "newSession response missing sessionId: " & $value)

proc terminateSession*(s: AppiumSession) =
  ## DELETE /session/{sessionId}.  Idempotent — calling on an already
  ## closed session is a no-op.  The underlying HTTP client is also
  ## closed.
  if s.sessionId.len == 0:
    return
  try:
    discard s.requestJson("DELETE", "/session/" & s.sessionId)
  except AppiumError:
    # Best-effort: a dead server still means we should release the
    # client. Swallow and continue.
    discard
  s.sessionId = ""
  if s.client != nil:
    try: s.client.close()
    except CatchableError: discard

# ---------------------------------------------------------------------------
# Element interactions
# ---------------------------------------------------------------------------

proc findElement*(s: AppiumSession, strategy, selector: string): string =
  ## POST /session/{sessionId}/element.  Returns the element id (the
  ## opaque string the WebDriver uses to refer to that element in
  ## subsequent calls).
  ##
  ## `strategy` is one of: `"accessibility id"`, `"class chain"`,
  ## `"xpath"`, `"predicate string"`, `"name"`, `"id"`.
  if s.sessionId.len == 0:
    raise newException(AppiumError, "findElement on closed session")
  let body = %* {"using": strategy, "value": selector}
  let value = s.requestJson(
    "POST", "/session/" & s.sessionId & "/element", body)
  # W3C: `{"element-6066-11e4-a52e-4f735466cecf": "<id>"}`.
  # Legacy: `{"ELEMENT": "<id>"}`.  Both are accepted.
  if value.kind != JObject:
    raise newException(AppiumError,
      "findElement returned non-object value: " & $value)
  const W3CKey = "element-6066-11e4-a52e-4f735466cecf"
  if value.hasKey(W3CKey):
    return value[W3CKey].getStr
  if value.hasKey("ELEMENT"):
    return value["ELEMENT"].getStr
  raise newException(AppiumError,
    "findElement response had no element key: " & $value)

proc click*(s: AppiumSession, elementId: string) =
  ## POST /session/{sessionId}/element/{elementId}/click — synchronous.
  if s.sessionId.len == 0:
    raise newException(AppiumError, "click on closed session")
  discard s.requestJson(
    "POST",
    "/session/" & s.sessionId & "/element/" & elementId & "/click",
    newJObject())

proc sendKeys*(s: AppiumSession, elementId, text: string) =
  ## POST /session/{sessionId}/element/{elementId}/value.
  ## The W3C wire format uses `text` for the full string and `value` for
  ## an array of code points.  We send both — servers accept either.
  if s.sessionId.len == 0:
    raise newException(AppiumError, "sendKeys on closed session")
  let arr = newJArray()
  for ch in text:
    arr.add newJString($ch)
  let body = %* {"text": text, "value": arr}
  discard s.requestJson(
    "POST",
    "/session/" & s.sessionId & "/element/" & elementId & "/value",
    body)

# ---------------------------------------------------------------------------
# Script execution
# ---------------------------------------------------------------------------

proc executeScript*(s: AppiumSession, script: string,
                    args: seq[JsonNode] = @[]): JsonNode =
  ## POST /session/{sessionId}/execute/sync.  For the mac2 driver this
  ## is how custom commands are invoked — for example
  ## `mobile: setBounds` to move/resize a window.
  if s.sessionId.len == 0:
    raise newException(AppiumError, "executeScript on closed session")
  let argArr = newJArray()
  for a in args: argArr.add a
  let body = %* {"script": script, "args": argArr}
  return s.requestJson(
    "POST", "/session/" & s.sessionId & "/execute/sync", body)

# ---------------------------------------------------------------------------
# Window bounds (helper around the mac2 driver's `mobile: setBounds`)
# ---------------------------------------------------------------------------

proc setWindowBounds*(s: AppiumSession, x, y, w, h: int) =
  ## Convenience wrapper that invokes the mac2-specific
  ## `mobile: setWindowBounds` extension to position and resize the
  ## active window.  On other automation backends this raises an
  ## `AppiumError` — callers can catch it if they want a no-op fallback.
  let args = @[
    %* {"x": x, "y": y, "width": w, "height": h}
  ]
  if s.automationName.toLowerAscii() == "mac2":
    discard s.executeScript("mobile: setWindowBounds", args)
  else:
    raise newException(AppiumError,
      "setWindowBounds is only implemented for the Mac2 driver; got '" &
      s.automationName & "'")

# ---------------------------------------------------------------------------
# Self-test hook (for `nim c -d:appiumSelfTest`)
# ---------------------------------------------------------------------------

when defined(appiumSelfTest):
  echo "appium module compiled; W3C body shape sample:"
  let caps = AppiumCapabilities(
    automationName: "Mac2",
    bundleId: some("com.apple.Terminal"))
  echo newSessionRequestBody(caps).pretty
