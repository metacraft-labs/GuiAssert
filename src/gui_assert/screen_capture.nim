## GuiAssert macOS Still-Frame and Window-Targeted Capture
##
## `capture.nim` records **video** (ffmpeg / avfoundation / wf-recorder /
## ddagrab). This module produces **single frames**, which is what the
## assertion harness actually consumes: `waitForText`, `visualCompare` and
## `detectLayoutOverflow` all work on one image. Until now the only way to get
## a still was `video_analysis.extractFrameTo` — record a video, then pull a
## frame out of it.
##
## Two capture modes:
##
##   * **full display** — `captureDisplayStill`
##   * **window-targeted** — `captureWindowStill`, which returns *that window's
##     own pixels*
##
## Why window targeting is a correctness property and not a convenience:
## cropping a display still to a window's `CGWindowList` bounds captures
## whatever is stacked **on top** of that window. ScreenCaptureKit's
## `SCContentFilter(desktopIndependentWindow:)` captures the window's own
## surface whether it is occluded or not. A coordinate crop cannot tell the two
## situations apart, and will silently assert against the wrong application.
##
## ## Why ScreenCaptureKit
##
## `CGWindowListCreateImage` is **obsoleted in macOS 15.0** — a hard compile
## error on this host, not a deprecation warning — so CoreGraphics offers no
## still-capture route any more. ScreenCaptureKit is the only forward-looking
## one. The Swift side lives in `helpers/screen_capture.swift` and is compiled
## on demand through `swift_helper`, exactly as the Apple Vision OCR helper is.
##
## ## The TCC subject is a dedicated signed `.app`, never the terminal
##
## Screen capture on macOS is gated by the `kTCCServiceScreenCapture` TCC
## service, and TCC attributes a request to the **responsible** process. A
## helper spawned from a terminal is attributed to the terminal, so the grant
## would have to be given to iTerm2 / Terminal / Ghostty — which hands every
## process that terminal ever runs the ability to read the screen. This module
## therefore builds a dedicated application bundle,
## `GuiAssertCapture.app` (bundle id `com.metacraft-labs.guiassert.capture`),
## and launches it through `open -n -g -W -a`, so **launchd** is the parent and
## the bundle is its own responsible process. `open` discards the child's
## stdout, which is why the helper's authoritative output channel is a
## `--report` file rather than stdout.
##
## ## What TCC keys the grant on — measured, not assumed
##
## TCC records the client's **designated requirement** in `access.csreq` and
## re-evaluates the calling code against it. Measured on aarch64-darwin, macOS
## 26.5.2 (build 25F84), 2026-10-12, by decoding every `csreq` blob in
## `/Library/Application Support/com.apple.TCC/TCC.db` with `csreq -r … -t`:
##
##   * A **certificate-signed** client records a byte-independent requirement,
##     e.g. `identifier "com.mitchellh.ghostty" and anchor apple generic and
##     … certificate leaf[subject.OU] = "24VZTF6M5V"`.
##   * An **ad-hoc signed** client records `cdhash H"…"` and nothing else — the
##     live row for a nix-built binary on this host is literally
##     `cdhash H"c03940b43ed187e2623d7f853d75d3755dcb98d6"`.
##
## An ad-hoc signature therefore keys the grant on the **code bytes**: every
## rebuild changes the cdhash, the recorded requirement stops matching, and the
## user is asked to approve again. Measured directly: two builds of the same
## bundle that differ only in one string literal signed `--sign -` produced
## `cdhash H"a8ff6b55…"` and `cdhash H"b9ff6e0a…"`, and the second fails the
## first's requirement (`codesign --verify -R=…` exits 3).
##
## Signing the same two bundles with an **Apple Development** identity — which
## a free Apple ID provides, no paid membership needed — produced one identical
## requirement for both:
##
##     identifier "com.metacraft-labs.guiassert.capture" and
##     anchor apple generic and
##     certificate leaf[subject.CN] = "Apple Development: …" and
##     certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
##
## and each bundle satisfies the other's requirement (exit 0), while an ad-hoc
## bundle and a differently-identified bundle both fail it (exit 3). So the
## grant survives rebuilds **iff** the bundle is signed with a real signing
## identity and keeps its bundle identifier.
##
## ### How to probe this without fooling yourself
##
## The first attempt at the experiment above changed the Swift source by
## appending a **comment** and concluded nothing had moved: the rebuilt binary
## was byte-identical and the CDHash unchanged. That probe could not see its
## own subject. Only a change to a **string literal** moved the CDHash, which
## is why the measurement above is phrased in terms of one.
##
## Re-derived independently on 2026-10-12 (same host), the reason is worth
## knowing, because it is not compiler determinism:
##
##   * `/usr/bin/swiftc` is **not** reproducible. Compiling byte-identical
##     source twice emits a different `LC_UUID` each time, so the binary hash
##     and the bundle CDHash both move on *every* rebuild — a comment change
##     included.
##   * So a probe that observes "byte-identical, CDHash unchanged" has not
##     observed the signature; it has observed `compileSwiftHelper`'s
##     mtime-keyed cache **declining to recompile**. That cache is in
##     `swift_helper.compileSwiftHelper`, and it is why appending a comment can
##     look like proof that nothing depends on the bytes.
##
## When re-checking this, confirm the CDHash moved (`codesign -dvvv`) before
## reading anything into whether the requirement still matches. Three
## cert-signed bundles whose CDHashes were measured distinct
## (`4b30d6c7…`, `93ac062a…`, `c0dd793e…`) all carried the one identical
## requirement above and all satisfied it, while two ad-hoc builds produced
## `cdhash H"79cf70a8…"` and `cdhash H"77c4f4ca…"` and the second failed the
## first's requirement (exit 3).
##
## `ensureCaptureApp` enforces this rather than trusting it: it records the
## designated requirement next to the bundle on first build and, after every
## re-sign, verifies the rebuilt bundle still satisfies the **recorded** one.
## If it does not, the grant is dead and the caller is told so explicitly
## instead of discovering it as a capture failure.
##
## ## Pure vs. host-dependent
##
## The parsers, the argv builder and the window matcher are pure and tested
## everywhere. Everything that touches the window server is macOS-only and
## raises `StillCaptureUnavailable` elsewhere, never a silent no-op.

