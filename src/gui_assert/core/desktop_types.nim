## GuiAssert core: the desktop object model.
##
## The objects every backend reports and every consumer reads: displays,
## windows, applications, sessions, captured images, recordings and input
## reports. Their shapes are the ones the `guiassert-desktop/1` contract
## serializes (spec §7.5); the one JSON serializer per object lives in
## `core/contract` (GS2), never in a backend.
##
## Coordinates follow spec §5: bounds and input positions are desktop
## coordinates (logical points); an `ImageRef` records the `origin` and
## `scale` that map its pixels back to them (`core/geometry`). A value the
## platform did not report is `none`, never a placeholder such as an empty
## string or 0, so "unknown" and "empty" stay distinguishable.

import std/[options, tables]

import ./geometry

type
  DesktopTypeError* = object of CatchableError
    ## Raised for an invalid name or an unknown enumeration spelling.

  Display* = object
    ## One display of a session.
    id*: string
    name*: Option[string]
    bounds*: Rect            ## desktop coordinates
    scale*: float            ## physical pixels per logical point
    primary*: bool
    isVirtual*: bool         ## exists only in software (`virtual` on the contract)

  Window* = object
    ## One top-level window, as the window server or compositor reports it
    ## (never the application's own account of itself).
    id*: string
    pid*: int
    app*: string
    appId*: Option[string]
    title*: Option[string]   ## none when the platform redacts it
    bounds*: Rect
    display*: Option[string]
    layer*: int
    onScreen*: bool
    focused*: bool
    minimized*: bool

  App* = object
    ## One running application.
    pid*: int
    name*: string
    bundleId*: Option[string]
    appId*: Option[string]
    frontmost*: bool
    hidden*: bool

  Isolation* = object
    ## Which properties a session isolates from the host session; each is
    ## true only when it holds for that session kind on that platform.
    pixels*: bool
    input*: bool
    clipboard*: bool

  SessionKind* = enum
    skHost = "host"
    skVirtualDisplay = "virtual-display"
    skIsolated = "isolated"
    skHeadless = "headless"

  SessionPlatform* = enum
    spMacos = "macos"
    spLinux = "linux"
    spWindows = "windows"
    spFixture = "fixture"

  SessionState* = enum
    ssStarting = "starting"
    ssRunning = "running"
    ssStopping = "stopping"
    ssStopped = "stopped"
    ssError = "error"

  SessionLifetime* = enum
    slDetached = "detached"
    slOwner = "owner"

  VncEndpoint* = object
    host*: string
    port*: int

  SessionBackends* = object
    ## The capture, tree and input backends a session was started with.
    capture*: string
    tree*: string
    input*: string

  Session* = object
    ## A desktop GuiAssert can capture, read and drive (spec §6).
    id*: string
    name*: Option[string]
    kind*: SessionKind
    backend*: string
    platform*: SessionPlatform
    state*: SessionState
    stateReason*: Option[string]
    lifetime*: SessionLifetime
    isolation*: Isolation
    displays*: seq[Display]
    env*: OrderedTable[string, string]
    vnc*: Option[VncEndpoint]
    backends*: SessionBackends
    createdAt*: string       ## RFC 3339 UTC with milliseconds
    hostPid*: Option[int]

  ImageSourceKind* = enum
    iskDisplay = "display"
    iskWindow = "window"
    iskWindowCrop = "window-crop"  ## a display capture cropped to a window
    iskRegion = "region"
    iskFile = "file"

  ImageSource* = object
    ## What an image or recording was captured from.
    kind*: ImageSourceKind
    id*: Option[string]
    session*: Option[string]

  ImageRef* = object
    ## A captured image on disk.
    path*: string
    format*: string          ## always "png" in contract version 1
    width*, height*: int     ## physical pixels
    scale*: float            ## physical pixels per logical point
    origin*: Point           ## desktop coordinates of the top-left pixel
    sha256*: string
    capturedAt*: string
    source*: ImageSource

  RecordingState* = enum
    rsRecording = "recording"
    rsStopped = "stopped"
    rsFailed = "failed"

  RecordingFormat* = enum
    rfMp4 = "mp4"
    rfPngSequence = "png-sequence"

  Recording* = object
    id*: string
    path*: string
    state*: RecordingState
    format*: RecordingFormat
    width*, height*: int
    fps*: float
    durationMs*: Option[int]
    frames*: Option[int]
    source*: ImageSource
    startedAt*: string
    stoppedAt*: Option[string]

  Delivery* = enum
    ## How input reached the target.
    dInjected = "injected"   ## through the system input stream
    dPosted = "posted"       ## posted to the target window's queue

  InputReport* = object
    ## What an input verb delivered (never what the application did with it).
    ## Typed text is reported by `length` only, never echoed.
    kind*: string
    at*: Option[Point]
    to*: Option[Point]
    button*: Option[string]
    count*: Option[int]
    length*: Option[int]
    keys*: Option[string]
    delivery*: Delivery
    session*: string

  PermissionState* = enum
    ## What the operating system says about one permission.
    psGranted = "granted"
    psDenied = "denied"
    psNotDetermined = "not-determined"
    psNotApplicable = "not-applicable"
    psUnknown = "unknown"

  Permissions* = object
    ## The permissions the substrate's work depends on, and the code
    ## identity (bundle or binary) the operating system evaluates them for.
    screenRecording*: PermissionState
    accessibility*: PermissionState
    inputSynthesis*: PermissionState
    desktopAccess*: PermissionState
    identity*: Option[string]

  FeatureState* = enum
    ## How far a backend can provide a feature on this host.
    fsSupported = "supported"      ## probed and working
    fsAvailable = "available"      ## present, not actively probed
    fsDegraded = "degraded"        ## works with a stated limitation
    fsUnavailable = "unavailable"  ## cannot be used here

  Feature* = object
    ## One entry of the `capabilities` report.
    feature*: string
    backend*: string
    state*: FeatureState
    reason*: Option[string]
    remedy*: Option[string]

const
  hostSessionId* = "host"
    ## The reserved id of the caller's own session, which always exists.
  maxNameLen* = 64

proc isValidName*(s: string): bool =
  ## True when `s` may name a session or a recording, i.e. matches
  ## `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` (spec §7.4). Such names become file
  ## names, so anything else is refused rather than sanitized: two names must
  ## never map to one record.
  if s.len == 0 or s.len > maxNameLen: return false
  if s[0] notin {'A'..'Z', 'a'..'z', '0'..'9'}: return false
  for c in s:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}: return false
  true

proc checkName*(s: string) =
  ## Raise `DesktopTypeError` unless `isValidName(s)`.
  if not isValidName(s):
    raise newException(DesktopTypeError,
      "invalid name '" & s & "': names match [A-Za-z0-9][A-Za-z0-9._-]{0,63}")

proc parseEnumValue*[T: enum](s: string): T =
  ## The member of `T` whose contract spelling is `s`. Raises
  ## `DesktopTypeError` for any other string (no case folding, no prefix
  ## match).
  for v in T:
    if $v == s: return v
  raise newException(DesktopTypeError,
    "'" & s & "' is not a valid " & $T)

proc hostIsolation*(): Isolation =
  ## The host session isolates nothing from itself.
  Isolation(pixels: false, input: false, clipboard: false)
