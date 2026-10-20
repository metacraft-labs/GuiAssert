## Unit tests for the contract's pure core: the serializers and strict
## parsers of `core/contract`, the SHA-256 of `core/sha256`, the key table of
## `core/keys` and the drawing of `core/raster`.
##
## Entirely in memory: no subprocess, no file, no mock. The SHA-256 vectors
## are FIPS 180-4's published examples plus boundary lengths computed with an
## independent implementation (Python's hashlib).

import std/[json, options, strutils, tables, unittest]

import ../src/gui_assert/core/[contract, geometry, image, desktop_types, ocr_types,
                              tree_types, keys, raster, sha256]

proc sampleSession(): Session =
  result = Session(id: "s1", name: some("s1"), kind: skHeadless, backend: "fixture",
                   platform: spFixture, state: ssRunning, lifetime: slOwner,
                   isolation: Isolation(pixels: true, input: true, clipboard: false),
                   displays: @[Display(id: "d1", name: none(string),
                                       bounds: rect(0, 0, 640, 480), scale: 2.0,
                                       primary: true, isVirtual: true)],
                   vnc: some(VncEndpoint(host: "127.0.0.1", port: 5901)),
                   backends: SessionBackends(capture: "a", tree: "b", input: "c"),
                   createdAt: "2026-01-01T00:00:01.000Z", hostPid: some(42),
                   envUnset: @["DISPLAY", "NO_AT_BRIDGE"])
  result.env["K"] = "V"

