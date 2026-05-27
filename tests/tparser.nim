## test_script_interpreter_parsing
##
## Verifies that:
##   1. The YAML parser correctly deserialises a 4-keyframe sample.
##   2. The JSON parser produces an identical Script for the same content.
##   3. Out-of-order timestamps raise `ScriptValidationError`.
##   4. Overlapping narration / next-keyframe schedules raise
##      `ScriptValidationError`.
##   5. Edge cases (empty timeline, single keyframe, missing metadata) parse
##      without error.

import std/[json, options, strutils, unittest]
import ../src/gui_assert/parser

const fourKeyframeYaml = """
metadata:
  title: "CodeTracer Hot Code Reloading Tutorial"
  resolution: "1920x1080"
  fps: 30
timeline:
  - time: 0.0
    action: launch_app
    params:
      app: "vs-code"
      workspace: "./examples/fibonacci"
    narration: "Welcome to CodeTracer."

  - time: 3.5
    action: move_cursor
    params:
      target: "editor.line(8)"
    narration: "Tracepoint."

  - time: 5.0
    action: click
    params:
      button: "left"

  - time: 6.2
    action: type_text
    params:
      text: "print(f'n={n}')"
      wpm: 80
"""

const fourKeyframeJson = """
{
  "metadata": {
    "title": "CodeTracer Hot Code Reloading Tutorial",
    "resolution": "1920x1080",
    "fps": 30
  },
  "timeline": [
    {
      "time": 0.0,
      "action": "launch_app",
      "params": {
        "app": "vs-code",
        "workspace": "./examples/fibonacci"
      },
      "narration": "Welcome to CodeTracer."
    },
    {
      "time": 3.5,
      "action": "move_cursor",
      "params": { "target": "editor.line(8)" },
      "narration": "Tracepoint."
    },
    {
      "time": 5.0,
      "action": "click",
      "params": { "button": "left" }
    },
    {
      "time": 6.2,
      "action": "type_text",
      "params": { "text": "print(f'n={n}')", "wpm": 80 }
    }
  ]
}
"""

proc assertSampleScript(s: Script) =
  check s.metadata.title == "CodeTracer Hot Code Reloading Tutorial"
  check s.metadata.resolution == "1920x1080"
  check s.metadata.fps == 30
  check s.timeline.len == 4

  check s.timeline[0].time == 0.0
  check s.timeline[0].action == "launch_app"
  check s.timeline[0].params["app"].getStr == "vs-code"
  check s.timeline[0].params["workspace"].getStr == "./examples/fibonacci"
  check s.timeline[0].narration.isSome
  check s.timeline[0].narration.get == "Welcome to CodeTracer."

  check s.timeline[1].time == 3.5
  check s.timeline[1].action == "move_cursor"
  check s.timeline[1].params["target"].getStr == "editor.line(8)"
  check s.timeline[1].narration.isSome
  check s.timeline[1].narration.get == "Tracepoint."

  check s.timeline[2].time == 5.0
  check s.timeline[2].action == "click"
  check s.timeline[2].params["button"].getStr == "left"
  check s.timeline[2].narration.isNone

  check s.timeline[3].time == 6.2
  check s.timeline[3].action == "type_text"
  check s.timeline[3].params["text"].getStr == "print(f'n={n}')"
  check s.timeline[3].params["wpm"].getInt == 80
  check s.timeline[3].narration.isNone

suite "test_script_interpreter_parsing":

  test "yaml deserialises a 4-keyframe sample correctly":
    let s = parseScriptYaml(fourKeyframeYaml)
    assertSampleScript(s)

  test "json deserialises a 4-keyframe sample correctly":
    let s = parseScriptJson(fourKeyframeJson)
    assertSampleScript(s)

  test "yaml and json produce identical timeline contents":
    let yScript = parseScriptYaml(fourKeyframeYaml)
    let jScript = parseScriptJson(fourKeyframeJson)
    check yScript.timeline.len == jScript.timeline.len
    for i in 0 ..< yScript.timeline.len:
      check yScript.timeline[i].time == jScript.timeline[i].time
      check yScript.timeline[i].action == jScript.timeline[i].action
      check yScript.timeline[i].narration == jScript.timeline[i].narration
      check $yScript.timeline[i].params == $jScript.timeline[i].params

  test "out-of-order timestamps raise ScriptValidationError":
    const badYaml = """
metadata:
  title: "bad"
  fps: 30
timeline:
  - time: 5.0
    action: click
  - time: 3.0
    action: click
"""
    expect ScriptValidationError:
      discard parseScriptYaml(badYaml)
    const badJson = """
{
  "timeline": [
    {"time": 5.0, "action": "click"},
    {"time": 3.0, "action": "click"}
  ]
}
"""
    expect ScriptValidationError:
      discard parseScriptJson(badJson)

  test "narration overlap raises ScriptValidationError":
    # 25 words at 150 wpm = 25/150 * 60 = 10 seconds of narration.
    # Next keyframe at t=5.0 is well within that window → must reject.
    let twentyFiveWords = "one two three four five six seven eight nine ten " &
      "eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen " &
      "nineteen twenty twenty-one twenty-two twenty-three twenty-four twenty-five"
    let overlapYaml = "timeline:\n" &
      "  - time: 0.0\n" &
      "    action: launch_app\n" &
      "    narration: \"" & twentyFiveWords & "\"\n" &
      "  - time: 5.0\n" &
      "    action: click\n"
    expect ScriptValidationError:
      discard parseScriptYaml(overlapYaml)

    let overlapJson = """
{
  "timeline": [
    {"time": 0.0, "action": "launch_app", "narration": "TWENTYFIVE"},
    {"time": 5.0, "action": "click"}
  ]
}
""".replace("TWENTYFIVE", twentyFiveWords)
    expect ScriptValidationError:
      discard parseScriptJson(overlapJson)

  test "edge: empty timeline":
    let s = parseScriptYaml("metadata:\n  title: \"x\"\ntimeline:\n")
    check s.timeline.len == 0
    check s.metadata.title == "x"

    let sj = parseScriptJson("""{"metadata": {"title": "x"}, "timeline": []}""")
    check sj.timeline.len == 0

  test "edge: single keyframe":
    let s = parseScriptYaml("""
timeline:
  - time: 1.0
    action: click
""")
    check s.timeline.len == 1
    check s.timeline[0].action == "click"

  test "edge: missing metadata block":
    let s = parseScriptYaml("""
timeline:
  - time: 0.0
    action: click
""")
    check s.metadata.title == ""
    check s.metadata.fps == 0
    check s.timeline.len == 1

    let sj = parseScriptJson("""{"timeline": [{"time": 0.0, "action": "click"}]}""")
    check sj.metadata.title == ""
    check sj.timeline.len == 1
