// solid_window.swift — the deterministic AppKit fixture application of the
// macOS live suites (tests/live/tcapture_macos.nim, tests/live/tocr_macos.nim).
//
// It opens ONE borderless window filled with ONE solid sRGB colour at a
// requested position and size, so every pixel of that window is known in
// advance, and writes a ready file once the window is on screen:
//
//   solid_window --title TEXT --rect X,Y,W,H --rgb R,G,B --ready PATH
//                [--level normal|floating]
//                [--label TEXT [--label-at X,Y] [--label-size PT]]
//
// `--rect` is in global desktop points with a top-left origin (the space
// CGWindowListCopyWindowInfo and GuiAssert report windows in). The ready
// file carries `pid=`, `window=` (the CGWindowID, i.e. NSWindow.windowNumber)
// and `bounds=X,Y,W,H` (the frame the window has now, converted to the same
// top-left space), written via a temporary sibling + rename and rewritten
// whenever the window moves or is resized.
//
// With `--label`, the window also shows one line of black text in the system
// font at `--label-size` points (default 40), its top-left at `--label-at`
// (window points from the window's top-left, default 20,20), and the ready
// file carries `label=X,Y,W,H`: the text's typographic rectangle (its origin
// and the size AppKit lays it out at) in the same desktop space as `bounds=`.
// That is the label's on-screen rect the OCR suite maps recognized words to.
//
// The window is borderless and shadowless, so the solid colour covers the
// whole window frame; `--level floating` puts it above every normal window,
// which is how the suite places an occluder over another fixture window. The
// process is an accessory application: it shows no Dock icon and does not
// take focus. It runs until it is terminated.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var title = "GuiAssert fixture"
var rectArg: [Double] = []
var rgb: [Double] = []
var readyPath: String? = nil
var floating = false
var label: String? = nil
var labelAt: [Double] = [20, 20]
var labelSize: Double = 40

var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    let a = argv[i]
    func next() -> String {
        guard i + 1 < argv.count else { fail("\(a) needs a value") }
        i += 1
        return argv[i]
    }
    switch a {
    case "--title": title = next()
    case "--rect": rectArg = next().split(separator: ",").compactMap { Double($0) }
    case "--rgb": rgb = next().split(separator: ",").compactMap { Double($0) }
    case "--ready": readyPath = next()
    case "--label": label = next()
    case "--label-at": labelAt = next().split(separator: ",").compactMap { Double($0) }
    case "--label-size": labelSize = Double(next()) ?? -1
    case "--level":
        let v = next()
        guard v == "normal" || v == "floating" else { fail("--level is normal or floating") }
        floating = v == "floating"
    default: fail("unknown option \(a)")
    }
    i += 1
}
guard rectArg.count == 4, rectArg[2] > 0, rectArg[3] > 0 else { fail("--rect needs X,Y,W,H") }
guard rgb.count == 3, rgb.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { fail("--rgb needs R,G,B in 0..255") }
guard let ready = readyPath else { fail("--ready PATH is required") }
guard labelAt.count == 2 else { fail("--label-at needs X,Y") }
guard labelSize > 0 else { fail("--label-size needs a positive number of points") }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// AppKit frames have a bottom-left origin on the primary screen; convert.
guard let primary = NSScreen.screens.first else { fail("no screen") }
let primaryHeight = primary.frame.height
let frame = NSRect(x: rectArg[0], y: primaryHeight - rectArg[1] - rectArg[3],
                   width: rectArg[2], height: rectArg[3])

let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.title = title
window.isOpaque = true
window.hasShadow = false
window.backgroundColor = NSColor(srgbRed: CGFloat(rgb[0] / 255.0),
                                 green: CGFloat(rgb[1] / 255.0),
                                 blue: CGFloat(rgb[2] / 255.0), alpha: 1.0)
window.level = floating ? .floating : .normal

/// The label's text attributes, and the view that draws it (top-left origin).
let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: CGFloat(labelSize)),
    .foregroundColor: NSColor.black,
]
final class LabelView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let text = label else { return }
        (text as NSString).draw(at: NSPoint(x: labelAt[0], y: labelAt[1]),
                                withAttributes: labelAttributes)
    }
}
if label != nil {
    let view = LabelView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
    view.autoresizingMask = [.width, .height]
    window.contentView = view
}
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.isReleasedWhenClosed = false
window.orderFrontRegardless()

/// (Re)write the ready file with the window's current frame. A window
/// manager may move or resize the window after it opened (a tiling manager
/// does), so the file is rewritten on every move and resize, and `seq=`
/// counts the rewrites.
var seq = 0
func report() {
    let f = window.frame
    let top = primaryHeight - f.origin.y - f.height
    seq += 1
    var text = "pid=\(getpid())\nwindow=\(window.windowNumber)\nseq=\(seq)\n" +
        "bounds=\(Int(f.origin.x.rounded())),\(Int(top.rounded())),\(Int(f.width.rounded())),\(Int(f.height.rounded()))\n"
    if let l = label {
        let size = (l as NSString).size(withAttributes: labelAttributes)
        let lx = f.origin.x + CGFloat(labelAt[0])
        let ly = top + CGFloat(labelAt[1])
        text += "label=\(Int(lx.rounded())),\(Int(ly.rounded())),\(Int(size.width.rounded())),\(Int(size.height.rounded()))\n"
    }
    let tmp = ready + ".partial"
    do {
        try text.data(using: .utf8)!.write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, ready)
    } catch {
        fail("cannot write \(ready): \(error)")
    }
}

// Report once the window server has the window (after one run-loop turn),
// then after every change of its frame.
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    report()
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
        NotificationCenter.default.addObserver(forName: name, object: window,
                                               queue: .main) { _ in report() }
    }
}

app.run()
