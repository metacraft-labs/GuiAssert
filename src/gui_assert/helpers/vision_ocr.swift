// vision_ocr.swift — Apple Vision OCR helper for GuiAssert.
//
// The macOS-only helper behind two callers, both of which compile it on demand
// with `swiftc` (`gui_assert/swift_helper`), so no build of GuiAssert carries a
// Swift or Vision dependency unless a caller selects Apple Vision on macOS:
//
// * the `apple-vision` OCR backend of the `guiassert` program
//   (`gui_assert/backends/ocr/apple_vision.nim`), through the `--json` and
//   `--languages` modes below;
// * the legacy `ocr.obAppleVision` dispatcher, through the original
//   positional mode, whose output is unchanged.
//
// Modes:
//
//   vision_ocr <image-path>
//       Legacy. One line per recognized string on stdout:
//       TEXT<TAB>conf<TAB>x<TAB>y<TAB>w<TAB>h (TEXT with tabs and newlines
//       replaced by spaces, conf in 0..1, an integer pixel box with a top-left
//       origin). Accurate recognition with language correction.
//
//   vision_ocr --json --out <result.json> [--lang <code>]... <image-path>
//       Word-level recognition, written as JSON to <result.json> (never to
//       stdout or stderr, so recognized text reaches only the caller that asked
//       for it):
//         {"width": W, "height": H, "languages": ["en-US", ...],
//          "lines": [{"confidence": 0..1, "box": [x, y, w, h],
//                     "words": [{"text": str, "box": [x, y, w, h]}]}]}
//       Lines are VNRecognizedTextObservations in Vision's order; a line's
//       words are its top candidate split at Unicode whitespace, each with the
//       box Vision reports for that character range (`boundingBox(for:)`). When
//       Vision gives no box for a word's range, the line is reported as ONE
//       word holding the whole line text and the line's box, never as words
//       carrying a box that is not theirs. `languages` are the languages the
//       request ran with: the `--lang` codes, or Vision's default.
//       Recognition level is accurate; language correction is OFF, so an
//       identifier, a number or a nonce on screen is read as drawn rather than
//       "corrected" towards a dictionary word.
//
//   vision_ocr --languages [--out <file>]
//       The languages accurate recognition supports, as a JSON array of
//       strings, written to <file> or else to stdout (no image is read).
//
// Boxes: Vision reports normalized (0..1) boxes with a bottom-left origin; the
// helper converts them to integer pixels of the image with a top-left origin,
// rounding each edge (so x + w is the rounded right edge).
//
// Exit codes: 0 ok, 2 bad usage, 3 image load failure, 4 Vision request
// failure, 5 a --lang code accurate recognition does not support, 6 the result
// file cannot be written. Diagnostics on stderr name paths, codes and errors,
// never recognized text.

import Foundation
import Vision
import CoreGraphics
import ImageIO

func die(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

/// The languages accurate recognition supports in this OS's Vision.
func supportedLanguages() -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    return (try? request.supportedRecognitionLanguages()) ?? []
}

/// A normalized, bottom-left-origin Vision box as integer image pixels with a
/// top-left origin: [x, y, w, h].
func pixelBox(_ bb: CGRect, _ width: CGFloat, _ height: CGFloat) -> [Int] {
    let x0 = Int((bb.minX * width).rounded())
    let x1 = Int((bb.maxX * width).rounded())
    let y0 = Int(((1.0 - bb.maxY) * height).rounded())
    let y1 = Int(((1.0 - bb.minY) * height).rounded())
    return [x0, y0, max(0, x1 - x0), max(0, y1 - y0)]
}

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        die(3, "cannot load image: \(path)")
    }
    return cgImage
}

// --- Legacy mode ------------------------------------------------------------

