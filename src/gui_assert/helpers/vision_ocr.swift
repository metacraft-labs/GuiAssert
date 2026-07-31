// vision_ocr.swift — Apple Vision OCR helper for GuiAssert (VU11).
//
// This is the tiny macOS-only helper that the `obAppleVision` OCR backend in
// `gui_assert/ocr.nim` shells out to. GuiAssert compiles it on demand with
// `swiftc` (see `resolveAppleVisionHelper`) so the default (Tesseract) pipeline
// carries no Swift/Vision dependency whatsoever — this file is only ever touched
// when a caller explicitly opts into the Apple Vision backend on a macOS host.
//
// Usage:   vision_ocr <image-path>
//
// It runs a `VNRecognizeTextRequest` in ACCURATE mode and prints one line per
// recognized string:
//
//     TEXT<TAB>conf<TAB>x<TAB>y<TAB>w<TAB>h
//
// where:
//   * TEXT is the recognized string with any embedded tabs/newlines replaced by
//     spaces so each record stays on a single physical line.
//   * conf is the Vision confidence in the range 0.0 .. 1.0 (the Nim side scales
//     this to Tesseract's 0..100 convention when filling `OcrWord.confidence`).
//   * x, y, w, h are INTEGER PIXEL coordinates in the image's own coordinate
//     space with a TOP-LEFT origin. Vision reports normalized (0..1) boxes with
//     a BOTTOM-LEFT origin, so we multiply by the image dimensions and flip the
//     y axis here (y = (1 - maxY) * height) — the Nim parser just reads pixels.
//
// Exit codes: 0 ok, 2 bad usage, 3 image load failure, 4 Vision request failure.

import Foundation
import Vision
import CoreGraphics
import ImageIO

func die(_ code: Int32, _ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

guard CommandLine.arguments.count >= 2 else {
    die(2, "usage: vision_ocr <image-path>")
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    die(3, "cannot load image: \(path)")
}

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
