## The `macos-cgwindow` capture backend: displays and windows of the macOS
## window server, read in-process through CoreGraphics (spec §4.1).
##
## It is the **unprivileged positive control** of the macOS capture stack:
## `CGWindowListCopyWindowInfo` and the `CGDisplay` calls need no TCC grant,
## so a live suite that cannot enumerate windows here has a dead GUI session,
## not a missing permission. It captures nothing: `screenshot` and the
## recording verbs are `backend-unavailable` / `not-implemented` with the
## feature they lack, and `macos-sck` (the default) is the backend that
## captures. `macos-sck` reuses this module's enumeration.
##
## What the window server tells, and what this backend reports:
##
## * **Titles.** `kCGWindowName` is redacted for code that holds no Screen
##   Recording grant. Whether the grant is held is asked directly
##   (`CGPreflightScreenCaptureAccess`, which never prompts) rather than
##   inferred from whether some title happened to be readable; without it
##   every `title` is `null` and `titlesVisible` is false (spec §7.5). The
##   grant that counts here is the one of the process running this code
##   (for the one-shot CLI, the process TCC holds responsible for it).
## * **Order.** Front to back, the order `CGWindowListCopyWindowInfo` returns.
## * **`focused`.** The frontmost layer-0 on-screen window of the frontmost
##   application (`NSWorkspace.frontmostApplication`). CoreGraphics has no
##   key-window notion of its own; the accessibility backend (GS7) can say
##   more.
## * **`minimized`.** Always false: CoreGraphics reports a minimized window
##   only as off screen, indistinguishable from one on another Space. A
##   window that is not on screen is reported `onScreen: false`.
## * **`document`.** Always null here: macOS names a window's document
##   through `AXDocument`, which belongs to the accessibility backend (C4,
##   GS7).
## * **`appId`.** The application's bundle identifier (`NSRunningApplication`),
##   null for a process that has none.
## * **Displays.** The online displays that mirror no other; `bounds` in
##   global points, `scale` the current mode's pixels per point, `primary`
##   the main display. `name` is null (CoreGraphics has no display names)
##   and `virtual` false: a virtual display this backend did not create
##   cannot be told apart.
##
## Pure parts (`assembleWindows`, `displayOf`) are exported and unit tested
## on every host; the bindings are compiled on macOS only, and elsewhere the
## constructor returns a backend whose every operation is `wrong-platform`
## (spec §3.3).

import std/[math, options, strutils]

import ../../core/[geometry, desktop_types, interfaces]

const macosCgwindowName* = "macos-cgwindow"
  ## The backend's contract name.

type
  CgWindowRow* = object
    ## One entry of `CGWindowListCopyWindowInfo`, as read.
    id*: int
    pid*: int
    owner*: string               ## `kCGWindowOwnerName`
    title*: Option[string]       ## `kCGWindowName` when present
    bounds*: Rect                ## global points, top-left origin
    layer*: int
    onScreen*: bool
    bundleId*: Option[string]

  CgSnapshot* = object
    ## Everything one enumeration read, before any filtering.
    rows*: seq[CgWindowRow]      ## front to back
    displays*: seq[Display]
    frontPid*: int               ## frontmost application; 0 when unknown
    titlesVisible*: bool         ## the reading code holds Screen Recording

# ---------------------------------------------------------------------------
# Pure: assembling the contract objects
# ---------------------------------------------------------------------------

proc displayOf*(bounds: Rect, displays: seq[Display]): Option[string] =
  ## The display holding the largest part of `bounds`; none when it lies on
  ## no display (an off-screen window).
  var best = 0
  for d in displays:
    let a = intersection(bounds, d.bounds).area
    if a > best:
      best = a
      result = some(d.id)