func legacy(_ path: String) {
    let cgImage = loadImage(path)
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        die(4, "vision request failed: \(error)")
    }

    var out = ""
    if let results = request.results {
        for obs in results {
            guard let candidate = obs.topCandidates(1).first else { continue }
            var text = candidate.string
            text = text.replacingOccurrences(of: "\t", with: " ")
            text = text.replacingOccurrences(of: "\n", with: " ")
            if text.isEmpty { continue }

            // Normalized box, origin bottom-left -> pixel box, origin top-left.
            let bb = obs.boundingBox
            let x = bb.minX * width
            let y = (1.0 - bb.maxY) * height
            let w = bb.width * width
            let h = bb.height * height
            let conf = candidate.confidence

            out += "\(text)\t\(conf)\t\(Int(x.rounded()))\t\(Int(y.rounded()))"
            out += "\t\(Int(w.rounded()))\t\(Int(h.rounded()))\n"
        }
    }
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}

// --- Word mode ----------------------------------------------------------------

/// The ranges of the whitespace-separated words of `s`.
func wordRanges(_ s: String) -> [Range<String.Index>] {
    var result: [Range<String.Index>] = []
    var i = s.startIndex
    while i < s.endIndex {
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        if i == s.endIndex { break }
        let start = i
        while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
        result.append(start..<i)
    }
    return result
}

func words(path: String, out: String, langs: [String]) {
    if !langs.isEmpty {
        let supported = supportedLanguages()
        for l in langs where !supported.contains(l) {
            die(5, "unsupported language: \(l)")
        }
    }
    let cgImage = loadImage(path)
    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    if !langs.isEmpty { request.recognitionLanguages = langs }
    let usedLanguages = request.recognitionLanguages

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
    } catch {
        die(4, "vision request failed: \(error)")
    }

    var lines: [[String: Any]] = []
    for obs in request.results ?? [] {
        guard let candidate = obs.topCandidates(1).first else { continue }
        let s = candidate.string
        let ranges = wordRanges(s)
        if ranges.isEmpty { continue }
        let lineBox = pixelBox(obs.boundingBox, width, height)
        var ws: [[String: Any]] = []
        var complete = true
        for r in ranges {
            guard let box = try? candidate.boundingBox(for: r) else {
                complete = false
                break
            }
            ws.append(["text": String(s[r]), "box": pixelBox(box.boundingBox, width, height)])
        }
        if !complete {
            let whole = ranges.map { String(s[$0]) }.joined(separator: " ")
            ws = [["text": whole, "box": lineBox]]
        }
        lines.append(["confidence": Double(candidate.confidence), "box": lineBox,
                      "words": ws])
    }
    let doc: [String: Any] = ["width": cgImage.width, "height": cgImage.height,
                              "languages": usedLanguages, "lines": lines]
    do {
        let data = try JSONSerialization.data(withJSONObject: doc, options: [])
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    } catch {
        die(6, "cannot write \(out): \(error.localizedDescription)")
    }
}

// --- Arguments ----------------------------------------------------------------

let argv = CommandLine.arguments
if argv.count == 2 && !argv[1].hasPrefix("--") {
    legacy(argv[1])
    exit(0)
}
if argv.count >= 2 && argv[1] == "--languages" {
    guard argv.count == 2 || (argv.count == 4 && argv[2] == "--out") else {
        die(2, "usage: vision_ocr --languages [--out <file>]")
    }
    let langs = supportedLanguages()
    guard let data = try? JSONSerialization.data(withJSONObject: langs, options: []) else {
        die(4, "cannot serialize the supported languages")
    }
    if argv.count == 4 {
        do {
            try data.write(to: URL(fileURLWithPath: argv[3]), options: .atomic)
        } catch {
            die(6, "cannot write \(argv[3]): \(error.localizedDescription)")
        }
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
    exit(0)
}
var json = false
var outPath: String? = nil
var langs: [String] = []
var image: String? = nil
var i = 1
while i < argv.count {
    let a = argv[i]
    func next() -> String {
        guard i + 1 < argv.count else { die(2, "\(a) needs a value") }
        i += 1
        return argv[i]
    }
    switch a {
    case "--json": json = true
    case "--out": outPath = next()
    case "--lang": langs.append(next())
    default:
        if a.hasPrefix("--") || image != nil { die(2, "unexpected argument \(a)") }
        image = a
    }
    i += 1
}
guard json, let out = outPath, let img = image else {
    die(2, "usage: vision_ocr <image> | vision_ocr --json --out <file> [--lang <code>]... <image> | vision_ocr --languages [--out <file>]")
}
words(path: img, out: out, langs: langs)
