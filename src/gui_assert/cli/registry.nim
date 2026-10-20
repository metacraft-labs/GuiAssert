## The `guiassert` registry: which verbs exist and what each accepts, which
## backends exist, which are compiled into this binary, and which one is the
## platform default (spec §3.4, §7.5).
##
## **Compile time.** With no define, every backend for the target OS is
## compiled in, plus `fixture`. `-d:guiassertMinimal` compiles `core` plus
## the `fixture` backends only (`guiassert-fixture`, spec §9.2).
## `-d:guiassertNo<Module>` (`Capture`, `Ocr`, `Tree`, `Input`, `Session`,
## `Media`) omits every backend of a module; `-d:guiassertNo<Backend>` (the
## backend name in CamelCase, e.g. `guiassertNoTesseract`,
## `guiassertNoFixture`) omits one backend.
##
## **Implemented.** The platform backends of spec §4 are filled in by later
## milestones (GS5–GS11); GS5 implemented `macos-sck` and `macos-cgwindow`.
## Until a backend is implemented, selecting it is
## `backend-unavailable` with reason `not-implemented` on its own platform,
## `wrong-platform` elsewhere, and `not-compiled-in` in a build that omits it,
## so a consumer can already tell the three apart.
##
## The verb table here is the CLI's half of the contract; the specification's
## verb tables are the other half, and `tests/contract/tcontract_schema.nim`
## checks that the two list the same verbs.

import std/[macros, strutils]

import ../core/contract

proc nimbleVersion(text: string): string {.compileTime.} =
  result = "0.0.0"
  for line in text.splitLines:
    let l = line.strip
    if l.startsWith("version"):
      result = l.split('=', 1)[1].strip.strip(chars = {'"'})

const
  guiassertVersion* = nimbleVersion(staticRead("../../../gui_assert.nimble"))
    ## The program version, taken from `gui_assert.nimble` at build time.

  minimalBuild* = defined(guiassertMinimal)
    ## True in `guiassert-fixture`.

type
  Module* = enum
    ## The runtime-selectable modules (spec §3.4).
    modCapture = "capture"
    modOcr = "ocr"
    modTree = "tree"
    modInput = "input"
    modSession = "session"

  HostPlatform* = enum
    hpMacos = "macos"
    hpLinux = "linux"
    hpWindows = "windows"

  KnownBackend* = object
    module*: Module
    name*: string
    platforms*: set[HostPlatform]
    implemented*: bool