import std/[algorithm, os, osproc, streams, strutils, tempfiles, times]

import ./swift_helper
import ./core/geometry

# This module stays at its path. Its pure code is the macOS helper's own
# report and window-list format, which belongs to the macOS capture backend
# rather than the platform-neutral core; the bridges at the end of the file
# convert its rectangles to `gui_assert/core/geometry.Rect`.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  CaptureStatus* = enum
    ## The helper's `status=` value. Kept distinct from a bare bool because the
    ## whole point of this module's error handling is that "the window is not
    ## there" and "I am not allowed to look" must never be reported alike.
    csOk              ## capture succeeded
    csUsage           ## the helper was invoked wrongly (a GuiAssert bug)
    csTargetNotFound  ## the window list was readable; nothing matched
    csDenied          ## TCC refused this code
    csCaptureFailed   ## ScreenCaptureKit failed for another reason
    csWriteFailed     ## the image could not be written
    csTimeout         ## the capture did not answer in time
    csUnknown         ## unparseable report

  WindowInfo* = object
    ## One row of `CGWindowListCopyWindowInfo`, as the helper reports it.
    ##
    ## `title` is `kCGWindowName`, which macOS **redacts** unless the calling
    ## code holds the ScreenCapture grant. `ownerName` is not redacted. A
    ## `WindowInfo` with an empty `title` therefore says nothing about whether
    ## the window has a title.
    windowId*: int
    ownerPid*: int
    ownerName*: string
    title*: string
    bounds*: array[4, int]   ## [x, y, w, h] in points, top-left origin
    layer*: int
    onScreen*: bool

  WindowQuery* = object
    ## How to select a window. An empty query is invalid for a capture; at
    ## least one of `windowId` / `owner` / `title` / `titleContains` must be set.
    windowId*: int           ## CoreGraphics window number; 0 means "unset"
    owner*: string           ## `kCGWindowOwnerName`, case-insensitive exact
    title*: string           ## exact `kCGWindowName`
    titleContains*: string   ## case-insensitive substring of `kCGWindowName`
    anyLayer*: bool          ## include non-zero window layers (panels, HUDs)
    includeOffscreen*: bool  ## include windows that are not on screen

  StillCaptureReport* = object
    ## Everything the helper attested about one invocation. `windowsSeen` is the
    ## positive control: it is the unprivileged `CGWindowListCopyWindowInfo`
    ## count, so a failure with `windowsSeen > 0` is a permission problem and
    ## the same failure with `windowsSeen == 0` is a dead GUI session.
    status*: CaptureStatus
    code*: int
    mode*: string
    outPath*: string
    width*, height*: int
    scale*: float
    windowsSeen*: int
    titlesVisible*: bool
    preflight*: bool
    candidates*: int
    windowId*: int
    windowOwner*: string
    windowTitle*: string
    windowBounds*: array[4, int]
    granted*: bool
    message*: string
    raw*: string             ## the report file verbatim, for diagnostics

  StillCaptureUnavailable* = object of CatchableError
    ## The host cannot provide still capture at all: not macOS, no `swiftc`,
    ## no helper source. Distinct from a denial — this one is not fixable by
    ## clicking anything.

  StillCaptureError* = object of CatchableError
    ## A capture that was attempted and failed.
    report*: StillCaptureReport

  StillCaptureDenied* = object of StillCaptureError
    ## TCC refused this code. Fixable by granting; see `grantInstructions`.

  StillCaptureTargetNotFound* = object of StillCaptureError
    ## No window matched the query, and the window list WAS readable.

const
  defaultCaptureBundleId* = "com.metacraft-labs.guiassert.capture"
  defaultCaptureAppName* = "GuiAssertCapture.app"
  captureHelperCacheName* = "gui_assert_screen_capture_helper"
  captureHelperBinName* = "screen_capture"

proc initWindowQuery*(windowId = 0, owner = "", title = "",
                      titleContains = "", anyLayer = false,
                      includeOffscreen = false): WindowQuery =
  ## Construct a `WindowQuery`. Prefer this over a raw object constructor so
  ## omitted fields keep their intended defaults.
  WindowQuery(windowId: windowId, owner: owner, title: title,
              titleContains: titleContains, anyLayer: anyLayer,
              includeOffscreen: includeOffscreen)

