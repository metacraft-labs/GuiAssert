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
//   screen_capture record  --out PATH.mp4 --status PATH [--fps F]
//                          [--display-id N | --window-id N | --region X,Y,W,H]
//                          [--timeout SECONDS]
//
// Options added for the `macos-sck` capture backend (all optional, so the
// older callers in `screen_capture.nim` are unaffected):
//
//   --display-id N    select the display by CGDirectDisplayID instead of
//                     by index (`display` and `record`)
//   --region X,Y,W,H  capture this rectangle of the desktop, in global
//                     points (`display` and `record`); it must lie within
//                     one display
//   --no-cursor       leave the pointer out of a display or region capture
//   --srgb            deliver pixels in sRGB rather than the display's own
//                     colour space, so a known colour reads back as itself
//
// `record` runs until it receives SIGTERM or SIGINT, then finalizes the MP4
// (its `moov` index) and exits. Its `--status` file is rewritten atomically
// as the recording progresses (`state=starting|recording|stopped|failed|
// denied`, `pid`, `width`, `height`, `scale`, `frames`, `message`); it is
// the channel the Nim side reads, because a detached `open` returns before
// the recording has even started. Frames are written at a constant rate:
// every 1/fps the newest complete ScreenCaptureKit frame is appended, so a
// still screen still yields fps frames per second.
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
import AVFoundation
import CoreMedia
import CoreVideo

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

/// Set by `record` mode: a failure exit also rewrites the `--status` file,
/// the only channel a detached recorder has.
var recordStatusOnExit = false

func flushAndExit(_ status: Status, _ message: String? = nil) -> Never {
    if recordStatusOnExit && status != .ok {
        writeStatus([("state", status == .denied ? "denied" : "failed"),
                     ("code", String(status.rawValue)), ("pid", String(getpid())),
                     ("message", message ?? status.label)])
    }
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
    flushAndExit(.usage, "usage: screen_capture <enumerate|preflight|request|display|window|record> [options]")
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
var displayId: UInt32? = nil
var region: CGRect? = nil
var showCursor = true
var useSrgb = false
var statusPath: String? = nil
var fps: Double = 10.0

/// "x,y,w,h" in points; nil unless four numbers with a positive size.
func parseRegion(_ s: String) -> CGRect? {
    let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2],
          let h = parts[3], w > 0, h > 0 else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

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
    case "--display-id":
        let v = next(a)
        guard let n = UInt32(v) else { flushAndExit(.usage, "--display-id needs a number, not \(v)") }
        displayId = n
    case "--region":
        let v = next(a)
        guard let r = parseRegion(v) else { flushAndExit(.usage, "--region needs x,y,w,h, not \(v)") }
        region = r
    case "--no-cursor":            showCursor = false
    case "--srgb":                 useSrgb = true
    case "--status":               statusPath = next(a)
    case "--fps":
        let v = next(a)
        guard let f = Double(v), f > 0, f <= 240 else { flushAndExit(.usage, "--fps needs a rate in (0, 240], not \(v)") }
        fps = f
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
// Target selection and the grant gate
// ---------------------------------------------------------------------------

/// Refuse up front, without touching ScreenCaptureKit, when this code holds
/// no Screen Recording grant. CGPreflightScreenCaptureAccess never prompts,
/// so a denied identity gets a denial report instead of a system dialog; and
/// a fresh process (every invocation of this helper is one) reads the
/// current grant, not a cached answer.
func requireGrant() {
    if !CGPreflightScreenCaptureAccess() {
        flushAndExit(.denied,
            "CGPreflightScreenCaptureAccess() is false for this code: it holds " +
            "no Screen Recording grant")
    }
}

/// The display to capture and, for `--region`, the rectangle within it in
/// display-local points. Exits `target-not-found` for an unknown display id
/// and `usage` for a region that does not lie within one display.
func selectDisplay(_ content: SCShareableContent) -> (SCDisplay, CGRect?) {
    let displays = content.displays
    if let r = region {
        // SCDisplay.frame is in global desktop points, the space --region
        // is given in.
        guard let d = displays.first(where: { $0.frame.contains(r) }) else {
            flushAndExit(.usage, "the region \(r) does not lie within one display")
        }
        let local = CGRect(x: r.origin.x - d.frame.origin.x,
                           y: r.origin.y - d.frame.origin.y,
                           width: r.width, height: r.height)
        return (d, local)
    }
    if let id = displayId {
        guard let d = displays.first(where: { $0.displayID == id }) else {
            flushAndExit(.targetNotFound,
                "no display \(id) among the \(displays.count) ScreenCaptureKit reports")
        }
        return (d, nil)
    }
    guard displayIndex >= 0 && displayIndex < displays.count else {
        flushAndExit(.targetNotFound,
            "display index \(displayIndex) out of range; ScreenCaptureKit reports " +
            "\(displays.count) display(s)")
    }
    return (displays[displayIndex], nil)
}

// ---------------------------------------------------------------------------
// Recording (SCStream -> AVAssetWriter)
// ---------------------------------------------------------------------------

/// Rewrite the `--status` file atomically (temp sibling + rename), so the
/// Nim side never reads a half-written status.
func writeStatus(_ pairs: [(String, String)]) {
    guard let p = statusPath else { return }
    var text = ""
    for (k, v) in pairs {
        text += "\(k)=\(v.replacingOccurrences(of: "\n", with: " "))\n"
    }
    let tmp = p + ".partial"
    guard let data = text.data(using: .utf8) else { return }
    do {
        try data.write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, p)
    } catch {
        // Nothing to report through: the status file IS the channel. The
        // Nim side treats a missing status as a recorder that did not start.
    }
}

