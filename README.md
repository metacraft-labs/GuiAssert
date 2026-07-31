# GuiAssert

Visual and scripting assertion library for CodeTracer GUI sessions. Companion to
`TermAssert` for character-cell terminal assertions, translated into pixel-space
visual-semantic assertions for graphical applications.

This repository currently implements **Milestone M2** of the Video Session
Capture initiative: the precise action-driver scripting protocol.

## Layout

```
GuiAssert/
├── gui_assert.nimble            # Nimble package manifest
├── src/
│   ├── gui_assert.nim           # Public umbrella module
│   └── gui_assert/
│       ├── parser.nim           # JSON/YAML keyframe script parser
│       ├── driver.nim           # Browser / PTY / VS Code drivers
│       └── pty_unix.nim         # Unix PTY primitives (posix_openpt, etc.)
└── tests/
    ├── tparser.nim              # Script interpreter parser tests
    ├── tdriver_browser.nim      # Browser driver emit-JSON test
    ├── tdriver_vscode.nim       # VS Code TCP client test
    └── tgui_assert.nim          # e2e_terminal_action_injection test
```

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
nim c -r --hints:off tests/tparser.nim
nim c -r --hints:off tests/tdriver_browser.nim
nim c -r --hints:off tests/tdriver_vscode.nim
nim c -r --hints:off tests/tgui_assert.nim
```

Or via `nimble test`.

## Talking-head plugins

GuiAssert ships a small built-in talking-head provider called
`stock_avatar` (the `testsrc2` placeholder used in CI dry runs) and
exposes a **plugin contract** so heavyweight providers can live in
sibling repos. Each plugin builds a `TalkingHeadProvider` value with
a `name`, an `isAvailable` probe, and a `generate` proc, then
registers itself with a `TalkingHeadRegistry`:

```nim
import gui_assert/talking_head

let reg = newRegistry()   # `stock_avatar` is pre-registered

# Plugin registration (one-liner exposed by each plugin):
import gui_assert_sadtalker
registerSadTalker(reg)

# Dispatch by provider name — the YAML facing identifier.  The
# registry handles aliases (`""`, `"stock"`, `"placeholder"` all map
# to `stock_avatar`; `"d-id"` maps to `"did"`; everything else is a
# direct lookup).
let opts = TalkingHeadOpts(
  avatarImagePath: some("/path/to/portrait.png"),
  device: "mps",
)
generateTalkingHead(reg, "sadtalker", "/path/to/narration.wav",
                    "/path/to/output.mp4", opts)
```

Available plugins (sibling repos):

- [`GuiAssert-SadTalker`](../GuiAssert-SadTalker/) — local SadTalker
  invocation via a Python 3.10 venv. Apple Silicon MPS supported.
- Reserved names: `did`, `heygen`, `hedra`, `musetalk` — each
  belongs to its own future sibling repo (not yet implemented).

Plugin authors: see
`src/gui_assert/talking_head/stock_avatar.nim` and
`../GuiAssert-SadTalker/src/gui_assert_sadtalker.nim` for the
canonical shape.  Use `cacheKeyFor` + `applyCache` from
`gui_assert/talking_head/core` to avoid re-implementing the cache.

## Design References

- `codetracer-specs/Planned-Work/Video-Session-Capture.md`
- `codetracer-specs/Planned-Work/Video-Session-Capture.milestones.org`
- `codetracer-specs/Planned-Work/GuiAssert-Library.md`
