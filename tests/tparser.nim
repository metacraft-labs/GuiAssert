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

import std/[json, options, strutils, tables, unittest]
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

  test "absence of new fields yields safe defaults":
    # Legacy scripts (no targets, no window_layout, no target_window)
    # must continue to parse and yield empty defaults.
    let s = parseScriptYaml(fourKeyframeYaml)
    check s.metadata.targets.len == 0
    check s.metadata.windowLayout.len == 0
    # When targets is empty, target_window stays as the empty string —
    # legacy single-window dispatch.
    for kf in s.timeline:
      check kf.targetWindow == ""

  test "new metadata.targets and window_layout parse from JSON":
    const j = """
    {
      "metadata": {
        "title": "Three Window",
        "resolution": "1920x1080",
        "fps": 30,
        "targets": ["desktop", "terminal", "vscode"],
        "window_layout": {
          "desktop":  {"x": 0,    "y": 0,   "width": 1280, "height": 1080},
          "terminal": {"x": 1280, "y": 0,   "width": 640,  "height": 540},
          "vscode":   {"x": 1280, "y": 540, "width": 640,  "height": 540}
        }
      },
      "timeline": [
        {"time": 0.0, "action": "click", "target_window": "desktop"},
        {"time": 1.0, "action": "type_text", "target_window": "terminal",
         "params": {"text": "echo hi"}},
        {"time": 2.0, "action": "open_file", "target_window": "vscode",
         "params": {"path": "x.nim"}}
      ]
    }
    """
    let s = parseScriptJson(j)
    check s.metadata.targets == @["desktop", "terminal", "vscode"]
    check s.metadata.windowLayout.len == 3
    check s.metadata.windowLayout["desktop"].x == 0
    check s.metadata.windowLayout["desktop"].width == 1280
    check s.metadata.windowLayout["terminal"].x == 1280
    check s.metadata.windowLayout["terminal"].height == 540
    check s.metadata.windowLayout["vscode"].y == 540
    check s.timeline[0].targetWindow == "desktop"
    check s.timeline[1].targetWindow == "terminal"
    check s.timeline[2].targetWindow == "vscode"

  test "new metadata.targets and window_layout parse from YAML":
    const y = """
metadata:
  title: "Three Window"
  resolution: "1920x1080"
  fps: 30
  targets: ["desktop", "terminal", "vscode"]
  window_layout:
    desktop:
      x: 0
      y: 0
      width: 1280
      height: 1080
    terminal:
      x: 1280
      y: 0
      width: 640
      height: 540
    vscode:
      x: 1280
      y: 540
      width: 640
      height: 540
timeline:
  - time: 0.0
    action: click
    target_window: desktop
  - time: 1.0
    action: type_text
    target_window: terminal
    params:
      text: "echo hi"
  - time: 2.0
    action: open_file
    target_window: vscode
    params:
      path: "x.nim"
"""
    let s = parseScriptYaml(y)
    check s.metadata.targets == @["desktop", "terminal", "vscode"]
    check s.metadata.windowLayout.len == 3
    check s.metadata.windowLayout["desktop"].width == 1280
    check s.metadata.windowLayout["terminal"].x == 1280
    check s.metadata.windowLayout["vscode"].height == 540
    check s.timeline[0].targetWindow == "desktop"
    check s.timeline[1].targetWindow == "terminal"
    check s.timeline[2].targetWindow == "vscode"

  test "default target_window is 'desktop' when targets includes it":
    const y = """
metadata:
  targets: ["desktop", "terminal"]
timeline:
  - time: 0.0
    action: click
  - time: 1.0
    action: type_text
    target_window: terminal
    params:
      text: "ls"
"""
    let s = parseScriptYaml(y)
    check s.timeline[0].targetWindow == "desktop"
    check s.timeline[1].targetWindow == "terminal"

  test "default target_window falls back to first target when no 'desktop'":
    const y = """
metadata:
  targets: ["browser", "terminal"]
timeline:
  - time: 0.0
    action: click
"""
    let s = parseScriptYaml(y)
    check s.timeline[0].targetWindow == "browser"

  test "invalid target_window referencing an unlisted target raises":
    const badYaml = """
metadata:
  targets: ["desktop", "terminal"]
timeline:
  - time: 0.0
    action: click
    target_window: vscode
"""
    expect ScriptValidationError:
      discard parseScriptYaml(badYaml)
    const badJson = """
    {
      "metadata": {"targets": ["desktop", "terminal"]},
      "timeline": [
        {"time": 0.0, "action": "click", "target_window": "vscode"}
      ]
    }
    """
    expect ScriptValidationError:
      discard parseScriptJson(badJson)

  test "window_layout key not in targets raises":
    const badJson = """
    {
      "metadata": {
        "targets": ["desktop"],
        "window_layout": {
          "vscode": {"x": 0, "y": 0, "width": 100, "height": 100}
        }
      },
      "timeline": [{"time": 0.0, "action": "click"}]
    }
    """
    expect ScriptValidationError:
      discard parseScriptJson(badJson)

  # --- metadata.talking_head schema -----------------------------------
  test "metadata.talking_head is absent by default":
    # Plain script without a talking_head block → empty provider, empty
    # avatar, empty device, empty extras.  Backwards compatible.
    let s = parseScriptYaml(fourKeyframeYaml)
    check s.metadata.talkingHead.provider == ""
    check s.metadata.talkingHead.avatarImage == ""
    check s.metadata.talkingHead.device == ""
    check s.metadata.talkingHead.extras.len == 0

  test "metadata.talking_head parses from YAML":
    const y = """
metadata:
  title: "with avatar"
  fps: 30
  talking_head:
    provider: sadtalker
    avatar_image: assets/founder.png
    device: auto
    preprocess: full
    enhancer: gfpgan
    still: true
timeline:
  - time: 0.0
    action: click
"""
    let s = parseScriptYaml(y)
    check s.metadata.talkingHead.provider == "sadtalker"
    check s.metadata.talkingHead.avatarImage == "assets/founder.png"
    check s.metadata.talkingHead.device == "auto"
    check s.metadata.talkingHead.extras["preprocess"] == "full"
    check s.metadata.talkingHead.extras["enhancer"] == "gfpgan"
    check s.metadata.talkingHead.extras["still"] == "true"

  test "metadata.talking_head parses from JSON":
    const j = """
    {
      "metadata": {
        "title": "with avatar",
        "talking_head": {
          "provider": "sadtalker",
          "avatar_image": "/abs/portrait.png",
          "device": "mps",
          "preprocess": "crop",
          "size": 512
        }
      },
      "timeline": [
        {"time": 0.0, "action": "click"}
      ]
    }
    """
    let s = parseScriptJson(j)
    check s.metadata.talkingHead.provider == "sadtalker"
    check s.metadata.talkingHead.avatarImage == "/abs/portrait.png"
    check s.metadata.talkingHead.device == "mps"
    check s.metadata.talkingHead.extras["preprocess"] == "crop"
    check s.metadata.talkingHead.extras["size"] == "512"

  test "metadata.talking_head=stock_avatar is a no-op default":
    const y = """
metadata:
  talking_head:
    provider: stock_avatar
timeline:
  - time: 0.0
    action: click
"""
    let s = parseScriptYaml(y)
    check s.metadata.talkingHead.provider == "stock_avatar"
    check s.metadata.talkingHead.avatarImage == ""

  test "metadata.talking_head rejects non-scalar extras":
    const badJson = """
    {
      "metadata": {
        "talking_head": {
          "provider": "sadtalker",
          "weird": {"nested": "object"}
        }
      },
      "timeline": [{"time": 0.0, "action": "click"}]
    }
    """
    expect ScriptParseError:
      discard parseScriptJson(badJson)

