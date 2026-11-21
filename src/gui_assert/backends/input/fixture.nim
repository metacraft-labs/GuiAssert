## The fixture input backend (spec §9.2): pointer and keyboard input, and
## window focus and placement, applied to the fixture desktop.
##
## What a real application would do with the input is modelled just enough
## for verbs to compose across invocations: a click focuses the window and
## node under the pointer, toggles a checkbox and presses a button; typed
## text is appended to the focused editable node; `BackSpace` deletes its
## last character. Every operation reports what it delivered
## (`delivery: "injected"`), never what the application did, and typed text
## is reported by length only.

import std/[options, strutils, unicode]

import ../../core/[geometry, desktop_types, tree_types, interfaces, keys]
import ../../cancel
import ../fixture_desktop

proc checkAccessibility(cfg: FixtureConfig) =
  if cfg.env.denyAccessibility: raise denied(screenRecording = false)

proc report(kind, session: string): InputReport =
  InputReport(kind: kind, delivery: dInjected, session: session)

proc newFixtureInput*(cfg: FixtureConfig): InputBackend =
  ## The fixture input backend. Raises `backend-unavailable` when
  ## GUIASSERT_FIXTURE_UNAVAILABLE names `input`.
  cfg.checkModuleAvailable(fmInput)
  result.name = fixtureBackendName

  result.move = proc (session: string, to: Point): InputReport =
    cfg.checkAccessibility()
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      d.pointer = to
      cfg.saveDesktop(session, d)
    result = report("move", session)
    result.to = some(to)

  result.click = proc (session: string, at: Point, button: MouseButton, count: int,
                       modifiers: seq[string]): InputReport =
    cfg.checkAccessibility()
    for i in 0 ..< count:
      cfg.token.checkpoint()
      cfg.transact(t):
        var d = cfg.loadDesktop(t, session)
        d.pointer = at
        if button == mbLeft:
          let hit = d.hitTest(at)
          if hit.isSome:
            let (wi, ti, chain) = hit.get
            d.focusWindowAt(wi)
            if ti >= 0 and chain.len > 0:
              d.focusNode(ti, chain)
              let n = d.nodeAt(ti, chain)
              if n.role in {roleButton, roleCheckbox} and actPress in n.actions:
                d.press(ti, chain)
        cfg.saveDesktop(session, d)
    result = report("click", session)
    result.at = some(at)
    result.button = some($button)
    result.count = some(count)
    if modifiers.len > 0: result.keys = some(modifiers.join("+"))

  result.drag = proc (session: string, path: seq[Point], button: MouseButton,
                      steps: int, durationMs: int, modifiers: seq[string]): InputReport =
    cfg.checkAccessibility()
    if path.len < 2:
      raise newBackendError(BackendError, fixtureBackendName, "input-failed",
        "a drag needs a start and an end point")
    # The pointer visits every vertex in order, `steps` events per segment,
    # with the button held throughout; the whole drag takes `durationMs`.
    let events = steps * (path.len - 1)
    let per = if events > 0: durationMs div events else: 0
    for seg in 0 ..< path.len - 1:
      for i in 0 ..< steps:
        cfg.token.sleepCancellable(per)
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      d.pointer = path[^1]
      cfg.saveDesktop(session, d)
    result = report("drag", session)
    result.at = some(path[0])
    result.to = some(path[^1])
    result.button = some($button)
    result.path = some(path)
    if modifiers.len > 0: result.keys = some(modifiers.join("+"))

  # the fixture desktop models no held buttons or keys: a gesture moves its
  # pointer to where the gesture ends and reports what was delivered
  result.gesture = proc (session: string, steps: seq[GestureStep]): InputReport =
    cfg.checkAccessibility()
    var last = none(Point)
    for st in steps:
      case st.kind
      of gsMove: last = some(st.to)
      of gsPress, gsRelease: last = some(st.at)
      of gsWait: cfg.token.sleepCancellable(st.ms)
      else: discard
    if last.isSome:
      cfg.transact(t):
        var d = cfg.loadDesktop(t, session)
        d.pointer = last.get
        cfg.saveDesktop(session, d)
    result = report("gesture", session)
    if last.isSome: result.to = last

  result.scroll = proc (session: string, at: Point, dx, dy: int,
                        unit: ScrollUnit): InputReport =
    cfg.checkAccessibility()
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      d.pointer = at
      cfg.saveDesktop(session, d)
    result = report("scroll", session)
    result.at = some(at)

  result.typeText = proc (session: string, text: string,
                          intervalMs: int): InputReport =
    cfg.checkAccessibility()
    let runes = text.toRunes
    for i, r in runes:
      if intervalMs > 0 and i > 0: cfg.token.sleepCancellable(intervalMs)
      cfg.token.checkpoint()
      cfg.transact(t):
        var d = cfg.loadDesktop(t, session)
        let f = d.focusedEditable()
        if f.isSome:
          let (ti, chain) = f.get
          d.nodeAt(ti, chain).value = some(d.nodeAt(ti, chain).value.get("") & $r)
          cfg.saveDesktop(session, d)
    result = report("type", session)
    result.length = some(runes.len)

  result.key = proc (session: string, combo: string): InputReport =
    cfg.checkAccessibility()
    let c = parseCombo(combo)
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      if c.modifiers == {} and c.key == "BackSpace":
        let f = d.focusedEditable()
        if f.isSome:
          let (ti, chain) = f.get
          let v = d.nodeAt(ti, chain).value.get("").toRunes
          if v.len > 0:
            d.nodeAt(ti, chain).value = some($v[0 ..< v.high])
            cfg.saveDesktop(session, d)
    result = report("key", session)
    result.keys = some(combo)

  result.focusWindow = proc (session, windowId: string): Window =
    cfg.checkAccessibility()
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      let wi = d.windowIndex(windowId)
      if wi < 0: raise notFound("window", "no window '" & windowId & "'")
      d.focusWindowAt(wi)
      cfg.saveDesktop(session, d)
      result = d.windows[0]

  result.setWindowBounds = proc (session, windowId: string, bounds: Rect): Window =
    cfg.checkAccessibility()
    if bounds.width < 1 or bounds.height < 1:
      raise newBackendError(BackendError, fixtureBackendName, "input-failed",
        "a window cannot be smaller than 1x1")
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      let wi = d.windowIndex(windowId)
      if wi < 0: raise notFound("window", "no window '" & windowId & "'")
      let old = d.windows[wi].bounds
      d.windows[wi].bounds = bounds
      # Keep the window's accessibility element where the window is: its
      # widgets move with its origin (a resize does not lay them out anew).
      let ti = d.treeIndex(d.windows[wi].pid)
      if ti >= 0:
        for c in d.trees[ti].root.children.mitems:
          if c.role == roleWindow and c.bounds == some(old):
            c.shiftBounds(bounds.x - old.x, bounds.y - old.y)
            c.bounds = some(bounds)
      cfg.saveDesktop(session, d)
      result = d.windows[wi]

  result.features = proc (probe: bool): seq[Feature] =
    let st = if cfg.env.denyAccessibility: fsUnavailable else: fsSupported
    let r = if cfg.env.denyAccessibility: some("tcc-accessibility") else: none(string)
    @[Feature(feature: "pointer-input", backend: fixtureBackendName, state: st, reason: r,
              remedy: none(string)),
      Feature(feature: "keyboard-input", backend: fixtureBackendName, state: st, reason: r,
              remedy: none(string)),
      Feature(feature: "window-management", backend: fixtureBackendName, state: st,
              reason: r, remedy: none(string))]