proc assembleWindows*(snap: CgSnapshot, filter: WindowFilter): WindowList =
  ## The `windows` answer for `filter` from one snapshot (module doc): front
  ## to back, titles null unless visible, the focused window marked, and
  ## `--title` / `--title-contains` matching nothing while titles are
  ## redacted (a redacted title is not an empty one).
  result.titlesVisible = snap.titlesVisible
  var focusedId = -1
  if snap.frontPid > 0:
    for r in snap.rows:
      if r.pid == snap.frontPid and r.layer == 0 and r.onScreen:
        focusedId = r.id
        break
  for r in snap.rows:
    if not filter.allLayers and r.layer != 0: continue
    if not filter.includeOffscreen and not r.onScreen: continue
    if filter.app.isSome and r.owner != filter.app.get: continue
    if filter.pid.isSome and r.pid != filter.pid.get: continue
    let title = if snap.titlesVisible: r.title else: none(string)
    if filter.title.isSome or filter.titleContains.isSome:
      if title.isNone: continue
      if filter.title.isSome and title.get != filter.title.get: continue
      if filter.titleContains.isSome and filter.titleContains.get notin title.get:
        continue
    result.windows.add Window(id: $r.id, pid: r.pid, app: r.owner,
      appId: r.bundleId, title: title, document: none(string), bounds: r.bounds,
      display: displayOf(r.bounds, snap.displays), layer: r.layer,
      onScreen: r.onScreen, focused: r.id == focusedId, minimized: false)

proc enumerationOnly(op: string): ref BackendUnavailableError =
  unavailable(macosCgwindowName, "not-implemented", "the macos-cgwindow backend " &
    "enumerates displays and windows only; it cannot " & op &
    " (select the macos-sck capture backend)")

# ---------------------------------------------------------------------------
# macOS bindings
# ---------------------------------------------------------------------------

