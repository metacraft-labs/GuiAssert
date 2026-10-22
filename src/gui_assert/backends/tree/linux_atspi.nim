## The `linux-atspi` accessibility-tree backend (spec §4.2): `tree`, `find`,
## `element`, `element-action` and `wait --element` over AT-SPI2, the Linux
## accessibility bus, on the session's own bus.
##
## **How it talks to AT-SPI.** Directly in the D-Bus wire protocol
## (`dbus_wire`), not through libatspi or libdbus: the binary loads no
## library for it, so the packaged `guiassert` needs nothing on its wrapper
## for the tree verbs, and every invocation reads the application's current
## state (libatspi caches names, roles and states and keeps them current only
## while a GLib main loop dispatches its change events, which a one-shot CLI
## never runs). Calls are pipelined: the reads of one node, and of all the
## children of a node, are sent before the first answer is awaited, so a tree
## costs about two round trips per parent rather than per property.
##
## **Which bus.** The invocation's environment names it, and nothing else
## does: `AT_SPI_BUS_ADDRESS` when set, else the address the session bus
## (`DBUS_SESSION_BUS_ADDRESS`) gives for `org.a11y.Bus.GetAddress`, asked
## with the no-auto-start flag so a read never starts an accessibility bus as
## a side effect. A session whose bus has no `org.a11y.Bus` (no
## at-spi-bus-launcher running in it), or that has no session bus at all, is
## exit 6 / `atspi-disabled`, never an empty tree (spec §7.3). The X11 root
## window property `AT_SPI_BUS`, which toolkits also consult, is not read: in
## the sessions GuiAssert runs (a private Xvfb, sway or GNOME Shell with its
## own session bus) it names the same bus, and reading it would need an X11
## client here.
##
## **Applications** are the children of the registry's root
## (`org.a11y.atspi.Registry`); an application's pid is the bus's account of
## the connection (`GetConnectionUnixProcessID`), and its name, which `--app`
## matches exactly (spec §7.5, "Matching rules"), is its AT-SPI name.
##
## **Nodes.** `role` maps the numeric AT-SPI role (`GetRole`; the role-name
## strings are the toolkit's own and differ between GTK 3 and GTK 4) onto the
## contract's vocabulary, with the AT-SPI role name in `nativeRole`. A text
## role is a `text-area` when it has the `multi-line` state, else a
## `text-field`. `name` and `description` are the Accessible properties
## (empty is null); `text` is the Text interface's whole content; `value` is
## the Value interface's current value (its `Text` when the toolkit gives
## one) or, for editable text, the text content. A **password field**
## (`ROLE_PASSWORD_TEXT`, which GTK 3, GTK 4 and Qt all report for one) gets
## the `protected` state and its text is never read (C3). `states` map
## AT-SPI's: `enabled` from `enabled` or `sensitive` (GTK 4 reports only the
## latter), `visible` from `visible` and `showing`, `offscreen` from
## `visible` without `showing`, `editable` from `editable` without
## `read-only`, `invalid` from `invalid-entry`. `actions` are those the
## element can perform here: `press` (an Action named click, press, toggle,
## jump or open, or activate on a non-text element), `focus` (Component
## `GrabFocus`), `set-value` (EditableText on editable text, or Value),
## `increment` / `decrement` (Value, or Action increase / decrease),
## `expand` / `collapse` (an Action of that name, or the toggle of an
## expandable element), `select` (a child of a Selection container),
## `show-menu` (an Action named show menu / menu / popup). `focus` is not
## offered by GTK 4 applications, whose GrabFocus answers NotSupported, and
## `scroll-to-visible` by none: GTK 3 and GTK 4 both refuse Component
## `ScrollTo` (measured 2026-10-22, GTK 3.24.51 and 4.20.3), so offering it
## would promise an action no measured toolkit performs.
##
## **Bounds are desktop coordinates** (C1). Neither GTK 4 nor GTK 3 on
## Wayland reports screen coordinates (measured 2026-10-22: GTK 4 answers
## `(0, 0)` for every element, GTK 3 on Wayland window-relative ones), so
## every extent is read in WINDOW coordinates and placed through the window
## the compositor or X server reports for the element's top-level (the
## session's capture backend's `windows`, so sway's IPC on sway and the X
## server on Xvfb): the AT-SPI frame is matched to a window of its pid (by
## title, else as the pid's only window, else by size), and the frame's
## origin in its own WINDOW space is found from the window's content size:
## when the frame's extents have that size their origin is the content's
## origin (GTK 4, and GTK 3 without client-side shadows); when the frame is
## larger (GTK 3 drawing its own decorations and shadow, whose frame is the
## whole surface) the union of the frame's children, which is the visible
## window, must have that size, and its origin is used. `desktop = window
## content origin + (extent - frame origin)`. A frame that cannot be matched
## or measured this way gives every node under it `bounds: null`, never a
## rectangle in another space; so does an element outside any frame, and one
## that is not `showing` (it is nowhere on the desktop).
##
## **Toolkits measured** (2026-10-22): GTK 3.24 (through at-spi2-atk), GTK
## 4.20 and Qt 6.10 Widgets, each on Wayland (sway) and X11 (Xvfb). Every
## property is read with `Properties.Get`, one per call, because Qt's bridge
## does not implement `GetAll`.
##
## Paths, matching and truncation follow `core/tree_types` exactly as the
## fixture backend does: `/app[<pid>]/<role>[<i>]/…`, the index counted
## among siblings of the same role; `--max-nodes` bounds the nodes read in
## depth-first order and says so with `truncated`.
##
## AT-SPI2 D-Bus interfaces:
## https://gitlab.gnome.org/GNOME/at-spi2-core/-/tree/main/xml ;
## roles and states: `atspi-constants.h` of at-spi2-core (the numeric values
## used below are that header's enumerations, checked against it by
## tests/live/ttree_linux.nim).

import std/[algorithm, json, options, strutils, tables]

import ../../core/[geometry, contract, desktop_types, tree_types, interfaces]
import ../../cancel
import ./dbus_wire

