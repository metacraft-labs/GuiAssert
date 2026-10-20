## GuiAssert core: the accessibility tree model.
##
## One platform-neutral shape for the trees that macOS (AXUIElement), Linux
## (AT-SPI2), Windows (UI Automation) and Appium report: a `Node` carries a
## normalized `role` from a fixed vocabulary, the platform's own role in
## `nativeRole`, its name, value, description and bounds (desktop
## coordinates), its states and the actions it offers, and its children.
##
## A node is addressed by a **path** `/app[<pid>]/<role>[<i>]/…`, where `<i>`
## is the index of the node among its siblings of the same role. A path is an
## address into the tree as it was read: it is how a caller names an element
## between two invocations, not a stable identity.
##
## `ElementFilter` and `matches` implement the element search shared by the
## `find` and `wait` verbs, so every backend filters the same way.

import std/[options, strutils, unicode]

import ./geometry

type
  TreeError* = object of CatchableError
    ## Raised for a malformed path, an unknown role or state name, or another
    ## structurally invalid tree input.

  Role* = enum
    ## The normalized role vocabulary (spec §7.5). The string value is the
    ## spelling used on the contract.
    roleApplication = "application"
    roleWindow = "window"
    roleDialog = "dialog"
    roleButton = "button"
    roleCheckbox = "checkbox"
    roleRadio = "radio"
    roleTextField = "text-field"
    roleTextArea = "text-area"
    roleLabel = "label"
    roleLink = "link"
    roleMenu = "menu"
    roleMenuItem = "menu-item"
    roleList = "list"
    roleListItem = "list-item"
    roleTable = "table"
    roleRow = "row"
    roleCell = "cell"
    roleTab = "tab"
    roleTabList = "tab-list"
    roleTree = "tree"
    roleTreeItem = "tree-item"
    roleComboBox = "combo-box"
    roleSlider = "slider"
    roleScrollArea = "scroll-area"
    roleToolbar = "toolbar"
    roleImage = "image"
    roleGroup = "group"
    roleUnknown = "unknown"

  NodeState* = enum
    ## The state vocabulary (spec §7.5).
    stFocused = "focused"
    stFocusable = "focusable"
    stEnabled = "enabled"
    stSelected = "selected"
    stChecked = "checked"
    stExpanded = "expanded"
    stEditable = "editable"
    stVisible = "visible"
    stOffscreen = "offscreen"
    stRequired = "required"
    stInvalid = "invalid"
    stProtected = "protected"
      ## A password or secure text field: its `value` and `text` are never
      ## reported (spec §7.5, C3 of contract 1.0).

  NodeAction* = enum
    ## The actions `element-action` can perform (spec §7.5).
    actPress = "press"
    actFocus = "focus"
    actSetValue = "set-value"
    actIncrement = "increment"
    actDecrement = "decrement"
    actExpand = "expand"
    actCollapse = "collapse"
    actSelect = "select"
    actShowMenu = "show-menu"
    actScrollToVisible = "scroll-to-visible"

  Node* = object
    ## One accessibility element. `childCount` is the number of children the
    ## platform reported, which is larger than `children.len` when the read
    ## was bounded (`--depth`, `--max-nodes`); an `Element` on the contract
    ## is a `Node` whose `children` is empty.
    path*: string
    role*: Role
    nativeRole*: string
    name*: Option[string]
    value*: Option[string]
    text*: Option[string]
      ## The node's text content as the platform's text interface reports it
      ## (AT-SPI Text, the AX value of static text, UIA TextPattern),
      ## distinct from `name` and `value`; none when it has no text interface.
    description*: Option[string]
    bounds*: Option[Rect]
      ## Desktop coordinates (spec §5), whatever space the platform reports
      ## them in; none when they cannot be mapped to the desktop.
    states*: set[NodeState]
    actions*: set[NodeAction]
    childCount*: int
    children*: seq[Node]

  PathStep* = object
    ## One `<role>[<i>]` step of a tree path.
    role*: Role
    index*: int

  TreePath* = object
    ## A parsed `/app[<pid>]/<role>[<i>]/…` path.
    pid*: int
    steps*: seq[PathStep]

  ElementFilter* = object
    ## An element search. Every set criterion must hold; an unset one
    ## matches everything. `states` must all be present on the node. Name
    ## matching is case-sensitive unless `ignoreCase` (spec §7.5, "Matching
    ## rules").
    role*: Option[Role]
    name*: Option[string]          ## the exact name
    nameContains*: Option[string]  ## a substring of the name
    ignoreCase*: bool              ## compare names with Unicode case folding
    states*: set[NodeState]