const
  allPlatforms = {hpMacos, hpLinux, hpWindows}

  currentPlatform* =
    when defined(macosx): hpMacos
    elif defined(windows): hpWindows
    else: hpLinux
    ## The platform this binary was built for.

  currentArch* = hostCPU
    ## The CPU architecture this binary was built for (Nim's spelling).

  knownBackends*: seq[KnownBackend] = @[
    KnownBackend(module: modCapture, name: "macos-sck", platforms: {hpMacos},
                 implemented: true),
    KnownBackend(module: modCapture, name: "macos-cgwindow", platforms: {hpMacos},
                 implemented: true),
    KnownBackend(module: modCapture, name: "linux-wlr", platforms: {hpLinux}),
    KnownBackend(module: modCapture, name: "linux-gnome", platforms: {hpLinux}),
    KnownBackend(module: modCapture, name: "linux-portal-pipewire", platforms: {hpLinux}),
    KnownBackend(module: modCapture, name: "linux-x11", platforms: {hpLinux}),
    KnownBackend(module: modCapture, name: "windows-dxgi", platforms: {hpWindows}),
    KnownBackend(module: modCapture, name: "windows-wgc", platforms: {hpWindows}),
    KnownBackend(module: modCapture, name: "windows-gdi", platforms: {hpWindows}),
    KnownBackend(module: modCapture, name: "fixture", platforms: allPlatforms,
                 implemented: true),
    KnownBackend(module: modOcr, name: "apple-vision", platforms: {hpMacos}),
    KnownBackend(module: modOcr, name: "tesseract", platforms: allPlatforms),
    KnownBackend(module: modOcr, name: "windows-media", platforms: {hpWindows}),
    KnownBackend(module: modOcr, name: "fixture", platforms: allPlatforms,
                 implemented: true),
    KnownBackend(module: modTree, name: "macos-ax", platforms: {hpMacos}),
    KnownBackend(module: modTree, name: "linux-atspi", platforms: {hpLinux}),
    KnownBackend(module: modTree, name: "windows-uia", platforms: {hpWindows}),
    KnownBackend(module: modTree, name: "appium", platforms: allPlatforms),
    KnownBackend(module: modTree, name: "fixture", platforms: allPlatforms,
                 implemented: true),
    KnownBackend(module: modInput, name: "macos-cgevent", platforms: {hpMacos}),
    KnownBackend(module: modInput, name: "linux-wlr-virtual", platforms: {hpLinux}),
    KnownBackend(module: modInput, name: "linux-mutter", platforms: {hpLinux}),
    KnownBackend(module: modInput, name: "linux-xtest", platforms: {hpLinux}),
    KnownBackend(module: modInput, name: "linux-uinput", platforms: {hpLinux}),
    KnownBackend(module: modInput, name: "windows-sendinput", platforms: {hpWindows}),
    KnownBackend(module: modInput, name: "fixture", platforms: allPlatforms,
                 implemented: true),
    KnownBackend(module: modSession, name: "macos-host", platforms: {hpMacos}),
    KnownBackend(module: modSession, name: "macos-virtual-display", platforms: {hpMacos}),
    KnownBackend(module: modSession, name: "macos-isolated", platforms: {hpMacos}),
    KnownBackend(module: modSession, name: "linux-host", platforms: {hpLinux}),
    KnownBackend(module: modSession, name: "linux-sway", platforms: {hpLinux}),
    KnownBackend(module: modSession, name: "linux-gnome", platforms: {hpLinux}),
    KnownBackend(module: modSession, name: "linux-xvfb", platforms: {hpLinux}),
    KnownBackend(module: modSession, name: "windows-host", platforms: {hpWindows}),
    KnownBackend(module: modSession, name: "windows-desktop", platforms: {hpWindows}),
    KnownBackend(module: modSession, name: "fixture", platforms: allPlatforms,
                 implemented: true)]
    ## Every backend name of spec §4, per module.

  platformDefaults*: array[HostPlatform, array[Module, string]] = [
    ["macos-sck", "apple-vision", "macos-ax", "macos-cgevent", "macos-host"],
    ["linux-wlr", "tesseract", "linux-atspi", "linux-wlr-virtual", "linux-host"],
    ["windows-dxgi", "windows-media", "windows-uia", "windows-sendinput",
     "windows-host"]]
    ## The default backend of each module (spec §4, bold entries).

proc camel(name: string): string =
  for part in name.split('-'):
    if part.len > 0: result.add part[0].toUpperAscii & part[1 .. ^1]

macro omissionTable(): untyped =
  ## `[defined(guiassertNo<Backend>) or defined(guiassertNo<Module>), …]` in
  ## `knownBackends` order, evaluated where the binary is compiled.
  result = newNimNode(nnkBracket)
  for b in knownBackends:
    let one = newCall(ident"defined", ident("guiassertNo" & camel(b.name)))
    let all = newCall(ident"defined", ident("guiassertNo" & camel($b.module)))
    result.add infix(one, "or", all)

const
  omittedByDefine = omissionTable()
  mediaCompiledIn* = not minimalBuild and not defined(guiassertNoMedia) and
                     not defined(guiassertNoFfmpeg)
    ## Whether the ffmpeg media backend (video decode/encode) is compiled in.

const
  macosCaptureCompiledIn* = not minimalBuild and defined(macosx) and
    not defined(guiassertNoCapture) and
    not (defined(guiassertNoMacosSck) and defined(guiassertNoMacosCgwindow))
    ## Whether the macOS capture backends' code is linked into this binary
    ## (either of them needs the module; `compiledIn` decides which one is
    ## selectable).

proc knownIndex(module: Module, name: string): int =
  for i, b in knownBackends:
    if b.module == module and b.name == name: return i
  -1

proc isKnownBackend*(module: Module, name: string): bool =
  ## True when `name` is a backend of `module` in spec §4.
  knownIndex(module, name) >= 0

proc compiledIn*(module: Module, name: string): bool =
  ## True when backend `name` of `module` is in this binary: implemented,
  ## not omitted by a define, for this platform, and (in a minimal build)
  ## the fixture.
  let i = knownIndex(module, name)
  if i < 0: return false
  let b = knownBackends[i]
  if omittedByDefine[i]: return false
  if minimalBuild and b.name != "fixture": return false
  b.implemented and currentPlatform in b.platforms