when defined(macosx):
  import std/dynlib

  {.passL: "-framework CoreGraphics -framework CoreFoundation".}

  # Declared without headers, with C-ABI-equivalent types, so this module
  # needs no SDK header search path. CF and CG "Ref" types are pointers.
  type
    CGPointC {.bycopy.} = object
      x, y: float64
    CGSizeC {.bycopy.} = object
      width, height: float64
    CGRectC {.bycopy.} = object
      origin: CGPointC
      size: CGSizeC

  const
    kCGWindowListOptionAll = 0'u32
    kCGWindowListOptionOnScreenOnly = 1'u32
    kCGWindowListExcludeDesktopElements = 16'u32
    kCGNullWindowID = 0'u32
    kCFNumberSInt64Type = 4'i32
    kCFStringEncodingUTF8 = 0x08000100'u32
    maxDisplays = 32'u32

  var
    kCGWindowNumber {.importc.}: pointer
    kCGWindowOwnerPID {.importc.}: pointer
    kCGWindowOwnerName {.importc.}: pointer
    kCGWindowName {.importc.}: pointer
    kCGWindowLayer {.importc.}: pointer
    kCGWindowIsOnscreen {.importc.}: pointer
    kCGWindowBounds {.importc.}: pointer

  proc CGWindowListCopyWindowInfo(option, relativeTo: uint32): pointer {.importc, cdecl.}
  proc CGRectMakeWithDictionaryRepresentation(dict: pointer, rect: ptr CGRectC): bool {.importc, cdecl.}
  proc CGPreflightScreenCaptureAccess(): bool {.importc, cdecl.}
  proc CGGetOnlineDisplayList(maxDisplays: uint32, displays: ptr uint32,
                              count: ptr uint32): int32 {.importc, cdecl.}
  proc CGDisplayMirrorsDisplay(display: uint32): uint32 {.importc, cdecl.}
  proc CGMainDisplayID(): uint32 {.importc, cdecl.}
  proc CGDisplayBounds(display: uint32): CGRectC {.importc, cdecl.}
  proc CGDisplayCopyDisplayMode(display: uint32): pointer {.importc, cdecl.}
  proc CGDisplayModeGetPixelWidth(mode: pointer): csize_t {.importc, cdecl.}
  proc CGDisplayModeGetWidth(mode: pointer): csize_t {.importc, cdecl.}
  proc CGDisplayModeRelease(mode: pointer) {.importc, cdecl.}
  proc CFArrayGetCount(a: pointer): int {.importc, cdecl.}
  proc CFArrayGetValueAtIndex(a: pointer, i: int): pointer {.importc, cdecl.}
  proc CFDictionaryGetValue(d, key: pointer): pointer {.importc, cdecl.}
  proc CFNumberGetValue(n: pointer, kind: int32, value: pointer): uint8 {.importc, cdecl.}
  proc CFBooleanGetValue(b: pointer): uint8 {.importc, cdecl.}
  proc CFStringGetLength(s: pointer): int {.importc, cdecl.}
  proc CFStringGetMaximumSizeForEncoding(length: int, encoding: uint32): int {.importc, cdecl.}
  proc CFStringGetCString(s: pointer, buf: cstring, size: int,
                          encoding: uint32): uint8 {.importc, cdecl.}
  proc CFRelease(p: pointer) {.importc, cdecl.}
  proc CGSessionCopyCurrentDictionary(): pointer {.importc, cdecl.}
  proc CFStringCreateWithCString(alloc: pointer, s: cstring,
                                 encoding: uint32): pointer {.importc, cdecl.}

  # The Objective-C runtime, for the two AppKit facts CoreGraphics lacks
  # (the frontmost application, a process's bundle identifier). AppKit is
  # loaded on first use rather than linked, so a `guiassert` invocation that
  # never enumerates windows does not pay for loading it.
  proc objc_getClass(name: cstring): pointer {.importc, cdecl.}
  proc sel_registerName(name: cstring): pointer {.importc, cdecl.}
  proc objc_msgSend() {.importc, cdecl.}
  proc objc_autoreleasePoolPush(): pointer {.importc, cdecl.}
  proc objc_autoreleasePoolPop(pool: pointer) {.importc, cdecl.}

  type
    MsgId = proc (self, op: pointer): pointer {.cdecl.}
    MsgIdPid = proc (self, op: pointer, pid: int32): pointer {.cdecl.}
    MsgInt = proc (self, op: pointer): int32 {.cdecl.}
    MsgCStr = proc (self, op: pointer): cstring {.cdecl.}

  proc appKitLoaded(): bool =
    ## Load AppKit once per process (dlopen is reference counted; the
    ## handle is deliberately never closed).
    let h = loadLib("/System/Library/Frameworks/AppKit.framework/AppKit")
    h != nil

  proc cfString(s: pointer): Option[string] =
    if s == nil: return none(string)
    let n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s),
                                              kCFStringEncodingUTF8) + 1
    var buf = newString(n)
    if CFStringGetCString(s, cstring(buf), n, kCFStringEncodingUTF8) == 0:
      return none(string)
    some($cstring(buf))

  proc cfInt(n: pointer): int =
    if n == nil: return 0
    var v: int64
    if CFNumberGetValue(n, kCFNumberSInt64Type, addr v) == 0: return 0
    int(v)

  proc nsString(s: pointer): Option[string] =
    if s == nil: return none(string)
    let utf8 = cast[MsgCStr](objc_msgSend)(s, sel_registerName("UTF8String"))
    if utf8 == nil: none(string) else: some($utf8)

  proc frontmostPid(): int =
    ## The pid of `NSWorkspace.sharedWorkspace.frontmostApplication`, or 0.
    if not appKitLoaded(): return 0
    let pool = objc_autoreleasePoolPush()
    defer: objc_autoreleasePoolPop(pool)
    let ws = cast[MsgId](objc_msgSend)(objc_getClass("NSWorkspace"),
                                       sel_registerName("sharedWorkspace"))
    if ws == nil: return 0
    let app = cast[MsgId](objc_msgSend)(ws, sel_registerName("frontmostApplication"))
    if app == nil: return 0
    int(cast[MsgInt](objc_msgSend)(app, sel_registerName("processIdentifier")))

  proc bundleIdOf(pid: int): Option[string] =
    ## `NSRunningApplication(processIdentifier:).bundleIdentifier`.
    if pid <= 0 or not appKitLoaded(): return none(string)
    let pool = objc_autoreleasePoolPush()
    defer: objc_autoreleasePoolPop(pool)
    let app = cast[MsgIdPid](objc_msgSend)(objc_getClass("NSRunningApplication"),
      sel_registerName("runningApplicationWithProcessIdentifier:"), int32(pid))
    if app == nil: return none(string)
    nsString(cast[MsgId](objc_msgSend)(app, sel_registerName("bundleIdentifier")))

  proc toRect(r: CGRectC): Rect =
    # Points are integral for every window and display the window server
    # reports; round rather than truncate so a fractional value cannot
    # shrink a rectangle by one.
    rect(int(round(r.origin.x)), int(round(r.origin.y)),
         int(round(r.size.width)), int(round(r.size.height)))

  proc readDisplays*(): seq[Display] =
    ## The active displays (module doc). Raises `BackendError` /
    ## `capture-failed` when CoreGraphics cannot list them.
    # The ONLINE list, not the active one: measured on macOS 26.5 (build
    # 25F84), CGGetActiveDisplayList fails with no displays in a process of
    # the Background launchd session (a terminal multiplexer started outside
    # the GUI login, say), while the online list, CGMainDisplayID and window
    # enumeration all answer. Online displays that mirror another one are
    # the same desktop area and are left out, as are ones with no extent.
    var ids: array[int(maxDisplays), uint32]
    var count: uint32
    if CGGetOnlineDisplayList(maxDisplays, addr ids[0], addr count) != 0:
      raise newBackendError(BackendError, macosCgwindowName, "capture-failed",
        "CGGetOnlineDisplayList failed")
    let main = CGMainDisplayID()
    for i in 0 ..< int(count):
      let id = ids[i]
      if CGDisplayMirrorsDisplay(id) != 0: continue
      if toRect(CGDisplayBounds(id)).isEmpty: continue
      var scale = 1.0
      let mode = CGDisplayCopyDisplayMode(id)
      if mode != nil:
        let pw = float(CGDisplayModeGetPixelWidth(mode))
        let w = float(CGDisplayModeGetWidth(mode))
        if w > 0 and pw > 0: scale = pw / w
        CGDisplayModeRelease(mode)
      result.add Display(id: $id, name: none(string),
                         bounds: toRect(CGDisplayBounds(id)), scale: scale,
                         primary: id == main, isVirtual: false)

  proc screenLocked*(): bool =
    ## True when the GUI login session's screen is locked
    ## (`CGSSessionScreenIsLocked` of `CGSessionCopyCurrentDictionary`).
    ## ScreenCaptureKit captures nothing then (measured on macOS 26.5: it
    ## lists no displays and fails window captures with
    ## SCStreamErrorDomain -3811), so a failed capture names the lock.
    let d = CGSessionCopyCurrentDictionary()
    if d == nil: return false
    defer: CFRelease(d)
    let key = CFStringCreateWithCString(nil, "CGSSessionScreenIsLocked",
                                        kCFStringEncodingUTF8)
    if key == nil: return false
    defer: CFRelease(key)
    let v = CFDictionaryGetValue(d, key)
    v != nil and CFBooleanGetValue(v) != 0

  proc screenRecordingPreflight*(): bool =
    ## Whether the code running this process holds Screen Recording, as TCC
    ## answers without prompting.
    CGPreflightScreenCaptureAccess()

  proc readSnapshot*(includeOffscreen: bool): CgSnapshot =
    ## One enumeration of the window server (module doc). Raises
    ## `BackendError` / `capture-failed` when it answers nothing at all,
    ## which means there is no GUI session to enumerate, never a missing
    ## permission (enumeration needs none).
    result.titlesVisible = CGPreflightScreenCaptureAccess()
    result.displays = readDisplays()
    result.frontPid = frontmostPid()
    let opts = kCGWindowListExcludeDesktopElements or
      (if includeOffscreen: kCGWindowListOptionAll else: kCGWindowListOptionOnScreenOnly)
    let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
    if arr == nil:
      raise newBackendError(BackendError, macosCgwindowName, "capture-failed",
        "CGWindowListCopyWindowInfo answered nothing: there is no GUI session " &
        "to enumerate (this is not a permission problem)")
    defer: CFRelease(arr)
    var bundles: seq[(int, Option[string])]
    for i in 0 ..< CFArrayGetCount(arr):
      let d = CFArrayGetValueAtIndex(arr, i)
      var r = CgWindowRow(id: cfInt(CFDictionaryGetValue(d, kCGWindowNumber)),
                          pid: cfInt(CFDictionaryGetValue(d, kCGWindowOwnerPID)),
                          owner: cfString(CFDictionaryGetValue(d, kCGWindowOwnerName)).get(""),
                          title: cfString(CFDictionaryGetValue(d, kCGWindowName)),
                          layer: cfInt(CFDictionaryGetValue(d, kCGWindowLayer)))
      let on = CFDictionaryGetValue(d, kCGWindowIsOnscreen)
      r.onScreen = on != nil and CFBooleanGetValue(on) != 0
      var cg: CGRectC
      let b = CFDictionaryGetValue(d, kCGWindowBounds)
      if b != nil and CGRectMakeWithDictionaryRepresentation(b, addr cg):
        r.bounds = toRect(cg)
      if r.id <= 0: continue
      var found = false
      for (p, bid) in bundles:
        if p == r.pid:
          r.bundleId = bid
          found = true
          break
      if not found:
        r.bundleId = bundleIdOf(r.pid)
        bundles.add (r.pid, r.bundleId)
      result.rows.add r

