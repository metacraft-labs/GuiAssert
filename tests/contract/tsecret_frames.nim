## Secret-guarded frames (contract 1.1, GS17; spec §7.5 "Secret-guarded
## frames"), through the REAL built binaries as subprocesses and over the
## REAL `guiassert serve`:
##
## * a secret typed into the built-in form's plain Name field is drawn, so
##   `screenshot --secret-stdin` and `ocr … --secret-stdin` are exit 5 /
##   `secret-visible`: the frame they captured is gone, the envelope holds
##   no image, word or text, and the secret is in no stream; `ocr --image
##   --secret-stdin` of a frame showing it refuses the same way and leaves
##   the caller's file in place;
## * typed into the protected Password field (drawn masked) the same verbs
##   succeed, report the frame and its words, and keep it (the control that
##   the guard is not a refusal of everything);
## * `--min-confidence` cannot hide a visible secret from the guard;
## * a frame the engine then fails to read is removed too (a stand-in
##   `tesseract` that fails every recognition);
## * a secret of fewer than 4 characters besides white space is exit 2 /
##   `invalid-value` before anything is captured;
## * over `serve`, the `run` request's `stdin` is the secret, with the CLI's
##   answers.
##
## Stand-ins: the fixture backend (spec §9.2) is the only one: its OCR reads
## exactly the words it drew, so "legible" is decided by the drawing, not by
## an engine's luck. The tesseract engine is exercised over real frames by
## the core rule's own tolerance tests (tests/tcore_secret_guard.nim).

import std/[json, os, osproc, sequtils, streams, strtabs, strutils, unittest]

import ./harness

const
  passwordCenter = "370,396"   ## the built-in form's Password field
  nameCenter = "370,152"       ## its Name field
  secret = "Kv7guardedQ"       ## 11 characters: exact or one misread

proc runCliInput(args: seq[string], env: StringTableRef, input: string): CliRun =
  ## `runCli` with `input` on the binary's standard input.
  let p = startProcess(contractBin(), args = args, env = env, options = {})
  try:
    p.inputStream.write(input)
    p.inputStream.close()
    result.exit = p.waitForExit(cliTimeoutMs)
    result.stdout = p.outputStream.readAll()
    result.stderr = p.errorStream.readAll()
  finally:
    p.close()

proc fixtureFrames(stateDir: string): int =
  toSeq(walkFiles(stateDir / "fixture" / "frames" / "*.json")).len

template ok(args: seq[string], vars: StringTableRef): JsonNode =
  let run = cli(args, vars)
  if run.exit != 0: checkpoint args.join(" ") & " -> " & run.line
  check run.exit == 0
  (if run.exit == 0: run.env.data else: newJObject())

template refusedVisible(r: CliRun) =
  ## Exit 5 / secret-visible, nothing of the frame reported, the secret in
  ## no stream.
  checkpoint r.stdout
  check r.exit == 5
  let e = envelopeOf(r)
  check e["ok"].getBool == false
  check e["error"]["kind"].getStr == "backend-error"
  check e["error"]["reason"].getStr == "secret-visible"
  check not e.hasKey("data")
  check secret notin r.stdout and secret notin r.stderr
  check secret.toLowerAscii notin r.stdout.toLowerAscii

proc typeInto(env: StringTableRef, at: string) =
  discard cli(@["click", "--at", at], env)
  let t = runCliInput(@["type", "--stdin"], env, secret)
  doAssert t.exit == 0, t.stdout

