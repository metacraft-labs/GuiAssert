# GuiAssert Desktop Substrate

Status: **in progress** (GS0, the specification and contract, written; GS1,
the core split, and GS2, the `guiassert` CLI, `serve`, the fixture backend
and the contract suite, implemented; GS2.1 decided and implemented the
companion campaign's change requests C1–C17, and **contract
`guiassert-desktop/1.0` is frozen** (§7.7); the platform backends of §4 are
not implemented) · Execution:
[[Desktop-Substrate.milestones.org]] · Related:
[[Vision-Understanding.md]], [[../src/gui_assert/image_math.nim]],
[[../src/gui_assert/ocr.nim]], [[../src/gui_assert/screen_capture.nim]],
[[../src/gui_assert/desktop_env.nim]], [[../src/gui_assert/vision_windows.nim]].

## 1. What this initiative is

GuiAssert becomes a **desktop substrate**: one library, and one program built
from it, that can look at a desktop, read it, and act on it, on macOS, Linux and
Windows, including desktops that nobody can see.

- **Look**: enumerate displays, windows and applications; capture still frames
  and recordings of a display, a window or a region.
- **Read**: OCR a frame; read the accessibility tree of an application; answer
  pure computer-vision questions about pixels (SSIM change detection, video
  segmentation, window detection from pixels alone).
- **Act**: synthesize pointer and keyboard input; focus and place windows;
  launch and quit applications.
- **Off-screen**: start a desktop session that is not the user's visible
  desktop (a virtual display, a separate login session, a headless compositor,
  a separate Windows desktop) and do all of the above inside it.

Two kinds of consumers use it:

1. **Nim applications** (GuiAssert's own assertion harness, DemoVideoScript
   backends, test suites) import the library and link **only the modules they
   use**. A program that only computes SSIM between two PNG files links no
   capture code, no Objective-C runtime, no D-Bus, and spawns no subprocess.
2. **Programs in other languages**, of which **Agent Harbor** is the first,
   run the `guiassert` executable and speak a **fixed JSON contract** to it:
   one invocation per verb (`guiassert <verb> …`, one JSON envelope on stdout,
   a fixed exit code), or a long-lived `guiassert serve` daemon that speaks the
   same verbs as NDJSON. They never link Nim code. The envelope follows the
   convention Agent Harbor already uses for its process-boundary substrates
   (`{"ok":true,"verb":…,"data":…}` / `{"ok":false,"verb":…,"error":{…}}`
   with frozen exit codes), so a consumer that has bound one such substrate
   binds this one the same way.

GuiAssert provides **mechanism, never policy** (§11). It does what it is asked,
reports exactly what happened, and refuses what it cannot do faithfully.

### 1.1 Non-goals

- No MCP server, no agent tool definitions, no prompt-facing descriptions.
- No access control between callers. Whoever can run the binary (or connect to
  the daemon's socket, which is owner-only) can use every verb.
- No storage beyond the files a verb is told to write and the state directory
  (§7.6). No encryption, upload, retention or masking of captured content.
- No remote network transport in contract v1 (§8.1). A remote caller reaches a
  host's `guiassert` through its own transport (SSH, its own daemon).
- Speech / screen-reader capture is not in this initiative.

## 2. Design principles

1. **Measured, not assumed.** Every report names its source: a window list
   comes from the window server or compositor, never from the application's
   account of itself; a capability is `supported` only if it was probed.
   (The same rule `desktop_env` already follows.)
2. **Reject, don't drop.** An input that cannot be honoured exactly is an
   error, never silently ignored or approximated. An unknown flag is
   `bad-args`; a known flag the selected backend cannot honour (capture a
   *window* with a display-only backend, OCR a language the engine lacks,
   `--lifetime owner` from a one-shot CLI) is `backend-unavailable` with a
   reason. A backend never substitutes a different operation (e.g. a
   display capture cropped to a window's bounds when window capture was
   asked for) without saying so in the request.
3. **One serializer per object.** Every object that crosses the contract has
   exactly one JSON shape, produced by one function in the core, used by the
   CLI, by `serve` and by the fixture alike (§7.4).
4. **The fixture is a backend, not a mock of the program.** Contract tests
   (GuiAssert's and every consumer's) run the real CLI and the real daemon with
   the deterministic fixture backend selected below them (§9.2).
5. **Opt-in at every layer.** Library modules are opt-in by import; CLI
   backends are opt-in by compile-time define and by runtime selection (§3).

## 3. Module layout and the opt-in mechanism

### 3.1 Layers

```
src/
├── gui_assert/core/            # PURE. Depends only on the Nim stdlib allowlist (§3.2).
│   ├── geometry.nim            #   Rect / Point / Size, desktop <-> image mapping
│   ├── image.nim               #   GrayImage / RgbImage / RgbaImage, conversions, crop, scale
│   ├── png.nim                 #   pure-Nim PNG decode/encode (8-bit gray/RGB/RGBA, inflate/deflate)
│   ├── ssim.nim                #   computeSsim, tiledSsim
│   ├── hashing.nim             #   dctHash (pHash), hammingDistance, edgeChangeRatio
│   ├── segmentation.nim        #   segmentBoundaries and the frame-series segmentation core
│   ├── vision_windows.nim      #   detectWindowRects, morphology, region tree (pixels only)
│   ├── ocr_types.nim           #   OcrWord / OcrResult, reading order, the OcrEngine interface
│   ├── tree_types.nim          #   accessibility Node, role/state vocabulary, path grammar, ElementFilter
│   ├── desktop_types.nim       #   Display / Window / App / Session / Recording / ImageRef
│   ├── interfaces.nim          #   CaptureBackend / OcrEngine / TreeBackend / InputBackend / SessionBackend
│   └── contract.nim            #   envelope, error codes and kinds, every object's toJson/fromJson
├── gui_assert/backends/        # OPT-IN. Each file is one backend; import only what you use.
│   ├── capture/  macos_sck.nim  macos_cgwindow.nim  linux_wlr.nim  linux_gnome.nim
│   │             linux_portal_pipewire.nim  linux_x11.nim  windows_dxgi.nim
│   │             windows_wgc.nim  windows_gdi.nim  fixture.nim
│   ├── ocr/      tesseract.nim  apple_vision.nim  windows_media.nim  fixture.nim
│   ├── tree/     macos_ax.nim  linux_atspi.nim  windows_uia.nim  appium.nim  fixture.nim
│   ├── input/    macos_cgevent.nim  linux_wlr_virtual.nim  linux_mutter.nim  linux_xtest.nim
│   │             linux_uinput.nim  windows_sendinput.nim  fixture.nim
│   ├── session/  macos_host.nim  macos_virtual_display.nim  macos_isolated.nim
│   │             linux_sway.nim  linux_gnome.nim  linux_xvfb.nim
│   │             windows_host.nim  windows_desktop.nim  fixture.nim
│   └── media/    ffmpeg.nim       # video decode/encode and non-PNG image decode (subprocess)
├── gui_assert/cli/             # The `guiassert` program, as a library (args, verbs, registry, serve, state)
└── guiassert.nim               # thin `main` over gui_assert/cli
```

The existing modules (`image_math`, `ocr`, `screen_capture`, `capture`,
`input`, `window_layout`, `vision_windows`, `video_analysis`, `desktop_env/*`)
keep their import paths. GS1 moves their pure parts into `core/` and leaves the
old modules as **re-exporting shims** plus their effectful remainder, so every
existing consumer (the plugins, DemoVideoScript backends, codetracer-marketing)
compiles unchanged. The `desktop_env` targets (headless sway and GNOME) become
the Linux session backends' implementation rather than a parallel copy: the
session backend wraps a `TargetEnvironment`.

### 3.2 The purity rule for `core/`

A module under `gui_assert/core/`:

- imports only other `core/` modules and this stdlib allowlist: `std/[math,
  strutils, sequtils, algorithm, tables, sets, hashes, options, json, times,
  parseutils, unicode, bitops, endians, streams, strformat]` (`streams` for
  in-memory streams only);
- performs no FFI (`importc`, `dynlib`, `header`, `emit`, `compile`), no
  subprocess (`osproc`), no filesystem access except through procs that take an
  explicit path and are named `…File` (`readPngFile`), no environment reads, no
  global mutable state;
- builds for every Nim target GuiAssert supports, including the JS backend for
  the pure maths (so a browser preview can reuse it).

`tests/tcore_purity.nim` enforces this statically (it parses the import graph
of every `core/` module with `nim genDepend` and fails on any module outside
the allowlist) and dynamically (it compiles a program that imports all of
`core/` and checks with `otool -L` / `ldd` / `dumpbin /dependents` that the
binary links no framework or shared library beyond the platform C runtime).

Decoding is the one place the old pure code was not pure: `image_math.decodeGray`
shells out to `ffmpeg`. In the new layout PNG is decoded in core (`png.nim`);
every other image and all video formats go through the opt-in
`backends/media/ffmpeg.nim`. Video *segmentation* is therefore pure (it consumes
a sequence of decoded frames, or an SSIM series), and video *decoding* is
opt-in.

### 3.3 How a Nim application links only what it needs

Each backend is a separate module with a constructor:

```nim
import gui_assert/core/[ssim, png]                    # pure: no FFI, no subprocess
import gui_assert/backends/capture/macos_sck          # opt-in: ScreenCaptureKit
import gui_assert/backends/ocr/apple_vision           # opt-in: Vision

let cap = newMacosSckCapture()                        # a CaptureBackend
let ocr = newAppleVisionOcr()                         # an OcrEngine
let frame = cap.captureDisplay(cap.displays()[0].id)  # -> ImageRef
let words = ocr.recognize(frame.path).words
```

Nothing is registered by side effect of an import. The interfaces in
`core/interfaces.nim` are objects of procs (the pattern the talking-head and
speech-synthesis plugin contracts already use), so the core never imports a
backend and a backend never imports the CLI.

A backend module that does not apply to the compile target still compiles, but
its constructor returns a backend whose every operation fails with
`backend-unavailable` / `wrong-platform`; it links no platform code there
(`when defined(macosx)` guards). This keeps cross-platform callers free of
`when` blocks around imports.

### 3.4 How the `guiassert` binary selects backends

**Compile time.** `gui_assert/cli/registry.nim` decides which backends are
compiled in:

| Define | Effect |
| --- | --- |
| *(none)* | every backend for the target OS, plus `fixture` |
| `-d:guiassertMinimal` | `core` plus the `fixture` backends only (this is `guiassert-fixture`, §9.2) |
| `-d:guiassertNo<Module>` (`Capture`, `Ocr`, `Tree`, `Input`, `Session`, `Media`) | omit every backend of that module |
| `-d:guiassertNo<Backend>` (e.g. `guiassertNoTesseract`) | omit one backend |

`version` and `capabilities` report what was compiled in, so a consumer can
tell "not compiled in" (`backend-unavailable`, reason `not-compiled-in`) from
"compiled in but unusable here" (reason `missing-tool`, `wrong-platform`, …).

**Run time.** Per module, the first of these that is set wins:

1. the flag `--<module>-backend <name>` (`--capture-backend`, `--ocr-backend`,
   `--tree-backend`, `--input-backend`, `--session-backend`);
2. the flag `--backend <name>`, which sets every module (today only
   `fixture` is meaningful for all modules at once);
3. the environment variable `GUIASSERT_<MODULE>_BACKEND`;
4. the environment variable `GUIASSERT_BACKEND`;
5. the session's own backends (a session started with a given session backend
   records the capture/tree/input backends it was started with, §6);
