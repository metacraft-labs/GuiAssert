// screen_capture.swift — ScreenCaptureKit still-frame helper for GuiAssert.
//
// The macOS-only helper that `gui_assert/screen_capture.nim` shells out to.
// GuiAssert compiles it on demand with `swiftc`, through the same sanitized
// environment path `ocr.resolveAppleVisionHelper` uses (a nix profile's
// SDKROOT / DEVELOPER_DIR must be dropped for the system /usr/bin/swiftc), so
// the default GuiAssert build carries no Swift dependency at all.
//
// WHY ScreenCaptureKit and not CGWindowListCreateImage: the latter is
// *obsoleted* in macOS 15.0 — a hard compile error, not a deprecation — so
// there is no CoreGraphics still-capture route left. ScreenCaptureKit is the
// only forward-looking one.
//
// WHY the window mode exists: cropping a full-display still to a window's
// CGWindowList bounds silently captures whatever is stacked ON TOP of that
// window. `SCContentFilter(desktopIndependentWindow:)` captures the window's
// own surface, occluded or not. Window targeting is therefore a correctness
// property, not a convenience.
//
// Usage:
//
//   screen_capture enumerate [--report PATH] [--include-offscreen] [--any-layer]
//   screen_capture preflight [--report PATH]
//   screen_capture request   [--report PATH]
//   screen_capture display --out PATH [--display N] [--report PATH]
//                          [--timeout SECONDS]
//   screen_capture window  --out PATH [--report PATH] [--timeout SECONDS]
//                          (--window-id N | [--owner NAME] [--title TEXT]
//                                           [--title-contains TEXT])
//                          [--include-offscreen] [--any-layer]
//
// `enumerate` prints one TSV row per window on stdout:
//
//     windowId<TAB>ownerPid<TAB>ownerName<TAB>title<TAB>x<TAB>y<TAB>w<TAB>h<TAB>layer<TAB>onscreen
//
// Tabs and newlines inside ownerName/title are replaced with spaces so each
// record stays on one physical line. Window TITLES (kCGWindowName) are
// redacted by the OS unless the calling process holds the ScreenCapture TCC
// grant; owner names are NOT. The report therefore carries `titles_visible`
// so the Nim side can tell "no window matched your title" apart from "titles
// are invisible to me", instead of reporting the first as the second.
//
// `--report PATH` writes a `key=value` report, one pair per line. It is the
// authoritative channel: the Nim side launches this helper through
// `open -n -g -W -a <bundle>` so that launchd — not the terminal — is the
// parent and the app bundle is its own TCC-responsible process, and that
// route discards stdout. Keys: status, code, mode, out, width, height,
// window_id, window_owner, window_title, window_bounds, windows_seen,
// titles_visible, preflight, message.
//
// Exit codes (also reported as `code=`):
//   0 ok
//   2 bad usage
//   3 target window not found (and the window list WAS readable)
//   4 permission denied by TCC
//   5 capture failed for another reason
//   6 could not write the output image
//   7 the capture did not return within --timeout
//
// Every capture bounds ITSELF with a timeout and exits. ffmpeg's avfoundation
// screen input was measured to HANG rather than fail when denied (not reaped
// at 138 s under `timeout 40`); a helper that cannot hang is cheaper than a
// caller that must always remember to reap one.

import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit

// ---------------------------------------------------------------------------
// Status / reporting
// ---------------------------------------------------------------------------

enum Status: Int32 {
    case ok = 0
    case usage = 2
    case targetNotFound = 3
    case denied = 4
    case captureFailed = 5
    case writeFailed = 6
    case timedOut = 7

    var label: String {
        switch self {
        case .ok:             return "ok"
        case .usage:          return "usage"
        case .targetNotFound: return "target-not-found"
        case .denied:         return "denied"
        case .captureFailed:  return "capture-failed"
        case .writeFailed:    return "write-failed"
        case .timedOut:       return "timeout"
        }
    }
}

var report: [(String, String)] = []
var reportPath: String? = nil

func put(_ key: String, _ value: String) {
    let clean = value
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    report.append((key, clean))
}

func put(_ key: String, _ value: Int) { put(key, String(value)) }
func put(_ key: String, _ value: Bool) { put(key, value ? "1" : "0") }

