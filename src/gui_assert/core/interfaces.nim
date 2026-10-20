## GuiAssert core: the backend interfaces.
##
## Each module of the substrate (capture, OCR, accessibility tree, input,
## sessions) is an object of procs. A backend module under
## `gui_assert/backends/` exposes a constructor that returns one of these
## objects, so:
##
## * the core never imports a backend, and a backend never imports the CLI;
## * nothing is registered as a side effect of an import: an application gets
##   a backend only by calling its constructor;
## * a backend that does not apply to the compile target still compiles, and
##   its constructor returns an object whose every operation raises
##   `BackendUnavailableError` with reason `wrong-platform` (spec §3.3).
##
## Every operation either does exactly what it was asked or raises; none
## returns a "could not" value a caller might overlook, and none substitutes a
## different operation without saying so in its result (spec §2, "reject,
## don't drop").

import std/options

import ./[geometry, desktop_types, ocr_types, tree_types]

type
  BackendError* = object of CatchableError
    ## A backend operation failed. `backend` names the backend; `reason` is
    ## the contract's machine-readable reason (spec §7.3).
    backend*: string
    reason*: string
    remedy*: string          ## what the operator can do; "" when nothing

  BackendUnavailableError* = object of BackendError
    ## The backend cannot perform the operation on this host: reasons
    ## include `wrong-platform`, `missing-tool`, `not-compiled-in` and
    ## `unsupported-option`.

  PermissionDeniedError* = object of BackendError
    ## The operating system refused the operation (for example a missing
    ## Screen Recording or Accessibility grant on macOS). `reason` names the
    ## permission.

  BackendNotFoundError* = object of BackendError
    ## The target of the operation (a window, display, element or session)
    ## does not exist. `reason` names what was looked for.

  CaptureTargetKind* = enum
    ctkDisplay = "display"
    ctkWindow = "window"
    ctkRegion = "region"

  CaptureTarget* = object
    ## What to capture. With `ctkDisplay` and no `id`, the session's primary
    ## display.
    case kind*: CaptureTargetKind
    of ctkDisplay, ctkWindow:
      id*: Option[string]
    of ctkRegion:
      region*: Rect          ## desktop coordinates

  CaptureRequest* = object
    session*: string
    target*: CaptureTarget
    outPath*: string         ## where the PNG is written; required
    ownPixels*: bool         ## a window's own pixels, never a display crop
    cursor*: bool

  RecordRequest* = object
    session*: string
    target*: CaptureTarget
    outPath*: string
    fps*: float
    durationMs*: Option[int] ## none: until stopped

  WindowFilter* = object
    ## The `windows` verb's query. Unset criteria match everything.
    app*: Option[string]
    pid*: Option[int]
    title*: Option[string]
    titleContains*: Option[string]
    allLayers*: bool
    includeOffscreen*: bool

  WindowList* = object
    windows*: seq[Window]    ## front to back
    titlesVisible*: bool     ## false when the platform redacted titles

  CaptureBackend* = object
    ## Displays, windows, still capture and recording.
    name*: string
    displays*: proc (session: string): seq[Display] {.closure.}
    windows*: proc (session: string, filter: WindowFilter): WindowList {.closure.}
    capture*: proc (req: CaptureRequest): ImageRef {.closure.}
    startRecording*: proc (req: RecordRequest): Recording {.closure.}
    stopRecording*: proc (id: string): Recording {.closure.}
    recordings*: proc (): seq[Recording] {.closure.}
    features*: proc (probe: bool): seq[Feature] {.closure.}
    screenRecording*: proc (probe: bool):
        tuple[state: PermissionState, identity: Option[string]] {.closure.}
      ## The Screen Recording permission as this backend's capture code holds
      ## it, and the code identity the operating system evaluates (added with
      ## the macOS capture backends, GS5). Nil for a backend that captures
      ## through no permission of its own; `capabilities` then reports what
      ## the session backend says. Without `probe` a backend may answer
      ## `unknown` rather than run an active check.

  OcrRequest* = object
    imagePath*: string
    languages*: seq[string]
    psm*: Option[int]
    upscale*: Option[float]
    invert*: Option[OcrInvert]
    minConfidence*: Option[float]

  OcrEngine* = object
    ## Text recognition on an image file. An engine that has no equivalent of
    ## a requested option raises `BackendUnavailableError`
    ## (`unsupported-option`) instead of ignoring it.
    name*: string
    recognize*: proc (req: OcrRequest): OcrResult {.closure.}
    validate*: proc (req: OcrRequest) {.closure.}
      ## Raise for an option of `req` the engine cannot honour, running
      ## nothing and reading no image, so a verb can refuse it before it
      ## captures the frame to read (added with the platform engines, GS6).
      ## `recognize` checks the same options itself. Nil: every option is
      ## checked only by `recognize`.
    features*: proc (probe: bool): seq[Feature] {.closure.}

  TreeTargetKind* = enum
    ttkPid, ttkApp, ttkWindow, ttkFocused

  TreeTarget* = object
    case kind*: TreeTargetKind
    of ttkPid: pid*: int
    of ttkApp: app*: string
    of ttkWindow: windowId*: string
    of ttkFocused: discard

  TreeRead* = object
    root*: Node
    nodeCount*: int
    truncated*: bool

  TreeBackend* = object
    ## Accessibility trees: read, search, and act on elements.
    name*: string
    tree*: proc (session: string, target: TreeTarget, depth: Option[int],
                 maxNodes: int): TreeRead {.closure.}
    find*: proc (session: string, target: Option[TreeTarget],
                 filter: ElementFilter,
                 limit: int): tuple[elements: seq[Node], truncated: bool] {.closure.}
    element*: proc (session, path: string): Node {.closure.}
    perform*: proc (session, path: string, action: NodeAction,
                    value: Option[string]): Node {.closure.}
    features*: proc (probe: bool): seq[Feature] {.closure.}

  MouseButton* = enum
    mbLeft = "left"
    mbRight = "right"
    mbMiddle = "middle"

  ScrollUnit* = enum
    suLine = "line"
    suPixel = "pixel"

  InputBackend* = object
    ## Synthesized input at desktop coordinates. Each operation reports what
    ## it delivered.
    name*: string
    move*: proc (session: string, to: Point): InputReport {.closure.}
    click*: proc (session: string, at: Point, button: MouseButton, count: int,
                  modifiers: seq[string]): InputReport {.closure.}
    drag*: proc (session: string, path: seq[Point], button: MouseButton,
                 steps: int, durationMs: int): InputReport {.closure.}
      ## Press at `path[0]`, move through every later point in order with the
      ## button held (`steps` pointer events per segment, `durationMs` over
      ## the whole drag), release at the last point. `path` has at least two
      ## points: `--from`, the `--path` waypoints, `--to`.
    scroll*: proc (session: string, at: Point, dx, dy: int,
                   unit: ScrollUnit): InputReport {.closure.}
    typeText*: proc (session: string, text: string,
                     intervalMs: int): InputReport {.closure.}
    key*: proc (session: string, combo: string): InputReport {.closure.}
      ## `combo` is already normalized (`core/keys.normalizeCombo`).
    focusWindow*: proc (session, windowId: string): Window {.closure.}
    setWindowBounds*: proc (session, windowId: string,
                            bounds: Rect): Window {.closure.}
      ## Returns the window with the bounds the window server reports after
      ## the change, which may differ from `bounds`.
    features*: proc (probe: bool): seq[Feature] {.closure.}

  SessionSpec* = object
    ## A `session-start` request.
    kind*: SessionKind
    name*: Option[string]
    size*: Option[Size]
    scale*: Option[float]
    displays*: int
    lifetime*: SessionLifetime
    vnc*: bool
    account*: Option[string]

  LaunchKind* = enum
    lkBundleId, lkAppPath, lkArgv

  LaunchSpec* = object
    ## An `app-launch` request.
    case kind*: LaunchKind
    of lkBundleId: bundleId*: string
    of lkAppPath: appPath*: string
    of lkArgv: argv*: seq[string]
    waitWindowMs*: Option[int]
      ## Wait this long for the first window; when it expires with the
      ## process still running, the launch fails with `timeout` /
      ## `condition-not-met` carrying the `App` (spec §7.5).
    env*: seq[(string, string)]
      ## `--env KEY=VALUE`, merged over `Session.env` (later wins).

  LaunchReport* = object
    app*: App
    window*: Option[Window]      ## none when no window appeared in time

  QuitReport* = object
    pid*: int
    exited*: bool
    exitCode*: Option[int]

  SessionBackend* = object
    ## Starting, listing and stopping sessions, and the applications and
    ## permissions of a session.
    name*: string
    start*: proc (spec: SessionSpec): Session {.closure.}
    list*: proc (): seq[Session] {.closure.}
    info*: proc (id: string): Session {.closure.}
    stop*: proc (id: string, force: bool): Session {.closure.}
    apps*: proc (session: string): seq[App] {.closure.}
    launch*: proc (session: string, spec: LaunchSpec): LaunchReport {.closure.}
    quit*: proc (session: string, pid: int, force: bool): QuitReport {.closure.}
    permissions*: proc (request: Option[string]): Permissions {.closure.}
      ## The current permission states; `request` names a permission whose
      ## operating-system prompt to show first (never bypassed).
    features*: proc (probe: bool): seq[Feature] {.closure.}

proc newBackendError*[T: BackendError](_: typedesc[T], backend, reason,
                                       msg: string): ref T =
  ## Build a backend error of type `T`, its message prefixed with the
  ## backend and the reason so a log line is self-describing.
  result = newException(T, backend & ": " & reason & ": " & msg)
  result.backend = backend
  result.reason = reason

proc unavailable*(backend, reason, msg: string): ref BackendUnavailableError =
  ## Shorthand for a `BackendUnavailableError`.
  newBackendError(BackendUnavailableError, backend, reason, msg)