/// Exit with a terminal recording status (`flushAndExit` writes it to the
/// status file in record mode). The MP4 left behind, if any, is not
/// finalized; the Nim side measures it and reports the recording as failed.
func recordExit(_ status: Status, _ message: String) -> Never {
    flushAndExit(status == .ok ? .captureFailed : status, message)
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "guiassert.capture.record")
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let rate: Double
    let width: Int, height: Int
    let scale: Double
    var stream: SCStream? = nil
    var timer: DispatchSourceTimer? = nil
    var latest: CVPixelBuffer? = nil   // newest complete frame (on `queue`)
    var frames = 0                     // frames appended to the writer
    var stopping = false

    init(writer: AVAssetWriter, input: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, rate: Double,
         width: Int, height: Int, scale: Double) {
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.rate = rate
        self.width = width
        self.height = height
        self.scale = scale
    }

    func status(_ state: String, _ extra: [(String, String)] = []) {
        writeStatus([("state", state), ("pid", String(getpid())),
                     ("width", String(width)), ("height", String(height)),
                     ("scale", String(format: "%.3f", scale)),
                     ("fps", String(rate)), ("frames", String(frames))] + extra)
    }

    // SCStreamOutput: keep only the newest COMPLETE frame. Idle and blank
    // frames carry no new pixels; the constant-rate timer repeats the last
    // complete one instead.
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let frameStatus = SCFrameStatus(rawValue: raw),
              frameStatus == .complete else { return }
        latest = pb
    }

    // SCStreamDelegate: the stream died under us (display unplugged, window
    // closed, grant revoked). Finalize what was written.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.finish(reason: "the stream stopped: \(error)") }
    }

    func tick() {
        guard !stopping else { return }
        // A writer that failed (disk full, encoder error) takes no more
        // frames and cannot be finalized: end the recording as failed now
        // rather than keep ticking until a stop request.
        if writer.status == .failed {
            finish(reason: "AVAssetWriter failed: \(String(describing: writer.error))")
            return
        }
        guard let pb = latest, input.isReadyForMoreMediaData else { return }
        let pts = CMTime(seconds: Double(frames) / rate, preferredTimescale: 600_000)
        if adaptor.append(pb, withPresentationTime: pts) {
            frames += 1
            if frames % max(1, Int(rate.rounded())) == 0 { status("recording") }
        }
    }

    func start(filter: SCContentFilter, config: SCStreamConfiguration) {
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            recordExit(classify(error), "addStreamOutput: \(error)")
        }
        stream = s
        s.startCapture { err in
            if let err = err {
                recordExit(classify(err), "startCapture: \(err)")
            }
            self.queue.async {
                guard self.writer.startWriting() else {
                    recordExit(.captureFailed,
                        "AVAssetWriter.startWriting: \(String(describing: self.writer.error))")
                }
                self.writer.startSession(atSourceTime: .zero)
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: 1.0 / self.rate, leeway: .milliseconds(1))
                t.setEventHandler { self.tick() }
                t.resume()
                self.timer = t
                self.status("recording")
            }
        }
    }

    /// Stop the stream and finalize the MP4: on `queue`. `reason` is set
    /// when the recording ended by itself rather than by a stop request.
    func finish(reason: String? = nil) {
        if stopping { return }
        stopping = true
        timer?.cancel()
        let done = {
            self.queue.async {
                // markAsFinished / finishWriting / cancelWriting raise an
                // Objective-C exception unless the writer is writing, so a
                // writer that never started or already failed is only
                // reported, never finalized.
                if self.writer.status != .writing {
                    recordExit(.captureFailed, reason ??
                        "the writer is not writing (status \(self.writer.status.rawValue)): " +
                        "\(String(describing: self.writer.error))")
                }
                if self.frames == 0 {
                    self.writer.cancelWriting()
                    recordExit(.captureFailed, reason ??
                        "the recording stopped before ScreenCaptureKit delivered a frame")
                }
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: CMTime(
                    seconds: Double(self.frames) / self.rate, preferredTimescale: 600_000))
                self.writer.finishWriting {
                    if self.writer.status == .completed && reason == nil {
                        self.status("stopped")
                        flushAndExit(.ok)
                    }
                    recordExit(.captureFailed, reason ??
                        "AVAssetWriter could not finalize: \(String(describing: self.writer.error))")
                }
            }
        }
        if let s = stream { s.stopCapture { _ in done() } } else { done() }
    }
}

