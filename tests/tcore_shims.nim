## The modules that existed before the core / opt-in split keep their import
## paths and their public API.
##
## `test_legacy_import_paths_still_compile` checks two things:
##
## 1. **Signatures.** For each split module, every public symbol in its
##    frozen pre-split API (`tests/fixtures/legacy_api/<module>.json`,
##    recorded by `nim jsondoc` at 8e8df7ea, see `tests/legacy_api.nim`) must
##    still be declared, by the module itself or by a module it re-exports,
##    with the same parameters, defaults and return type, and for types and
##    constants the same definition. On the platform the baselines were
##    recorded on (macOS), a routine must also raise and tag nothing beyond
##    what it did before, so a caller that spelled out the old effects still
##    compiles; elsewhere the effects are platform-dependent and only the
##    signature head is compared.
## 2. **Reachability through the old path.** A probe that imports only
##    `gui_assert/<module>` must see every one of those symbols
##    (`declared(<module>.<symbol>)`), and a probe importing every public
##    module of the package must build.
##
## A control feeds the comparison a baseline entry whose signature differs
## from the current one and requires it to be reported, so a comparison that
## accepts everything cannot pass.
##
## NO MOCKS: the real compiler's view of the real modules.

import std/[os, sets, strutils, unittest]

import ./[legacy_api, probe_compiler]

const
  fixtures = currentSourcePath().parentDir / "fixtures" / "legacy_api"
  baselinePlatform = "macosx"
    ## The host the baselines were recorded on (see the header).

  splitModules = [
    ("image_math", @["image_math", "core/image", "core/ssim", "core/hashing",
                     "backends/media/ffmpeg"]),
    ("ocr", @["ocr", "core/ocr_types"]),
    ("vision_windows", @["vision_windows", "core/vision_windows"]),
    ("video_analysis", @["video_analysis", "core/segmentation",
                         "core/ocr_types"]),
    ("screen_capture", @["screen_capture"]),
    ("capture", @["capture"]),
    ("input", @["input"]),
  ]
    ## Each legacy module and the modules whose declarations it now
    ## re-exports (its own file first).

proc srcFile(rel: string): string =
  srcDir() / "gui_assert" / (rel & ".nim")

proc compatibleWith(old: ApiEntry, current: seq[ApiEntry], strict: bool): bool =
  for cur in current:
    if strict:
      if compatible(old, cur): return true
    elif old.name == cur.name and old.kind == cur.kind:
      if old.kind in ["skProc", "skFunc", "skMethod", "skIterator",
                      "skConverter", "skTemplate", "skMacro"]:
        if splitEffects(old.code).head == splitEffects(cur.code).head:
          return true
      elif compatible(old, cur):
        return true
  false

suite "legacy import paths":
  test "test_legacy_import_paths_still_compile":
    let strict = hostOS == baselinePlatform
    let work = freshDir("shims")
    defer: removeDir(work)
    var probe = ""
    var probedNames = 0
    for (module, sources) in splitModules:
      let baseline = readBaseline(fixtures / module & ".json")
      check baseline.len > 0
      var current: seq[ApiEntry] = @[]
      for src in sources:
        current.add apiOf(srcFile(src), work / module / src.replace('/', '_'))
      var missing: seq[string] = @[]
      for old in baseline:
        if not compatibleWith(old, current, strict):
          missing.add old.kind & " " & old.code.splitLines.join(" ")
      if missing.len > 0:
        checkpoint module & ": pre-split API not preserved:\n" &
          indent(missing.join("\n"))
      check missing.len == 0
      # Every baseline name must be reachable through the legacy path.
      probe.add "import gui_assert/" & module & "\n"
      var names = initHashSet[string]()
      for old in baseline: names.incl old.name
      for name in names:
        probe.add "static: doAssert declared(" & module & "." & name &
          "), \"" & module & "." & name & " is gone\"\n"
        inc probedNames
    check probedNames > 100
    let (_, output, code) = compileProbe(work, "reachable", probe)
    if code != 0: checkpoint "legacy path probe failed:\n" & indent(output)
    check code == 0

    # Every public module of the package still builds from its old path.
    var everything = "import gui_assert\n"
    for pattern in ["*.nim", "desktop_env" / "*.nim"]:
      for f in walkFiles(srcDir() / "gui_assert" / pattern):
        let rel = f.relativePath(srcDir() / "gui_assert").replace('\\', '/')
        when not defined(posix):
          if rel == "pty_unix.nim": continue   # a POSIX-only module by design
        everything.add "import gui_assert/" & rel[0 ..< ^4] & "\n"
    let (_, eout, ecode) = compileProbe(work, "everything", everything)
    if ecode != 0: checkpoint "importing every public module failed:\n" & indent(eout)
    check ecode == 0
    # The vision CLI is a program, not a library; it must still build.
    let (vout, vcode) = run(nimExe(), @["c", "--hints:off", "--warnings:off",
      "--nimcache:" & (work / "nimcache_vision"),
      "-o:" & (work / "gui_assert_vision".addFileExt(ExeExt)),
      srcDir() / "gui_assert_vision.nim"])
    if vcode != 0: checkpoint "gui_assert_vision failed to build:\n" & indent(vout)
    check vcode == 0

  test "control: a changed signature is reported":
    let work = freshDir("shims_control")
    defer: removeDir(work)
    let current = apiOf(srcFile("core/ssim"), work)
    var changed = ApiEntry(name: "computeSsim", kind: "skProc",
      code: "proc computeSsim(a, b: GrayImage; window = 8): float " &
            "{.raises: [ImageMathError], tags: [], forbids: [].}")
    check not compatibleWith(changed, current, strict = true)
    check not compatibleWith(changed, current, strict = false)
    # An extra raised type is reported where effects are compared.
    changed.code = "proc computeSsim(a, b: GrayImage): float " &
                   "{.raises: [], tags: [], forbids: [].}"
    check not compatibleWith(changed, current, strict = true)
    # And the unchanged declaration is accepted.
    changed.code = "proc computeSsim(a, b: GrayImage): float " &
                   "{.raises: [ImageMathError], tags: [], forbids: [].}"
    check compatibleWith(changed, current, strict = true)
