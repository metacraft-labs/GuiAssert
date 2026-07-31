## GuiAssert Agent Storyboard Engine
##
## Translates a high-level natural-language goal — e.g. "Demonstrate recursive
## stepping" — into a valid keyframe YAML script compatible with the M2
## parser. The engine is structured around an exchangeable `StoryboardBackend`
## so that the rule-based recipe library shipped today can be swapped for a
## real LLM caller tomorrow without rewriting the rest of the pipeline.
##
## Design rules:
##
##   * The generated YAML must round-trip through `parseScriptYaml` and
##     `validateScript` without raising.
##   * Narration timings must respect the M2 parser's `WordsPerMinute = 150`
##     overlap check: each keyframe's narration must end strictly before the
##     next keyframe's `time`.
##   * Unrecognised goals receive a sensible default script (3 keyframes:
##     launch app, focus editor, pause).
##
## Recipe library (case-insensitive keyword match against `req.goal`):
##
##   * `recursive`   — call-stack exploration in a recursive Fibonacci demo.
##   * `breakpoint`  — setting a breakpoint and stepping over it.
##   * `hot-reload`  — saving a file and watching the hot-reload kick in.
##
## All other goals fall through to the default recipe.

import std/[options, strformat, strutils]
import ./parser

const
  DefaultStoryboardApp* = "app"
    ## Fallback for `StoryboardRequest.app`.  Deliberately generic: a default
    ## naming a specific product would re-couple this engine to it for every
    ## caller that did not think to override, which is exactly how the
    ## hardcoded "codetracer" survived here unnoticed.

  DefaultStoryboardWorkspaceRoot* = "./examples"
    ## Fallback for `StoryboardRequest.workspaceRoot`.  A relative path with
    ## no project in it, so the recipes remain runnable out of the box while
    ## naming nothing product-specific.

type
  StoryboardError* = object of CatchableError
    ## Raised when the backend produces YAML that the M2 parser rejects.

  StoryboardRequest* = object
    ## Inputs to the storyboard pipeline.
    goal*: string         ## natural-language description of the video
    durationSec*: float   ## target total length of the video
    resolution*: string   ## e.g. "1920x1080"
    fps*: int             ## frames per second; M2 parser does not validate
                          ## the value beyond it being numeric
    app*: string          ## application the recipes drive.  Empty means
                          ## `DefaultStoryboardApp`.  This engine is
                          ## project-agnostic: the recipe library used to
                          ## hardcode "codetracer", which made a public,
                          ## reusable component silently specific to one
                          ## product.  Callers name their own app here.
    workspaceRoot*: string
                          ## directory the per-recipe workspace names are
                          ## resolved against.  Empty means
                          ## `DefaultStoryboardWorkspaceRoot`.  Same reason:
                          ## the `./examples/...` paths the recipes open are a
                          ## property of the *project* being filmed, not of
                          ## the storyboard engine.

  StoryboardBackend* = object
    ## A pluggable translator. The closure receives the request and must
    ## return a YAML string. The seam exists specifically so a real LLM
    ## caller can be dropped in without touching `generateScriptYaml`.
    translate*: proc(req: StoryboardRequest): string {.closure.}

# ---------------------------------------------------------------------------
# YAML emission helpers
# ---------------------------------------------------------------------------

proc escapeYamlString(s: string): string =
  ## Render `s` as a double-quoted YAML scalar compatible with the M2
  ## parser's quoted-string rules.
  result = "\""
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '"':  result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:    result.add(ch)
  result.add("\"")

type
  KfParam = object
    key: string
    value: string  ## already-escaped YAML scalar (use `escapeYamlString` for
                   ## strings, or stringify for numerics)

  Keyframe = object
    time: float
    action: string
    params: seq[KfParam]
    narration: Option[string]

proc emitMetadata(title, resolution: string, fps: int): string =
  result = "metadata:\n"
  result.add "  title: " & escapeYamlString(title) & "\n"
  result.add "  resolution: " & escapeYamlString(resolution) & "\n"
  result.add "  fps: " & $fps & "\n"

proc emitTimeline(keyframes: seq[Keyframe]): string =
  result = "timeline:\n"
  for kf in keyframes:
    # Use plain numeric for time so the parser stays in the numeric path.
    result.add "  - time: " & formatFloat(kf.time, ffDecimal, 2) & "\n"
    result.add "    action: " & kf.action & "\n"
    if kf.params.len > 0:
      result.add "    params:\n"
      for p in kf.params:
        result.add "      " & p.key & ": " & p.value & "\n"
    if kf.narration.isSome:
      result.add "    narration: " & escapeYamlString(kf.narration.get) & "\n"