# ---------------------------------------------------------------------------
# metadata.emotive_defaults + metadata.avatar_preferences + per-keyframe
# emotive overrides
# ---------------------------------------------------------------------------

suite "metadata.emotive_defaults parsing":

  test "absent block leaves an empty CommonEmotiveConfig":
    let s = parseScriptJson("""
      {"metadata":{"title":"x"},"timeline":[{"time":0,"action":"click"}]}
    """)
    check s.metadata.emotiveDefaults.emotion.isNone
    check s.metadata.emotiveDefaults.intensity.isNone

  test "JSON metadata.emotive_defaults populates the typed config":
    let s = parseScriptJson("""
      {
        "metadata": {
          "emotive_defaults": {
            "emotion": "confident",
            "intensity": 0.8,
            "voice_speed": 1.05,
            "voice_stability": 0.4,
            "background": "green_screen"
          }
        },
        "timeline": [{"time": 0, "action": "click"}]
      }
    """)
    check s.metadata.emotiveDefaults.emotion == some(eConfident)
    check s.metadata.emotiveDefaults.intensity == some(0.8)
    check s.metadata.emotiveDefaults.voiceSpeed == some(1.05)
    check s.metadata.emotiveDefaults.voiceStability == some(0.4)
    check s.metadata.emotiveDefaults.background == some(bmGreenScreen)

  test "YAML metadata.emotive_defaults populates the typed config":
    let s = parseScriptYaml("""
metadata:
  emotive_defaults:
    emotion: "excited"
    intensity: 0.6
    voice_pitch: 1.5
    background: "transparent"
timeline:
  - time: 0
    action: click
""")
    check s.metadata.emotiveDefaults.emotion == some(eExcited)
    check s.metadata.emotiveDefaults.intensity == some(0.6)
    check s.metadata.emotiveDefaults.voicePitch == some(1.5)
    check s.metadata.emotiveDefaults.background == some(bmTransparent)

  test "non-object emotive_defaults is rejected":
    expect ScriptParseError:
      discard parseScriptJson("""
        {"metadata":{"emotive_defaults":"oops"},
         "timeline":[{"time":0,"action":"click"}]}
      """)