suite "contract envelope and kinds":
  test "exit codes and kinds are the frozen table":
    check ekInternal.code == 1 and ekCancelled.code == 8
    for k in ErrorKind: check kindOfCode(k.code) == k
    expect ValueError: discard kindOfCode(0)
    expect ValueError: discard kindOfCode(9)
    check "unknown-verb" in reasonsOf(ekBadArgs)
    check "request" in reasonsOf(ekNotFound) and "request" in reasonsOf(ekCancelled)

  test "an unlisted reason becomes internal instead of reaching a consumer":
    let e = newContractError(ekNotFound, "deadline", "x")
    check e.kind == ekInternal and e.reason == "exception"
    let ok = newContractError(ekTimeout, "deadline", "x", "do y", %*{"a": 1})
    check ok.kind == ekTimeout and ok.remedy == "do y"

  test "envelopes have the documented keys, compact on one line":
    let s = renderEnvelope(successEnvelope("version", %*{"a": 1.5}))
    check s == """{"ok":true,"verb":"version","data":{"a":1.5}}"""
    let f = failureEnvelope("x", newContractError(ekBadArgs, "unknown-flag", "m"))
    check renderEnvelope(f) ==
      """{"ok":false,"verb":"x","error":{"code":2,"kind":"bad-args","message":"m","reason":"unknown-flag","remedy":null,"details":null}}"""
    check envelopeExitCode(f) == 2
    check envelopeExitCode(successEnvelope("v", newJObject())) == 0

  test "non-finite floats and 54-bit integers are not written":
    # std/json writes NaN and the infinities as strings; the contract's
    # floats go through finiteJson, which refuses them instead.
    for f in [NaN, Inf, NegInf]:
      expect ContractError: discard finiteJson(f)
      try:
        discard Display(id: "d", scale: f).toJson
        check false
      except ContractError as e:
        check e.kind == ekInternal and e.reason == "serialization"
    check finiteJson(0.5).getFloat == 0.5
    # A float node that is already non-finite, and integers beyond 53 bits,
    # are caught when the envelope is rendered.
    for bad in [%*{"x": newJFloat(NaN)}, %*{"x": [newJFloat(Inf)]},
                %*{"x": 9007199254740992'i64}, %*{"x": -9007199254740992'i64}]:
      expect ContractError:
        discard renderEnvelope(successEnvelope("v", bad))
    check renderEnvelope(successEnvelope("v", %*{"x": 9007199254740991'i64})).len > 0

suite "contract scalars":
  test "timestamps are RFC 3339 UTC with milliseconds, parsed strictly":
    check formatTimestamp(0) == "1970-01-01T00:00:00.000Z"
    check formatTimestamp(1792487702123) == "2026-10-20T09:15:02.123Z"
    check parseTimestamp("2026-10-20T09:15:02.123Z") == 1792487702123
    for bad in ["2026-10-20T09:15:02Z", "2026-10-20T09:15:02.123+00:00",
                "2026-10-20 09:15:02.123Z", "2026-13-20T09:15:02.123Z", ""]:
      expect JsonShapeError: discard parseTimestamp(bad)

  test "invalid UTF-8 is repaired with U+FFFD and flagged":
    var lossy = false
    check sanitizeUtf8("plain ✓", lossy) == "plain ✓" and not lossy
    for bad in ["\xff", "a\xc0\x80b", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82"]:
      lossy = false
      let s = sanitizeUtf8(bad, lossy)
      check lossy
      check isValidUtf8(s)
      check "\xEF\xBF\xBD" in s
    let w = Window(id: "w", app: "A\xffB", title: some("ok"), bounds: rect(0, 0, 1, 1))
    let j = w.toJson
    check j["lossy"].getBool
    check j["app"].getStr == "A\xEF\xBF\xBDB"
    check Window(id: "w", app: "ok").toJson.hasKey("lossy") == false

suite "contract objects":
  test "every object round-trips through its one serializer":
    let s = sampleSession()
    let back = Session.fromJson(s.toJson)
    check back.toJson == s.toJson
    check back.env["K"] == "V" and back.hostPid == some(42) and back.kind == skHeadless and
          back.vnc.get.port == 5901 and back.lifetime == slOwner
    check back.envUnset == @["DISPLAY", "NO_AT_BRIDGE"]
    let d = s.displays[0]
    check Display.fromJson(d.toJson) == d
    let w = Window(id: "w1", pid: 7, app: "A", appId: some("x"), title: none(string),
                   document: some("file:///d.txt"),
                   bounds: rect(1, 2, 3, 4), display: some("d1"), layer: 3,
                   onScreen: true, focused: false, minimized: true)
    check Window.fromJson(w.toJson) == w
    let a = App(pid: 7, name: "A", bundleId: some("b"), frontmost: true)
    check App.fromJson(a.toJson) == a
    check a.toJson["accessible"].kind == JNull
    for acc in [true, false]:
      let b = App(pid: 7, name: "A", accessible: some(acc))
      check App.fromJson(b.toJson) == b
    let src = ImageSource(kind: iskWindowCrop, id: some("w1"), session: some("host"))
    let img = ImageRef(path: "/x.png", format: "png", width: 10, height: 20, scale: 2.0,
                       origin: point(-5, 7), sha256: "ab", capturedAt: formatTimestamp(1),
                       source: src)
    check ImageRef.fromJson(img.toJson) == img
    let rec = Recording(id: "r", path: "/r", state: rsStopped, format: rfPngSequence,
                        width: 2, height: 2, fps: 10.0, durationMs: some(100),
                        frames: some(1), source: src, startedAt: formatTimestamp(1),
                        stoppedAt: some(formatTimestamp(2)))
    check Recording.fromJson(rec.toJson) == rec
    let word = OcrWord(text: "Hi", confidence: 90.0, bbox: [1, 2, 3, 4], lineNum: 1, blockNum: 2)
    check OcrWord.fromJson(word.toJson) == word
    let node = Node(path: "/app[1]", role: roleApplication, nativeRole: "AXApplication",
                    name: some("A"), text: some("body"), states: {stFocused, stEnabled},
                    actions: {actPress},
                    childCount: 1, children: @[Node(path: "/app[1]/button[0]",
                      role: roleButton, nativeRole: "AXButton", bounds: some(rect(1, 1, 2, 2)))])
    check $Node.fromJson(node.toJson).toJson == $node.toJson
    check node.elementToJson["children"].len == 0
    check node.elementToJson["childCount"].getInt == 1
    let rep = InputReport(kind: "type", length: some(3), delivery: dPosted, session: "s")
    check InputReport.fromJson(rep.toJson) == rep
    check rep.toJson["path"].kind == JNull
    let drag = InputReport(kind: "drag", path: some(@[point(1, 2), point(3, 4)]),
                           delivery: dInjected, session: "s")
    check InputReport.fromJson(drag.toJson) == drag
    check $drag.toJson["path"] == "[[1,2],[3,4]]"
    check not rep.toJson.hasKey("text")
    let p = Permissions(screenRecording: psGranted, accessibility: psDenied,
                        inputSynthesis: psUnknown, desktopAccess: psNotApplicable,
                        identity: some("id"))
    check Permissions.fromJson(p.toJson) == p
    let f = Feature(feature: "window-capture", backend: "b", state: fsDegraded,
                    reason: some("window-crop"))
    check Feature.fromJson(f.toJson) == f

  test "features follow the closed vocabulary and reason rules":
    # Spec §7.5 "Features": a name outside the vocabulary, a reason on a
    # supported feature, a degraded or unavailable feature without its kind
    # of reason: none is written, none is read.
    let bad = [Feature(feature: "x", backend: "b", state: fsSupported),
               Feature(feature: "ocr", backend: "b", state: fsSupported, reason: some("r")),
               Feature(feature: "ocr", backend: "b", state: fsDegraded, reason: some("busy")),
               Feature(feature: "ocr", backend: "b", state: fsDegraded),
               Feature(feature: "ocr", backend: "b", state: fsUnavailable,
                       reason: some("window-crop")),
               Feature(feature: "ocr", backend: "b", state: fsUnavailable)]
    for f in bad:
      expect ContractError: discard f.toJson
      var j = %*{"feature": f.feature, "backend": "b", "state": $f.state,
                 "reason": (if f.reason.isSome: %f.reason.get else: newJNull()),
                 "remedy": nil}
      expect JsonShapeError: discard Feature.fromJson(j)
    for f in [Feature(feature: "ocr", backend: "b", state: fsAvailable),
              Feature(feature: "recording", backend: "b", state: fsDegraded,
                      reason: some("png-sequence")),
              Feature(feature: "tree-read", backend: "b", state: fsUnavailable,
                      reason: some("tcc-accessibility")),
              Feature(feature: "video-decode", backend: "b", state: fsUnavailable,
                      reason: some("not-compiled-in"))]:
      check Feature.fromJson(f.toJson) == f
    check featuresOfModule("media") == @["video-decode"]
    check featureModule("own-pixels-capture") == "capture"
    check not isFeature("capture")

  test "withFeature names the feature of exit 4 and exit 6 only":
    let u = withFeature(newContractError(ekBackendUnavailable, "missing-tool", "m"), "ocr")
    check u.details["feature"].getStr == "ocr"
    let p = withFeature(newContractError(ekPermissionDenied, "tcc-accessibility", "m",
                                         details = %*{"backend": "x"}), "tree-read")
    check p.details["feature"].getStr == "tree-read" and p.details["backend"].getStr == "x"
    # An error that names its feature (or null) keeps it.
    let kept = withFeature(newContractError(ekBackendUnavailable, "unsupported-option",
                                            "m", details = %*{"feature": nil}), "ocr")
    check kept.details["feature"].kind == JNull
    let inner = withFeature(withFeature(newContractError(ekBackendUnavailable,
                                                         "missing-tool", "m"), "region-capture"), "ocr")
    check inner.details["feature"].getStr == "region-capture"
    # A feature-free reason is null whatever the verb's feature.
    let gone = withFeature(newContractError(ekBackendUnavailable, "session-not-running", "m"),
                           "pointer-input")
    check gone.details["feature"].kind == JNull
    # Other kinds are untouched.
    check withFeature(newContractError(ekBackendError, "busy", "m"), "ocr").details.isNil
    check withFeature(badArgs("invalid-value", "m"), "ocr").details.isNil

  test "a protected node never carries its value or text":
    let n = Node(path: "/app[1]/text-field[0]", role: roleTextField, nativeRole: "AXSecureTextField",
                 name: some("Password"), value: some("hunter2"), text: some("hunter2"),
                 states: {stProtected, stEditable})
    let j = n.toJson
    check j["value"].kind == JNull and j["text"].kind == JNull
    check "hunter2" notin $j and "hunter2" notin $n.elementToJson
    check "protected" in $j["states"]
    var forged = j.copy
    forged["value"] = %"hunter2"
    expect JsonShapeError: discard Node.fromJson(forged)
    # Control: the same node without the state reports both.
    var open = n
    open.states.excl stProtected
    check open.toJson["value"].getStr == "hunter2" and open.toJson["text"].getStr == "hunter2"

  test "element names match case-sensitively unless ignoreCase":
    let n = Node(path: "/app[1]/button[0]", role: roleButton, nativeRole: "b",
                 name: some("Submit Ärger"))
    check n.matches(ElementFilter(name: some("Submit Ärger")))
    check not n.matches(ElementFilter(name: some("submit ärger")))
    check n.matches(ElementFilter(name: some("submit ärger"), ignoreCase: true))
    check n.matches(ElementFilter(nameContains: some("mit Ä")))
    check not n.matches(ElementFilter(nameContains: some("mit ä")))
    check n.matches(ElementFilter(nameContains: some("MIT ä"), ignoreCase: true))
    check not n.matches(ElementFilter(nameContains: some("Cancel"), ignoreCase: true))

  test "absent optionals are null, never omitted; arrays are never null":
    let w = Window(id: "w", app: "A").toJson
    for k in ["appId", "title", "display"]:
      check w.hasKey(k) and w[k].kind == JNull
    let s = Session(id: "x", createdAt: formatTimestamp(0)).toJson
    check s["displays"].kind == JArray and s["vnc"].kind == JNull and
          s["hostPid"].kind == JNull and s["env"].kind == JObject

  test "parsing is strict: unknown, missing and mistyped keys are refused":
    var j = sampleSession().toJson
    j["extra"] = %1
    expect JsonShapeError: discard Session.fromJson(j)
    j = sampleSession().toJson
    j.delete("vnc")
    expect JsonShapeError: discard Session.fromJson(j)
    j = sampleSession().toJson
    j["hostPid"] = %"42"
    expect JsonShapeError: discard Session.fromJson(j)
    j = sampleSession().toJson
    j["kind"] = %"desktop"
    expect JsonShapeError: discard Session.fromJson(j)
    j = sampleSession().toJson
    j["displays"][0]["bounds"] = %[0, 0, -1, 4]
    expect JsonShapeError: discard Session.fromJson(j)
    var n = Node(path: "/app[1]", role: roleButton, nativeRole: "b").toJson
    n["states"] = %["shiny"]
    expect JsonShapeError: discard Node.fromJson(n)
    n = Node(path: "not-a-path", role: roleButton, nativeRole: "b").toJson
    expect JsonShapeError: discard Node.fromJson(n)
    var o = OcrWord(text: "x", confidence: 50.0, bbox: [0, 0, 1, 1]).toJson
    o["confidence"] = %101.0
    expect JsonShapeError: discard OcrWord.fromJson(o)

suite "sha256":
  test "FIPS 180-4 examples and block boundaries":
    check sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256Hex('a'.repeat(1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    const boundary = {55: "7cda990214cc40c5e59b2a5f09f1c34da7ea4a7d44479d36b150ea7c04aa009a",
                      56: "642b572edefc37c5664b4b95a7a83bdc5617dc06b241bfac5c8094b10fec734e",
                      63: "125d5830922e3666b5891332b54f12d328861b7ec30fec51a03fa27bbe549642",
                      64: "15c32cfa73534b3c34a1244e4331e3757b34daf267f6a7322d471c849e3a5c65",
                      65: "ddd761939cd192b02ac5b652b6f4763b0351e0c40a325432c318b0aab6c4afc5",
                      119: "a1913d07c18ff09efb38be9e5317b92e7a4cf103f6fb7448257c30c7cab59462",
                      120: "f9fe9011baded2c49c901e5d4d74f66a00f057070e9e9d641b566eeea45f3be3",
                      128: "fc49b6d718953707a8cb0ca90a5b9bd2703d166a18db96de7f288056ff6f62da"}
    for (n, want) in boundary:
      var s = ""
      for i in 0 ..< n: s.add char(97 + (i * 7) mod 26)
      check sha256Hex(s) == want

suite "keys":
  test "combinations normalize and unknown names are refused":
    check normalizeCombo("cmd+s") == "cmd+s"
    check normalizeCombo("shift+ctrl+Tab") == "ctrl+shift+Tab"
    check normalizeCombo("Return") == "Return"
    check normalizeCombo("alt+F12") == "alt+F12"
    for bad in ["", "cmd+", "+s", "ctrl+ctrl+a", "F0", "F25", "f25", "cmd+s+x",
                "PgUp", "page_up", "hyper+a", "ctrl+control+a", "cmd+meta+a",
                "Tab+a", "ctrl+\t", "ctrl+ ", "++", "a b", "\x7F", "\xC2\x85"]:
      expect KeyComboError: discard normalizeCombo(bad)
    check parseModifiers("cmd,shift") == {modShift, modCmd}
    expect KeyComboError: discard parseModifiers("cmd,cmd")
    expect KeyComboError: discard parseModifiers("cmd,meta")
    expect KeyComboError: discard parseModifiers("cmd,")

  test "names are case-insensitive and aliases normalize to the canonical spelling":
    # Every spelling of the table (spec §7.5, "The key table").
    for (spelled, canonical) in [("Enter", "Return"), ("enter", "Return"),
        ("RETURN", "Return"), ("Esc", "Escape"), ("ESCAPE", "Escape"),
        ("backspace", "BackSpace"), ("pageup", "PageUp"), ("PAGEDOWN", "PageDown"),
        ("pause", "Pause"), ("insert", "Insert"), ("f5", "F5"), ("F24", "F24"),
        ("S", "s"), ("é", "é"), ("+", "+"), ("!", "!"), ("1", "1")]:
      check normalizeCombo(spelled) == canonical
    for (spelled, canonical) in [("Control+a", "ctrl+a"), ("option+a", "alt+a"),
        ("command+a", "cmd+a"), ("meta+a", "cmd+a"), ("super+a", "cmd+a"),
        ("WIN+a", "cmd+a"), ("Ctrl+Shift+Tab", "ctrl+shift+Tab"),
        ("cmd+option+control+shift+Enter", "ctrl+alt+shift+cmd+Return"),
        ("ctrl++", "ctrl++")]:
      check normalizeCombo(spelled) == canonical
    check parseModifiers("Meta,OPTION") == {modAlt, modCmd}

suite "raster":
  test "text is drawn where its rectangle says, glyphs differ":
    var img = newImage(RgbImage, 100, 20)
    let r = img.drawText("AB", point(3, 4), (255, 255, 255), 2)
    check r == rect(3, 4, (2 * cellWidth - 1) * 2, glyphHeight * 2)
    var inside, outside = 0
    for y in 0 ..< img.height:
      for x in 0 ..< img.width:
        let lit = img.pixels[(y * img.width + x) * 3] != '\0'
        if lit:
          if r.contains(point(x, y)): inc inside else: inc outside
    check inside > 20 and outside == 0
    var a = newImage(RgbImage, 12, 14)
    var b = newImage(RgbImage, 12, 14)
    discard a.drawText("O", point(0, 0), (255, 255, 255), 2)
    discard b.drawText("Q", point(0, 0), (255, 255, 255), 2)
    check a.pixels != b.pixels
    var c = newImage(RgbImage, 12, 14)
    discard c.drawText("o", point(0, 0), (255, 255, 255), 2)
    check c.pixels == a.pixels             # lower case uses the upper-case glyph