proc isEmpty*(q: WindowQuery): bool =
  ## True when the query names no target at all.
  q.windowId == 0 and q.owner.len == 0 and q.title.len == 0 and
    q.titleContains.len == 0

# ---------------------------------------------------------------------------
# Pure: status mapping
# ---------------------------------------------------------------------------

proc statusFromLabel*(label: string): CaptureStatus =
  ## Map the helper's `status=` word onto `CaptureStatus`. An unrecognised word
  ## becomes `csUnknown` rather than `csOk`: a report we cannot read must never
  ## be read as a success.
  case label.strip()
  of "ok": csOk
  of "usage": csUsage
  of "target-not-found": csTargetNotFound
  of "denied": csDenied
  of "capture-failed": csCaptureFailed
  of "write-failed": csWriteFailed
  of "timeout": csTimeout
  else: csUnknown

# ---------------------------------------------------------------------------
# Pure: report parsing
# ---------------------------------------------------------------------------

proc parseBoundsField(s: string): array[4, int] =
  result = [0, 0, 0, 0]
  let parts = s.split(',')
  if parts.len != 4: return
  for i in 0 .. 3:
    try:
      result[i] = parseInt(parts[i].strip())
    except ValueError:
      return [0, 0, 0, 0]

proc parseCaptureReport*(text: string): StillCaptureReport =
  ## Parse the helper's `key=value` report. Unknown keys are ignored; a missing
  ## `status` yields `csUnknown`.
  result = StillCaptureReport(status: csUnknown, code: -1, scale: 1.0, raw: text)
  for rawLine in text.splitLines:
    let line = rawLine.strip()
    if line.len == 0: continue
    let eq = line.find('=')
    if eq <= 0: continue
    let key = line[0 ..< eq]
    let val = line[eq + 1 .. ^1]
    template intVal(): int =
      (try: parseInt(val.strip()) except ValueError: 0)
    case key
    of "status": result.status = statusFromLabel(val)
    of "code": result.code = intVal()
    of "mode": result.mode = val
    of "out": result.outPath = val
    of "width": result.width = intVal()
    of "height": result.height = intVal()
    of "scale":
      result.scale = (try: parseFloat(val.strip()) except ValueError: 1.0)
    of "windows_seen": result.windowsSeen = intVal()
    of "titles_visible": result.titlesVisible = val.strip() == "1"
    of "preflight": result.preflight = val.strip() == "1"
    of "candidates": result.candidates = intVal()
    of "window_id": result.windowId = intVal()
    of "window_owner": result.windowOwner = val
    of "window_title": result.windowTitle = val
    of "window_bounds": result.windowBounds = parseBoundsField(val)
    of "granted": result.granted = val.strip() == "1"
    of "message": result.message = val
    else: discard

# ---------------------------------------------------------------------------
# Pure: window-list parsing and matching
# ---------------------------------------------------------------------------

proc parseWindowListTsv*(text: string): seq[WindowInfo] =
  ## Parse the helper's `enumerate` TSV:
  ##
  ##   windowId  ownerPid  ownerName  title  x  y  w  h  layer  onscreen
  ##
  ## Rows that do not have ten columns, or whose numeric columns do not parse,
  ## are skipped — a half-parsed window would be worse than a missing one.
  result = @[]
  for rawLine in text.splitLines:
    if rawLine.len == 0: continue
    let cols = rawLine.split('\t')
    if cols.len < 10: continue
    var w: WindowInfo
    try:
      w.windowId = parseInt(cols[0].strip())
      w.ownerPid = parseInt(cols[1].strip())
      w.ownerName = cols[2]
      w.title = cols[3]
      w.bounds[0] = parseInt(cols[4].strip())
      w.bounds[1] = parseInt(cols[5].strip())
      w.bounds[2] = parseInt(cols[6].strip())
      w.bounds[3] = parseInt(cols[7].strip())
      w.layer = parseInt(cols[8].strip())
      w.onScreen = cols[9].strip() == "1"
    except ValueError:
      continue
    result.add w

proc matchWindows*(windows: seq[WindowInfo], q: WindowQuery): seq[WindowInfo] =
  ## Apply `q` to `windows` and return the matches, largest-area first (and
  ## on-screen first among equal areas) — the same ordering the Swift helper
  ## uses, so the Nim side can attest the target the helper will pick.
  result = @[]
  for w in windows:
    if not q.anyLayer and w.layer != 0: continue
    if not q.includeOffscreen and not w.onScreen: continue
    if q.windowId != 0 and w.windowId != q.windowId: continue
    if q.owner.len > 0 and cmpIgnoreCase(w.ownerName, q.owner) != 0: continue
    if q.title.len > 0 and w.title != q.title: continue
    if q.titleContains.len > 0 and
       not w.title.toLowerAscii.contains(q.titleContains.toLowerAscii):
      continue
    result.add w
  result.sort(proc (a, b: WindowInfo): int =
    let aa = a.bounds[2] * a.bounds[3]
    let ba = b.bounds[2] * b.bounds[3]
    if aa != ba: return cmp(ba, aa)
    return cmp(ord(b.onScreen), ord(a.onScreen)))

# ---------------------------------------------------------------------------
# Pure: argv builder
# ---------------------------------------------------------------------------

