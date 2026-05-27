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

## Design References

- `codetracer-specs/Planned-Work/Video-Session-Capture.md`
- `codetracer-specs/Planned-Work/Video-Session-Capture.milestones.org`
- `codetracer-specs/Planned-Work/GuiAssert-Library.md`
