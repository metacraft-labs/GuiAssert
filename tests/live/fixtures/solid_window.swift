// solid_window.swift — the deterministic AppKit fixture application of the
// macOS live capture suite (tests/live/tcapture_macos.nim).
//
// It opens ONE borderless window filled with ONE solid sRGB colour at a
// requested position and size, so every pixel of that window is known in
// advance, and writes a ready file once the window is on screen:
//
//   solid_window --title TEXT --rect X,Y,W,H --rgb R,G,B --ready PATH
//                [--level normal|floating]
//
// `--rect` is in global desktop points with a top-left origin (the space
// CGWindowListCopyWindowInfo and GuiAssert report windows in). The ready
// file carries `pid=`, `window=` (the CGWindowID, i.e. NSWindow.windowNumber)
// and `bounds=X,Y,W,H` (the frame the window has now, converted to the same
// top-left space), written via a temporary sibling + rename and rewritten
// whenever the window moves or is resized.
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
    let text = "pid=\(getpid())\nwindow=\(window.windowNumber)\nseq=\(seq)\n" +
        "bounds=\(Int(f.origin.x.rounded())),\(Int(top.rounded())),\(Int(f.width.rounded())),\(Int(f.height.rounded()))\n"
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