proc compiledBackends*(module: Module): seq[string] =
  ## The backends of `module` compiled into this binary, in table order.
  for b in knownBackends:
    if b.module == module and compiledIn(module, b.name): result.add b.name

proc unavailability*(module: Module, name: string):
    tuple[ok: bool, reason, message, remedy: string] =
  ## Whether backend `name` of `module` can run in this binary on this host,
  ## and if not the `backend-unavailable` reason (spec §7.3) and a message.
  ## `name` must be known (`isKnownBackend`).
  let i = knownIndex(module, name)
  doAssert i >= 0, "unknown backend " & name
  let b = knownBackends[i]
  if omittedByDefine[i] or (minimalBuild and b.name != "fixture"):
    return (false, "not-compiled-in",
            "the " & $module & " backend '" & name & "' is not compiled into this binary" &
              (if minimalBuild: " (guiassert-fixture has only the fixture backends)" else: ""),
            "use a guiassert build that includes it, or select another backend")
  if currentPlatform notin b.platforms:
    return (false, "wrong-platform",
            "the " & $module & " backend '" & name & "' does not run on " & $currentPlatform,
            "select a backend for " & $currentPlatform)
  if not b.implemented:
    return (false, "not-implemented",
            "the " & $module & " backend '" & name & "' is not implemented yet",
            "select another backend (see `guiassert capabilities`)")
  (true, "", "", "")

proc platformDefault*(module: Module): string =
  ## The default backend of `module` on this platform.
  platformDefaults[currentPlatform][module]

# ---------------------------------------------------------------------------
# Verbs and flags
# ---------------------------------------------------------------------------

type
  FlagKind* = enum
    fkSwitch     ## present or absent, takes no value
    fkValue      ## takes one value, at most once
    fkRepeated   ## takes one value, may repeat

  FlagSpec* = tuple[name: string, kind: FlagKind]

  VerbSpec* = object
    ## What a verb accepts. `positionals` lists the positional arguments by
    ## name; a name ending in `?` is optional (only trailing ones are).
    name*: string
    positionals*: seq[string]
    flags*: seq[FlagSpec]
    passthrough*: bool       ## accepts `-- <argv…>` (app-launch only)