proc buildHelperArgv*(mode: string, outPath = "", q = initWindowQuery(),
                      displayIndex = 0, timeoutMs = 20000,
                      reportPath = ""): seq[string] =
  ## Build the helper's argv. Pure and individually tested, in the same spirit
  ## as `capture.buildAvfoundationArgv`, so the command line can be asserted
  ## without a window server.
  result = @[mode]
  if outPath.len > 0:
    result.add "--out"
    result.add outPath
  if reportPath.len > 0:
    result.add "--report"
    result.add reportPath
  if mode == "display":
    result.add "--display"
    result.add $displayIndex
  if mode in ["window", "enumerate"]:
    if q.windowId != 0:
      result.add "--window-id"
      result.add $q.windowId
    if q.owner.len > 0:
      result.add "--owner"
      result.add q.owner
    if q.title.len > 0:
      result.add "--title"
      result.add q.title
    if q.titleContains.len > 0:
      result.add "--title-contains"
      result.add q.titleContains
  if q.anyLayer:
    result.add "--any-layer"
  if q.includeOffscreen:
    result.add "--include-offscreen"
  if mode in ["display", "window"]:
    result.add "--timeout"
    # Seconds, with one decimal: the helper bounds ITSELF so a denial can never
    # become a hang the way ffmpeg's avfoundation input does.
    result.add formatFloat(max(float(timeoutMs) / 1000.0, 1.0), ffDecimal, 1)

# ---------------------------------------------------------------------------
# Grant instructions
# ---------------------------------------------------------------------------

proc grantInstructions*(appPath = ""): string =
  ## The exact, clickable steps for granting the capture bundle its one-time
  ## ScreenCapture permission. Printed by every denial path so the remedy
  ## travels with the failure instead of living only in a document.
  ##
  ## Assembled line by line rather than as one triple-quoted block: a
  ## triple-quoted string interrupted by `& path &` silently drops the newline
  ## after the resumed quote, which wrapped "…to your terminal" across a line
  ## break and broke the sentence a test asserts on.
  let p = if appPath.len > 0: appPath
          else: "(run ensureCaptureApp to build it)"
  var lines = @[
    "GuiAssert still capture needs a one-time macOS Screen Recording grant",
    "for its own application bundle:",
    "",
    "    " & p,
    "",
    "Grant it ONCE, like this:",
    "",
    "  1. Open System Settings > Privacy & Security >",
    "     Screen & System Audio Recording",
    "  2. Click the  +  button (authenticate with Touch ID or your password).",
    "  3. In the file dialog press  Shift-Cmd-G  and paste exactly:",
    "       " & p,
    "  4. Select GuiAssertCapture.app and click Open.",
    "  5. Make sure its switch is ON.",
    "",
    "Nothing else needs to be granted.",
    "Do NOT grant Screen Recording to your terminal — the bundle exists",
    "precisely so the terminal does not need it.",
    "",
    "The grant is recorded against the bundle's code-signing designated",
    "requirement, not against its bytes, so rebuilding the helper does not",
    "revoke it (`ensureCaptureApp` verifies exactly that after every re-sign)."
  ]
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Host-dependent: everything below needs macOS
# ---------------------------------------------------------------------------

proc captureHelperSource*(): string =
  ## Path to the bundled Swift source. Honors `GUIASSERT_CAPTURE_HELPER_SRC`.
  let envSrc = getEnv("GUIASSERT_CAPTURE_HELPER_SRC")
  if envSrc.len > 0:
    return envSrc
  result = currentSourcePath().parentDir / "helpers" / "screen_capture.swift"

proc stillCaptureProbablyAvailable*(): bool =
  ## Cheap probe (no compilation, no signing): macOS + a resolvable `swiftc` +
  ## the helper source, or a prebuilt binary / bundle via the env overrides.
  when hostOS != "macosx":
    return false
  else:
    if getEnv("GUIASSERT_CAPTURE_APP").len > 0: return true
    if getEnv("GUIASSERT_CAPTURE_HELPER").len > 0: return true
    return resolveSwiftc().len > 0 and fileExists(captureHelperSource())

proc requireMacos(what: string) =
  when hostOS != "macosx":
    raise newException(StillCaptureUnavailable,
      what & " is macOS-only (ScreenCaptureKit). This host is " & hostOS & ".")
  else:
    discard

proc resolveCaptureHelper*(): string =
  ## Compile (or reuse) the raw ScreenCaptureKit helper binary and return its
  ## path. This binary is enough for `enumerate` / `preflight`, which need no
  ## TCC grant; the capture modes must go through the signed bundle instead.
  requireMacos("GuiAssert still capture")
  let prebuilt = getEnv("GUIASSERT_CAPTURE_HELPER")
  if prebuilt.len > 0:
    if fileExists(prebuilt): return prebuilt
    raise newException(StillCaptureUnavailable,
      "GUIASSERT_CAPTURE_HELPER points at " & prebuilt &
      " but no file exists there.")
  let src = captureHelperSource()
  if not fileExists(src):
    raise newException(StillCaptureUnavailable,
      "ScreenCaptureKit helper source not found: " & src &
      " (set GUIASSERT_CAPTURE_HELPER_SRC or GUIASSERT_CAPTURE_HELPER).")
  try:
    return compileSwiftHelper(captureHelperCacheName, captureHelperBinName, src)
  except SwiftHelperError as e:
    raise newException(StillCaptureUnavailable, e.msg)