# ---------------------------------------------------------------------------
# The backend
# ---------------------------------------------------------------------------

proc cgwindowFeatures*(backend: string, enumeration, titlesVisible: bool): seq[Feature] =
  ## The capture features of an enumeration-only backend: window
  ## enumeration (degraded to `titles-redacted` without the grant) and
  ## every capture feature `not-implemented`.
  proc f(name: string, state: FeatureState, reason = ""): Feature =
    Feature(feature: name, backend: backend, state: state,
            reason: (if reason.len > 0: some(reason) else: none(string)),
            remedy: (if state == fsUnavailable:
                       some("select the macos-sck capture backend") else: none(string)))
  result.add(
    if not enumeration: f("window-enumeration", fsUnavailable, "wrong-platform")
    elif titlesVisible: f("window-enumeration", fsSupported)
    else: f("window-enumeration", fsDegraded, "titles-redacted"))
  for name in ["display-capture", "window-capture", "region-capture",
               "own-pixels-capture", "recording"]:
    result.add f(name, fsUnavailable, "not-implemented")

proc newMacosCgwindowCapture*(): CaptureBackend =
  ## The `macos-cgwindow` backend (module doc). Off macOS every operation
  ## raises `backend-unavailable` / `wrong-platform`.
  result.name = macosCgwindowName
  when defined(macosx):
    result.displays = proc (session: string): seq[Display] = readDisplays()
    result.windows = proc (session: string, filter: WindowFilter): WindowList =
      assembleWindows(readSnapshot(filter.includeOffscreen), filter)
    result.features = proc (probe: bool): seq[Feature] =
      var enumerates = true
      if probe:
        try: enumerates = readSnapshot(false).rows.len > 0
        except BackendError: enumerates = false
      result = cgwindowFeatures(macosCgwindowName, true, screenRecordingPreflight())
      if not enumerates:
        result[0] = Feature(feature: "window-enumeration", backend: macosCgwindowName,
          state: fsUnavailable, reason: some("display-server-unsupported"),
          remedy: some("run inside a logged-in macOS GUI session"))
  else:
    proc wrong(): ref BackendUnavailableError =
      unavailable(macosCgwindowName, "wrong-platform",
        "the macos-cgwindow backend runs on macOS only")
    result.displays = proc (session: string): seq[Display] = raise wrong()
    result.windows = proc (session: string, filter: WindowFilter): WindowList =
      raise wrong()
    result.features = proc (probe: bool): seq[Feature] =
      for f in cgwindowFeatures(macosCgwindowName, false, false):
        result.add Feature(feature: f.feature, backend: f.backend,
          state: fsUnavailable, reason: some("wrong-platform"),
          remedy: some("select a capture backend for this platform"))
  # Enumeration only (module doc); off macOS the platform is the reason.
  proc refuse(op: string): ref BackendUnavailableError =
    when defined(macosx): enumerationOnly(op)
    else: unavailable(macosCgwindowName, "wrong-platform",
                      "the macos-cgwindow backend runs on macOS only")
  result.capture = proc (req: CaptureRequest): ImageRef = raise refuse("capture images")
  result.startRecording = proc (req: RecordRequest): Recording = raise refuse("record")
  result.stopRecording = proc (id: string): Recording = raise refuse("record")
  result.recordings = proc (): seq[Recording] = raise refuse("record")
