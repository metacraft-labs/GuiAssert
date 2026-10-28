# GuiAssert

Visual and scripting assertion library for CodeTracer GUI sessions. Companion to
`TermAssert` for character-cell terminal assertions, translated into pixel-space
visual-semantic assertions for graphical applications.

It captures the screen and windows, reads them (OCR, layout detection, image
math, accessibility trees), and delivers OS-level input, through one JSON contract
(the `guiassert` program below) and a Nim library.

**Video production lives in [DemoVideoStudio](https://github.com/metacraft-labs/DemoVideoStudio).**
The timeline editor and its web UI, composition (`media`), narration
(`speech_synthesis`), the presenter overlay (`talking_head`, `avatar_track`,
`emotive`), the per-stage artifact project, the storyboard and the keyframe-script
parser and driver moved there with their history. The talking-head and speech
provider plugins (`GuiAssert-*`) build against DemoVideoStudio's plugin contract.
What every module that runs ffmpeg shares — finding the binary and naming files to
it — stays here, in `gui_assert/ffmpeg_tools`.

## Running tests

### Reproducible toolchain (recommended)

The repo ships a `flake.nix` that pins the whole vision toolchain — `nim`,
`nimble`, `ffmpeg` (with `drawtext`/libx264), and `tesseract` 5.x (English
traineddata included). The devShell exports `FFMPEG_BIN`/`FFPROBE`/
`TESSERACT_BIN` (and puts them on `PATH`) so the OCR/ffmpeg modules resolve the
**pinned** binaries with zero host setup:

```sh
nix develop -c nimble test
```

Run just the vision suites the same way:

```sh
nix develop -c bash -c 'for f in tvideo_analysis tvision_windows tvision_cli; do nim c -r --hints:off tests/$f.nim; done'
```

The `just analyze VIDEO` recipe is meant to be run inside this shell too, e.g.
`nix develop -c just analyze session.mp4`.

### Against a host toolchain

From inside any Nim development shell with `ffmpeg`/`tesseract` on `PATH`:

```sh
nim c -r --hints:off tests/tgui_assert.nim
```

Or via `nimble test`.

## The `guiassert` program

`guiassert` is the desktop substrate as a program with a fixed JSON contract
(`guiassert-desktop/1`, `Planned-Work/Desktop-Substrate.md` §7–§8): one verb
per invocation, exactly one JSON envelope line on stdout, and a frozen exit
code (0 ok, 1 internal, 2 bad-args, 3 not-found, 4 backend-unavailable,
5 backend-error, 6 permission-denied, 7 timeout, 8 cancelled). `guiassert
serve` speaks the same verbs as NDJSON over stdio or an owner-only Unix
socket. The CLI is a thin `main` over `gui_assert/cli/run.runInvocation`, so a
Nim program can run verbs without a subprocess.

```sh
just build-cli                     # build/bin/guiassert and build/bin/guiassert-fixture
export GUIASSERT_BACKEND=fixture   # the deterministic fixture desktop (no OS access)
build/bin/guiassert type Ada
build/bin/guiassert click --at 190,278
build/bin/guiassert find --role label --name-contains submitted
# EOF on stdin cancels whatever is in flight; a draining shutdown lets it finish
printf '%s\n' '{"v":1,"id":"r1","op":"run","argv":["displays"]}' \
  '{"v":1,"id":"s1","op":"shutdown","drain":true}' | build/bin/guiassert serve
just test-contract                 # the contract suite, against both binaries
```

Contract 1.1 (GS17) adds what an unattended sign-in needs: `session-start
--vnc-socket` serves a private session over VNC on an owner-only Unix socket
(`Session.vncSocket`; a person watches or takes over through
`ssh -L <port>:<socket> <host>` and a viewer), and `screenshot --secret-stdin`
/ `ocr … --secret-stdin` keep a frame or answer its words only when the secret
given on stdin is not legible in it (else exit 5 / `secret-visible`).

Another flake consumes the program as `packages.<system>.guiassert` of this
flake, pinned by revision (on Linux it carries Xvfb, Openbox, x11vnc, wayvnc,
sway and tesseract on its own PATH):

```nix
inputs.gui-assert.url = "github:metacraft-labs/GuiAssert/<rev>";
# devShell: packages = [ inputs.gui-assert.packages.${system}.guiassert ];
```

`guiassert-fixture` (built `-d:guiassertMinimal`) contains only the pure core
and the fixture backends; consumers' contract tests run against it. The
platform backends (spec §4) answer `backend-unavailable` / `not-implemented`
until their milestones land.

## Desktop-environment targets

`gui_assert/desktop_env` drives a GUI application inside a real desktop
session and checks what the COMPOSITOR reports, not what the application
says about itself. A *target* starts the session, runs the application,
injects pointer and key input, reads windows back, captures frames, changes
desktop settings, and answers *facts*: typed questions about what the desktop
supports and prefers, each marked as measured, declared or configured. A
scenario is written once and computes its expectations from the facts.

```nim
import gui_assert/desktop_env, gui_assert/desktop_env/sway

let t = newSwayTarget(floatingAppIds = @["my-app"])   # or newGnomeTarget()
t.start()
defer: t.stop()
discard t.spawn(@["./my-app"])
let w = t.waitWindow("my-app")
t.drag(w.rect.center, w.rect.center + (100, 0))
if t.boolFact("window.canMaximize"): discard   # …expect a maximize button to act
```

Backends:

- **Headless sway** (`desktop_env/sway`, Linux). A private sway, with its own
  runtime directory and session bus. The settings portal serves GSettings from
  a private keyfile, so `configure("buttonLayout", …)` reaches the application
  the way a desktop's setting would. Input goes through a virtual pointer
  device (`helpers/linux/virtual_pointer.c`) and `wtype`, frames are captured
  with `grim`, and windows are read back through sway's IPC. Facts are
  measured with `helpers/linux/wm_probe.c`, which opens a real window and
  reports what sway grants it.

- **Headless GNOME** (`desktop_env/gnome`, Linux). A private
  `gnome-shell --headless --unsafe-mode` (GNOME Shell with its Mutter), with
  its own runtime directory, session bus and settings, and the settings
  portal. Input goes through Clutter virtual devices inside the shell, the
  mechanism Mutter's remote desktop uses. Windows are read back from Mutter's
  own window list, positions included, and frames come from the shell's
  screenshot API. GNOME draws no window decorations, so this is the target
  where an application must draw its own.

**Attaching** to a session that is already running, such as the
developer's own, is `attachSwayTarget()` / `attachGnomeTarget()`. Nothing is
started, `stop` leaves the session alone, and `configure` is refused unless
`allowConfigure = true`, in which case `stop` restores what it changed. The
GNOME target needs GNOME Shell's unsafe mode, which only the developer can
turn on (Looking Glass: `global.context.unsafe_mode = true`). Without it the
target refuses to attach and says so.

The same scenario runs on every target: `tests/tdesktop_env_targets.nim`
runs one suite on each (`GUIENV_TARGETS=sway,gnome`).

Every failure to prepare the environment raises `EnvError`, naming the target
and the operation. It is never a skip. Run the backend suite inside
`nix develop` (the flake pins sway, the portal stack and the helpers' build
tools):

```sh
nix develop -c just test-desktop-env
```

## macOS still-frame and window-targeted capture

`gui_assert/capture` records **video**. `gui_assert/screen_capture` produces
**single frames** — which is what every assertion actually consumes — through
ScreenCaptureKit:

```nim
import gui_assert

# The positive control. Unprivileged: it works with no permission at all, and
# if it comes back empty nothing else in this module can work either.
for w in listWindows():
  echo w.windowId, " ", w.ownerName, " ", w.bounds

# A full-display still.
discard captureDisplayStill("/tmp/screen.png")

# One window's OWN pixels — not a crop of the screen, so an overlapping window
# cannot corrupt the assertion.
discard captureWindowStill("/tmp/editor.png", initWindowQuery(owner = "iTerm"))

# Or drive the assertion harness straight off a live capture. `waitForText`
# re-invokes the frame source on every poll, so this is a real wait loop.
let harness = newLiveWindowHarness(initWindowQuery(owner = "iTerm"))
doAssert harness.waitForText("fibonacci", timeoutMs = 5000)
doAssert harness.visualCompare("tests/gui/snapshots/golden/editor.png")
```

The path-based API is unchanged: `newGuiAssertHarness(path)` and the
three-argument `visualCompare` / `detectLayoutOverflow` behave exactly as
before.

### The one-time permission

macOS gates screen capture behind TCC. GuiAssert does **not** ask you to grant
it to your terminal — granting a terminal screen recording grants it to every
process that terminal will ever run. Instead it builds and signs its own tiny
bundle, `~/Library/Application Support/GuiAssert/GuiAssertCapture.app`, and
runs the capture inside it:

```sh
nim c -d:captureLive -r --hints:off tests/tscreen_capture.nim
```

The first run builds and signs the bundle, then fails the capture tests with
the exact click-path to grant it (`screen_capture.grantInstructions`). Grant it
once in **System Settings > Privacy & Security > Screen & System Audio
Recording** and the capture tests go green.

The grant is recorded by TCC against the bundle's code-signing *designated
requirement*. With a real signing identity — an Apple Development certificate
from a free Apple ID is enough — that requirement is keyed on the bundle
identifier and the signing certificate, not on the code bytes, so rebuilding
the helper does **not** revoke the grant. `ensureCaptureApp` verifies this after
every re-sign and refuses rather than letting a silently-dead grant look like a
capture bug. An ad-hoc signature (`codesign -s -`) yields a `cdhash`-keyed
requirement, which every rebuild invalidates; set
`GUIASSERT_CAPTURE_SIGN_IDENTITY` to avoid that.

Environment overrides: `GUIASSERT_CAPTURE_APP`, `GUIASSERT_CAPTURE_APP_DIR`,
`GUIASSERT_CAPTURE_BUNDLE_ID`, `GUIASSERT_CAPTURE_SIGN_IDENTITY`,
`GUIASSERT_CAPTURE_HELPER`, `GUIASSERT_CAPTURE_HELPER_SRC`, `SWIFTC`.

Two things worth knowing before you debug a failure:

- **Window titles are invisible until the grant exists.** macOS redacts
  `kCGWindowName` for ungranted code, so `--title` / `titleContains` queries
  cannot match before you grant. Match on `owner` instead. Every report carries
  `titlesVisible` so a test can tell "no such window" from "I cannot read any
  title".
- **`target-not-found` and `denied` are different.** The helper attests the
  target against the unprivileged window list before it calls ScreenCaptureKit,
  so `StillCaptureTargetNotFound` and `StillCaptureDenied` are distinct
  exceptions with distinct remedies.

## Design References

- `Planned-Work/Desktop-Substrate.md` (with `Desktop-Substrate.milestones.org`):
  GuiAssert as a desktop substrate — the pure core and opt-in backends, the
  `guiassert` CLI / `serve` JSON contract, and off-screen sessions.
- `Planned-Work/Vision-Understanding.md` (with `Vision-Understanding.milestones.org`)
- `codetracer-specs/Planned-Work/Video-Session-Capture.md`
- `codetracer-specs/Planned-Work/Video-Session-Capture.milestones.org`
- `codetracer-specs/Planned-Work/GuiAssert-Library.md`
