## The fixture accessibility-tree backend (spec §9.2): reads, searches and
## acts on the fixture desktop's trees, which input verbs change as well
## (typing sets a text field's value; pressing Submit adds a status label).
##
## Actions an element does not list are refused (`backend-error` /
## `tree-failed`), as a platform accessibility API refuses them.

import std/[options, strutils]

import ../../core/[geometry, contract, desktop_types, tree_types, interfaces]
import ../../cancel
import ../fixture_desktop

proc checkAccessibility(cfg: FixtureConfig) =
  if cfg.env.denyAccessibility: raise denied(screenRecording = false)

proc targetTree(d: Desktop, target: TreeTarget):
    tuple[ti: int, chain: seq[int]] =
  ## The tree index and child chain of the node a tree target names.
  case target.kind
  of ttkPid:
    let ti = d.treeIndex(target.pid)
    if ti < 0: raise notFound("app", "no application with pid " & $target.pid)
    (ti, @[])
  of ttkApp:
    for a in d.apps:
      if a.name == target.app:
        let ti = d.treeIndex(a.pid)
        if ti >= 0: return (ti, @[])
    raise notFound("app", "no application named '" & target.app & "'")
  of ttkWindow:
    let wi = d.windowIndex(target.windowId)
    if wi < 0: raise notFound("window", "no window '" & target.windowId & "'")
    let w = d.windows[wi]
    let ti = d.treeIndex(w.pid)
    if ti >= 0:
      for ci, c in d.trees[ti].root.children:
        if c.role == roleWindow and (c.bounds == some(w.bounds) or c.name == w.title):
          return (ti, @[ci])
    raise notFound("element", "window '" & w.id & "' has no accessibility element")
  of ttkFocused:
    if d.windows.len == 0: raise notFound("window", "no window has focus")
    let ti = d.treeIndex(d.windows[0].pid)
    if ti < 0: raise notFound("app", "the focused application has no tree")
    (ti, @[])

proc subtree(d: Desktop, ti: int, chain: seq[int], depth: Option[int],
             maxNodes: int): TreeRead =
  ## The subtree at a chain as contract nodes, paths kept absolute.
  var dd = d
  let path = d.pathOf(ti, chain)
  var sub = dd.trees[ti].root.walk(chain)
  var tmp = Desktop(trees: @[AppTree(pid: d.trees[ti].pid, root: sub)])
  let (root, count, truncated) = tmp.nodeTree(0, depth, maxNodes)
  # Re-root the paths: `nodeTree` numbers from /app[pid]; splice the prefix.
  proc reroot(n: var Node, prefix, base: string) =
    n.path = prefix & n.path[base.len .. ^1]
    for c in n.children.mitems: reroot(c, prefix, base)
  result = TreeRead(root: root, nodeCount: count, truncated: truncated)
  if chain.len > 0:
    reroot(result.root, path, "/app[" & $d.trees[ti].pid & "]")

proc newFixtureTree*(cfg: FixtureConfig): TreeBackend =
  ## The fixture tree backend. Raises `backend-unavailable` when
  ## GUIASSERT_FIXTURE_UNAVAILABLE names `tree`.
  cfg.checkModuleAvailable(fmTree)
  result.name = fixtureBackendName

  result.tree = proc (session: string, target: TreeTarget, depth: Option[int],
                      maxNodes: int): TreeRead =
    cfg.checkAccessibility()
    cfg.transact(t):
      let d = cfg.loadDesktop(t, session)
      let (ti, chain) = d.targetTree(target)
      result = d.subtree(ti, chain, depth, maxNodes)

  result.find = proc (session: string, target: Option[TreeTarget],
                      filter: ElementFilter, limit: int):
                      tuple[elements: seq[Node], truncated: bool] =
    cfg.checkAccessibility()
    cfg.transact(t):
      let d = cfg.loadDesktop(t, session)
      var roots: seq[Node]
      if target.isSome:
        let (ti, chain) = d.targetTree(target.get)
        roots.add d.subtree(ti, chain, none(int), high(int)).root
      else:
        for ti in 0 ..< d.trees.len:
          roots.add d.nodeTree(ti, none(int), high(int)).root
      for r in roots:
        let left = limit - result.elements.len
        let found = findAll(r, filter, max(left, 0))
        result.elements.add found.elements
        if found.truncated:
          result.truncated = true
          break

  result.element = proc (session, path: string): Node =
    cfg.checkAccessibility()
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      let (ti, chain) = d.resolvePath(path)
      result = d.elementAt(ti, chain)

  result.perform = proc (session, path: string, action: NodeAction,
                         value: Option[string]): Node =
    cfg.checkAccessibility()
    cfg.token.checkpoint()
    cfg.transact(t):
      var d = cfg.loadDesktop(t, session)
      let (ti, chain) = d.resolvePath(path)
      if action notin d.nodeAt(ti, chain).actions:
        raise failed("tree-failed", "the element at " & path & " does not offer '" &
          $action & "'")
      case action
      of actPress: d.press(ti, chain)
      of actFocus: d.focusNode(ti, chain)
      of actSetValue:
        if stEditable notin d.nodeAt(ti, chain).states:
          raise failed("tree-failed", "the element at " & path & " is not editable")
        d.nodeAt(ti, chain).value = some(value.get(""))
      of actExpand: d.nodeAt(ti, chain).states.incl stExpanded
      of actCollapse: d.nodeAt(ti, chain).states.excl stExpanded
      of actSelect: d.nodeAt(ti, chain).states.incl stSelected
      of actIncrement, actDecrement, actShowMenu, actScrollToVisible: discard
      cfg.saveDesktop(session, d)
      result = d.elementAt(ti, chain)

  result.features = proc (probe: bool): seq[Feature] =
    let st = if cfg.env.denyAccessibility: fsUnavailable else: fsSupported
    let r = if cfg.env.denyAccessibility: some("tcc-accessibility") else: none(string)
    @[Feature(feature: "tree", backend: fixtureBackendName, state: st, reason: r,
              remedy: none(string)),
      Feature(feature: "element-actions", backend: fixtureBackendName, state: st,
              reason: r, remedy: none(string))]
