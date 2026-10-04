version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Visual + scripting assertion library for CodeTracer GUI sessions"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

proc runDeclaredTest(command: string) =
  when defined(linux):
    exec "bash scripts/run-test-in-display.sh " & command
  else:
    exec command

task test, "Run tests":
  runDeclaredTest "nim c -r --hints:off tests/tnimcache_is_worktree_local.nim"
  runDeclaredTest "nim c -r --hints:off tests/tparser.nim"
  runDeclaredTest "nim c -r --hints:off tests/tdriver_browser.nim"
  runDeclaredTest "nim c -r --hints:off tests/tdriver_vscode.nim"
  runDeclaredTest "nim c -r --hints:off tests/tgui_assert.nim"
  runDeclaredTest "nim c -r --hints:off tests/tmedia.nim"
  runDeclaredTest "nim c -r --hints:off tests/tspeech_synthesis.nim"
  runDeclaredTest "nim c -r --hints:off tests/teditor.nim"
  runDeclaredTest "nim c -r --hints:off tests/tcapture.nim"
  runDeclaredTest "nim c -r --hints:off tests/temotive.nim"
  runDeclaredTest "nim c -r --hints:off tests/tdiscovery.nim"
  runDeclaredTest "nim c -r --hints:off tests/twindow_layout.nim"
  runDeclaredTest "nim c -r --hints:off tests/tinput.nim"
  runDeclaredTest "nim c -r --hints:off tests/tpacing.nim"
  runDeclaredTest "nim c -r --hints:off tests/tvideo_analysis.nim"
  runDeclaredTest "nim c -r --hints:off tests/tchange_detect.nim"
  runDeclaredTest "nim c -r --hints:off tests/tvision_windows.nim"
  runDeclaredTest "nim c -r --hints:off tests/tlayout_tree.nim"
  runDeclaredTest "nim c -r --hints:off tests/tvision_cli.nim"
  runDeclaredTest "nim c -r --hints:off tests/tocr_vision.nim"
  runDeclaredTest "nim c -r --hints:off tests/tocr_backends.nim"
