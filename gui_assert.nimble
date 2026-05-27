version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Visual + scripting assertion library for CodeTracer GUI sessions"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r --hints:off tests/tparser.nim"
  exec "nim c -r --hints:off tests/tdriver_browser.nim"
  exec "nim c -r --hints:off tests/tdriver_vscode.nim"
  exec "nim c -r --hints:off tests/tgui_assert.nim"