proc emitScript(title, resolution: string, fps: int,
                keyframes: seq[Keyframe]): string =
  result = emitMetadata(title, resolution, fps)
  result.add emitTimeline(keyframes)

# ---------------------------------------------------------------------------
# Timeline timing helpers
# ---------------------------------------------------------------------------

const NarrationSlackSec = 0.5
  ## Minimum gap between the projected end of a keyframe's narration and the
  ## next keyframe's `time`. Comfortably above the M2 parser's 1e-9 epsilon
  ## while still keeping the timelines tight.

proc layoutKeyframes(keyframes: var seq[Keyframe], totalDuration: float) =
  ## Walk the keyframe sequence and lift each `time` forward so narration
  ## from the previous keyframe fits with a `NarrationSlackSec` margin.
  ## The final keyframe's `time` is clamped to `totalDuration - epsilon`
  ## so callers may rely on the script fitting inside the requested
  ## duration.
  for i in 1 ..< keyframes.len:
    let prev = keyframes[i - 1]
    var minTime = prev.time
    if prev.narration.isSome:
      let narrEnd = prev.time + estimateNarrationSeconds(prev.narration.get)
      minTime = max(minTime, narrEnd + NarrationSlackSec)
    if keyframes[i].time < minTime:
      keyframes[i].time = minTime
  if keyframes.len > 0 and totalDuration > 0.0:
    let lastIdx = keyframes.high
    let cap = totalDuration - 0.01
    if keyframes[lastIdx].time > cap:
      keyframes[lastIdx].time = cap

# ---------------------------------------------------------------------------
# Recipe library
# ---------------------------------------------------------------------------

proc appName(req: StoryboardRequest): string =
  ## The application every recipe's `launch_app` keyframe targets.
  if req.app.len > 0: req.app else: DefaultStoryboardApp

proc workspace(req: StoryboardRequest; name: string): string =
  ## Resolve a recipe's workspace name against the caller's root, so the
  ## recipes describe *which scenario* to open without owning where a given
  ## project keeps it.
  let root = if req.workspaceRoot.len > 0: req.workspaceRoot
             else: DefaultStoryboardWorkspaceRoot
  if root.endsWith("/"): root & name else: root & "/" & name

proc recursiveSteppingRecipe(req: StoryboardRequest): seq[Keyframe] =
  result = @[
    Keyframe(
      time: 0.0,
      action: "launch_app",
      params: @[
        KfParam(key: "app", value: escapeYamlString(req.appName)),
        KfParam(key: "workspace",
                value: escapeYamlString(req.workspace("fibonacci")))
      ],
      narration: some(
        "Welcome. Let's trace a recursive Fibonacci call.")
    ),
    Keyframe(
      time: 3.0,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("editor"))],
      narration: some(
        "Here is the recursive function.")
    ),
    Keyframe(
      time: 6.0,
      action: "move_cursor",
      params: @[KfParam(key: "target", value: escapeYamlString("editor.line(8)"))],
      narration: some(
        "Stepping into fib of five.")
    ),
    Keyframe(
      time: 9.0,
      action: "step_in",
      params: @[],
      narration: some(
        "The call stack now shows the recursive frames.")
    ),
    Keyframe(
      time: 12.0,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("callstack"))],
      narration: some(
        "Each frame holds the local value of n.")
    )
  ]

proc breakpointRecipe(req: StoryboardRequest): seq[Keyframe] =
  result = @[
    Keyframe(
      time: 0.0,
      action: "launch_app",
      params: @[
        KfParam(key: "app", value: escapeYamlString(req.appName)),
        KfParam(key: "workspace",
                value: escapeYamlString(req.workspace("server")))
      ],
      narration: some(
        "Let's set a breakpoint on the request handler.")
    ),
    Keyframe(
      time: 3.0,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("editor"))],
      narration: some(
        "Open the handler file.")
    ),
    Keyframe(
      time: 5.5,
      action: "click",
      params: @[
        KfParam(key: "target", value: escapeYamlString("editor.gutter(20)")),
        KfParam(key: "button", value: escapeYamlString("left"))
      ],
      narration: some(
        "Click the gutter to drop a breakpoint.")
    ),
    Keyframe(
      time: 8.0,
      action: "run",
      params: @[],
      narration: some(
        "Run the program; execution pauses at the breakpoint.")
    ),
    Keyframe(
      time: 11.0,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("variables"))],
      narration: some(
        "Inspect local variables in the side pane.")
    )
  ]

