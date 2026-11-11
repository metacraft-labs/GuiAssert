## Facts every Wayland target measures the same way: with `wm_probe`, a real
## client that opens a window and reports what the compositor grants it.

import std/[json, os, osproc, streams, strtabs, strutils, tables]
import ../desktop_env, ./helpers

proc probe*(t: TargetEnvironment; args: varargs[string]): JsonNode =
  ## Run `wm_probe` in the target's session and parse its JSON line.
  var env: seq[(string, string)]
  for k, v in t.sessionEnv: env.add (k, v)
  let p = startProcess(helper("wm_probe"), args = @args,
                       env = (proc(): StringTableRef =
                         result = newStringTable(modeCaseSensitive)
                         for k, v in envPairs(): result[k] = v
                         for (k, v) in env: result[k] = v)(),
                       options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0: raise t.envError("probe " & args.join(" "), output.strip())
  try: parseJson(output.strip().splitLines()[^1])
  except JsonParsingError, IndexDefect:
    raise t.envError("probe " & args.join(" "), "unreadable output: " & output)

proc measureWaylandFacts*(t: TargetEnvironment; facts: var Table[string, Fact]) =
  ## The decoration mode granted, whether a client-side request is honoured
  ## (`always`, `floating-only`, `never`), whether server-side decorations
  ## exist at all, the advertised capabilities, and whether maximize and
  ## fullscreen requests on a mapped window take effect.
  let chosen = t.probe()
  let asked = t.probe("client")
  let askedFloating = t.probe("client", "fixed")
  let mapped = t.probe("map")
  template put(factName, factValue, how: string) =
    facts[factName] = Fact(name: factName, value: factValue,
                           provenance: fpMeasured, detail: how)
  put("decorations.default",
      (if chosen["decoration_mode"].getStr == "none": "client"
       else: chosen["decoration_mode"].getStr),
      "the mode a window that asks for none is granted (no decoration " &
      "manager: the client decorates)")
  put("decorations.serverAvailable", $chosen["decoration_manager"].getBool,
      "the compositor offers xdg-decoration, so it can draw a frame")
  let honoured =
    if not chosen["decoration_manager"].getBool: "always"
    elif asked["decoration_mode"].getStr == "client": "always"
    elif askedFloating["decoration_mode"].getStr == "client": "floating-only"
    else: "never"
  put("decorations.honoursClientRequest", honoured,
      "client-side requested by a tiled and by a floating window")
  var caps: seq[string]
  for c in chosen["capabilities"]: caps.add c.getStr
  let reported = chosen["capabilities_reported"].getBool
  put("window.capabilities", caps.join(","),
      if reported: "xdg_toplevel.wm_capabilities" else: "not reported: all assumed")
  template advertised(c: string): string = $(not reported or c in caps)
  put("window.canMinimize", advertised("minimize"),
      "advertised by wm_capabilities")
  put("window.hasWindowMenu", advertised("window_menu"),
      "advertised by wm_capabilities")
  put("window.canMaximize", $mapped["maximize_honoured"].getBool,
      "a mapped window asked to maximize")
  put("window.canFullscreen", $mapped["fullscreen_honoured"].getBool,
      "a mapped window asked to go fullscreen")