suite "secret-guarded frames (GS17, contract 1.1)":

  test "test_secret_visible_frame_is_refused_and_removed":
    let st = freshDir("sg-vis")
    let work = freshDir("sg-vis-work")
    let env = fixtureEnv(st)
    typeInto(env, nameCenter)
    # screenshot: refused, the frame it captured removed.
    let shot = work / "shot.png"
    refusedVisible(runCliInput(@["screenshot", "--out", shot, "--secret-stdin"], env, secret))
    check not fileExists(shot)
    check fixtureFrames(st) == 1          # it did capture: the guard read the frame
    # ocr of a capture: refused, the frame removed, no words.
    let cap = work / "cap.png"
    refusedVisible(runCliInput(@["ocr", "--display", "fixture-display-1", "--out", cap,
                                 "--secret-stdin"], env, secret))
    check not fileExists(cap)
    # --min-confidence above every word's cannot hide it from the guard.
    let cap2 = work / "cap2.png"
    refusedVisible(runCliInput(@["ocr", "--region", "0,0,800,600", "--out", cap2,
                                 "--min-confidence", "100", "--secret-stdin"], env, secret))
    check not fileExists(cap2)
    # ocr --image: refused, the caller's file left alone.
    let plain = work / "plain.png"
    discard ok(@["screenshot", "--out", plain], env)
    refusedVisible(runCliInput(@["ocr", "--image", plain, "--secret-stdin"], env, secret))
    check fileExists(plain)
    # Control: unguarded, the same frame's words do hold the secret.
    let words = ok(@["ocr", "--image", plain], env)
    check secret in words["text"].getStr
    # A misread glyph is still visible (11 characters allow one).
    let misread = secret[0 .. ^2] & "Z"
    let m = runCliInput(@["screenshot", "--out", work / "m.png", "--secret-stdin"], env, misread)
    check m.exit == 5 and envelopeOf(m)["error"]["reason"].getStr == "secret-visible"
    check not fileExists(work / "m.png")

  test "test_secret_masked_frame_is_kept":
    let st = freshDir("sg-mask")
    let work = freshDir("sg-mask-work")
    let env = fixtureEnv(st)
    typeInto(env, passwordCenter)
    let shot = work / "shot.png"
    let r = runCliInput(@["screenshot", "--out", shot, "--secret-stdin"], env, secret)
    checkpoint r.stdout
    check r.exit == 0
    check fileExists(shot)
    check envelopeOf(r)["data"]["image"]["path"].getStr == shot
    let o = runCliInput(@["ocr", "--display", "fixture-display-1", "--out", work / "o.png",
                          "--secret-stdin"], env, secret)
    checkpoint o.stdout
    check o.exit == 0
    let d = envelopeOf(o)["data"]
    check d["words"].len > 0 and repeat('*', secret.len) in d["text"].getStr
    check secret notin o.stdout
    check fileExists(work / "o.png")
    let i = runCliInput(@["ocr", "--image", shot, "--secret-stdin"], env, secret)
    check i.exit == 0 and envelopeOf(i)["data"]["words"].len > 0

  test "test_short_secret_is_refused_before_capture":
    let st = freshDir("sg-short")
    let work = freshDir("sg-short-work")
    let env = fixtureEnv(st)
    for s in ["abc", "", " a b c \n"]:
      let r = runCliInput(@["screenshot", "--out", work / "s.png", "--secret-stdin"], env, s)
      checkpoint r.stdout
      check r.exit == 2 and envelopeOf(r)["error"]["reason"].getStr == "invalid-value"
      let o = runCliInput(@["ocr", "--region", "0,0,10,10", "--out", work / "o.png",
                            "--secret-stdin"], env, s)
      check o.exit == 2 and envelopeOf(o)["error"]["reason"].getStr == "invalid-value"
    check not fileExists(work / "s.png") and not fileExists(work / "o.png")
    check fixtureFrames(st) == 0
    let bad = runCliInput(@["screenshot", "--out", work / "s.png", "--secret-stdin"], env,
                          "\xff\xfe\xfd\xfc")
    check bad.exit == 2 and envelopeOf(bad)["error"]["reason"].getStr == "invalid-value"

  test "test_secret_guarded_frame_is_removed_when_recognition_fails":
    # The engine fails after the frame is captured: the guard could not
    # judge the frame, so it must not keep it. A stand-in `tesseract`
    # (TESSERACT_BIN) lists `eng` and fails every recognition; the fixture
    # capture backend records each frame it captures, which shows that the
    # frame was written before it was removed.
    let st = freshDir("sg-fail")
    let work = freshDir("sg-fail-work")
    let stub = work / "tesseract"
    writeFile(stub, "#!/bin/sh\n" &
      "if [ \"$1\" = --list-langs ]; then\n" &
      "  printf 'List of available languages (1):\\neng\\n'; exit 0\n" &
      "fi\n" &
      "echo 'stand-in engine failure' >&2; exit 1\n")
    setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
    let env = fixtureEnv(st, [("TESSERACT_BIN", stub)])
    typeInto(env, nameCenter)
    let shot = work / "shot.png"
    let cap = work / "cap.png"
    let s = runCliInput(@["--ocr-backend", "tesseract", "screenshot", "--out", shot,
                          "--secret-stdin"], env, secret)
    let o = runCliInput(@["--ocr-backend", "tesseract", "ocr", "--display",
                          "fixture-display-1", "--out", cap, "--secret-stdin"], env, secret)
    checkpoint s.stdout
    checkpoint o.stdout
    check not fileExists(shot) and not fileExists(cap)
    check secret notin s.stdout & s.stderr & o.stdout & o.stderr
    if isMinimalBinary():
      # No tesseract in this build: refused before anything is captured.
      check s.exit == 4 and envelopeOf(s)["error"]["reason"].getStr == "not-compiled-in"
      check o.exit == 4
      check fixtureFrames(st) == 0
    else:
      check s.exit == 5 and envelopeOf(s)["error"]["reason"].getStr == "ocr-failed"
      check o.exit == 5 and envelopeOf(o)["error"]["reason"].getStr == "ocr-failed"
      check fixtureFrames(st) == 2        # both were captured, then removed

  test "test_secret_guard_over_serve":
    let st = freshDir("sg-serve")
    let work = freshDir("sg-serve-work")
    let env = fixtureEnv(st)
    typeInto(env, nameCenter)
    var d = startServe(@["serve", "--stdio"], env)
    d.send(%*{"v": 1, "id": "g1", "op": "run",
              "argv": ["screenshot", "--out", work / "g1.png", "--secret-stdin"],
              "stdin": secret})
    let raw = d.recvRaw()
    let r1 = parseJson(raw)
    check r1["exit"].getInt == 5
    check r1["envelope"]["error"]["reason"].getStr == "secret-visible"
    check secret notin raw
    check not fileExists(work / "g1.png")
    # Without stdin the flag has nothing to read.
    d.send(%*{"v": 1, "id": "g2", "op": "run",
              "argv": ["screenshot", "--out", work / "g2.png", "--secret-stdin"]})
    let r2 = parseJson(d.recvRaw())
    check r2["exit"].getInt == 2 and r2["envelope"]["error"]["reason"].getStr ==
      "missing-argument"
    # stdin offered to a screenshot without the flag is refused, as before.
    d.send(%*{"v": 1, "id": "g3", "op": "run",
              "argv": ["screenshot", "--out", work / "g3.png"], "stdin": secret})
    let r3 = parseJson(d.recvRaw())
    check r3["exit"].getInt == 2 and r3["envelope"]["error"]["reason"].getStr ==
      "conflicting-arguments"
    d.closeInput()
    discard d.reader.readLine(30_000)
    check d.finish() == 0

cleanupFreshDirs()