proc hotReloadRecipe(req: StoryboardRequest): seq[Keyframe] =
  result = @[
    Keyframe(
      time: 0.0,
      action: "launch_app",
      params: @[
        # Was hardcoded to "vs-code" — a second product name, in a recipe the
        # caller may well be filming in their own editor.  Same rule as every
        # other recipe: the app under test comes from the request.
        KfParam(key: "app", value: escapeYamlString(req.appName)),
        KfParam(key: "workspace",
                value: escapeYamlString(req.workspace("hot-reload")))
      ],
      narration: some(
        "Watch hot reload in action.")
    ),
    Keyframe(
      time: 2.5,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("editor"))],
      narration: some(
        "Open the source file.")
    ),
    Keyframe(
      time: 5.0,
      action: "type_text",
      params: @[
        KfParam(key: "text", value: escapeYamlString("print('hi')")),
        KfParam(key: "wpm", value: "80")
      ],
      narration: some(
        "Add a small print statement.")
    ),
    Keyframe(
      time: 8.0,
      action: "hot_key",
      params: @[KfParam(key: "keys", value: "[\"Cmd\", \"S\"]")],
      narration: some(
        "Save the file to trigger hot reload.")
    ),
    Keyframe(
      time: 11.0,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("terminal"))],
      narration: some(
        "The running process picks up the change without restarting.")
    )
  ]

proc defaultRecipe(req: StoryboardRequest): seq[Keyframe] =
  result = @[
    Keyframe(
      time: 0.0,
      action: "launch_app",
      params: @[KfParam(key: "app", value: escapeYamlString(req.appName))],
      narration: some("Launching the demo application.")
    ),
    Keyframe(
      time: 3.0,
      action: "focus_window",
      params: @[KfParam(key: "window", value: escapeYamlString("editor"))],
      narration: some("Focusing the editor pane.")
    ),
    Keyframe(
      time: 6.0,
      action: "pause",
      params: @[KfParam(key: "duration", value: "2.0")],
      narration: some("Pausing briefly for orientation.")
    )
  ]

proc pickRecipe(goal: string, req: StoryboardRequest): seq[Keyframe] =
  let g = goal.toLowerAscii
  if "recursive" in g or "recursion" in g:
    return recursiveSteppingRecipe(req)
  if "breakpoint" in g:
    return breakpointRecipe(req)
  if "hot-reload" in g or "hot reload" in g or "hotreload" in g:
    return hotReloadRecipe(req)
  return defaultRecipe(req)

proc titleForRequest(req: StoryboardRequest): string =
  ## Title the video after the app being filmed.  This used to read
  ## "CodeTracer: …" unconditionally, so every video produced by every
  ## consumer of this engine was titled after one product.
  let app = req.appName
  if req.goal.len == 0:
    return app & " Demo"
  result = app & ": " & req.goal

# ---------------------------------------------------------------------------
# Backend constructors
# ---------------------------------------------------------------------------

proc newRuleBasedBackend*(): StoryboardBackend =
  ## Returns the rule-based translator described in the module docs.
  result.translate = proc(req: StoryboardRequest): string {.closure.} =
    var kfs = pickRecipe(req.goal, req)
    let total =
      if req.durationSec > 0.0: req.durationSec
      else: 15.0
    layoutKeyframes(kfs, total)
    let res =
      if req.resolution.len > 0: req.resolution
      else: "1920x1080"
    let fps =
      if req.fps > 0: req.fps
      else: 30
    result = emitScript(titleForRequest(req), res, fps, kfs)

# ---------------------------------------------------------------------------
# Top-level pipeline
# ---------------------------------------------------------------------------

proc generateScriptYaml*(backend: StoryboardBackend,
                        req: StoryboardRequest): string =
  ## Invoke the backend, validate the resulting YAML through the M2 parser,
  ## and return the YAML string. Raises `StoryboardError` if the backend
  ## produced syntactically invalid YAML or a script that fails timing
  ## validation.
  if backend.translate.isNil:
    raise newException(StoryboardError, "StoryboardBackend has no translate proc")
  let yaml = backend.translate(req)
  if yaml.len == 0:
    raise newException(StoryboardError, "Backend returned empty YAML")
  try:
    let script = parseScriptYaml(yaml)
    if script.timeline.len == 0:
      raise newException(StoryboardError,
        "Backend produced a script with zero keyframes")
  except ScriptParseError as e:
    raise newException(StoryboardError,
      "Backend YAML failed to parse: " & e.msg & "\n--- yaml ---\n" & yaml)
  except ScriptValidationError as e:
    raise newException(StoryboardError,
      "Backend YAML failed validation: " & e.msg & "\n--- yaml ---\n" & yaml)
  result = yaml