# --- the signed application bundle ----------------------------------------

proc captureAppDir*(): string =
  ## Directory that holds `GuiAssertCapture.app`. Honors
  ## `GUIASSERT_CAPTURE_APP_DIR`; defaults to
  ## `~/Library/Application Support/GuiAssert`.
  ##
  ## Deliberately NOT the temp dir: the user grants the permission against a
  ## path they picked in a file dialog, and System Settings shows the app by
  ## path. A bundle that moves or is reaped leaves a confusing stale entry even
  ## though the grant itself is path-independent.
  let envDir = getEnv("GUIASSERT_CAPTURE_APP_DIR")
  if envDir.len > 0: return envDir
  result = getHomeDir() / "Library" / "Application Support" / "GuiAssert"

proc captureBundleId*(): string =
  let e = getEnv("GUIASSERT_CAPTURE_BUNDLE_ID")
  if e.len > 0: e else: defaultCaptureBundleId

proc captureAppPath*(): string =
  ## Full path of the capture bundle (built or not). Honors
  ## `GUIASSERT_CAPTURE_APP` as a complete override.
  let envApp = getEnv("GUIASSERT_CAPTURE_APP")
  if envApp.len > 0: return envApp
  result = captureAppDir() / defaultCaptureAppName

proc captureInfoPlist*(bundleId: string): string =
  ## The bundle's `Info.plist`. `LSUIElement` keeps the app out of the Dock and
  ## the app switcher — it is a one-shot capture tool, not something the user
  ## should see appear and vanish on every frame.
  result = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>""" & bundleId & """</string>
  <key>CFBundleName</key><string>GuiAssertCapture</string>
  <key>CFBundleDisplayName</key><string>GuiAssert Capture</string>
  <key>CFBundleExecutable</key><string>guiassert-capture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