6. the platform default (§4).

An unknown backend name is `bad-args` / `unknown-backend`. A known name that is
not compiled in, or cannot run on this host, is `backend-unavailable`. There is
**no fallback** from an explicitly selected backend to another one: falling back
is policy, and a caller that wants it asks `capabilities` and chooses.

## 4. Platform backends

Defaults are in **bold**. "TCC" marks a macOS privacy permission (§9.4).

### 4.1 macOS

| Module | Backends | Notes |
| --- | --- | --- |
| capture | **`macos-sck`** (ScreenCaptureKit: `SCScreenshotManager` stills, `SCStream` recordings), `macos-cgwindow` (enumeration only) | Stills and window-own-pixel capture already exist (`screen_capture.nim`, a signed helper bundle). Enumeration through `CGWindowListCopyWindowInfo` is unprivileged and is the positive control; window titles are redacted without the TCC grant, reported as `title: null` and `titlesVisible: false`. TCC: Screen Recording. |
| ocr | **`apple-vision`** (`VNRecognizeTextRequest`), `tesseract` | Apple Vision already exists behind `ocr.obAppleVision`. Confidence is normalized to 0–100. |
| tree | **`macos-ax`** (`AXUIElement`), `appium` (Mac2 driver, optional) | Direct C API, no helper. TCC: Accessibility. |
| input | **`macos-cgevent`** (`CGEventCreateMouseEvent` / `CGEventCreateKeyboardEvent` / `CGEventKeyboardSetUnicodeString`, posted with `CGEventPost`, or `CGEventPostToPid` when a target pid is given) | Replaces the AppleScript keystroke path in `input.nim` (kept as a shim). TCC: Accessibility (posting events). |
| session | **`macos-host`** (the logged-in user's own session), `macos-virtual-display`, `macos-isolated` | §6.2. |

Objective-C / Swift-only APIs (ScreenCaptureKit, Vision, `CGVirtualDisplay`)
are reached through the small signed Swift helper pattern GuiAssert already
uses (`swift_helper.nim`), or through the Objective-C runtime from Nim; the C
APIs (AX, CGEvent, CGWindow) are bound directly. TCC-gated work runs inside the
signed GuiAssert helper bundle so that the grant is bound to GuiAssert's own
code identity (§9.4).

### 4.2 Linux

| Module | Backends | Notes |
| --- | --- | --- |
| capture | **`linux-wlr`** (wlr-screencopy via `grim`; recordings via `wf-recorder`), `linux-gnome` (GNOME Shell screenshot API), `linux-portal-pipewire` (xdg-desktop-portal ScreenCast + PipeWire stream, for compositors that only offer the portal), `linux-x11` (XGetImage/XShm; recordings via ffmpeg `x11grab`, for Xvfb) | Default follows the session: sway → `linux-wlr`, GNOME → `linux-gnome`, Xvfb → `linux-x11`. Window capture on wlroots crops the compositor-reported window rect and says so (`source.kind: "window-crop"`), because wlr-screencopy has no per-window capture; a caller that needs own-pixels capture gets `backend-unavailable` / `unsupported-option` when it passes `--own-pixels`. |
| ocr | **`tesseract`** | Pinned by the flake. |
| tree | **`linux-atspi`** (AT-SPI2 over D-Bus, on the session's own bus), `appium` (optional) | Requires the application's toolkit accessibility bridge; a session backend starts the AT-SPI bus inside the session it owns. |
| input | **`linux-wlr-virtual`** (wlroots virtual-pointer and virtual-keyboard protocols; the existing `helpers/linux/virtual_pointer.c` and `wtype`), `linux-mutter` (Clutter virtual devices inside GNOME Shell, as `desktop_env/gnome` does today), `linux-xtest` (XTest, for Xvfb), `linux-uinput` (`/dev/uinput`, compositor-independent, needs device access) | Default follows the session. |
| session | **`linux-host`** (attach to the caller's session; `attachSwayTarget` / `attachGnomeTarget`), `linux-sway` (private headless sway), `linux-gnome` (private headless GNOME Shell), `linux-xvfb` (Xvfb plus a minimal window manager) | §6.3. Optional per-session VNC endpoint through `wayvnc` (sway) or `x11vnc` (Xvfb), bound to loopback. |

### 4.3 Windows

| Module | Backends | Notes |
| --- | --- | --- |
| capture | **`windows-dxgi`** (DXGI Desktop Duplication, displays), `windows-wgc` (Windows.Graphics.Capture, window own-pixels), `windows-gdi` (`BitBlt` / `PrintWindow`, works on a non-input desktop) | Desktop Duplication only sees the *input* desktop; on a `windows-desktop` session the default becomes `windows-gdi`. |
| ocr | **`windows-media`** (`Windows.Media.Ocr`), `tesseract` | |
| tree | **`windows-uia`** (UI Automation) | |
| input | **`windows-sendinput`** (`SendInput`) | `SendInput` reaches only the input desktop; on a `windows-desktop` session input is posted to the target window (`PostMessage` of mouse/keyboard messages) and the report says `delivery: "posted"`. Applications that read raw input or check the input desktop will not see posted input; that limit is a GS11 measurement item. |
| session | **`windows-host`**, `windows-desktop` (`CreateDesktop` in the caller's window station; processes launched with `STARTUPINFO.lpDesktop`) | §6.4. |

## 5. Coordinates and units

- **Desktop coordinates** are the session's global logical coordinates: origin
  at the top-left of the primary display, unit = one logical point (macOS
  points, Wayland logical pixels, Windows device-independent pixels at the
  display's DPI). Window bounds, input positions and display bounds use them.
- **Image coordinates** are physical pixels of a captured image, origin at its
  top-left. OCR word boxes and vision results use them.
- Every captured image records `origin` (desktop coordinates of its top-left)
  and `scale` (physical pixels per logical point), so
  `desktop = origin + image / scale`. `core/geometry.nim` provides the mapping;
  a consumer clicking an OCR word never guesses the scale.
- Rectangles serialize as `[x, y, w, h]` integer arrays; points as `[x, y]`.

## 6. The off-screen session model

### 6.1 Sessions in general

A **session** is a desktop GuiAssert can capture, read and drive. Every verb
that touches a desktop takes `--session <id>`; the default is the reserved id
`host`, the caller's own desktop, which always exists and is never started or
stopped by GuiAssert.

| Kind | Meaning |
| --- | --- |
| `host` | the caller's own interactive session (attached, never modified beyond what a verb does) |
| `virtual-display` | an extra display that exists only in software, attached to the host's window server; windows placed on it are not visible on any physical monitor |
| `isolated` | a separate login session (its own window server session, its own input focus, its own clipboard) |
| `headless` | a private display server or compositor with no physical output (Linux sway / GNOME / Xvfb; Windows separate desktop) |

`session-start` returns a `Session` (§7.5) and records it in the state
directory (§7.6). A session outlives the CLI invocation that started it: the
session is owned by a detached **session host** process (`guiassert` running an
internal, non-contract verb) whose pid is recorded, and every later invocation
re-attaches through the record. Each call reconciles the record against
reality (is the host pid alive, does the compositor answer); a session whose
host died is reported with `state: "error"` and a reason, never as running.
Every verb that targets a session that is not `running` (its host died, or
it is still starting) answers exit 4 / `session-not-running`, never exit 3
or exit 5, so a caller tells "the session is gone, recreate it" from "the
operation failed" by the exit code alone; `session-info`, `session-list`,
`session-stop`, `capabilities` and `permissions` still answer for it.

**Readiness.** `session-start` returns only once the session is `running`:
its display server answers and, for a kind whose session has a tree backend,
its accessibility bus is up, so an `app-launch` right after it works. A
session that does not get there within the **readiness bound** (10 s, or the
`--timeout-ms` deadline less 250 ms when that is shorter) fails the start with
exit 5 / `session-failed`; the start then stops everything it started and
leaves no record. A session host that exits before the session is ready
fails it the same way, at once.

**Names.** `--name` sets the session's id. A name that a session which is
not stopped already uses (running, starting or in error) is exit 2 /
`name-in-use` with `details: {"name", "state"}`; a stopped session leaves no
record, so its name can be used again. A session started without `--name`
gets a generated id that never takes a name already in use.

`--lifetime detached` (default) keeps the session until `session-stop`.
`--lifetime owner` is accepted only under `serve` and stops the session when the
daemon shuts down or its client disconnects; from the one-shot CLI it is
`backend-unavailable` / `unsupported-option` (the owner would exit
immediately).

Applications are started **into** a session with `app-launch --session <id>`,
which supplies the session's environment (`WAYLAND_DISPLAY`, `DISPLAY`,
`XDG_RUNTIME_DIR`, the session bus `DBUS_SESSION_BUS_ADDRESS`, the AT-SPI bus
`AT_SPI_BUS_ADDRESS`) or its launch mechanism (macOS `launchctl asuser` / a
LaunchAgent in the session's `gui/<uid>` domain; Windows `lpDesktop`). The
session's environment is also returned, so a caller may spawn processes
itself and get exactly what `app-launch` would: `Session.env` carries every
variable a process in the session needs set (the session bus and the AT-SPI
bus included), and `Session.envUnset` every variable it must **not** inherit
from the caller (for example the host's `DISPLAY`, or `NO_AT_BRIDGE`,
`GTK_A11Y`, `GDK_BACKEND`, `QT_QPA_PLATFORM` when they would route the
application away from the session or disable its accessibility). A process
spawned into the session starts from the caller's environment, removes every
`envUnset` variable, then sets every `env` variable; `app-launch --env
KEY=VALUE` (repeatable) is applied last and wins over both.

**Isolation is stated, not implied.** A `Session` carries
`isolation: {pixels, input, clipboard}`, each `true` only when that property
holds for the session kind on this platform (§6.2–6.4). A `virtual-display`
session on macOS isolates pixels but **shares** input focus and clipboard with
the host session, and says so.

### 6.2 macOS (GS9)

- **`macos-virtual-display`**: creates a virtual display with the
  `CGVirtualDisplay` API (configurable size, scale and refresh rate) in the
  logged-in user's session, moves the launched application's windows onto it,
  and captures it with ScreenCaptureKit as any display. Pixels are off-screen;
  the pointer and keyboard focus are the host's. Input to a virtual-display
  session therefore serializes with the user's own input and can steal focus;
  `isolation.input` is `false`, and a caller that needs real input isolation
  uses `macos-isolated`.
- **`macos-isolated`**: drives a separate Aqua login session belonging to a
  dedicated account. Verbs are dispatched into that session by bootstrapping a
  per-invocation LaunchAgent in the account's `gui/<uid>` domain whose program
  is the signed GuiAssert helper itself (so TCC evaluates GuiAssert's own code
  identity, not `sshd`'s or a shell's), and its JSON result is collected. The
  session must already exist (console auto-login of the dedicated account in a
  VM, or a background fast-user-switching session); GuiAssert does not log a
  user in and does not handle passwords. GS9 also measures whether the private
  SkyLight session-creation API can produce a session with a usable `gui/<uid>`
  domain without console login; until that measurement says yes,
  `session-start --kind isolated` attaches to an existing session and refuses
  (`backend-unavailable`, reason `no-isolated-session`) when there is none.
- **Refusal on the operator's own session.** `macos-isolated` refuses to
  engage when the only Aqua session on the machine is the caller's own: it
  would otherwise drive the operator's desktop while reporting isolation.

### 6.3 Linux (GS10)

- **`linux-sway`**: a private headless sway (`WLR_BACKENDS=headless`), with its
  own runtime directory, session bus, settings portal and AT-SPI bus: the
  existing `desktop_env/sway` target. Virtual outputs give the requested size;
  optional `wayvnc` exposes it on loopback (`--vnc`).
- **`linux-gnome`**: a private `gnome-shell --headless` (the existing
  `desktop_env/gnome` target).
- **`linux-xvfb`**: Xvfb with a minimal window manager, for X11-only
  applications; optional `x11vnc`.
- **`linux-host`**: attach to the caller's sway or GNOME session
  (`attach…Target`), never modifying settings unless asked.

All three private kinds isolate pixels, input and clipboard (`isolation` all
`true`) because nothing else connects to the private display server.

### 6.4 Windows (GS11)

- **`windows-desktop`**: `CreateDesktop` in the caller's window station;
  applications are launched onto it with `lpDesktop`. Pixels are isolated; input
  is posted rather than injected (§4.3), so `isolation.input` is `true` but
  `delivery: "posted"` is reported on every input verb; the clipboard is shared
  with the window station (`isolation.clipboard: false`).
- A separate interactive Windows session (a second RDP / console session) is a
  later option, measured in GS11 before it is promised.

## 7. The CLI contract (contract `guiassert-desktop/1`)

### 7.1 Invocation

```
guiassert [global flags] <verb> [verb positionals] [verb flags] [-- <argv>]
```

Global flags may appear before or after the verb. `--` ends flag parsing and
is used only by `app-launch`. `guiassert --help` prints human help on stdout
and exits 0; it is the only output that is not an envelope, and consumers do
not call it.

**Global flags**

| Flag | Meaning |
| --- | --- |
| `--state-dir <dir>` | state directory root (§7.6) |
| `--session <id>` | session to act in (default `host`) |
| `--backend <name>` / `--<module>-backend <name>` | backend selection (§3.4) |
| `--timeout-ms <n>` | overall deadline for the verb; on expiry the verb is cancelled and exits 7 / `deadline` |
| `--contract <major>` | the contract major version the caller speaks; any other value than one this binary implements is `bad-args` / `contract-unsupported` |
| `--fixture-scenario <file>` | the fixture backend's scenario file (§9.2); `bad-args` / `conflicting-arguments` when no module selects `fixture` |

**Environment**: `GUIASSERT_STATE_DIR`, `GUIASSERT_BACKEND`,
`GUIASSERT_<MODULE>_BACKEND`, and the fixture's variables (§9.2). Existing
variables (`TESSERACT_BIN`, `FFMPEG_BIN`, `GUIASSERT_CAPTURE_*`) keep their
meaning for the backends that use them.

### 7.2 The envelope

Every invocation prints **exactly one line** on stdout, a compact JSON object,
and nothing else. Diagnostics go to stderr; stderr is not part of the
contract.

```jsonc
// success
{"ok": true,  "verb": "<verb>", "data": { /* verb-specific, §7.5 */ }}
// failure
{"ok": false, "verb": "<verb>",
 "error": {"code": <int>, "kind": "<kind>", "message": "<human text>",
           "reason": "<machine-readable sub-reason>" | null,
           "remedy": "<what the operator can do>" | null,
           "details": { /* reason-specific */ } | null}}
```

`code`, `kind` and `message` are the keys every process-boundary consumer
reads; `reason`, `remedy` and `details` are always present and `null` when
they do not apply (the §7.4 rule that a key's presence never depends on the
backend). A consumer that reads only `code`/`kind`/`message` is a complete
consumer.

**`details.feature`.** Every exit 4 (`backend-unavailable`) and exit 6
(`permission-denied`) envelope has a `details` object, and it always carries
`feature`: the name, from the closed vocabulary of §7.5 ("Features"), of the
capability the invocation lacked, so a consumer names what is missing from a
stable payload instead of a table keyed on verbs. It is `null` exactly when
the failure is not about a capability:

- reason `session-not-running`: the session, not a capability, is missing;
- an option or flag the **transport** cannot honour: `--lifetime owner` on
  the one-shot CLI (`unsupported-option`, §6.1), and `serve --listen unix:`
  in a build without a Unix-socket transport (`wrong-platform`, §8.1).

Alongside `feature`, `details` carries `module` and `backend` when a backend
was selected (and `selectedBy`, the §3.4 rule that chose it, when the backend
cannot run at all).

- `verb` is the canonical verb name when the verb resolved, otherwise the
  token as given, otherwise `""`.
- The process exit code equals `error.code` (0 on success). Consumers branch on
  the **exit code** (and may refine on `reason`); never on `message`.
- `code`/`kind` are 1:1 (§7.3). `reason` values are a closed, versioned set per
  kind (§7.3); a new reason is a minor contract change.
- Consumers must ignore unknown keys in responses (minor versions add keys);
  GuiAssert rejects unknown keys in anything it parses (§7.4).

### 7.3 Exit codes, kinds and reasons (frozen)

| code | kind | meaning | reasons |
| --- | --- | --- | --- |
| 0 | — | success, `"ok": true` | |
| 1 | `internal` | unexpected failure, a bug | `exception`, `serialization` |
| 2 | `bad-args` | malformed invocation | `unknown-verb`, `unknown-flag`, `missing-argument`, `invalid-value`, `conflicting-arguments`, `unknown-backend`, `contract-unsupported`, `invalid-name`, `name-in-use` |
| 3 | `not-found` | a named object does not resolve | `session`, `display`, `window`, `app`, `element`, `recording`, `file`, `request` (serve `cancel` target) |
| 4 | `backend-unavailable` | the selected backend cannot do this here | `not-compiled-in`, `wrong-platform`, `missing-tool`, `display-server-unsupported`, `unsupported-option`, `not-implemented`, `no-isolated-session`, `session-not-running` |
| 5 | `backend-error` | the backend tried and failed | `capture-failed`, `ocr-failed`, `tree-failed`, `input-failed`, `session-failed`, `busy`, `stale-path` |
| 6 | `permission-denied` | the OS refused for lack of a permission | `tcc-screen-recording`, `tcc-accessibility`, `uinput-access`, `atspi-disabled`, `desktop-access` |
| 7 | `timeout` | a deadline or wait condition expired | `deadline`, `condition-not-met` |
| 8 | `cancelled` | cancelled by the caller (serve `cancel`, SIGINT, SIGTERM) | `request`, `signal`, `shutdown` |

Codes 0–5 have the meanings of the process-boundary convention Agent Harbor
already parses; 6–8 are GuiAssert's additions. `permission-denied` is separate
from `backend-unavailable` because its remedy is an operator action (grant a
permission), not a different backend; its `remedy` names the permission, the
binary or bundle that needs it, and the settings path. A permission problem is
never reported as an empty success (an empty window list, an empty tree): a
backend that cannot tell "nothing there" from "not allowed to see" returns
`permission-denied`.

### 7.4 Serialization rules

- Every object type in §7.5 has exactly one `toJson` and one strict `fromJson`
  in `core/contract.nim`. The CLI, `serve` and the fixture backend all use them.
- Keys are camelCase. Absent optional values are `null`, never omitted, so a
  key's presence does not depend on the backend. Arrays are never `null`.
- Strings are UTF-8; invalid sequences from a platform API are replaced with
  U+FFFD and the object gains `"lossy": true`.
- Timestamps are RFC 3339 UTC with milliseconds (`2026-10-20T09:15:02.123Z`).
- Integers fit in 53 bits. Floats are finite; a NaN or infinity is a
  `internal` / `serialization` error, never written.
- **Reject, don't drop**, on input: unknown flags, unknown JSON keys in serve
  requests and fixture scenarios, duplicate flags that are not repeatable,
  values out of range: all `bad-args`. On output: an object that cannot be
  serialized faithfully fails the verb (`internal` / `serialization`); a list is
  never silently shortened. Lists that are deliberately bounded (`--limit`,
  `--max-nodes`) say so with `truncated: true` and the total when known.
- Names that become filenames (session names, recording ids) match
  `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; anything else is `bad-args` /
  `invalid-name`, never sanitized (two names must never map to one record).

### 7.5 Verbs and payloads

Common objects:

```jsonc
Rect      = [x, y, w, h]                        // ints
Point     = [x, y]
Display   = {"id": str, "name": str|null, "bounds": Rect, "scale": float,
             "primary": bool, "virtual": bool}
Window    = {"id": str, "pid": int, "app": str, "appId": str|null,
             "title": str|null, "document": str|null, "bounds": Rect, "display": str|null,
             "layer": int, "onScreen": bool, "focused": bool, "minimized": bool}
App       = {"pid": int, "name": str, "bundleId": str|null, "appId": str|null,
             "frontmost": bool, "hidden": bool, "accessible": bool|null}
Isolation = {"pixels": bool, "input": bool, "clipboard": bool}
Session   = {"id": str, "name": str|null, "kind": "host"|"virtual-display"|"isolated"|"headless",
             "backend": str, "platform": "macos"|"linux"|"windows"|"fixture",
             "state": "starting"|"running"|"stopping"|"stopped"|"error",
             "stateReason": str|null, "lifetime": "detached"|"owner",
             "isolation": Isolation, "displays": [Display], "env": {str: str},
             "envUnset": [str], "vnc": {"host": str, "port": int}|null,
             "backends": {"capture": str, "tree": str, "input": str},
             "createdAt": str, "hostPid": int|null}
ImageRef  = {"path": str, "format": "png", "width": int, "height": int,
             "scale": float, "origin": Point, "sha256": str, "capturedAt": str,
             "source": {"kind": "display"|"window"|"window-crop"|"region"|"file",
                        "id": str|null, "session": str|null}}
Recording = {"id": str, "path": str, "state": "recording"|"stopped"|"failed",
             "format": "mp4"|"png-sequence", "width": int, "height": int, "fps": float,
             "durationMs": int|null, "frames": int|null, "source": ImageRef.source,
             "startedAt": str, "stoppedAt": str|null}
OcrWord   = {"text": str, "confidence": float /*0-100*/, "bbox": Rect /*image px*/,
             "line": int, "block": int}
Node      = {"path": str, "role": str, "nativeRole": str, "name": str|null,
             "value": str|null, "text": str|null, "description": str|null, "bounds": Rect|null,
             "states": [str], "actions": [str], "childCount": int,
             "children": [Node]}           // Element = Node with "children": []
InputReport = {"kind": str, "at": Point|null, "to": Point|null, "button": str|null,
               "count": int|null, "length": int|null, "keys": str|null,
               "path": [Point]|null, "delivery": "injected"|"posted", "session": str}
```

What the newer keys mean:

- `Window.document`: the document the window shows, as the platform names it
  (macOS `AXDocument`, a file URL); `null` where the platform has no
  equivalent or the window shows none. A caller can verify which document a
  window holds without trusting its title.
- `App.accessible`: whether the application exposes an accessibility tree on
  the session's bus (macOS: its AX application element answers; Linux: it is
  registered with the session's AT-SPI registry; Windows: it has a UIA
  provider); `null` when that cannot be determined, for example without the
  Accessibility permission (never `false` for "could not look").
- `Session.env` / `Session.envUnset`: §6.1.
- `Node.text`: the node's **text content** as the platform's text interface
  reports it (AT-SPI `Text`, the AX value of static text, UIA `TextPattern`):
  a label's string, a text field's or document's content. It is distinct from
  `name` (the accessible label) and `value` (the value interface), and `null`
  for a node with no text interface.
- `InputReport.path`: `drag` only, the vertices delivered with the button
  held, in order (`--from`, every `--path` waypoint, `--to`); `null` for every
  other verb.

The accessibility `role` is a normalized vocabulary (`application`, `window`,
`dialog`, `button`, `checkbox`, `radio`, `text-field`, `text-area`, `label`,
`link`, `menu`, `menu-item`, `list`, `list-item`, `table`, `row`, `cell`,
`tab`, `tab-list`, `tree`, `tree-item`, `combo-box`, `slider`, `scroll-area`,
`toolbar`, `image`, `group`, `unknown`), with the platform's own role kept in
`nativeRole`. `states` come from `focused`, `focusable`, `enabled`,
`selected`, `checked`, `expanded`, `editable`, `visible`, `offscreen`,
`required`, `invalid`, `protected`. A `path` is `/app[<pid>]/<role>[<i>]/…`, where `<i>` is
the index among siblings of the same role. Paths are addresses into the tree as
it was read; a path that no longer resolves is `not-found` / `element`, and one
that resolves to a node of another role is `backend-error` / `stale-path`.

**`Node.bounds` are desktop coordinates** (§5), whatever space the platform
reports: a tree backend whose platform gives window-relative geometry (AT-SPI
on Wayland) converts it through the compositor's window placement, so the
centre of an element's `bounds` is where `click --at` reaches it. When a
backend cannot map a node's geometry to the desktop, `bounds` is `null`,
never a rectangle in another space.

**Protected fields.** A password or secure text field (macOS
`AXSecureTextField`, AT-SPI `ROLE_PASSWORD_TEXT`, UIA `IsPassword`) carries the
state `protected` and reports `value: null` and `text: null` on every verb
(`tree`, `find`, `element`, the re-read of `element-action`, `wait
--element`); its role stays the normalized one (`text-field`). The serializer
enforces it for every backend.

Typed text is never echoed back: `type` reports its `length`, not its
characters, so a password typed through GuiAssert does not reach a log through
GuiAssert's own output.

**Captured content.** Typed and set text, the `value` and `text` of nodes
(protected ones never appear at all), OCR words and text are captured
content. GuiAssert puts captured content **only in the `data` object** of an
envelope (and, where documented, in `details`, such as `details.app` of an
`app-launch` expiry or `details.recording`, which carry no text): never in
`message`, never in a diagnostic on stderr, never in a serve `event` payload,
and never in a state record (the fixture's simulated desktop under
`<state-dir>/fixture/`, §9.2, is the simulated application's own state and is
the one exception). Every image file a verb writes is reported: `wait --text`
writes one frame (`<out-dir>/wait-frame.png`) and reports it as `data.image`
when it matches, and removes it when the wait ends any other way; `watch
--frames` reports every frame it writes in one `frame` event (on serve, and in
`--events-file`), so the files in `--out-dir` are exactly the ones its events
name. A consumer that masks, encrypts or expires captured content therefore
knows every place GuiAssert put some.

#### Matching rules

- `find` and `wait --element` match `--name` exactly and `--name-contains` as
  a substring, both **case-sensitive**; `--ignore-case` makes both compare
  with Unicode case folding (and is refused without one of them).
- `windows --title` / `--title-contains` are case-sensitive as well.
- `--app <name>` matches `App.name` exactly. Where it selects **one**
  application (`tree`, `find`, `wait --element`), a name that more than one
  running application has is exit 2 / `conflicting-arguments` with the
  candidates' pids in `details.pids`, never the first match; select one with
  `--pid`. `windows --app` is a filter and lists the windows of every
  application of that name.

#### Features

`capabilities.features` lists every feature of this vocabulary exactly once,
each reported by the backend selected for its module (for `--session <id>`,
that session's backends, §3.4). The same names are `details.feature` of exit 4
and exit 6 envelopes (§7.2). The set is closed; a new feature is a minor
contract change.

| Feature | Module | Needed by |
| --- | --- | --- |
| `window-enumeration` | capture | `displays`, `windows`, `wait --window` / `--window-gone`, `watch --windows` |
| `display-capture` | capture | `screenshot`, `ocr` and `wait --text` of a display, `watch --frames` |
| `window-capture` | capture | `screenshot --window`, `ocr --window` |
| `region-capture` | capture | `screenshot --region`, `ocr --region`, `wait --text --ocr-region` |
| `own-pixels-capture` | capture | `screenshot --window --own-pixels` |
| `recording` | capture | `record`, `record-start`, `record-stop`, `recordings` |
| `ocr` | ocr | `ocr`, `wait --text`, `vision-windows --ocr` |
| `tree-read` | tree | `tree`, `find`, `element`, `wait --element` |
| `element-actions` | tree | `element-action` |
| `pointer-input` | input | `move`, `click`, `drag`, `scroll` |
| `keyboard-input` | input | `type`, `key` |
| `window-management` | input | `window-focus`, `window-set-bounds` |
| `session-management` | session | `session-list`, `session-info`, `session-stop`, `permissions` |
| `app-management` | session | `apps`, `app-launch`, `app-quit` |
| `session-virtual-display` | session | `session-start --kind virtual-display` |
| `session-isolated` | session | `session-start --kind isolated` |
| `session-headless` | session | `session-start --kind headless` |
| `session-vnc` | session | `session-start --vnc` |
| `video-decode` | media | `vision-segment <video>` |

A feature's `reason` is `null` when its `state` is `supported` or
`available`; a `backend-unavailable` or `permission-denied` reason (§7.3) when
it is `unavailable`; and one of the following when it is `degraded`:

| Degraded reason | Meaning |
| --- | --- |
| `window-crop` | window capture crops a display capture to the window (`source.kind: "window-crop"`) |
| `png-sequence` | recordings are PNG sequences (no media backend) |
| `fixture-frames-only` | the fixture OCR reads only frames the fixture captured |
| `titles-redacted` | windows are enumerated with `title: null` (no Screen Recording grant) |
| `posted-delivery` | input is posted to the target window (`delivery: "posted"`) |

#### The key table

`key <combo>` takes `[<modifier>+]…<key>`, and `click --modifiers` a
comma-separated list of modifiers. Names match **case-insensitively**, and
each row's spellings are interchangeable; the reported `keys` is normalized to
the canonical spellings, modifiers in the order of this table. A combination
naming a modifier twice (under any spelling) or a name not in the table is
exit 2 / `invalid-value`, never guessed. Spelling variants beyond these
(`page_up`, `arrowleft`) are the caller's to translate.

| Kind | Canonical | Also accepted |
| --- | --- | --- |
| modifier | `ctrl` | `control` |
| modifier | `alt` | `option` |
| modifier | `shift` | — |
| modifier | `cmd` | `command`, `meta`, `super`, `win` |
| named | `Return` | `Enter` |
| named | `Tab` | — |
| named | `Escape` | `Esc` |
| named | `BackSpace` | — |
| named | `Delete` | — |
| named | `Insert` | — |
| named | `Space` | — |
| named | `Home` | — |
| named | `End` | — |
| named | `PageUp` | — |
| named | `PageDown` | — |
| named | `Pause` | — |
| named | `Up` | — |
| named | `Down` | — |
| named | `Left` | — |
| named | `Right` | — |
| function | `F1` … `F24` | — |
| character | any single printable character | — |

`cmd` is the Command key on macOS and the Windows / Super key elsewhere. A
**character** is one Unicode code point that is not a control character and
not white space (the space bar is `Space`); the letters `A`–`Z` name the same
key as `a`–`z` and normalize to lower case (an upper-case letter is
`shift+a`, or `type A`); `+` is written last (`ctrl++`, or `+` alone).

**Meta**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `version` | — | `{"guiassert": str, "contract": {"name": "guiassert-desktop", "major": 1, "minor": int}, "platform": str, "arch": str, "compiled": {"capture": [str], "ocr": [str], "tree": [str], "input": [str], "session": [str], "media": [str]}}` |
| `capabilities` | `[--probe]` (run active probes, may take seconds); honours `--session` (that session's backends) | `{"platform": str, "selected": {module: str}, "features": [{"feature": str, "backend": str, "state": "supported"\|"available"\|"degraded"\|"unavailable", "reason": str\|null, "remedy": str\|null}], "permissions": Permissions}` |
| `permissions` | `[--request screen-recording\|accessibility]` (shows the OS prompt; never bypasses it) | `{"permissions": Permissions, "requested": str\|null}` where `Permissions = {"screenRecording", "accessibility", "inputSynthesis", "desktopAccess"}` each `"granted"\|"denied"\|"not-determined"\|"not-applicable"\|"unknown"`, plus `"identity": str\|null` (the bundle or binary the OS evaluates) |

**Sessions and applications**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `session-start` | `--kind <kind> [--name <n>] [--width W --height H] [--scale S] [--displays N] [--lifetime detached\|owner] [--vnc] [--account <user>]` (`--account` only for `isolated`); returns once the session is ready, else exit 5 / `session-failed`; a `--name` in use is exit 2 / `name-in-use` (§6.1) | `{"session": Session}` (state `running`) |
| `session-list` | — | `{"sessions": [Session]}` (includes `host`) |
| `session-info` | `<id>` | `{"session": Session}` |
| `session-stop` | `<id> [--force]` | `{"session": Session}` (state `stopped`); stopping `host` is `bad-args` |
| `apps` | — | `{"apps": [App]}` |
| `app-launch` | `(--bundle-id <id> \| --app <path> \| -- <argv…>) [--wait-window-ms N] [--env KEY=VALUE]…` | `{"app": App, "window": Window\|null}` |
| `app-quit` | `<pid> [--force]` | `{"pid": int, "exited": bool, "exitCode": int\|null}` |

`app-launch` without `--wait-window-ms` does not wait: `window` is the
application's first window if it already has one, else `null`. With
`--wait-window-ms N`, when no window appears within N ms while the process is
still running, the verb answers exit 7 / `condition-not-met` with
`details.app` (the `App`, its pid included) and leaves the application
running, so the caller can `app-quit` it instead of leaking it. `--env
KEY=VALUE` (repeatable; `KEY` matches `[A-Za-z_][A-Za-z0-9_]*`, each key at
most once) sets a variable for the launched process over `Session.env`
(§6.1).

**Displays and windows**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `displays` | — | `{"displays": [Display]}` |
| `windows` | `[--app <name>] [--pid N] [--title <exact>] [--title-contains <s>] [--all-layers] [--include-offscreen]` | `{"windows": [Window], "titlesVisible": bool}` (ordered front to back) |
| `window-focus` | `<window-id>` | `{"window": Window}` |
| `window-set-bounds` | `<window-id> --bounds x,y,w,h` | `{"window": Window, "requested": Rect}` (the window's *reported* bounds after the change; they may differ from `requested`, and the caller decides) |

**Capture**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `screenshot` | `--out <path.png> [--display <id> \| --window <id> \| --region x,y,w,h] [--own-pixels] [--no-cursor]` | `{"image": ImageRef}` |
| `record` | `--out <path.mp4> --duration-ms N [--display\|--window\|--region] [--fps F]` (blocking) | `{"recording": Recording}`; serve streams `progress` |
| `record-start` | `--out <path.mp4> [--display\|--window\|--region] [--fps F]` | `{"recording": Recording}` (state `recording`) |
| `record-stop` | `<recording-id>` | `{"recording": Recording}` (state `stopped`, `durationMs` and `frames` set) |
| `recordings` | — | `{"recordings": [Recording]}` |

**Recordings.** `record` and `record-stop` report `durationMs`, `frames`,
`width` and `height` **measured from the finalized file**: an MP4's from its
container (the video track's duration, sample count and presentation size),
a PNG sequence's from its frames (its duration is frames / fps). A file whose
container is not finalized (no `moov` index, zero duration, no samples, a
frame that does not decode) is exit 5 / `capture-failed` with
`details.recording` (the recording, state `failed`), never state `stopped`;
`recordings` lists it as `failed`.

`--out` is required: GuiAssert writes where it is told and keeps no capture
archive. With no `--display` / `--window` / `--region`, a capture verb uses the
session's primary display. A recording whose `format` is `png-sequence` (only
the fixture without the media backend, §9.2) treats `--out` as a directory and
writes `000000.png`, `000001.png`, … into it. The output file is written to a temporary name in the same directory
and renamed when complete, so a reader never sees a partial PNG or MP4.

**OCR**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `ocr` | `(--image <path> \| (--display <id> \| --window <id> \| --region x,y,w,h) --out <path.png>) [--lang <code>…] [--psm N] [--upscale F] [--invert auto\|never\|always] [--min-confidence C]` | `{"image": ImageRef, "backend": str, "languages": [str], "words": [OcrWord], "text": str}` (`text` in reading order) |

Capturing for OCR requires `--out`, so the frame the words refer to is always
available to the caller. `--psm` and `--invert` are Tesseract preprocessing
knobs; an engine that has no equivalent rejects them (`unsupported-option`).

**Accessibility tree**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `tree` | `(--pid N \| --app <name> \| --window <id> \| --focused) [--depth N] [--max-nodes N (default 5000)]` | `{"root": Node, "nodeCount": int, "truncated": bool}` |
| `find` | `[--pid\|--app\|--window] [--role r] [--name s] [--name-contains s] [--ignore-case] [--state s]… [--limit N]` (matching rules above) | `{"elements": [Element], "truncated": bool}` |
| `element` | `<path>` | `{"element": Element}` |
| `element-action` | `<path> <action> [--value v \| --value-stdin]` (`press`, `focus`, `set-value`, `increment`, `decrement`, `expand`, `collapse`, `select`, `show-menu`, `scroll-to-visible`; `--value` / `--value-stdin` only for `set-value`, and `set-value --value ""` is valid and clears the field) | `{"element": Element, "action": str}` (the element re-read after the action) |
| `wait` | `(--element <filter flags as in find> \| --text <needle> [--ocr-region x,y,w,h] --out-dir <dir> \| --window <query flags as in windows> \| --window-gone <query>) --wait-ms N [--interval-ms N]` | `{"matched": true, "elapsedMs": int, "attempts": int, "element": Element\|null, "word": OcrWord\|null, "image": ImageRef\|null, "window": Window\|null}`; on expiry exit 7 / `condition-not-met` with `details.attempts`; serve streams `poll` |

`wait --wait-ms` bounds the wait condition and expires as `condition-not-met`;
the global `--timeout-ms` bounds the whole verb and expires as `deadline`.
When both are given and `--timeout-ms` is not larger than `--wait-ms`, the
invocation is `bad-args` / `conflicting-arguments`, so the reason a caller sees
never depends on a race between the two clocks.

**Input**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `move` | `--to x,y` | `{"input": InputReport}` |
| `click` | `--at x,y [--button left\|right\|middle] [--count N] [--modifiers cmd,shift,…]` | `{"input": InputReport}` |
| `drag` | `--from x,y --to x,y [--path x,y;x,y;…] [--button b] [--steps N] [--duration-ms N]` | `{"input": InputReport}` (`path` set) |
| `scroll` | `--at x,y --dx N --dy N [--unit line\|pixel]` | `{"input": InputReport}` |
| `type` | `(<text> \| --text-file <path> \| --stdin)` `[--interval-ms N]` | `{"input": InputReport}` (`length` set, text not echoed) |
| `key` | `<combo>` e.g. `cmd+s`, `ctrl+shift+Tab`, `Return` (names from the key table above; unknown names are `bad-args`) | `{"input": InputReport}` (`keys` normalized) |

**Secrets off `argv`.** On the one-shot CLI, `argv` is visible to other local
users through the process table, and `--text-file` puts the text on disk.
`type --stdin` reads the text to type from standard input, and
`element-action <path> set-value --value-stdin` the value to set; both take
the input whole and exactly as given (nothing is stripped, a trailing newline
is typed), at most 1 MiB, and it must be valid UTF-8. Exactly one of `<text>`,
`--text-file` and `--stdin` is given. The input is read to its end (a
terminal, too, until end-of-file); an empty input is the empty string, and a
standard input that is closed or cannot be read is exit 2 / `invalid-value`.
A read still waiting for its writer is interrupted by the `--timeout-ms`
deadline (exit 7) and by a signal (exit 8), like any other wait. Over `serve`
the input is the `run` request's `stdin` key (§8.3), and since a request line
is at most 1 MiB, its JSON-escaped `stdin` is bounded by that as well.

**Drag paths.** `drag --path x,y;x,y;…` adds up to 1000 waypoints between
`--from` and `--to`: the button is pressed at `--from`, the pointer passes
through every waypoint in order with the button held, and it is released at
`--to`; `--steps` pointer events are delivered per segment and
`--duration-ms` spans the whole drag. A drag cannot be composed from
separate `move` requests, because the button must stay down.

Input verbs act at desktop coordinates in the given session. They report what
was delivered, not what the application did; checking the effect is the
caller's next `windows` / `tree` / `screenshot`.

**Vision (pure core; no session, no permission)**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `vision-compare` | `<a.png> <b.png> [--tiles GXxGY]` | `{"width": int, "height": int, "ssim": float, "tiles": {"grid": [int, int], "values": [float], "min": float}\|null, "phashDistance": int, "edgeChangeRatio": float}`; different sizes are `bad-args` |
| `vision-segment` | `(<video> [--fps F] [--scale-width W] \| --frames <dir-of-png>) [--threshold T]` (video input needs the media backend) | `{"source": {"path": str, "durationS": float\|null, "width": int, "height": int}, "params": {"fps": float\|null, "scaleWidth": int\|null, "threshold": float}, "segments": [{"index": int, "tStart": float, "tEnd": float, "changeScore": float}]}` |
| `vision-windows` | `<image.png> [--ocr]` | `{"image": {"path": str, "width": int, "height": int}, "windows": [{"bbox": Rect, "confidence": float, "titleText": str\|null, "text": str\|null}]}` (`titleText`/`text` are `null` without `--ocr`) |

`vision-segment` defaults (written down in GS4; they fill in what the 1.0
table leaves unstated and change no shape or meaning): `--threshold` 0.35, applied to the most-changed cell of a
4x4 grid of tile SSIMs; `--frames` at `--fps` 1 and unscaled; a video sampled
at `--fps` 2 and scaled to `--scale-width` 320 (ffmpeg samples and scales it,
the pure core scores it). `params` reports the values applied, so a video's
`scaleWidth` is never `null`; `source.width` / `height` are the source's own
size (the first PNG frame's, or the video stream's) whatever the scaling, and
`source.durationS` is the frame count over the rate for `--frames` and the
container duration for a video (`null` when the container states none). A
`--scale-width` keeps the aspect ratio, rounding the height to the nearest
pixel. Video input without ffmpeg is exit 4 / `missing-tool`, a file that is
not a readable video is exit 2 / `invalid-value`; `capabilities` reports
`video-decode` `available` when ffmpeg and ffprobe are found and `supported`
only when `--probe` ran ffmpeg.

The existing `gui-assert-vision` program (`analyze`, `find`, `extract-frame`,
`contact-sheet`, `windows`) is unchanged; its pure parts become callable through
these verbs.

**Streaming (serve-first)**

| Verb | Arguments | `data` |
| --- | --- | --- |
| `watch` | `(--windows \| --frames --out-dir <dir> [--fps F]) [--duration-ms N] [--events-file <path>]` | `{"events": int, "elapsedMs": int}`; serve streams `windows-changed` / `frame` events until `--duration-ms`, cancel or shutdown. On the one-shot CLI `--duration-ms` and `--events-file` are required, and events are appended there as NDJSON (stdout stays one line). |

### 7.6 State directory

The first configured location wins (never "first writable", so separate
processes agree without probing):

1. `--state-dir <root>`
2. `$GUIASSERT_STATE_DIR`
3. macOS `~/Library/Application Support/GuiAssert/state`; Linux
   `$XDG_STATE_HOME/guiassert` or `~/.local/state/guiassert`; Windows
   `%LOCALAPPDATA%\GuiAssert\state`

Layout: `sessions/<id>.json` (`{"schema": "guiassert/session/1", …Session,
"private": {…backend handle…}}`), `recordings/<id>.json`, `fixture/` (§9.2),
`serve.sock` (§8.1). Records are written with write-then-rename, mode 0600,
directory 0700. A per-session lock serializes verbs that mutate a session;
a verb that cannot take it within its deadline is `backend-error` / `busy`.
Records from a newer schema are refused (`internal`), never half-read.

### 7.7 Contract versioning

**Contract `guiassert-desktop/1.0` is FROZEN** (2026-10-20, after GS2.1
decided and implemented the consumer requests C1–C17 of the milestone file).
Everything this section's tables, objects and rules say is the 1.0 contract;
from here on every change is an **additive 1.x minor** under the rules
below, and anything that would change a shape or a meaning needs major 2.

- The contract is `guiassert-desktop/<major>.<minor>`; `version` reports it, and
  so does the serve `ready` line.
- **Minor** (compatible): a new verb, a new optional flag, a new key in a
  `data` object, a new `reason`, a new event type, a new backend name.
- **Major** (breaking): removing or renaming a verb, flag or key; changing a
  type, an exit code, a kind, or the meaning of an existing value.
- The contract table in this document and `core/contract.nim` change together;
  `tests/contract/tcontract_schema.nim` checks that every verb listed here is
  implemented, that the fixture emits every documented key of its `data`, and
  that the closed lists written here (the reasons of §7.3, the feature
  vocabulary and degraded reasons, the key table) equal the ones the code
  enforces (`core/contract`, `core/keys`).
- A binary implements exactly one major. `--contract <major>` and the serve
  `hello` let a consumer fail fast on a mismatch.

## 8. `guiassert serve`

`serve` keeps one process alive so that consumers can run many verbs without
paying start-up cost, receive streaming events, cancel requests, and own
sessions whose lifetime is bound to the connection.

### 8.1 Transports

- `guiassert serve --stdio` (default): NDJSON requests on stdin, NDJSON
  messages on stdout, diagnostics on stderr. One client: the parent process.
- `guiassert serve --listen unix:<path>` (default path `<state-dir>/serve.sock`):
  a Unix domain socket (an AF_UNIX socket on Windows as well), created mode
  0600 in a 0700 directory; each connection's peer uid is checked
  (`SO_PEERCRED` / `getpeereid`) and must equal the daemon's. Several clients
  may connect; each connection is independent.
- No TCP transport in contract v1.

`serve` takes `--stdio` or `--listen unix:<path>` (exactly one; `--stdio` when
neither is given), `--max-concurrency <n>` (§8.5) and the global flags, which
become the defaults of every request on it. A `run` request whose `argv` names
`serve` is `bad-args` / `invalid-value`; a daemon never starts a nested daemon.

### 8.2 Framing

One JSON object per line, UTF-8, `\n`-terminated, no embedded newlines. A
request line longer than 1 MiB is rejected with a `protocol-error` and
discarded. Every message carries `"v": 1` (the serve protocol version, which
moves with the contract major).

On start the daemon writes one line before reading anything:

```jsonc
{"v":1,"type":"ready","data":{"pid":4242,"guiassert":"0.2.0",
 "contract":{"name":"guiassert-desktop","major":1,"minor":0},"transport":"stdio"}}
```

### 8.3 Requests

```jsonc
{"v":1,"id":"r1","op":"run","argv":["screenshot","--out","/tmp/a.png"],"timeoutMs":5000}
{"v":1,"id":"h1","op":"hello","contract":[1]}
{"v":1,"id":"c1","op":"cancel","target":"r1"}
{"v":1,"id":"s1","op":"shutdown","drain":false}
```

- `id`: client-chosen, `[A-Za-z0-9._:-]{1,64}`, unique among the
  connection's in-flight requests. A duplicate in-flight id is a
  `protocol-error` naming it, and the request does not run.
- `op: "run"`: `argv` is exactly a CLI invocation without the program name. It
  is parsed by the same parser and executed by the same code as the CLI, so the
  envelope is **byte-identical** to the CLI's stdout line for the same argv and
  state. `timeoutMs` is equivalent to `--timeout-ms`. `stdin` (optional, a
  string) is the request's standard input, what `type --stdin` and
  `element-action … --value-stdin` read (the daemon's own stdin is the
  protocol stream and is never a verb's input); a request with `stdin` whose
  argv reads none is exit 2 / `conflicting-arguments`, and `--stdin` in a
  request without it is exit 2 / `missing-argument`.
- `op: "hello"`: optional; answers `{"contract": …, "accepted": bool}` with
  `accepted: false` and exit 2 / `contract-unsupported` when none of the listed
  majors is implemented.
- Unknown `op`, unknown keys, a missing `id`, or a line that is not a JSON
  object are a `protocol-error`; the connection stays open.

### 8.4 Responses and events

Every accepted request receives zero or more `event` messages and then
**exactly one** terminal `result`:

```jsonc
{"v":1,"id":"r9","type":"event","seq":0,"event":"progress","data":{"elapsedMs":1000,"frames":30}}
{"v":1,"id":"r9","type":"result","exit":0,
 "envelope":{"ok":true,"verb":"record","data":{"recording":{…}}}}
{"v":1,"id":null,"type":"protocol-error",
 "error":{"code":2,"kind":"bad-args","message":"duplicate in-flight id \"r9\"","reason":"invalid-value"}}
```

- `seq` counts a request's events from 0 without gaps.
- `result.exit` equals the CLI exit code; `result.envelope` is the CLI
  envelope. `cancel`, `hello` and `shutdown` answer with a `result` too
  (verbs `cancel` / `hello` / `shutdown`).
- Event types in contract 1.0: `progress` (`record`), `poll` (`wait`:
  `{"attempt", "elapsedMs", "observed"}`), `windows-changed` and `frame`
  (`watch`), `session-state` (a session owned by this connection changed
  state; below).
- `session-state` is the one **connection** event: a session outlives the
  `session-start` request that created it, so the event belongs to no
  request. It carries `"id": null` and its own `seq`, counted per connection
  from 0 without gaps (separately from every request's `seq`), and
  `data: {"session": Session}`, the session as `session-info` reports it.
  The daemon sends it for the `lifetime: owner` sessions of the connection,
  and only for changes that no request on the connection reported itself:
  when the session's state changes on its own (its host exited: `state:
  "error"`), which the daemon checks at least once a second, and when the
  daemon stops the session because the connection closes or the daemon
  shuts down (`state: "stopped"`, before the `shutdown` line). A session
  whose record another client removed (`session-stop` on another
  connection) is no longer owned by this one and gets no event; the
  stopping client's own result reports it.

### 8.5 Concurrency and ordering

Requests on one connection that target the same session run **in arrival
order**, one at a time (input must not interleave). Requests for different
sessions, and session-less verbs (`vision-*`, `ocr --image`, `version`,
`capabilities`), may run concurrently, up to `--max-concurrency` (default 4).
Results may therefore arrive out of order; clients match by `id`.

### 8.6 Cancellation and deadlines

`cancel` asks a running or queued request to stop. A queued request is removed
and answers `exit 8` / `request`; a running one is interrupted at its next safe
point (between input events, between poll attempts, at frame boundaries; a
recording is finalized so the partial file stays valid) and answers `exit 8`.
The `cancel` result says `{"target": id, "state": "cancelled"|"already-finished"}`;
an unknown target is exit 3. A request whose `timeoutMs` expires behaves as
cancelled but answers `exit 7` / `deadline`.

### 8.7 Shutdown

The daemon shuts down on `op: "shutdown"`, on EOF of stdin (`--stdio`), or on
SIGTERM/SIGINT. It stops accepting requests; with `drain: true` it lets
in-flight requests finish, otherwise it cancels them (each still gets its
`result`, `exit 8` / `shutdown`); it stops every session with `lifetime: owner`
that belongs to the closing connection(s); it writes
`{"v":1,"type":"shutdown","data":{"cancelled":N,"sessionsStopped":N}}` and exits
0. A client disconnect on the socket transport is a shutdown of that
connection only. Sessions with `lifetime: detached` are left running.

## 9. Test strategy

### 9.1 Layers

| Layer | What runs | Where |
| --- | --- | --- |
| core unit | pure procs on in-memory images and fixture JSON | every host, default `just test` |
| core purity | `tests/tcore_purity.nim` (§3.2) | every host |
| contract | the real `guiassert` binary and real `guiassert serve` with the fixture backend: envelope shape, every verb, every exit code, CLI/serve byte parity, cancellation, shutdown | every host, `just test-contract` |
| backend live | each platform backend against the real OS: real compositor, real window server, real tesseract/Vision, a real fixture application | per platform, `just test-live-<os>` |
| parity | the consumer scenarios (GS12–GS14) against GuiAssert's backends | per platform |

Workspace policy applies: mock as little as possible, and every test file that
uses a stand-in justifies it in its header comment. The fixture backend is the
single sanctioned stand-in for the contract layer, and it sits **below** the
CLI, serve and serialization that are under test.

### 9.2 The fixture backend

`fixture` implements every module (capture, ocr, tree, input, session)
deterministically from a scenario file, with no OS access:

- Selected with `--backend fixture` or `GUIASSERT_BACKEND=fixture` (per module
  as well). `guiassert-fixture` is the same CLI built `-d:guiassertMinimal`, so
  a consumer can depend on a binary that contains no platform code at all.
- `GUIASSERT_FIXTURE_SCENARIO=<file.json>` (or `--fixture-scenario`) describes
  displays, windows, apps, an accessibility tree, a base frame (PNG) and the
  OCR words on it. A built-in default scenario ("fixture-form": one window with
  a labelled text field, a checkbox and a Submit button) is used when none is
  given. Scenario files are parsed strictly (unknown keys are rejected).
  The built-in scenario's form also has a **protected** Password field
  (`AXSecureTextField`, state `protected`, §7.5) whose characters the fixture
  never reports or draws (it shows one `*` per character), and its window
  names a `document`. Scenario keys beyond the contract objects: per node an
  optional `text` (default: a label's name, a text field's value) and
  `onPress`; at the top `launchWindow` (default `true`; `false` makes
  launched applications open no window, so `--wait-window-ms` expires) and
  the rendering and clock keys of the built-in scenario. An app's
  `accessible` must agree with whether the scenario gives it a tree.
- State lives under `<state-dir>/fixture/` so that verbs compose **across
  invocations**: `type` into the focused text field changes that node's
  `value`; `click` on the Submit button's bounds adds a status label to the
  tree and to the OCR words; `session-start` creates a session record that a
  later `session-list` returns; `record-start`/`record-stop` write a small
  valid MP4 (or a PNG sequence when the media backend is not compiled in, with
  `format` saying so).
- Captured frames are rendered by the pure core (base PNG plus the scenario's
  text drawn with a built-in bitmap font), and the fixture's OCR returns the
  words it drew, so `screenshot` → `ocr --image` round-trips exactly.
- Failure injection: `GUIASSERT_FIXTURE_FAIL=<verb>:<code>[:<reason>]` (comma
  separated) makes that verb fail with that code; `GUIASSERT_FIXTURE_DENY=
  screen-recording|accessibility` makes the matching verbs return exit 6;
  `GUIASSERT_FIXTURE_UNAVAILABLE=<module>` makes a module exit 4;
  `GUIASSERT_FIXTURE_DELAY_MS=<verb>:<ms>` makes a verb slow enough to cancel;
  `GUIASSERT_FIXTURE_HOST=exit-before-ready|never-ready` makes the session
  host of the next `session-start` exit, or never report ready (exit 5 /
  `session-failed`, §6.1); `GUIASSERT_FIXTURE_RECORDING=unfinalized` writes
  recordings without their container index (exit 5 / `capture-failed`,
  §7.5).
- Fixture sessions are ready once their session host has seen its record;
  their `env` is `{"GUIASSERT_SESSION": <id>}` and their `envUnset`
  `["DISPLAY", "WAYLAND_DISPLAY"]` (a fixture session has no display server,
  so the host's must not leak in). Every `app-launch` records the
  environment the process would receive relative to the session in
  `<state-dir>/fixture/launches/<pid>.json` (`{"schema":
  "guiassert/fixture-launch/1", "session", "pid", "env": {…}, "envUnset":
  […]}`: `Session.env` merged with `--env`, and the `envUnset` names that
  `--env` does not set), so a consumer's launch policy is observable without a
  real process.
- The fixture is shipped as a flake package output (`guiassert-fixture`)
  alongside `guiassert`, so consumers pin both by revision.

Agent Harbor's contract tests for its GuiAssert backend run against this
fixture binary, the way GuiAssert's own contract tests do; neither needs a
display, a permission or a network.

### 9.3 Live backend tests

Live tests start a real fixture application (a small AppKit app on macOS, a
GTK app on Linux, a Win32 app on Windows, each built from source in this repo
at test time) and assert against what the OS reports. Each live test carries a
negative control (the same probe on a state where the answer must differ) so a
probe that reads a constant cannot pass.

### 9.4 TCC-gated tests on macOS

Screen Recording and Accessibility are TCC permissions granted to a code
identity. GuiAssert never asks the operator to grant them to a terminal
(which would grant every process the terminal runs) and never tries to bypass
TCC:

- TCC-gated work runs inside the signed GuiAssert helper bundle (the existing
  `GuiAssertCapture.app` mechanism, extended to Accessibility and input), whose
  designated requirement is keyed on bundle id and signing certificate, so
  rebuilds keep the grant (`GUIASSERT_CAPTURE_SIGN_IDENTITY`).
- The default suites (`just test`, `just test-contract`) contain no TCC-gated
  test. TCC-gated tests are compiled only with `-d:tccLive` and run by
  `just test-live-macos`.
- When a gated test runs and the grant is missing, it **fails** (never skips)
  with `BLOCKED: TCC <Screen Recording|Accessibility> for <bundle or binary
  path>` and the grant click-path, so a missing grant cannot pass as green.
- Every gated suite first runs the unprivileged positive control (window
  enumeration without titles) so "no permission" and "nothing works" are told
  apart.
- CI runners are not granted TCC permissions; macOS CI runs the default suites
  and the contract tests. Live macOS evidence is recorded in the milestone file
  from a host with the grants.

## 10. CI

GuiAssert's workflows run on the organization's self-hosted runner classes:
the three Nix-capable legs `[self-hosted, linux, x64]`,
`[self-hosted, linux, arm64]` and `[self-hosted, macos, arm64]` inside
`nix develop`, and a Windows job on
`[self-hosted, windows, x64, dev-env-ready]` with the non-Nix toolchain that is
defined but not a required check (Windows capacity is scarce; the job may
queue). Windows arm64 is a documented omission until the Windows backends are
measured on it (GS11); the workflow says so in a comment. No workflow runs on the
`agents` branch; `agents` is gated locally by `just test` and
`just test-contract`, and full CI runs on the promotion pull request into `dev`.
Details are in GS1.

## 11. What stays in Agent Harbor

GuiAssert is mechanism. Agent Harbor keeps every policy decision, including:

- **Session lifecycle policy**: when a desktop session is created, for which
  task, under which name, how long it lives, when it is torn down, and how a
  session is bound to an agent or executor. GuiAssert only starts, lists and
  stops sessions when told.
- **Grants**: which agent may use which session, application or verb; approval
  flows; who may see a session through a remote viewer.
- **MCP**: the MCP server, tool definitions and descriptions, and the mapping
  from tools to GuiAssert verbs.
- **Archive storage**: where screenshots and recordings go after GuiAssert
  writes them to the path it was given; retention, upload, manifests.
- **Encryption** of stored artifacts.
- **Budgets**: rate limits, capture counts, durations, resource quotas.
  GuiAssert offers deadlines (`--timeout-ms`) and nothing else.
- **Masking and redaction** of sensitive regions or text in captures and OCR
  output.
- Remote-view and human-intervention surfaces, login requests, browser
  profiles, screen-reader speech capture, and script runners.

Agent Harbor drives GuiAssert through a backend that runs the CLI or the serve
daemon and parses this contract. It is selected opt-in, with the existing
native paths remaining the default until the parity milestones
(GS12–GS14) are green for the platform in question; the duplicated native code
is removed only after parity holds on every platform (GS16).

## 12. Open questions

1. **macOS isolated sessions without console login.** Whether a SkyLight-created
   session can host a usable `gui/<uid>` domain is measured in GS9; if not,
   `isolated` requires an existing session of the dedicated account.
2. **Windows input on a non-input desktop.** Posted input does not reach
   applications that read raw input; GS11 decides whether a separate Windows
   session is needed instead.
3. **PNG in core.** The pure PNG codec needs inflate/deflate; GS1 either writes
   them in core or vendors a small pure-Nim implementation under the MIT
   licence, keeping the stdlib allowlist intact.
4. **Remote transport.** Contract v1 has no TCP. If a consumer needs to reach a
   host's daemon without its own transport, a later minor version can add an
   authenticated listener; until then, remote use goes through the consumer's
   transport.