const
  linuxAtspiName* = "linux-atspi"
    ## The backend's contract name.
  callTimeoutMs = 5000
    ## How long one application may take to answer one call.
  registryName = "org.a11y.atspi.Registry"
  rootPath = "/org/a11y/atspi/accessible/root"
  ifAccessible = "org.a11y.atspi.Accessible"
  ifPropsName = "org.freedesktop.DBus.Properties"
  maxReadDepth = 512
    ## A tree nested deeper than this is refused rather than recursed into.
  pipelineChunk = 64
    ## The most objects whose reads are in flight at once. Unbounded
    ## pipelining of a wide node (thousands of children, several calls
    ## each) could fill the socket with calls while the answers queue
    ## unread on the bus, until the bus's per-connection limits refuse them.
  disabledRemedy = "start the session's AT-SPI bus (at-spi-bus-launcher, which a " &
    "GuiAssert session backend starts in the sessions it owns), or point " &
    "AT_SPI_BUS_ADDRESS at it"

  atspiRoleNames*: array[131, string] = [
    "invalid", "accelerator label", "alert", "animation", "arrow", "calendar",
    "canvas", "check box", "check menu item", "color chooser", "column header",
    "combo box", "date editor", "desktop icon", "desktop frame", "dial",
    "dialog", "directory pane", "drawing area", "file chooser", "filler",
    "focus traversable", "font chooser", "frame", "glass pane",
    "html container", "icon", "image", "internal frame", "label",
    "layered pane", "list", "list item", "menu", "menu bar", "menu item",
    "option pane", "page tab", "page tab list", "panel", "password text",
    "popup menu", "progress bar", "button", "radio button", "radio menu item",
    "root pane", "row header", "scroll bar", "scroll pane", "separator",
    "slider", "spin button", "split pane", "status bar", "table", "table cell",
    "table column header", "table row header", "tearoff menu item",
    "terminal", "text", "toggle button", "tool bar", "tool tip", "tree",
    "tree table", "unknown", "viewport", "window", "extended", "header",
    "footer", "paragraph", "ruler", "application", "autocomplete", "editbar",
    "embedded", "entry", "chart", "caption", "document frame", "heading",
    "page", "section", "redundant object", "form", "link",
    "input method window", "table row", "tree item", "document spreadsheet",
    "document presentation", "document text", "document web",
    "document email", "comment", "list box", "grouping", "image map",
    "notification", "info bar", "level bar", "title bar", "block quote",
    "audio", "video", "definition", "article", "landmark", "log", "marquee",
    "math", "rating", "timer", "static", "math fraction", "math root",
    "subscript", "superscript", "description list", "description term",
    "description value", "footnote", "content deletion", "content insertion",
    "mark", "suggestion", "push button menu", "switch"]
    ## `AtspiRole` in order (ATSPI_ROLE_INVALID = 0 … ATSPI_ROLE_SWITCH =
    ## 130), spelled as the identifiers after `ATSPI_ROLE_`, lower case, `_`
    ## as a space.

  atspiStateNames*: array[44, string] = [
    "invalid", "active", "armed", "busy", "checked", "collapsed", "defunct",
    "editable", "enabled", "expandable", "expanded", "focusable", "focused",
    "has tooltip", "horizontal", "iconified", "modal", "multi line",
    "multiselectable", "opaque", "pressed", "resizable", "selectable",
    "selected", "sensitive", "showing", "single line", "stale", "transient",
    "vertical", "visible", "manages descendants", "indeterminate", "required",
    "truncated", "animated", "invalid entry", "supports autocompletion",
    "selectable text", "is default", "visited", "checkable", "has popup",
    "read only"]
    ## `AtspiStateType` in order (ATSPI_STATE_INVALID = 0 …
    ## ATSPI_STATE_READ_ONLY = 43).

  # The roles and states this backend interprets, by their header value.
  rPasswordText = 40
  rToggleButton = 62
  rText = 61
  rEntry = 79
  rTerminal = 60
  rDocumentText = 94
  sChecked = 4
  sEditable = 7
  sEnabled = 8
  sExpandable = 9
  sExpanded = 10
  sFocusable = 11
  sFocused = 12
  sMultiLine = 17
  sPressed = 20
  sSelectable = 22
  sSelected = 23
  sSensitive = 24
  sShowing = 25
  sVisible = 30
  sRequired = 33
  sInvalidEntry = 36
  sReadOnly = 43
  sActive = 1

type
  LinuxAtspiConfig* = object
    ## What the backend runs with.
    env*: Table[string, string]
      ## The invocation's environment: the session's bus addresses.
    token*: CancelToken
      ## Cancellation and the `--timeout-ms` deadline.
    windows*: proc (): seq[Window] {.closure.}
      ## The session's top-level windows as its compositor or X server
      ## reports them (desktop coordinates), for placing extents; nil, or a
      ## proc that returns nothing, leaves every node's bounds null.

  Iface = enum
    ifComponent, ifText, ifEditableText, ifValue, ifAction, ifSelection

  ObjRef = tuple[bus, path: string]

  Raw = object
    ## One accessible object as read, before it becomes a contract node.
    obj: ObjRef
    roleNum: int
    name, description: string
    childCount: int
    states: uint64
    ifaces: set[Iface]
    childRefs: seq[ObjRef]
    extents: Option[Rect]   ## WINDOW coordinates
    text: Option[string]
    value: Option[string]
    actions: seq[string]    ## lower-case action names, in Action order
    sub: seq[Raw]           ## the children read
    parentSelection: bool   ## its parent implements Selection
    grabFocus: bool         ## its toolkit implements Component.GrabFocus

  AtspiApp* = object
    ## An application registered on the session's AT-SPI bus.
    pid*: int
    name*: string
    root: ObjRef

  Placement* = object
    ## How a frame's WINDOW coordinates become desktop coordinates.
    content: Point          ## the window's content origin on the desktop
    origin: Point           ## that origin in the frame's WINDOW coordinates

  Reader = ref object
    cfg: LinuxAtspiConfig
    conn: DbusConnection
    windowsRead: bool
    windows: seq[Window]
    grabFocus: Table[string, bool]   ## per bus name: GrabFocus works there

# ---------------------------------------------------------------------------
# Pure: roles, states and actions
# ---------------------------------------------------------------------------

proc nativeRoleName*(roleNum: int): string =
  ## The AT-SPI name of role `roleNum`, `role-<n>` beyond the known ones.
  if roleNum >= 0 and roleNum < atspiRoleNames.len: atspiRoleNames[roleNum]
  else: "role-" & $roleNum