"""

proc runCmd(cmd: string, args: seq[string], timeoutMs = 120_000):
    tuple[code: int, output: string] =
  ## Run `cmd`, merge stderr into stdout, and bound it with `timeout` ms.
  ## Nim's `waitForExit(p, timeout)` SIGKILLs the child when the deadline
  ## passes, which is exactly the external bound every capture-adjacent
  ## subprocess needs.
  var p: Process
  try:
    p = startProcess(command = cmd, args = args, options = {poStdErrToStdOut})
  except OSError as e:
    return (127, "cannot start " & cmd & ": " & e.msg)
  var code = -1
  try:
    code = p.waitForExit(timeoutMs)
  except OSError as e:
    code = -1
    p.close()
    return (code, "waiting for " & cmd & " failed: " & e.msg)
  let output =
    try: p.outputStream().readAll()
    except IOError, OSError: ""
  p.close()
  return (code, output)

proc detectSigningIdentity*(): string =
  ## Pick a code-signing identity for the bundle, or "-" for an ad-hoc
  ## signature. Honors `GUIASSERT_CAPTURE_SIGN_IDENTITY` (pass `-` to force
  ## ad-hoc). Otherwise prefers, in order:
  ##
  ##   1. `Developer ID Application:` — distributable
  ##   2. `Apple Development:`        — a free Apple ID provides one
  ##   3. `Apple Distribution:`
  ##   4. any other valid codesigning identity
  ##
  ## and falls back to "-" when the host has none. The ordering matters only
  ## for stability: all four give a certificate-keyed designated requirement
  ## (so the grant survives rebuilds) and "-" gives a cdhash-keyed one (so it
  ## does not).
  let forced = getEnv("GUIASSERT_CAPTURE_SIGN_IDENTITY")
  if forced.len > 0: return forced
  let (code, output) = runCmd("/usr/bin/security",
                              @["find-identity", "-v", "-p", "codesigning"],
                              30_000)
  if code != 0: return "-"
  var buckets: array[4, string]
  for line in output.splitLines:
    let q1 = line.find('"')
    if q1 < 0: continue
    let q2 = line.rfind('"')
    if q2 <= q1: continue
    let cn = line[q1 + 1 ..< q2]
    if cn.len == 0: continue
    let tier =
      if cn.startsWith("Developer ID Application:"): 0
      elif cn.startsWith("Apple Development:"): 1
      elif cn.startsWith("Apple Distribution:"): 2
      else: 3
    if buckets[tier].len == 0: buckets[tier] = cn
  for t in 0 .. 3:
    if buckets[t].len > 0: return buckets[t]
  return "-"

proc designatedRequirement*(appPath: string): string =
  ## `codesign -d -r-` for `appPath`, reduced to the requirement expression
  ## (the `designated => ` prefix stripped). "" when it cannot be read.
  let (code, output) = runCmd("/usr/bin/codesign",
                              @["-d", "-r-", appPath], 60_000)
  if code != 0: return ""
  for line in output.splitLines:
    let i = line.find("designated =>")
    if i >= 0:
      return line[i + len("designated =>") .. ^1].strip()
  return ""

proc satisfiesRequirement*(appPath, requirement: string): bool =
  ## True when `appPath`'s signature satisfies `requirement`. This is the same
  ## evaluation TCC performs against the `csreq` blob it stored at grant time,
  ## so it is the test for "does the recorded grant still apply to this build".
  if requirement.len == 0: return false
  let (code, _) = runCmd("/usr/bin/codesign",
                         @["--verify", "-R=" & requirement, appPath], 60_000)
  return code == 0

proc ensureCaptureApp*(force = false): string =
  ## Build, sign and return the path of `GuiAssertCapture.app`, rebuilding only
  ## when the compiled helper is newer than the bundled executable (or `force`).
  ##
  ## Signing arrangement and its consequence for the grant are documented in
  ## this module's header. After every re-sign this proc **verifies** that the
  ## bundle still satisfies the designated requirement recorded beside it on
  ## the first build, and raises if it does not — because that, and only that,
  ## is the condition under which the user's one-time approval stops applying.
  requireMacos("GuiAssert still capture")
  let envApp = getEnv("GUIASSERT_CAPTURE_APP")
  if envApp.len > 0:
    if dirExists(envApp): return envApp
    raise newException(StillCaptureUnavailable,
      "GUIASSERT_CAPTURE_APP points at " & envApp & " but no bundle is there.")

  let helper = resolveCaptureHelper()
  let app = captureAppPath()
  let macosDir = app / "Contents" / "MacOS"
  let exe = macosDir / "guiassert-capture"
  let plist = app / "Contents" / "Info.plist"
  let reqFile = app.parentDir / (defaultCaptureAppName & ".designated-requirement")
  let bundleId = captureBundleId()

  var needBuild = force or not fileExists(exe) or not fileExists(plist)
  if not needBuild:
    try:
      if getLastModificationTime(helper) > getLastModificationTime(exe):
        needBuild = true
    except OSError:
      needBuild = true
    if not needBuild and readFile(plist) != captureInfoPlist(bundleId):
      needBuild = true

  if needBuild:
    try:
      createDir(macosDir)
    except OSError as e:
      raise newException(StillCaptureUnavailable,
        "cannot create " & macosDir & ": " & e.msg)
    writeFile(plist, captureInfoPlist(bundleId))
    copyFile(helper, exe)
    setFilePermissions(exe, {fpUserExec, fpUserRead, fpUserWrite,
                             fpGroupExec, fpGroupRead,
                             fpOthersExec, fpOthersRead})
    let identity = detectSigningIdentity()
    var signArgs = @["--force", "--sign", identity,
                     "--identifier", bundleId, app]
    if identity != "-":
      # No --timestamp: a timestamp needs network reachability, and nothing
      # about the TCC requirement depends on one.
      signArgs = @["--force", "--sign", identity, "--identifier", bundleId,
                   "--timestamp=none", "--options", "runtime", app]
    let (sc, so) = runCmd("/usr/bin/codesign", signArgs, 180_000)
    if sc != 0:
      raise newException(StillCaptureUnavailable,
        "codesign failed for " & app & " with identity '" & identity &
        "' (" & $sc & "):\n" & so)
    let dr = designatedRequirement(app)
    if dr.len == 0:
      raise newException(StillCaptureUnavailable,
        "could not read the designated requirement of " & app &
        " after signing; refusing to pretend the grant is durable.")
    if not fileExists(reqFile):
      writeFile(reqFile, dr & "\n")
    else:
      let recorded = readFile(reqFile).strip()
      if not satisfiesRequirement(app, recorded):
        raise newException(StillCaptureUnavailable,
          "the rebuilt " & defaultCaptureAppName & " no longer satisfies the " &
          "designated requirement recorded at " & reqFile & ":\n  " & recorded &
          "\nIts current requirement is:\n  " & dr &
          "\nAny macOS Screen Recording grant given to the previous build no " &
          "longer applies. This happens when the bundle is signed ad-hoc " &
          "(`cdhash`-keyed) or with a different identity. Install a signing " &
          "identity, or set GUIASSERT_CAPTURE_SIGN_IDENTITY, then delete " &
          reqFile & " and re-grant once.\n\n" & grantInstructions(app))
  return app

# --- running the helper ----------------------------------------------------

proc raiseForReport(rep: StillCaptureReport, app: string) =
  ## Turn a non-ok report into the matching exception, with the remedy attached
  ## to the denial case.
  if rep.status == csOk: return
  var msg = "GuiAssert still capture failed: status=" & $rep.status &
            " code=" & $rep.code
  if rep.message.len > 0: msg &= "\n  " & rep.message
  msg &= "\n  windows_seen=" & $rep.windowsSeen &
         " titles_visible=" & (if rep.titlesVisible: "1" else: "0") &
         " preflight=" & (if rep.preflight: "1" else: "0")
  case rep.status
  of csDenied:
    var e = newException(StillCaptureDenied, msg & "\n\n" & grantInstructions(app))
    e.report = rep
    raise e
  of csTargetNotFound:
    var e = newException(StillCaptureTargetNotFound, msg)
    e.report = rep
    raise e
  else:
    var e = newException(StillCaptureError, msg)
    e.report = rep
    raise e

proc readReportFile(path: string): StillCaptureReport =
  if not fileExists(path):
    return StillCaptureReport(status: csUnknown, code: -1, scale: 1.0)
  result = parseCaptureReport(readFile(path))

proc runHelperDirect(args: seq[string], timeoutMs: int):
    tuple[code: int, output: string] =
  ## Run the raw helper as a child of this process. TCC attributes it to
  ## whatever is *responsible* for this process — in a terminal session, the
  ## terminal — so this route is only for the modes that need no grant.
  let helper = resolveCaptureHelper()
  result = runCmd(helper, args, timeoutMs)

proc runHelperViaApp*(args: seq[string], timeoutMs: int,
                      reportPath: string): StillCaptureReport =
  ## Run the helper **inside the signed bundle**, launched by launchd through
  ## `open`, so the bundle is its own TCC-responsible process rather than
  ## inheriting the terminal's (denied) identity.
  ##
  ## The caller owns `reportPath` and its siblings, including the enumerate
  ## TSV, and must remove them after consuming the result. Public operations
  ## below give these files invocation-scoped lifetimes.
  ##
  ## `open` gives us no exit status and no stdout from the app, which is why
  ## the report file is the authoritative channel. `-g` keeps the capture from
  ## stealing focus; `-n` forces a fresh instance; `-W` waits for it to exit.
  let app = ensureCaptureApp()
  removeFile(reportPath)
  var openArgs = @["-n", "-g", "-W", "-a", app, "--args"]
  for a in args: openArgs.add a
  # `open` itself must be bounded too: it is waiting on the app, and a wedged
  # app would otherwise wedge the test run.
  let (code, output) = runCmd("/usr/bin/open", openArgs, timeoutMs)
  if not fileExists(reportPath):
    var rep = StillCaptureReport(status: csUnknown, code: code, scale: 1.0)
    rep.message = "the capture bundle wrote no report at " & reportPath &
      "; `open` exited " & $code &
      (if output.len > 0: " with: " & output.strip() else: "") &
      ". The bundle is " & app
    return rep
  result = readReportFile(reportPath)

proc launchHelperDetached*(args: seq[string], timeoutMs = 30_000):
    tuple[code: int, output: string] =
  ## Start the helper **inside the signed bundle** without waiting for it to
  ## exit (`open -n -g` without `-W`), for the long-running `record` mode.
  ## `open` returns once LaunchServices has launched the app; the helper's
  ## own progress is reported through the files its arguments name. Returns
  ## `open`'s exit code and output.
  let app = ensureCaptureApp()
  var openArgs = @["-n", "-g", "-a", app, "--args"]
  for a in args: openArgs.add a
  result = runCmd("/usr/bin/open", openArgs, timeoutMs)

proc tempReportPath(tag: string): string =
  ## The report is an invocation's private transport, never a persistent log.
  ## Its caller removes the whole directory after consuming the report/TSV,
  ## including on failures, so partial writes cannot leave title-bearing files.
  let dir = createTempDir("gui_assert_capture_", "")
  result = dir / ("report_" & tag & ".txt")

# --- public capture API ----------------------------------------------------

proc listWindows*(q = initWindowQuery(), viaApp = false,
                  timeoutMs = 30_000): seq[WindowInfo] =
  ## Enumerate windows through `CGWindowListCopyWindowInfo`, then apply `q`.
  ##
  ## This is the **positive control** for everything else in this module: it
  ## needs no TCC grant, and on a live GUI session it returns real owner names.
  ## If it comes back empty, nothing else here can work and the cause is not
  ## permissions.
  ##
  ## `viaApp = true` runs the enumeration inside the signed bundle instead, so
  ## that `kCGWindowName` titles are visible **if** the bundle holds the grant.
  ## Window titles are redacted for ungranted code, so title-based matching
  ## needs either the grant or `viaApp`.
  requireMacos("listWindows")
  if viaApp:
    let reportPath = tempReportPath("enumerate")
    defer: removeDir(reportPath.parentDir)
    let args = buildHelperArgv("enumerate", q = q, reportPath = reportPath)
    let rep = runHelperViaApp(args, timeoutMs, reportPath)
    let tsv = reportPath & ".tsv"
    if rep.status != csOk and not fileExists(tsv):
      raiseForReport(rep, captureAppPath())
    if not fileExists(tsv): return @[]
    return matchWindows(parseWindowListTsv(readFile(tsv)), q)
  let args = buildHelperArgv("enumerate", q = q)
  let (code, output) = runHelperDirect(args, timeoutMs)
  let windows = parseWindowListTsv(output)
  if windows.len == 0 and code != 0:
    raise newException(StillCaptureError,
      "the window-list helper exited " & $code &
      " and listed no windows. This is NOT a TCC denial: " &
      "CGWindowListCopyWindowInfo needs no permission. Output:\n" & output)
  return matchWindows(windows, q)

proc screenCapturePreflight*(viaApp = true, timeoutMs = 30_000):
    StillCaptureReport =
  ## Ask whether the capture code currently holds the ScreenCapture grant,
  ## without attempting a capture. `viaApp = true` (the default) asks about the
  ## **bundle**, which is the subject that matters; `viaApp = false` asks about
  ## the raw helper as attributed to this process's responsible process.
  ##
  ## Returns the report either way — including a `csDenied` one — rather than
  ## raising, because "not granted yet" is the expected answer before the
  ## one-time approval and callers want to print the remedy, not a traceback.
  requireMacos("screenCapturePreflight")
  if viaApp:
    let reportPath = tempReportPath("preflight")
    defer: removeDir(reportPath.parentDir)
    let args = buildHelperArgv("preflight", reportPath = reportPath)
    return runHelperViaApp(args, timeoutMs, reportPath)
  let args = buildHelperArgv("preflight")
  let (_, output) = runHelperDirect(args, timeoutMs)
  return parseCaptureReport(output)

proc requestScreenCaptureAccess*(timeoutMs = 120_000): StillCaptureReport =
  ## Trigger the one-time system prompt for the **bundle**.
  ##
  ## macOS shows the prompt only when no decision is recorded for that code. If
  ## a denial is already recorded it silently answers false; the returned
  ## report then says so, and `grantInstructions` is the only way forward.
  requireMacos("requestScreenCaptureAccess")
  let reportPath = tempReportPath("request")
  defer: removeDir(reportPath.parentDir)
  let args = buildHelperArgv("request", reportPath = reportPath)
  return runHelperViaApp(args, timeoutMs, reportPath)

proc captureDisplayStill*(outPath: string, displayIndex = 0,
                          timeoutMs = 30_000): StillCaptureReport
                          {.discardable.} =
  ## Capture a full-display still into `outPath` (PNG) and return the helper's
  ## attestation. Raises `StillCaptureDenied` when TCC refuses,
  ## `StillCaptureUnavailable` when the host cannot do it at all.
  requireMacos("captureDisplayStill")
  let abs = absolutePath(outPath)
  createDir(abs.parentDir)
  let reportPath = tempReportPath("display")
  defer: removeDir(reportPath.parentDir)
  let args = buildHelperArgv("display", outPath = abs,
                             displayIndex = displayIndex,
                             timeoutMs = timeoutMs, reportPath = reportPath)
  let rep = runHelperViaApp(args, timeoutMs + 15_000, reportPath)
  raiseForReport(rep, captureAppPath())
  if not fileExists(abs):
    var e = newException(StillCaptureError,
      "the capture bundle reported ok but wrote no file at " & abs)
    e.report = rep
    raise e
  return rep

proc captureWindowStill*(outPath: string, q: WindowQuery,
                         timeoutMs = 30_000): StillCaptureReport
                         {.discardable.} =
  ## Capture one window's **own pixels** into `outPath` (PNG).
  ##
  ## `q` must name a target. The helper attests the chosen window against the
  ## unprivileged window list before capturing, so the returned report carries
  ## the window id, owner, title and CoreGraphics bounds it actually captured —
  ## which is what lets a test prove it got the window rather than a crop of
  ## the screen.
  requireMacos("captureWindowStill")
  if q.isEmpty:
    raise newException(ValueError,
      "captureWindowStill needs a target: set WindowQuery.windowId, .owner, " &
      ".title or .titleContains")
  let abs = absolutePath(outPath)
  createDir(abs.parentDir)
  let reportPath = tempReportPath("window")
  defer: removeDir(reportPath.parentDir)
  let args = buildHelperArgv("window", outPath = abs, q = q,
                             timeoutMs = timeoutMs, reportPath = reportPath)
  let rep = runHelperViaApp(args, timeoutMs + 15_000, reportPath)
  raiseForReport(rep, captureAppPath())
  if not fileExists(abs):
    var e = newException(StillCaptureError,
      "the capture bundle reported ok but wrote no file at " & abs)
    e.report = rep
    raise e
  return rep

# --- frame sources ---------------------------------------------------------

proc newDisplayFrameSource*(dir = "", displayIndex = 0,
                            timeoutMs = 30_000): proc(): string {.closure.} =
  ## A frame source closure (see `gui_assert.GuiAssertHarness`) that captures a
  ## fresh full-display still on every call and returns its path.
  ##
  ## Frames rotate through two alternating file names rather than one, so a
  ## consumer that still holds the previous path (an SSIM comparison against
  ## the last frame, say) is not reading a file being overwritten underneath it.
  let base = if dir.len > 0: dir else: createTempDir("gui_assert_frames_", "")
  createDir(base)
  var tick = 0
  result = proc(): string {.closure.} =
    let path = base / ("display_" & $(tick mod 2) & ".png")
    inc tick
    discard captureDisplayStill(path, displayIndex, timeoutMs)
    return path

proc newWindowFrameSource*(q: WindowQuery, dir = "",
                           timeoutMs = 30_000): proc(): string {.closure.} =
  ## A frame source closure that captures the targeted window's own pixels on
  ## every call. Same two-slot rotation as `newDisplayFrameSource`.
  let base = if dir.len > 0: dir else: createTempDir("gui_assert_frames_", "")
  createDir(base)
  var tick = 0
  let query = q
  result = proc(): string {.closure.} =
    let path = base / ("window_" & $(tick mod 2) & ".png")
    inc tick
    discard captureWindowStill(path, query, timeoutMs)
    return path

# ---------------------------------------------------------------------------
# Bridges to the pure core
# ---------------------------------------------------------------------------

proc boundsRect*(w: WindowInfo): Rect =
  ## The window's bounds as a core `Rect` (desktop points, top-left origin).
  rect(w.bounds)

proc windowBoundsRect*(rep: StillCaptureReport): Rect =
  ## The captured window's bounds from a report, as a core `Rect`.
  rect(rep.windowBounds)