func flushAndExit(_ status: Status, _ message: String? = nil) -> Never {
    var out = "status=\(status.label)\ncode=\(status.rawValue)\n"
    for (k, v) in report { out += "\(k)=\(v)\n" }
    if let m = message { out += "message=\(m.replacingOccurrences(of: "\n", with: " "))\n" }
    if let p = reportPath {
        // Write via a temp sibling + rename so a reader never sees a partial
        // report and mistake a truncated one for a complete one.
        let tmp = p + ".partial"
        if let data = out.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: tmp))
            try? FileManager.default.removeItem(atPath: p)
            try? FileManager.default.moveItem(atPath: tmp, toPath: p)
        }
    }
    FileHandle.standardError.write(out.data(using: .utf8)!)
    exit(status.rawValue)
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    flushAndExit(.usage, "usage: screen_capture <enumerate|preflight|request|display|window> [options]")
}

let mode = argv[1]
var outPath: String? = nil
var displayIndex = 0
var windowId: UInt32? = nil
var wantOwner: String? = nil
var wantTitleExact: String? = nil
var wantTitleContains: String? = nil
var timeoutSeconds: Double = 20.0
var includeOffscreen = false
var anyLayer = false

var i = 2
while i < argv.count {
    let a = argv[i]
    func next(_ what: String) -> String {
        guard i + 1 < argv.count else { flushAndExit(.usage, "\(what) needs a value") }
        i += 1
        return argv[i]
    }
    switch a {
    case "--out", "-o":            outPath = next(a)
    case "--report":               reportPath = next(a)
    case "--display":              displayIndex = Int(next(a)) ?? 0
    case "--window-id":            windowId = UInt32(next(a))
    case "--owner":                wantOwner = next(a)
    case "--title":                wantTitleExact = next(a)
    case "--title-contains":       wantTitleContains = next(a)
    case "--timeout":              timeoutSeconds = Double(next(a)) ?? 20.0
    case "--include-offscreen":    includeOffscreen = true
    case "--any-layer":            anyLayer = true
    default:
        flushAndExit(.usage, "unknown option: \(a)")
    }
    i += 1
}

put("mode", mode)

// ---------------------------------------------------------------------------
// The positive control: CGWindowListCopyWindowInfo
//
// This is UNPRIVILEGED — it answers with real owner names with no TCC grant at
// all — so it is the probe that proves the GUI session is live and enumerable
// before any ScreenCaptureKit call is attempted. A ScreenCaptureKit failure
// with a non-empty window list is a PERMISSION problem; the same failure with
// an empty list is a broken session, and the two must not be reported alike.
// ---------------------------------------------------------------------------

struct CGWindowRecord {
    var windowId: UInt32
    var ownerPid: Int
    var ownerName: String
    var title: String
    var x: Int, y: Int, w: Int, h: Int
    var layer: Int
    var onScreen: Bool
}

func sanitizeField(_ s: String) -> String {
    return s.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
}

func cgWindowList() -> [CGWindowRecord] {
    var opts: CGWindowListOption = [.excludeDesktopElements]
    if !includeOffscreen { opts.insert(.optionOnScreenOnly) }
    else { opts.insert(.optionAll) }
    guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var out: [CGWindowRecord] = []
    for d in raw {
        guard let wid = d[kCGWindowNumber as String] as? UInt32 else { continue }
        let pid = (d[kCGWindowOwnerPID as String] as? Int) ?? 0
        let owner = sanitizeField((d[kCGWindowOwnerName as String] as? String) ?? "")
        let title = sanitizeField((d[kCGWindowName as String] as? String) ?? "")
        let layer = (d[kCGWindowLayer as String] as? Int) ?? 0
        let onScreen = (d[kCGWindowIsOnscreen as String] as? Bool) ?? false
        var x = 0, y = 0, w = 0, h = 0
        if let b = d[kCGWindowBounds as String] as? [String: Any] {
            x = Int((b["X"] as? Double) ?? 0)
            y = Int((b["Y"] as? Double) ?? 0)
            w = Int((b["Width"] as? Double) ?? 0)
            h = Int((b["Height"] as? Double) ?? 0)
        }
        if !anyLayer && layer != 0 { continue }
        out.append(CGWindowRecord(windowId: wid, ownerPid: pid, ownerName: owner,
                                  title: title, x: x, y: y, w: w, h: h,
                                  layer: layer, onScreen: onScreen))
    }
    return out
}