proc has(states: uint64, s: int): bool = (states and (1'u64 shl s)) != 0

proc isTextRole(roleNum: int): bool =
  roleNum in [rText, rEntry, rPasswordText, rTerminal, rDocumentText]

proc contractRole*(roleNum: int, states: uint64): Role =
  ## The contract role of an AT-SPI role (module doc).
  if isTextRole(roleNum):
    if roleNum != rPasswordText and states.has(sMultiLine): return roleTextArea
    if roleNum in [rTerminal, rDocumentText]: return roleTextArea
    return roleTextField
  case nativeRoleName(roleNum)
  of "application": roleApplication
  of "frame", "window": roleWindow
  of "dialog", "alert", "file chooser", "color chooser", "font chooser": roleDialog
  of "button", "toggle button", "push button menu": roleButton
  of "check box", "switch": roleCheckbox
  of "radio button": roleRadio
  of "label", "static", "caption", "heading", "paragraph", "accelerator label",
     "description term", "description value": roleLabel
  of "link": roleLink
  of "menu", "popup menu", "menu bar": roleMenu
  of "menu item", "check menu item", "radio menu item", "tearoff menu item": roleMenuItem
  of "list", "list box", "description list": roleList
  of "list item": roleListItem
  of "table": roleTable
  of "table row": roleRow
  of "table cell", "column header", "row header", "table column header",
     "table row header": roleCell
  of "page tab": roleTab
  of "page tab list": roleTabList
  of "tree", "tree table": roleTree
  of "tree item": roleTreeItem
  of "combo box": roleComboBox
  of "slider", "scroll bar", "dial", "spin button": roleSlider
  of "scroll pane", "viewport": roleScrollArea
  of "tool bar": roleToolbar
  of "image", "icon", "desktop icon", "animation", "image map": roleImage
  of "panel", "filler", "grouping", "section", "form", "layered pane",
     "root pane", "split pane", "glass pane", "internal frame", "embedded",
     "html container", "header", "footer", "landmark", "article",
     "block quote", "document frame", "document web", "document email",
     "document spreadsheet", "document presentation", "page", "info bar",
     "title bar", "option pane", "directory pane", "status bar",
     "notification", "canvas", "drawing area", "log", "marquee",
     "redundant object", "extended": roleGroup
  else: roleUnknown

proc contractStates*(roleNum: int, states: uint64): set[NodeState] =
  ## The contract states of an AT-SPI state set (module doc).
  if states.has(sFocused): result.incl stFocused
  if states.has(sFocusable): result.incl stFocusable
  if states.has(sEnabled) or states.has(sSensitive): result.incl stEnabled
  if states.has(sSelected): result.incl stSelected
  if states.has(sChecked) or (roleNum == rToggleButton and states.has(sPressed)):
    result.incl stChecked
  if states.has(sExpanded): result.incl stExpanded
  if states.has(sEditable) and not states.has(sReadOnly): result.incl stEditable
  if states.has(sVisible):
    if states.has(sShowing): result.incl stVisible
    else: result.incl stOffscreen
  if states.has(sRequired): result.incl stRequired
  if states.has(sInvalidEntry): result.incl stInvalid
  if roleNum == rPasswordText: result.incl stProtected

const
  pressNames = ["click", "press", "toggle", "jump", "open"]
  menuNames = ["show menu", "showmenu", "menu", "popup", "popup menu"]

proc actionIndex(r: Raw, names: openArray[string]): int =
  for i, a in r.actions:
    if a in names: return i
  -1

proc pressIndex(r: Raw): int =
  result = r.actionIndex(pressNames)
  if result < 0 and not isTextRole(r.roleNum): result = r.actionIndex(["activate"])

proc toggleIndex(r: Raw): int =
  ## The action that toggles an expandable element.
  r.actionIndex(["expand or contract", "toggle", "activate", "click"])

proc contractActions(r: Raw): set[NodeAction] =
  if r.pressIndex >= 0: result.incl actPress
  if ifComponent in r.ifaces and r.states.has(sFocusable) and r.grabFocus:
    result.incl actFocus
  if r.actionIndex(["setfocus", "set focus"]) >= 0: result.incl actFocus
  let editableText = ifEditableText in r.ifaces and r.states.has(sEditable) and
                     not r.states.has(sReadOnly)
  if editableText or (ifValue in r.ifaces and not isTextRole(r.roleNum)):
    result.incl actSetValue
  if (ifValue in r.ifaces and not isTextRole(r.roleNum)) or
     r.actionIndex(["increase", "increment"]) >= 0: result.incl actIncrement
  if (ifValue in r.ifaces and not isTextRole(r.roleNum)) or
     r.actionIndex(["decrease", "decrement"]) >= 0: result.incl actDecrement
  let expandable = r.states.has(sExpandable) and r.toggleIndex >= 0
  if r.actionIndex(["expand"]) >= 0 or (expandable and not r.states.has(sExpanded)):
    result.incl actExpand
  if r.actionIndex(["collapse"]) >= 0 or (expandable and r.states.has(sExpanded)):
    result.incl actCollapse
  if r.parentSelection and r.states.has(sSelectable): result.incl actSelect
  if r.actionIndex(menuNames) >= 0: result.incl actShowMenu

proc formatValue(v: float): string =
  ## A numeric value as text: integral values without a fraction. The range
  ## is checked before the conversion, which is undefined for NaN and for
  ## values beyond int64.
  if abs(v) < 1e15 and v == float(int64(v)): $int64(v)
  else: formatFloat(v, ffDefault, -1)

proc countOf(v: Option[float]): int =
  ## A child count the peer answered, as a count: none, NaN or a negative
  ## number is 0, and it is bounded by int32 (AT-SPI's `ChildCount` is `i`).
  if v.isNone or not (v.get >= 0.0): return 0
  int(min(v.get, float(high(int32))))

# ---------------------------------------------------------------------------
# Pure: placing WINDOW coordinates on the desktop
# ---------------------------------------------------------------------------

proc sameSize(a: Rect, w, h: int): bool = abs(a.width - w) <= 1 and abs(a.height - h) <= 1

proc unionOf(rs: seq[Rect]): Option[Rect] =
  for r in rs:
    if r.width <= 0 or r.height <= 0: continue
    if result.isNone: result = some(r)
    else:
      let u = result.get
      let x0 = min(u.x, r.x)
      let y0 = min(u.y, r.y)
      let x1 = max(u.x + u.width, r.x + r.width)
      let y1 = max(u.y + u.height, r.y + r.height)
      result = some(rect(x0, y0, x1 - x0, y1 - y0))

proc frameOrigin*(frame: Rect, children: seq[Rect], content: Size): Option[Point] =
  ## Where the window's content origin lies in a frame's WINDOW coordinates
  ## (module doc): the frame's own origin when it has the content's size,
  ## else the origin of its children's union when that has it; none when
  ## neither does.
  if frame.sameSize(content.width, content.height): return some(point(frame.x, frame.y))
  let u = unionOf(children)
  if u.isSome and u.get.sameSize(content.width, content.height):
    return some(point(u.get.x, u.get.y))
  none(Point)

proc matchWindow*(frameName: string, frameExtents: Option[Rect], childUnion: Option[Rect],
                  showingFrames: int, candidates: seq[Window]): Option[Window] =
  ## The window of an AT-SPI frame among the windows of its pid: the one
  ## whose title is the frame's name, else the pid's only window when the
  ## application shows one frame, else the one window of the frame's size.
  if candidates.len == 0: return none(Window)
  if frameName.len > 0:
    var byTitle: seq[Window]
    for w in candidates:
      if w.title == some(frameName): byTitle.add w
    if byTitle.len == 1: return some(byTitle[0])
  if candidates.len == 1 and showingFrames <= 1: return some(candidates[0])
  var bySize: seq[Window]
  for w in candidates:
    let s = w.bounds.size
    if (frameExtents.isSome and frameExtents.get.sameSize(s.width, s.height)) or
       (childUnion.isSome and childUnion.get.sameSize(s.width, s.height)):
      bySize.add w
  if bySize.len == 1: return some(bySize[0])
  none(Window)

proc placeExtents*(extents: Rect, p: Option[Placement]): Option[Rect] =
  ## Extents in a frame's WINDOW coordinates as desktop coordinates.
  if p.isNone: return none(Rect)
  let q = p.get
  some(rect(q.content.x + extents.x - q.origin.x, q.content.y + extents.y - q.origin.y,
            extents.width, extents.height))

proc newPlacement*(content, origin: Point): Placement =
  ## A placement (exported for the unit tests).
  Placement(content: content, origin: origin)

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

proc disabled(msg: string): ref PermissionDeniedError =
  result = newBackendError(PermissionDeniedError, linuxAtspiName, "atspi-disabled", msg)
  result.remedy = disabledRemedy

proc treeFailed(msg: string): ref BackendError =
  newBackendError(BackendError, linuxAtspiName, "tree-failed", msg)

proc notFoundErr(reason, msg: string): ref BackendNotFoundError =
  newBackendError(BackendNotFoundError, linuxAtspiName, reason, msg)

proc isGone(e: ref DbusCallError): bool =
  ## The object or its application no longer exists.
  e.errorName in ["org.freedesktop.DBus.Error.ServiceUnknown",
                  "org.freedesktop.DBus.Error.NameHasNoOwner",
                  "org.freedesktop.DBus.Error.UnknownObject",
                  "org.freedesktop.DBus.Error.NoReply",
                  "org.freedesktop.DBus.Error.Disconnected"]

template transport(what: string, body: untyped): untyped =
  ## Run `body`; a transport failure or a timeout becomes `tree-failed`.
  try:
    body
  except DbusTimeoutError as e:
    raise treeFailed(what & ": " & e.msg & " (an application did not answer within " &
      $callTimeoutMs & " ms)")
  except DbusCallError:
    raise
  except DbusError as e:
    raise treeFailed(what & ": " & e.msg)

# ---------------------------------------------------------------------------
# The bus
# ---------------------------------------------------------------------------

proc a11yAddress(cfg: LinuxAtspiConfig): string =
  ## The address of the session's AT-SPI bus (module doc). Raises
  ## `atspi-disabled` when the session has none.
  let direct = cfg.env.getOrDefault("AT_SPI_BUS_ADDRESS", "")
  if direct.len > 0: return direct
  let session = cfg.env.getOrDefault("DBUS_SESSION_BUS_ADDRESS", "")
  if session.len == 0:
    raise disabled("the session has no D-Bus session bus (DBUS_SESSION_BUS_ADDRESS " &
      "and AT_SPI_BUS_ADDRESS are unset), so it has no AT-SPI bus")
  var sb: DbusConnection
  try:
    sb = connectBus(session, callTimeoutMs, proc () = cfg.token.checkpoint())
  except DbusTimeoutError as e:
    raise treeFailed("the session bus did not answer: " & e.msg)
  except DbusError as e:
    raise disabled("the session bus cannot be reached (" & e.msg & "), so its AT-SPI " &
      "bus cannot be found")
  try:
    let r = sb.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                    flags = flagNoAutoStart, timeoutMs = callTimeoutMs)
    if r.len != 1 or r[0].kind != dkString or r[0].str.len == 0:
      raise disabled("org.a11y.Bus answered no AT-SPI bus address")
    result = r[0].str
  except DbusCallError as e:
    if e.errorName in ["org.freedesktop.DBus.Error.ServiceUnknown",
                       "org.freedesktop.DBus.Error.NameHasNoOwner"]:
      raise disabled("no AT-SPI bus runs in this session (nothing owns org.a11y.Bus " &
        "on its session bus)")
    raise treeFailed("org.a11y.Bus.GetAddress failed: " & e.msg)
  except DbusTimeoutError as e:
    raise treeFailed("org.a11y.Bus did not answer: " & e.msg)
  except DbusError as e:
    raise treeFailed("org.a11y.Bus.GetAddress failed: " & e.msg)
  finally:
    sb.close()

proc open(r: Reader) =
  ## Connect to the AT-SPI bus once per reader.
  if r.conn != nil: return
  let address = a11yAddress(r.cfg)
  let cfg = r.cfg
  try:
    r.conn = connectBus(address, callTimeoutMs, proc () = cfg.token.checkpoint())
  except DbusTimeoutError as e:
    raise treeFailed("the AT-SPI bus did not answer: " & e.msg)
  except DbusError as e:
    raise disabled("the session's AT-SPI bus cannot be reached: " & e.msg)

proc close(r: Reader) =
  if r.conn != nil:
    r.conn.close()
    r.conn = nil

proc sessionWindows(r: Reader): seq[Window] =
  ## The session's windows, read once per reader.
  if not r.windowsRead:
    r.windowsRead = true
    if r.cfg.windows != nil:
      try: r.windows = r.cfg.windows()
      except CatchableError: r.windows = @[]
  r.windows

# ---------------------------------------------------------------------------
# Reading objects (pipelined)
# ---------------------------------------------------------------------------

proc sendOn(r: Reader, obj: ObjRef, iface, member: string,
            args: openArray[DValue] = []): uint32 =
  transport("sending to the AT-SPI bus"):
    result = r.conn.send(obj.bus, obj.path, iface, member, args, timeoutMs = callTimeoutMs)

proc answer(r: Reader, serial: uint32): Option[seq[DValue]] =
  ## The answer to `serial`; none for an error reply (an interface the
  ## object lacks, or an object that went away).
  transport("reading from the AT-SPI bus"):
    try:
      result = some(r.conn.reply(serial, callTimeoutMs))
    except DbusCallError:
      result = none(seq[DValue])

proc refOf(v: DValue): ObjRef =
  let u = v.unwrap
  if u.kind != dkStruct or u.items.len != 2:
    raise treeFailed("malformed object reference of type " & u.sig)
  (u.items[0].asStr, u.items[1].asStr)

proc ifaceOf(name: string): Option[Iface] =
  case name
  of "org.a11y.atspi.Component": some(ifComponent)
  of "org.a11y.atspi.Text": some(ifText)
  of "org.a11y.atspi.EditableText": some(ifEditableText)
  of "org.a11y.atspi.Value": some(ifValue)
  of "org.a11y.atspi.Action": some(ifAction)
  of "org.a11y.atspi.Selection": some(ifSelection)
  else: none(Iface)

proc getProp(r: Reader, obj: ObjRef, iface, prop: string): uint32 =
  ## Send `Properties.Get(iface, prop)`. One property per call: Qt's bridge
  ## implements `Get` but not `GetAll` (measured with Qt 6.10, 2026-10-22).
  r.sendOn(obj, ifPropsName, "Get", [dstr(iface), dstr(prop)])

proc propValue(r: Reader, serial: uint32): Option[DValue] =
  ## The value a `getProp` answered, without its variant; none for an error.
  let a = r.answer(serial)
  if a.isSome and a.get.len == 1: some(a.get[0].unwrap) else: none(DValue)

proc propStr(r: Reader, serial: uint32): Option[string] =
  let v = r.propValue(serial)
  if v.isSome and v.get.kind == dkString: some(v.get.str) else: none(string)

proc propNum(r: Reader, serial: uint32): Option[float] =
  let v = r.propValue(serial)
  if v.isSome and v.get.kind in {dkDouble, dkInt32, dkUint32, dkInt64, dkUint64, dkInt16,
                                 dkUint16, dkByte}:
    some(v.get.asFloat)
  else: none(float)

proc grabFocusOn(r: Reader, bus: string): bool =
  ## Whether the toolkit of the application at `bus` implements
  ## Component.GrabFocus: GTK 4 answers it with NotSupported (measured with
  ## GTK 4.20, 2026-10-22), so for it `focus` is not offered.
  if bus in r.grabFocus: return r.grabFocus[bus]
  result = true
  let sn = r.getProp((bus, rootPath), "org.a11y.atspi.Application", "ToolkitName")
  let sv = r.getProp((bus, rootPath), "org.a11y.atspi.Application", "Version")
  let name = r.propStr(sn)
  let version = r.propStr(sv)
  if name.isSome and version.isSome:
    let name = name.get
    let version = version.get
    if name.toLowerAscii == "gtk":
      try:
        if parseInt(version.split('.')[0]) >= 4: result = false
      except ValueError: discard
  r.grabFocus[bus] = result

proc readBasics(r: Reader, objs: seq[ObjRef], withChildren = true): seq[Option[Raw]] =
  ## Role, name, description, child count, states, interfaces and (with
  ## `withChildren`) the child list of each object; none for an object that
  ## no longer answers.
  if objs.len > pipelineChunk:
    var i = 0
    while i < objs.len:
      result.add r.readBasics(objs[i ..< min(i + pipelineChunk, objs.len)], withChildren)
      i += pipelineChunk
    return
  var pend: seq[seq[uint32]]
  for o in objs:
    var s = @[r.sendOn(o, ifAccessible, "GetRole"),
              r.getProp(o, ifAccessible, "Name"),
              r.getProp(o, ifAccessible, "Description"),
              r.getProp(o, ifAccessible, "ChildCount"),
              r.sendOn(o, ifAccessible, "GetState"),
              r.sendOn(o, ifAccessible, "GetInterfaces")]
    if withChildren: s.add r.sendOn(o, ifAccessible, "GetChildren")
    pend.add s
  for i, o in objs:
    let role = r.answer(pend[i][0])
    let name = r.propStr(pend[i][1])
    let description = r.propStr(pend[i][2])
    let count = r.propNum(pend[i][3])
    let st = r.answer(pend[i][4])
    let ifs = r.answer(pend[i][5])
    let ch = if withChildren: r.answer(pend[i][6]) else: none(seq[DValue])
    if role.isNone or role.get.len != 1:
      result.add none(Raw)
      continue
    var raw = Raw(obj: o, roleNum: int(role.get[0].asInt), grabFocus: r.grabFocusOn(o.bus),
                  name: name.get(""), description: description.get(""),
                  childCount: countOf(count))
    if st.isSome and st.get.len == 1:
      for wi, w in st.get[0].elems:
        if wi < 2: raw.states = raw.states or (uint64(w.asInt and 0xffff_ffff) shl (32 * wi))
    if ifs.isSome and ifs.get.len == 1:
      for n in ifs.get[0].elems:
        let f = ifaceOf(n.asStr)
        if f.isSome: raw.ifaces.incl f.get
    if ch.isSome and ch.get.len == 1:
      for c in ch.get[0].elems: raw.childRefs.add refOf(c)
      raw.childCount = raw.childRefs.len
    result.add some(raw)

proc readDetails(r: Reader, raws: var seq[Raw]) =
  ## Extents (WINDOW coordinates), text, value and actions of each object,
  ## per its interfaces. A protected field's text is never asked for.
  if raws.len > pipelineChunk:
    var i = 0
    while i < raws.len:
      var part = raws[i ..< min(i + pipelineChunk, raws.len)]
      r.readDetails(part)
      for k, p in part: raws[i + k] = p
      i += pipelineChunk
    return
  type Asked = object
    extents, text, value, valueText, actions: int64
  var asked: seq[Asked]
  for raw in raws:
    var a = Asked(extents: -1, text: -1, value: -1, valueText: -1, actions: -1)
    let protected = raw.roleNum == rPasswordText
    if ifComponent in raw.ifaces:
      a.extents = int64(r.sendOn(raw.obj, "org.a11y.atspi.Component", "GetExtents",
                                 [duint32(1)]))
    if ifText in raw.ifaces and not protected:
      a.text = int64(r.sendOn(raw.obj, "org.a11y.atspi.Text", "GetText",
                              [dint32(0), dint32(-1)]))
    if ifValue in raw.ifaces and not protected:
      a.value = int64(r.getProp(raw.obj, "org.a11y.atspi.Value", "CurrentValue"))
      a.valueText = int64(r.getProp(raw.obj, "org.a11y.atspi.Value", "Text"))
    if ifAction in raw.ifaces:
      a.actions = int64(r.sendOn(raw.obj, "org.a11y.atspi.Action", "GetActions"))
    asked.add a
  for i in 0 ..< raws.len:
    let a = asked[i]
    if a.extents >= 0:
      let e = r.answer(uint32(a.extents))
      if e.isSome and e.get.len == 1 and e.get[0].elems.len == 4:
        let it = e.get[0].elems
        let x = it[0].asInt
        let y = it[1].asInt
        let w = it[2].asInt
        let h = it[3].asInt
        # GTK answers INT_MIN for an element it has not allocated.
        if x > int64(low(int32)) and y > int64(low(int32)) and x <= int64(high(int32)) and
           y <= int64(high(int32)) and w in 0'i64 .. int64(high(int32)) and
           h in 0'i64 .. int64(high(int32)):
          raws[i].extents = some(rect(int(x), int(y), int(w), int(h)))
    if a.text >= 0:
      let t = r.answer(uint32(a.text))
      if t.isSome and t.get.len == 1 and t.get[0].kind == dkString:
        raws[i].text = some(t.get[0].str)
    if a.value >= 0:
      # `Text` (at-spi2-core 2.46 and later) is the value as the toolkit
      # words it; older bridges have only the number.
      let cur = r.propNum(uint32(a.value))
      let txt = r.propStr(uint32(a.valueText))
      if txt.isSome and txt.get.len > 0: raws[i].value = txt
      elif cur.isSome: raws[i].value = some(formatValue(cur.get))
    if a.actions >= 0:
      let act = r.answer(uint32(a.actions))
      if act.isSome and act.get.len == 1:
        for x in act.get[0].elems:
          if x.kind == dkStruct and x.items.len >= 1:
            raws[i].actions.add x.items[0].asStr.toLowerAscii
    if ifEditableText in raws[i].ifaces and raws[i].roleNum != rPasswordText and
       raws[i].value.isNone:
      raws[i].value = raws[i].text

proc readOne(r: Reader, obj: ObjRef, withChildren = true): Option[Raw] =
  let b = r.readBasics(@[obj], withChildren)
  if b[0].isNone: return none(Raw)
  var s = @[b[0].get]
  r.readDetails(s)
  some(s[0])

proc readChildren(r: Reader, parent: Raw, limit: int): seq[Raw] =
  ## The first `limit` children of `parent` that still answer, with their
  ## basics and details.
  var refs = parent.childRefs
  if refs.len > limit: refs.setLen(limit)
  for b in r.readBasics(refs):
    if b.isSome: result.add b.get
  r.readDetails(result)
  for c in result.mitems: c.parentSelection = ifSelection in parent.ifaces

proc readSubtree(r: Reader, raw: var Raw, depthLeft: int, budget: var int,
                 truncated: var bool, level = 0) =
  ## Fill `raw.sub` depth first: at most `budget` nodes in all (the caller
  ## counted `raw`), `depthLeft` levels below (-1: unbounded).
  if depthLeft == 0 or raw.childRefs.len == 0: return
  if level > maxReadDepth: raise treeFailed("the tree nests deeper than " & $maxReadDepth)
  if budget <= 0:
    truncated = true
    return
  raw.sub = r.readChildren(raw, budget)
  if raw.sub.len < raw.childRefs.len and budget < raw.childRefs.len: truncated = true
  var kept = 0
  for c in raw.sub.mitems:
    if budget <= 0:
      truncated = true
      break
    dec budget
    inc kept
    r.readSubtree(c, (if depthLeft < 0: -1 else: depthLeft - 1), budget, truncated, level + 1)
  raw.sub.setLen(kept)

# ---------------------------------------------------------------------------
# Applications
# ---------------------------------------------------------------------------

proc apps(r: Reader): seq[AtspiApp] =
  ## Every application registered on the bus, with its pid and name.
  r.open()
  var roots: seq[ObjRef]
  transport("listing the AT-SPI registry"):
    var listed: seq[DValue]
    try:
      listed = r.conn.call(registryName, rootPath, ifAccessible, "GetChildren",
                           timeoutMs = callTimeoutMs)
    except DbusCallError as e:
      raise treeFailed("the AT-SPI registry did not list its applications: " & e.msg)
    if listed.len == 1:
      for c in listed[0].elems: roots.add refOf(c)
  var pend: seq[(uint32, uint32)]
  for o in roots:
    var s1, s2: uint32
    transport("asking for an application's pid"):
      s1 = r.conn.send("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                       "GetConnectionUnixProcessID", [dstr(o.bus)], timeoutMs = callTimeoutMs)
    s2 = r.sendOn(o, ifPropsName, "Get", [dstr(ifAccessible), dstr("Name")])
    pend.add (s1, s2)
  for i, o in roots:
    let pid = r.answer(pend[i][0])
    let name = r.answer(pend[i][1])
    if pid.isNone or pid.get.len != 1: continue
    var n = ""
    if name.isSome and name.get.len == 1 and name.get[0].unwrap.kind == dkString:
      n = name.get[0].unwrap.str
    result.add AtspiApp(pid: int(pid.get[0].asInt), name: n, root: o)

proc appOfPid(r: Reader, pid: int): Option[AtspiApp] =
  for a in r.apps():
    if a.pid == pid: return some(a)
  none(AtspiApp)

proc appRaw(r: Reader, app: AtspiApp): Raw =
  let raw = r.readOne(app.root)
  if raw.isNone:
    raise notFoundErr("app", "application " & $app.pid & " left the AT-SPI bus while it was read")
  raw.get

# ---------------------------------------------------------------------------
# Placement of frames
# ---------------------------------------------------------------------------

proc childExtents(r: Reader, frame: Raw): seq[Rect] =
  ## The extents of a frame's direct children (read now when the tree read
  ## did not reach them).
  var kids = frame.sub
  if kids.len < frame.childRefs.len:
    kids = r.readChildren(frame, frame.childRefs.len)
  for k in kids:
    if k.extents.isSome and k.states.has(sShowing): result.add k.extents.get

proc candidatesOf(r: Reader, pid: int): seq[Window] =
  ## The windows a frame of `pid` may be: its on-screen windows with an
  ## area (an X11 toolkit also owns unmapped helper windows), else all of
  ## its windows with an area.
  var all: seq[Window]
  for w in r.sessionWindows():
    if w.pid == pid and w.bounds.width > 0 and w.bounds.height > 0:
      all.add w
      if w.onScreen: result.add w
  if result.len == 0: result = all

proc placementOf(r: Reader, pid: int, frame: Raw, showingFrames: int): Option[Placement] =
  ## How the frame `frame` of application `pid` is placed on the desktop.
  if frame.extents.isNone: return none(Placement)
  let candidates = r.candidatesOf(pid)
  if candidates.len == 0: return none(Placement)
  let kids = r.childExtents(frame)
  let w = matchWindow(frame.name, frame.extents, unionOf(kids), showingFrames, candidates)
  if w.isNone: return none(Placement)
  let o = frameOrigin(frame.extents.get, kids, w.get.bounds.size)
  if o.isNone: return none(Placement)
  some(Placement(content: point(w.get.bounds.x, w.get.bounds.y), origin: o.get))

proc showingFrameCount(app: Raw): int =
  for c in app.sub:
    if c.states.has(sShowing): inc result

# ---------------------------------------------------------------------------
# Raw objects as contract nodes
# ---------------------------------------------------------------------------

proc nonEmpty(s: string): Option[string] = (if s.len > 0: some(s) else: none(string))

proc toNode(raw: Raw, path: string, placement: Option[Placement]): Node =
  ## The contract node of `raw` without children.
  let protected = raw.roleNum == rPasswordText
  result = Node(path: path, role: contractRole(raw.roleNum, raw.states),
                nativeRole: nativeRoleName(raw.roleNum),
                name: nonEmpty(raw.name), description: nonEmpty(raw.description),
                states: contractStates(raw.roleNum, raw.states),
                actions: contractActions(raw), childCount: raw.childCount)
  if not protected:
    result.value = raw.value
    result.text = raw.text
  # An element that is not showing has no place on the desktop (GTK answers
  # INT_MIN for it, Qt minus the window's origin), so it has no bounds.
  if raw.extents.isSome and raw.states.has(sShowing):
    result.bounds = placeExtents(raw.extents.get, placement)

proc childPaths(parentPath: string, kids: seq[Raw]): seq[string] =
  var seen = initCountTable[Role]()
  for k in kids:
    let role = contractRole(k.roleNum, k.states)
    result.add childPath(parentPath, role, seen.getOrDefault(role, 0))
    seen.inc role

proc convert(raw: Raw, path: string, placement: Option[Placement], count: var int): Node =
  result = toNode(raw, path, placement)
  inc count
  let paths = childPaths(path, raw.sub)
  for i, c in raw.sub: result.children.add convert(c, paths[i], placement, count)

proc appNode(r: Reader, pid: int, app: Raw, count: var int): Node =
  ## An application's tree (as read into `app.sub`) as contract nodes, each
  ## frame's subtree placed through that frame's window.
  result = toNode(app, "/app[" & $pid & "]", none(Placement))
  inc count
  let frames = app.showingFrameCount
  let paths = childPaths(result.path, app.sub)
  for i, f in app.sub:
    result.children.add convert(f, paths[i], r.placementOf(pid, f, frames), count)

# ---------------------------------------------------------------------------
# Resolving targets and paths
# ---------------------------------------------------------------------------

proc appByName(r: Reader, name: string): AtspiApp =
  ## The one application named `name`; two or more are refused with their
  ## pids (spec §7.5, "Matching rules").
  var found: seq[AtspiApp]
  for a in r.apps():
    if a.name == name: found.add a
  if found.len > 1:
    var pids: seq[int]
    for a in found: pids.add a.pid
    pids.sort()
    raise badArgs("conflicting-arguments", $found.len & " running applications are named '" &
      name & "'; select one with --pid", details = %*{"pids": pids})
  if found.len == 0:
    raise notFoundErr("app", "no application named '" & name & "' is on the session's AT-SPI bus")
  found[0]

proc appByPid(r: Reader, pid: int): AtspiApp =
  let a = r.appOfPid(pid)
  if a.isNone:
    raise notFoundErr("app", "no application with pid " & $pid &
      " is on the session's AT-SPI bus")
  a.get

type Resolved = object
  pid: int
  app: Raw           ## the application, its direct children listed
  chain: seq[Raw]    ## the nodes along the path, the target last (empty: the app)
  path: string

proc resolve(r: Reader, path: string): Resolved =
  ## The node a path names. Not found (exit 3 / `element`) when a step does
  ## not resolve.
  var tp: TreePath
  try: tp = parseTreePath(path)
  except TreeError as e: raise badArgs("invalid-value", e.msg)
  r.open()
  let a = r.appOfPid(tp.pid)
  if a.isNone: raise notFoundErr("element", "no application with pid " & $tp.pid &
    " is on the session's AT-SPI bus")
  result.pid = tp.pid
  result.app = r.appRaw(a.get)
  result.path = $tp
  var cur = result.app
  for si, st in tp.steps:
    var refs = cur.childRefs
    var found = none(Raw)
    var seen = 0
    let basics = r.readBasics(refs, withChildren = true)
    for b in basics:
      if b.isNone: continue
      if contractRole(b.get.roleNum, b.get.states) == st.role:
        if seen == st.index:
          found = b
          break
        inc seen
    if found.isNone: raise notFoundErr("element", "no element at " & path)
    var s = @[found.get]
    r.readDetails(s)
    s[0].parentSelection = ifSelection in cur.ifaces
    result.chain.add s[0]
    cur = s[0]

proc placementFor(r: Reader, res: Resolved): Option[Placement] =
  ## The placement of the frame that holds the resolved node.
  if res.chain.len == 0: return none(Placement)
  var app = res.app
  app.sub = r.readChildren(app, app.childRefs.len)
  r.placementOf(res.pid, res.chain[0], app.showingFrameCount)

proc elementOf(r: Reader, res: Resolved): Node =
  if res.chain.len == 0: return toNode(res.app, res.path, none(Placement))
  toNode(res.chain[^1], res.path, r.placementFor(res))

proc appTree(r: Reader, app: AtspiApp, depth: Option[int], maxNodes: int): TreeRead =
  var root = r.appRaw(app)
  var budget = maxNodes - 1
  var truncated = false
  r.readSubtree(root, (if depth.isSome: depth.get else: -1), budget, truncated)
  var count = 0
  result.root = r.appNode(app.pid, root, count)
  result.nodeCount = count
  result.truncated = truncated

proc subtreeAt(r: Reader, res: Resolved, depth: Option[int], maxNodes: int): TreeRead =
  ## The subtree at a resolved node, paths absolute.
  if res.chain.len == 0:
    return r.appTree(AtspiApp(pid: res.pid, root: res.app.obj), depth, maxNodes)
  let placement = r.placementFor(res)
  var top = res.chain[^1]
  var budget = maxNodes - 1
  var truncated = false
  r.readSubtree(top, (if depth.isSome: depth.get else: -1), budget, truncated)
  var count = 0
  result.root = convert(top, res.path, placement, count)
  result.nodeCount = count
  result.truncated = truncated

proc frameOfWindow(r: Reader, windowId: string): Resolved =
  ## The AT-SPI frame of the compositor's window `windowId`.
  var win = none(Window)
  for w in r.sessionWindows():
    if w.id == windowId: win = some(w)
  if win.isNone: raise notFoundErr("window", "no window '" & windowId & "' in this session")
  let w = win.get
  let app = r.appByPid(w.pid)
  var appRaw = r.appRaw(app)
  appRaw.sub = r.readChildren(appRaw, appRaw.childRefs.len)
  let frames = appRaw.showingFrameCount
  var seen = initCountTable[Role]()
  for f in appRaw.sub:
    let role = contractRole(f.roleNum, f.states)
    let idx = seen.getOrDefault(role, 0)
    seen.inc role
    let candidates = r.candidatesOf(w.pid)
    let kids = r.childExtents(f)
    let m = matchWindow(f.name, f.extents, unionOf(kids), frames, candidates)
    if m.isSome and m.get.id == windowId:
      return Resolved(pid: w.pid, app: appRaw, chain: @[f],
                      path: childPath("/app[" & $w.pid & "]", role, idx))
  raise notFoundErr("element", "window '" & windowId & "' has no accessibility element")

proc focusedApp(r: Reader): AtspiApp =
  ## The application holding the active frame, else the one owning the
  ## compositor's focused window.
  let all = r.apps()
  for a in all:
    let raw = r.appRaw(a)
    for b in r.readBasics(raw.childRefs, withChildren = false):
      if b.isSome and b.get.states.has(sActive): return a
  for w in r.sessionWindows():
    if w.focused:
      for a in all:
        if a.pid == w.pid: return a
  raise notFoundErr("window", "no accessible application has the focus")

proc targetTree(r: Reader, target: TreeTarget, depth: Option[int], maxNodes: int): TreeRead =
  r.open()
  case target.kind
  of ttkPid: r.appTree(r.appByPid(target.pid), depth, maxNodes)
  of ttkApp: r.appTree(r.appByName(target.app), depth, maxNodes)
  of ttkFocused: r.appTree(r.focusedApp(), depth, maxNodes)
  of ttkWindow: r.subtreeAt(r.frameOfWindow(target.windowId), depth, maxNodes)

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc boolAnswer(r: Reader, obj: ObjRef, iface, member: string, args: openArray[DValue],
                what: string) =
  ## Call a method answering a boolean; false or an error reply is
  ## `tree-failed`.
  let s = r.sendOn(obj, iface, member, args)
  var ans: seq[DValue]
  transport("performing " & what):
    try:
      ans = r.conn.reply(s, callTimeoutMs)
    except DbusCallError as e:
      raise treeFailed("the application refused " & what & ": " & e.errorName)
  if ans.len == 1 and ans[0].kind == dkBool and ans[0].num == 0:
    raise treeFailed("the application refused " & what)

proc doAction(r: Reader, raw: Raw, index: int, what: string) =
  r.boolAnswer(raw.obj, "org.a11y.atspi.Action", "DoAction", [dint32(index)], what)

proc setNumeric(r: Reader, raw: Raw, v: float, what: string) =
  let s = r.sendOn(raw.obj, ifPropsName, "Set",
                   [dstr("org.a11y.atspi.Value"), dstr("CurrentValue"), dvariant(ddouble(v))])
  transport("performing " & what):
    try: discard r.conn.reply(s, callTimeoutMs)
    except DbusCallError as e:
      raise treeFailed("the application refused " & what & ": " & e.errorName)

proc valueRange(r: Reader, raw: Raw): tuple[cur, lo, hi, step: float] =
  const iface = "org.a11y.atspi.Value"
  let s = [r.getProp(raw.obj, iface, "CurrentValue"), r.getProp(raw.obj, iface, "MinimumValue"),
           r.getProp(raw.obj, iface, "MaximumValue"),
           r.getProp(raw.obj, iface, "MinimumIncrement")]
  let cur = r.propNum(s[0])
  if cur.isNone: raise treeFailed("the element's value cannot be read")
  result = (cur.get, r.propNum(s[1]).get(-Inf), r.propNum(s[2]).get(Inf),
            r.propNum(s[3]).get(0.0))

proc indexInParent(r: Reader, raw: Raw): int =
  let s = r.sendOn(raw.obj, ifAccessible, "GetIndexInParent")
  let a = r.answer(s)
  if a.isNone or a.get.len != 1: raise treeFailed("the element's index cannot be read")
  int(a.get[0].asInt)

proc perform(r: Reader, res: Resolved, action: NodeAction, value: Option[string]) =
  let raw = res.chain[^1]
  let what = "'" & $action & "' on " & res.path
  case action
  of actPress: r.doAction(raw, raw.pressIndex, what)
  of actFocus:
    let i = raw.actionIndex(["setfocus", "set focus"])
    # The same condition that offered it (`contractActions`): GrabFocus only
    # where the toolkit implements it, else the element's own focus action.
    if ifComponent in raw.ifaces and raw.states.has(sFocusable) and raw.grabFocus:
      r.boolAnswer(raw.obj, "org.a11y.atspi.Component", "GrabFocus", [], what)
    else: r.doAction(raw, i, what)
  of actSetValue:
    let v = value.get("")
    if ifEditableText in raw.ifaces and raw.states.has(sEditable):
      r.boolAnswer(raw.obj, "org.a11y.atspi.EditableText", "SetTextContents", [dstr(v)], what)
    else:
      var f: float
      try: f = parseFloat(v.strip)
      except ValueError:
        raise badArgs("invalid-value", "the element at " & res.path &
          " holds a number; --value is not one")
      r.setNumeric(raw, f, what)
  of actIncrement, actDecrement:
    let named = raw.actionIndex(if action == actIncrement: ["increase", "increment"]
                                else: ["decrease", "decrement"])
    if named >= 0: r.doAction(raw, named, what)
    else:
      let (cur, lo, hi, step) = r.valueRange(raw)
      let d = if step > 0: step else: 1.0
      r.setNumeric(raw, clamp(cur + (if action == actIncrement: d else: -d), lo, hi), what)
  of actExpand, actCollapse:
    let named = raw.actionIndex([$action])
    r.doAction(raw, (if named >= 0: named else: raw.toggleIndex), what)
  of actSelect:
    let parent = if res.chain.len >= 2: res.chain[^2] else: res.app
    r.boolAnswer(parent.obj, "org.a11y.atspi.Selection", "SelectChild",
                 [dint32(r.indexInParent(raw))], what)
  of actShowMenu: r.doAction(raw, raw.actionIndex(menuNames), what)
  of actScrollToVisible:
    # Never offered (module doc), so `contractActions` refused it already.
    raise treeFailed("the element at " & res.path & " does not offer 'scroll-to-visible'")

# ---------------------------------------------------------------------------
# The backend
# ---------------------------------------------------------------------------

proc newReader(cfg: LinuxAtspiConfig): Reader = Reader(cfg: cfg)

template withReader(cfg: LinuxAtspiConfig, r: untyped, body: untyped): untyped =
  ## Run `body` with a reader, closed after it. An answer of an unexpected
  ## type (`asInt` of a string, `elems` of a number) or a protocol failure
  ## not already reported is `tree-failed`, never an internal error.
  let r = newReader(cfg)
  try:
    body
  except DbusError as e:
    raise treeFailed("an application answered the AT-SPI bus malformed: " & e.msg)
  finally:
    r.close()

proc registeredApps*(cfg: LinuxAtspiConfig): Option[seq[AtspiApp]] =
  ## The applications registered on the session's AT-SPI bus; none when the
  ## session has no reachable AT-SPI bus (so "accessible" cannot be told,
  ## spec §7.5 `App.accessible`). Raises for a bus that answers wrongly.
  withReader(cfg, r):
    try:
      r.open()
    except PermissionDeniedError:
      return none(seq[AtspiApp])
    result = some(r.apps())

proc atspiReachable*(cfg: LinuxAtspiConfig): bool =
  ## Whether the session's AT-SPI bus answers (its registry lists its
  ## applications).
  try:
    registeredApps(cfg).isSome
  except CatchableError:
    false

proc newLinuxAtspiTree*(cfg: LinuxAtspiConfig): TreeBackend =
  ## The `linux-atspi` tree backend.
  result.name = linuxAtspiName

  result.tree = proc (session: string, target: TreeTarget, depth: Option[int],
                      maxNodes: int): TreeRead =
    withReader(cfg, r):
      result = r.targetTree(target, depth, maxNodes)

  result.find = proc (session: string, target: Option[TreeTarget], filter: ElementFilter,
                      limit: int): tuple[elements: seq[Node], truncated: bool] =
    withReader(cfg, r):
      var roots: seq[Node]
      if target.isSome:
        roots.add r.targetTree(target.get, none(int), high(int)).root
      else:
        r.open()
        for a in r.apps():
          try:
            roots.add r.appTree(a, none(int), high(int)).root
          except BackendNotFoundError:
            discard   # it left the bus while the others were read
      for root in roots:
        let left = limit - result.elements.len
        let found = findAll(root, filter, max(left, 0))
        result.elements.add found.elements
        if found.truncated:
          result.truncated = true
          break

  result.element = proc (session, path: string): Node =
    withReader(cfg, r):
      result = r.elementOf(r.resolve(path))

  result.perform = proc (session, path: string, action: NodeAction,
                         value: Option[string]): Node =
    cfg.token.checkpoint()
    withReader(cfg, r):
      let res = r.resolve(path)
      if res.chain.len == 0 or action notin contractActions(res.chain[^1]):
        raise treeFailed("the element at " & path & " does not offer '" & $action & "'")
      r.perform(res, action, value)
      result = r.elementOf(r.resolve(path))

  result.features = proc (probe: bool): seq[Feature] =
    var state = fsAvailable
    var reason = none(string)
    var remedy = none(string)
    let hasBus = cfg.env.getOrDefault("AT_SPI_BUS_ADDRESS", "").len > 0 or
                 cfg.env.getOrDefault("DBUS_SESSION_BUS_ADDRESS", "").len > 0
    if not hasBus:
      state = fsUnavailable
      reason = some("atspi-disabled")
      remedy = some(disabledRemedy)
    elif probe:
      try:
        withReader(cfg, r):
          r.open()
          discard r.apps()
        state = fsSupported
      except ContractError:
        raise
      except BackendError as e:
        state = fsUnavailable
        reason = some(if e of ref PermissionDeniedError: e.reason else: "atspi-disabled")
        remedy = some(disabledRemedy)
      except CatchableError:
        state = fsUnavailable
        reason = some("atspi-disabled")
        remedy = some(disabledRemedy)
    for f in ["tree-read", "element-actions"]:
      result.add Feature(feature: f, backend: linuxAtspiName, state: state, reason: reason,
                         remedy: remedy)
