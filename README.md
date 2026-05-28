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

From inside a Nim development shell:

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