# ---------------------------------------------------------------------------

suite "metadata.avatar_preferences parsing":

  test "absent block yields empty preferred list":
    let s = parseScriptJson("""
      {"timeline":[{"time":0,"action":"click"}]}
    """)
    check s.metadata.avatarPreferences.preferred.len == 0
    check s.metadata.avatarPreferences.fallback == ""

  test "list form populates `preferred` in order":
    let s = parseScriptJson("""
      {
        "metadata": {
          "avatar_preferences": [
            {"name": "Sarah", "gender": "female"},
            {"name": "Daniel", "gender": "male"}
          ]
        },
        "timeline": [{"time": 0, "action": "click"}]
      }
    """)
    check s.metadata.avatarPreferences.preferred.len == 2
    check s.metadata.avatarPreferences.preferred[0].name == "Sarah"

  test "object form preserves per_provider overrides + fallback":
    let s = parseScriptJson("""
      {
        "metadata": {
          "avatar_preferences": {
            "preferred": [{
              "name": "Anna",
              "role": "presenter",
              "gender": "female",
              "tags": ["studio", "warm"],
              "per_provider": {
                "heygen": "Daisy-inskirt-20220818",
                "synthesia": "anna_costume1_cameraA"
              }
            }],
            "fallback": "default"
          }
        },
        "timeline": [{"time": 0, "action": "click"}]
      }
    """)
    check s.metadata.avatarPreferences.preferred.len == 1
    check s.metadata.avatarPreferences.preferred[0].role == "presenter"
    check s.metadata.avatarPreferences.preferred[0].tags == @["studio", "warm"]
    check s.metadata.avatarPreferences.preferred[0].perProvider["heygen"] ==
      "Daisy-inskirt-20220818"
    check s.metadata.avatarPreferences.fallback == "default"

  test "scalar avatar_preferences value is rejected":
    expect ScriptParseError:
      discard parseScriptJson("""
        {"metadata":{"avatar_preferences":"oops"},
         "timeline":[{"time":0,"action":"click"}]}
      """)

# ---------------------------------------------------------------------------

suite "per-keyframe emotive overrides":

  test "keyframe without an emotive block leaves an empty override":
    let s = parseScriptJson("""
      {"timeline":[{"time":0,"action":"click"}]}
    """)
    check s.timeline[0].emotive.emotion.isNone
    check s.timeline[0].emotive.intensity.isNone

  test "keyframe emotive block parses into the typed config":
    let s = parseScriptJson("""
      {
        "timeline": [{
          "time": 0,
          "action": "click",
          "emotive": {"emotion": "surprised", "intensity": 0.9}
        }]
      }
    """)
    check s.timeline[0].emotive.emotion == some(eSurprised)
    check s.timeline[0].emotive.intensity == some(0.9)

  test "effectiveEmotive layers keyframe overrides on script defaults":
    let s = parseScriptJson("""
      {
        "metadata": {
          "emotive_defaults": {
            "emotion": "neutral",
            "intensity": 0.5,
            "voice_speed": 1.0
          }
        },
        "timeline": [{
          "time": 0,
          "action": "click",
          "emotive": {"emotion": "excited", "voice_pitch": 2.0}
        }]
      }
    """)
    let eff = effectiveEmotive(s.metadata, s.timeline[0])
    check eff.emotion == some(eExcited)        # override wins
    check eff.intensity == some(0.5)           # base wins
    check eff.voiceSpeed == some(1.0)          # base wins
    check eff.voicePitch == some(2.0)          # override-only field

  test "non-object keyframe emotive is rejected":
    expect ScriptParseError:
      discard parseScriptJson("""
        {"timeline":[{"time":0,"action":"click","emotive":"oops"}]}
      """)