const
  globalFlags*: seq[string] = @["state-dir", "session", "backend",
    "capture-backend", "ocr-backend", "tree-backend", "input-backend",
    "session-backend", "timeout-ms", "contract", "fixture-scenario"]
    ## The global flags (spec §7.1); each takes one value, at most once.

  targetFlags: seq[FlagSpec] = @[("display", fkValue), ("window", fkValue),
                                 ("region", fkValue)]
  findFlags: seq[FlagSpec] = @[("pid", fkValue), ("app", fkValue),
    ("role", fkValue), ("name", fkValue), ("name-contains", fkValue),
    ("ignore-case", fkSwitch), ("state", fkRepeated)]

  verbSpecs*: seq[VerbSpec] = @[
    VerbSpec(name: "version"),
    VerbSpec(name: "capabilities", flags: @[("probe", fkSwitch)]),
    VerbSpec(name: "permissions", flags: @[("request", fkValue)]),
    VerbSpec(name: "session-start", flags: @[("kind", fkValue), ("name", fkValue),
      ("width", fkValue), ("height", fkValue), ("scale", fkValue),
      ("displays", fkValue), ("lifetime", fkValue), ("vnc", fkSwitch),
      ("account", fkValue)]),
    VerbSpec(name: "session-list"),
    VerbSpec(name: "session-info", positionals: @["id"]),
    VerbSpec(name: "session-stop", positionals: @["id"], flags: @[("force", fkSwitch)]),
    VerbSpec(name: "apps"),
    VerbSpec(name: "app-launch", flags: @[("bundle-id", fkValue), ("app", fkValue),
      ("wait-window-ms", fkValue), ("env", fkRepeated)], passthrough: true),
    VerbSpec(name: "app-quit", positionals: @["pid"], flags: @[("force", fkSwitch)]),
    VerbSpec(name: "displays"),
    VerbSpec(name: "windows", flags: @[("app", fkValue), ("pid", fkValue),
      ("title", fkValue), ("title-contains", fkValue), ("all-layers", fkSwitch),
      ("include-offscreen", fkSwitch)]),
    VerbSpec(name: "window-focus", positionals: @["window-id"]),
    VerbSpec(name: "window-set-bounds", positionals: @["window-id"],
      flags: @[("bounds", fkValue)]),
    VerbSpec(name: "screenshot", flags: @[("out", fkValue)] & targetFlags &
      @[("own-pixels", fkSwitch), ("no-cursor", fkSwitch)]),
    VerbSpec(name: "record", flags: @[("out", fkValue), ("duration-ms", fkValue)] &
      targetFlags & @[("fps", fkValue)]),
    VerbSpec(name: "record-start", flags: @[("out", fkValue)] & targetFlags &
      @[("fps", fkValue)]),
    VerbSpec(name: "record-stop", positionals: @["recording-id"]),
    VerbSpec(name: "recordings"),
    VerbSpec(name: "ocr", flags: @[("image", fkValue), ("out", fkValue)] & targetFlags &
      @[("lang", fkRepeated), ("psm", fkValue), ("upscale", fkValue),
        ("invert", fkValue), ("min-confidence", fkValue)]),
    VerbSpec(name: "tree", flags: @[("pid", fkValue), ("app", fkValue),
      ("window", fkValue), ("focused", fkSwitch), ("depth", fkValue),
      ("max-nodes", fkValue)]),
    VerbSpec(name: "find", flags: @[("window", fkValue)] & findFlags &
      @[("limit", fkValue)]),
    VerbSpec(name: "element", positionals: @["path"]),
    VerbSpec(name: "element-action", positionals: @["path", "action"],
      flags: @[("value", fkValue), ("value-stdin", fkSwitch)]),
    VerbSpec(name: "wait", flags: @[("element", fkSwitch), ("text", fkValue),
      ("window", fkSwitch), ("window-gone", fkSwitch)] & findFlags &
      @[("title", fkValue), ("title-contains", fkValue), ("ocr-region", fkValue),
        ("out-dir", fkValue), ("wait-ms", fkValue), ("interval-ms", fkValue)]),
    VerbSpec(name: "move", flags: @[("to", fkValue)]),
    VerbSpec(name: "click", flags: @[("at", fkValue), ("button", fkValue),
      ("count", fkValue), ("modifiers", fkValue)]),
    VerbSpec(name: "drag", flags: @[("from", fkValue), ("to", fkValue),
      ("path", fkValue), ("button", fkValue), ("steps", fkValue),
      ("duration-ms", fkValue)]),
    VerbSpec(name: "scroll", flags: @[("at", fkValue), ("dx", fkValue),
      ("dy", fkValue), ("unit", fkValue)]),
    VerbSpec(name: "type", positionals: @["text?"],
      flags: @[("text-file", fkValue), ("stdin", fkSwitch), ("interval-ms", fkValue)]),
    VerbSpec(name: "key", positionals: @["combo"]),
    VerbSpec(name: "vision-compare", positionals: @["a", "b"],
      flags: @[("tiles", fkValue)]),
    VerbSpec(name: "vision-segment", positionals: @["video?"],
      flags: @[("frames", fkValue), ("fps", fkValue), ("scale-width", fkValue),
        ("threshold", fkValue)]),
    VerbSpec(name: "vision-windows", positionals: @["image"],
      flags: @[("ocr", fkSwitch)]),
    VerbSpec(name: "watch", flags: @[("windows", fkSwitch), ("frames", fkSwitch),
      ("out-dir", fkValue), ("fps", fkValue), ("duration-ms", fkValue),
      ("events-file", fkValue)])]
    ## Every contract verb (spec §7.5) and the flags it accepts besides the
    ## global ones.

  sessionlessVerbs* = ["version", "vision-compare", "vision-segment",
                       "vision-windows"]
    ## Verbs that touch no desktop: an explicit `--session` is refused.

proc verbNames*(): seq[string] =
  ## The contract verbs this binary implements, in table order.
  for v in verbSpecs: result.add v.name

proc findVerb*(name: string): int =
  ## The index of verb `name` in `verbSpecs`, or -1.
  for i, v in verbSpecs:
    if v.name == name: return i
  -1

proc contractSupported*(major: string): bool =
  ## True when this binary implements contract major `major`.
  major == $contractMajor