func tsvRow(_ r: CGWindowRecord) -> String {
    return "\(r.windowId)\t\(r.ownerPid)\t\(r.ownerName)\t\(r.title)" +
           "\t\(r.x)\t\(r.y)\t\(r.w)\t\(r.h)\t\(r.layer)\t\(r.onScreen ? 1 : 0)"
}

// ---------------------------------------------------------------------------
// PNG writing
// ---------------------------------------------------------------------------

func writePng(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// ---------------------------------------------------------------------------
// ScreenCaptureKit
// ---------------------------------------------------------------------------

func classify(_ error: Error) -> Status {
    let ns = error as NSError
    // SCStreamErrorDomain -3801 == SCStreamErrorUserDeclined. The textual form
    // measured on this host is "The user declined TCCs for application, window,
    // display capture"; match on both so a renamed string does not turn a
    // denial into a generic failure.
    if ns.code == -3801 { return .denied }
    let d = "\(error)".lowercased()
    if d.contains("declined") || d.contains("not authorized") || d.contains("tcc") {
        return .denied
    }
    return .captureFailed
}

func shareableContent(timeout: Double) -> (SCShareableContent?, Status, String) {
    let sem = DispatchSemaphore(value: 0)
    var content: SCShareableContent? = nil
    var status: Status = .ok
    var message = ""
    SCShareableContent.getWithCompletionHandler { c, err in
        if let err = err {
            status = classify(err)
            message = "SCShareableContent: \(err)"
        } else {
            content = c
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        return (nil, .timedOut, "SCShareableContent did not answer within \(timeout)s")
    }
    if content == nil && status == .ok {
        status = .captureFailed
        message = "SCShareableContent returned no content and no error"
    }
    return (content, status, message)
}

func captureStill(filter: SCContentFilter, config: SCStreamConfiguration,
                  timeout: Double) -> (CGImage?, Status, String) {
    let sem = DispatchSemaphore(value: 0)
    var image: CGImage? = nil
    var status: Status = .ok
    var message = ""
    guard #available(macOS 14.0, *) else {
        return (nil, .captureFailed,
                "SCScreenshotManager requires macOS 14.0 or newer; " +
                "CGWindowListCreateImage is obsoleted in macOS 15.0 and is not a fallback")
    }
    Task {
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                              configuration: config)
        } catch {
            status = classify(error)
            message = "captureImage: \(error)"
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        return (nil, .timedOut, "SCScreenshotManager.captureImage did not answer within \(timeout)s")
    }
    if image == nil && status == .ok {
        status = .captureFailed
        message = "captureImage returned no image and no error"
    }
    return (image, status, message)
}

// ---------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------

let windows = cgWindowList()
let titlesVisible = windows.contains { !$0.title.isEmpty }
put("windows_seen", windows.count)
put("titles_visible", titlesVisible)
put("preflight", CGPreflightScreenCaptureAccess())