proc parseRole*(s: string): Role =
  ## The `Role` spelled `s` on the contract. Raises `TreeError` for a name
  ## outside the vocabulary (an unknown role is never guessed).
  for r in Role:
    if $r == s: return r
  raise newException(TreeError, "unknown role '" & s & "'")

proc parseNodeState*(s: string): NodeState =
  ## The `NodeState` spelled `s`. Raises `TreeError` for an unknown state.
  for st in NodeState:
    if $st == s: return st
  raise newException(TreeError, "unknown state '" & s & "'")

proc parseNodeAction*(s: string): NodeAction =
  ## The `NodeAction` spelled `s`. Raises `TreeError` for an unknown action.
  for a in NodeAction:
    if $a == s: return a
  raise newException(TreeError, "unknown action '" & s & "'")

proc parseIndexed(step, what: string): tuple[label: string, index: int] =
  ## Split `label[<n>]` into its parts; the index is a non-negative decimal
  ## integer with no sign, spaces or leading zeros.
  let open = step.find('[')
  if open <= 0 or not step.endsWith("]"):
    raise newException(TreeError, "malformed " & what & " step '" & step & "'")
  let digits = step[open + 1 ..< step.len - 1]
  if digits.len == 0 or (digits.len > 1 and digits[0] == '0'):
    raise newException(TreeError, "malformed index in '" & step & "'")
  for c in digits:
    if c notin Digits:
      raise newException(TreeError, "malformed index in '" & step & "'")
  if digits.len > 15:
    raise newException(TreeError, "index out of range in '" & step & "'")
  result = (step[0 ..< open], parseInt(digits))

proc parseTreePath*(s: string): TreePath =
  ## Parse a tree path. The grammar is strict: `/app[<pid>]` first, then zero
  ## or more `/<role>[<i>]` steps naming roles of the vocabulary, no empty
  ## steps and no trailing slash. Raises `TreeError` otherwise.
  if not s.startsWith("/"):
    raise newException(TreeError, "a tree path starts with '/': '" & s & "'")
  let parts = s[1 .. ^1].split('/')
  let (app, pid) = parseIndexed(parts[0], "application")
  if app != "app":
    raise newException(TreeError, "a tree path starts with /app[<pid>]: '" & s & "'")
  result.pid = pid
  for i in 1 ..< parts.len:
    let (label, index) = parseIndexed(parts[i], "role")
    result.steps.add PathStep(role: parseRole(label), index: index)

proc `$`*(p: TreePath): string =
  ## The canonical spelling of `p`; `parseTreePath($p) == p`.
  result = "/app[" & $p.pid & "]"
  for st in p.steps:
    result.add "/" & $st.role & "[" & $st.index & "]"

proc childPath*(parent: string, role: Role, index: int): string =
  ## The path of the `index`-th child of role `role` under `parent`.
  parent & "/" & $role & "[" & $index & "]"

proc foldCase(s: string): string =
  ## `s` lower-cased rune by rune (Unicode simple case mapping), for the
  ## `ignoreCase` comparison. Invalid UTF-8 is compared as given.
  if validateUtf8(s) >= 0: s else: unicode.toLower(s)

proc matches*(n: Node, f: ElementFilter): bool =
  ## True when node `n` satisfies every criterion of `f`. A name criterion
  ## never matches a node without a name. Names compare exactly
  ## (case-sensitive) unless `f.ignoreCase`.
  if f.role.isSome and n.role != f.role.get: return false
  if f.name.isSome:
    if n.name.isNone: return false
    if f.ignoreCase:
      if foldCase(n.name.get) != foldCase(f.name.get): return false
    elif n.name.get != f.name.get: return false
  if f.nameContains.isSome:
    if n.name.isNone: return false
    if f.ignoreCase:
      if not foldCase(n.name.get).contains(foldCase(f.nameContains.get)): return false
    elif not n.name.get.contains(f.nameContains.get): return false
  result = f.states <= n.states

proc findAll*(root: Node, f: ElementFilter, limit = high(int)):
    tuple[elements: seq[Node], truncated: bool] =
  ## Every node under `root` (itself included) that matches `f`, in
  ## depth-first pre-order, as elements (children dropped). At most `limit`
  ## are returned; `truncated` says whether more matched. The walk is
  ## iterative, so a deep tree cannot exhaust the call stack.
  var stack = @[root]
  while stack.len > 0:
    let n = stack.pop()
    if n.matches(f):
      if result.elements.len >= limit:
        result.truncated = true
        return
      var e = n
      e.children = @[]
      result.elements.add e
    for i in countdown(n.children.high, 0):
      stack.add n.children[i]