var activeRecorder: Recorder? = nil
var signalSources: [DispatchSourceSignal] = []

func runRecorder(out: String) -> Never {
    recordStatusOnExit = true
    writeStatus([("state", "starting"), ("pid", String(getpid()))])
    requireGrant()
    let (content, st, msg) = shareableContent(timeout: timeoutSeconds)
    guard let content = content else { recordExit(st, msg) }
    var filter: SCContentFilter
    var sourceRect: CGRect? = nil
    var showsCursor = showCursor
    if let wid = windowId {
        guard let w = content.windows.first(where: { $0.windowID == wid }) else {
            recordExit(.targetNotFound, "window \(wid) is not among the " +
                "\(content.windows.count) shareable windows")
        }
        filter = SCContentFilter(desktopIndependentWindow: w)
        showsCursor = false
    } else {
        let (d, r) = selectDisplay(content)
        filter = SCContentFilter(display: d, excludingWindows: [])
        sourceRect = r
    }
    let scale = Double(filter.pointPixelScale)
    let pointSize = sourceRect?.size ?? filter.contentRect.size
    // H.264 and HEVC encode even dimensions only.
    let width = max(2, Int((Double(pointSize.width) * scale).rounded()) / 2 * 2)
    let height = max(2, Int((Double(pointSize.height) * scale).rounded()) / 2 * 2)
    let config = SCStreamConfiguration()
    if let r = sourceRect { config.sourceRect = r }
    config.width = width
    config.height = height
    config.captureResolution = .best
    config.showsCursor = showsCursor
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(seconds: 1.0 / fps, preferredTimescale: 600_000)
    config.queueDepth = 6
    if useSrgb { config.colorSpaceName = CGColorSpace.sRGB }
    if windowId != nil { config.ignoreShadowsSingleWindow = true }

    try? FileManager.default.removeItem(atPath: out)
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: out), fileType: .mp4)
    } catch {
        recordExit(.writeFailed, "AVAssetWriter(\(out)): \(error)")
    }
    // H.264 tops out at 4096 pixels a side; larger captures use HEVC.
    let codec: AVVideoCodecType = (width > 4096 || height > 4096) ? .hevc : .h264
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
        recordExit(.captureFailed, "AVAssetWriter cannot take a \(width)x\(height) video input")
    }
    writer.add(input)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height])
    let rec = Recorder(writer: writer, input: input, adaptor: adaptor, rate: fps,
                       width: width, height: height, scale: scale)
    activeRecorder = rec
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { rec.queue.async { rec.finish() } }
        src.resume()
        signalSources.append(src)
    }
    rec.start(filter: filter, config: config)
    dispatchMain()
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
    requireGrant()
    let (content, st, msg) = shareableContent(timeout: timeoutSeconds)
    guard let content = content else { flushAndExit(st, msg) }
    put("displays_seen", content.displays.count)
    let (display, sourceRect) = selectDisplay(content)
    put("display_id", Int(display.displayID))
    put("display_points", "\(display.width)x\(display.height)")
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let scale = Double(filter.pointPixelScale)
    let config = SCStreamConfiguration()
    if let r = sourceRect {
        config.sourceRect = r
        config.width = Int((Double(r.width) * scale).rounded())
        config.height = Int((Double(r.height) * scale).rounded())
    } else {
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
    }
    config.captureResolution = .best
    config.showsCursor = showCursor
    if useSrgb { config.colorSpaceName = CGColorSpace.sRGB }
    let (image, cst, cmsg) = captureStill(filter: filter, config: config,
                                          timeout: timeoutSeconds)
    guard let image = image else { flushAndExit(cst, cmsg) }
    put("width", image.width)
    put("height", image.height)
    put("scale", String(format: "%.3f", scale))
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

    requireGrant()
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
    if useSrgb { config.colorSpaceName = CGColorSpace.sRGB }
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

case "record":
    guard let out = outPath else { flushAndExit(.usage, "record mode needs --out PATH") }
    guard statusPath != nil else { flushAndExit(.usage, "record mode needs --status PATH") }
    runRecorder(out: out)

default:
    flushAndExit(.usage, "unknown mode '\(mode)'")
}
