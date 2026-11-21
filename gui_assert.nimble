version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Visual + scripting assertion library for CodeTracer GUI sessions"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run tests":
  exec "bash scripts/run-default-tests.sh --nimble"