switch mode {

case "enumerate":
    var text = ""
    for r in windows { text += tsvRow(r) + "\n" }
    FileHandle.standardOutput.write(text.data(using: .utf8)!)
    if let p = reportPath {
        // The TSV goes to a sibling file so the report stays key=value.
        try? text.data(using: .utf8)!.write(to: URL(fileURLWithPath: p + ".tsv"))
    }
    if windows.isEmpty {
        flushAndExit(.captureFailed,
            "CGWindowListCopyWindowInfo returned no windows: this is not a TCC " +
            "denial, it means there is no live GUI session to capture")
    }
    flushAndExit(.ok)

case "preflight":
    if CGPreflightScreenCaptureAccess() {
        flushAndExit(.ok, "ScreenCapture access is already granted to this code")
    }
    flushAndExit(.denied,
        "CGPreflightScreenCaptureAccess() is false for this code: it holds no " +
        "ScreenCapture grant yet")

case "request":
    // Triggers the one-time system prompt when no decision is recorded. When a
    // DENIAL is already recorded, macOS does NOT re-prompt — it just answers
    // false — so a false here is a recorded denial, not a missing prompt.
    let granted = CGRequestScreenCaptureAccess()
    put("granted", granted)
    if granted { flushAndExit(.ok, "ScreenCapture access granted") }
    flushAndExit(.denied,
        "CGRequestScreenCaptureAccess() returned false. Either the user has not " +
        "answered the prompt yet, or a denial is already recorded for this code " +
        "and macOS will not re-prompt: clear it in System Settings > Privacy & " +
        "Security > Screen & System Audio Recording.")

case "display":
    guard let out = outPath else { flushAndExit(.usage, "display mode needs --out PATH") }
    let (content, st, msg) = shareableContent(timeout: timeoutSeconds)
    guard let content = content else { flushAndExit(st, msg) }
    let displays = content.displays
    put("displays_seen", displays.count)
    guard displayIndex >= 0 && displayIndex < displays.count else {
        flushAndExit(.targetNotFound,
            "display index \(displayIndex) out of range; ScreenCaptureKit reports " +
            "\(displays.count) display(s)")
    }
    let display = displays[displayIndex]
    put("display_id", Int(display.displayID))
    put("display_points", "\(display.width)x\(display.height)")
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
    config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
    config.captureResolution = .best
    config.showsCursor = true
    let (image, cst, cmsg) = captureStill(filter: filter, config: config,
                                          timeout: timeoutSeconds)
    guard let image = image else { flushAndExit(cst, cmsg) }
    put("width", image.width)
    put("height", image.height)
    put("scale", String(format: "%.3f", Double(filter.pointPixelScale)))
    put("out", out)
    if !writePng(image, to: out) {
        flushAndExit(.writeFailed, "could not write PNG to \(out)")
    }
    flushAndExit(.ok)

case "window":
    guard let out = outPath else { flushAndExit(.usage, "window mode needs --out PATH") }
    if windowId == nil && wantOwner == nil && wantTitleExact == nil && wantTitleContains == nil {
        flushAndExit(.usage,
            "window mode needs --window-id, or --owner / --title / --title-contains")
    }

    // Attest the target against the unprivileged window list FIRST.
    var candidates = windows
    if let wid = windowId {
        candidates = candidates.filter { $0.windowId == wid }
    }
    if let owner = wantOwner {
        candidates = candidates.filter { $0.ownerName.caseInsensitiveCompare(owner) == .orderedSame }
    }
    if let t = wantTitleExact {
        candidates = candidates.filter { $0.title == t }
    }
    if let t = wantTitleContains {
        candidates = candidates.filter { $0.title.localizedCaseInsensitiveContains(t) }
    }
    // Largest area wins; among equal areas prefer an on-screen window.
    candidates.sort { a, b in
        let aa = a.w * a.h, ba = b.w * b.h
        if aa != ba { return aa > ba }
        return (a.onScreen ? 1 : 0) > (b.onScreen ? 1 : 0)
    }
    put("candidates", candidates.count)
    guard let target = candidates.first else {
        var why = "no window in CGWindowListCopyWindowInfo matched"
        if (wantTitleExact != nil || wantTitleContains != nil) && !titlesVisible {
            why += "; NOTE no window title was readable at all (titles_visible=0), " +
                   "so a title filter cannot match: kCGWindowName is redacted " +
                   "until this code holds the ScreenCapture grant. Match on " +
                   "--owner instead, or grant first"
        }
        flushAndExit(.targetNotFound, why)
    }
    put("window_id", Int(target.windowId))
    put("window_owner", target.ownerName)
    put("window_title", target.title)
    put("window_bounds", "\(target.x),\(target.y),\(target.w),\(target.h)")
    put("window_onscreen", target.onScreen)

    let (content, st, msg) = shareableContent(timeout: timeoutSeconds)
    guard let content = content else { flushAndExit(st, msg) }
    guard let scWindow = content.windows.first(where: { $0.windowID == target.windowId }) else {
        flushAndExit(.targetNotFound,
            "window \(target.windowId) (\(target.ownerName)) is in the CoreGraphics " +
            "window list but not in SCShareableContent.windows " +
            "(\(content.windows.count) shareable window(s))")
    }
    // desktopIndependentWindow captures the window's OWN surface. A crop of a
    // display still would instead capture whatever is stacked above it.
    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let config = SCStreamConfiguration()
    config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
    config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
    config.captureResolution = .best
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    let (image, cst, cmsg) = captureStill(filter: filter, config: config,
                                          timeout: timeoutSeconds)
    guard let image = image else { flushAndExit(cst, cmsg) }
    put("width", image.width)
    put("height", image.height)
    put("scale", String(format: "%.3f", Double(filter.pointPixelScale)))
    put("out", out)
    if !writePng(image, to: out) {
        flushAndExit(.writeFailed, "could not write PNG to \(out)")
    }
    flushAndExit(.ok)

default:
    flushAndExit(.usage, "unknown mode '\(mode)'")
}
