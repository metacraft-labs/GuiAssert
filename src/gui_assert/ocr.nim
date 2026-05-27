## GuiAssert OCR Dispatcher
##
## The library spec calls for native macOS Vision / Windows.Media.Ocr /
## Linux Tesseract backends behind a unified API. The M4 milestone agreed to
## keep the FFI surface small and ship a Tesseract-based dispatcher first,
## documenting native bindings as a follow-up. This module therefore:
##
##   1. Locates a `tesseract` binary (`TESSERACT_BIN`, then `$PATH`).
##   2. Runs it on an image, requesting TSV-formatted word boxes
##      (`-c tessedit_create_tsv=1` via the `tsv` output config).
##   3. Parses the TSV into `OcrWord` records that carry bounding-box
##      coordinates in pixels.
##
## We **fail loudly** when `tesseract` is not on PATH — there are no graceful
## skips. The repository's setup notes instruct developers to install it via
## `brew install tesseract` (macOS), `nix-env -iA nixpkgs.tesseract` (Nix
## hosts), or distro packages on Linux.

import std/[os, osproc, strtabs, strutils, streams]

type
  OcrError* = object of CatchableError
    ## Raised when Tesseract is missing, exits non-zero, or its TSV output
    ## cannot be parsed.

  OcrWord* = object
    ## A single recognised word.
    text*: string
    confidence*: float
    bbox*: array[4, int]  ## [x, y, w, h] in pixels
    lineNum*: int
    blockNum*: int

proc resolveTesseractBinary*(): string =
  ## Locate the Tesseract binary. Honors `TESSERACT_BIN`, then `$PATH`.
  ## Raises `OcrError` with installation guidance when missing.
  let envBin = getEnv("TESSERACT_BIN")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(OcrError,
        "TESSERACT_BIN points at " & envBin & " but no file exists there.")
    return envBin
  let p = findExe("tesseract")
  if p.len == 0:
    raise newException(OcrError,
      "tesseract not found on PATH. Install via `brew install tesseract` " &
      "(macOS), `nix-env -iA nixpkgs.tesseract` (Nix), or the appropriate " &
      "distribution package on Linux.")
  return p

proc sanitizedEnv(path: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       path.startsWith("/nix/"):
      continue
    result[k] = v

proc parseTsv(output: string): seq[OcrWord] =
  ## Parse Tesseract's `--psm 6 tsv` output. The TSV columns are:
  ##
  ##   level page_num block_num par_num line_num word_num
  ##     left top width height conf text
  ##
  ## The header row is `level\tpage_num\t...`; data rows have `level=5` for
  ## individual words (per Tesseract's TSV docs). We keep only those.
  result = @[]
  var sawHeader = false
  for rawLine in output.splitLines:
    let line = rawLine.strip(leading = false, trailing = true)
    if line.len == 0: continue
    let cols = line.split('\t')
    if not sawHeader:
      # First non-empty line is the header.
      sawHeader = true
      if cols.len >= 1 and cols[0] == "level":
        continue
      # Some Tesseract builds skip header; fall through and try to parse.
    if cols.len < 12: continue
    var level: int
    try:
      level = parseInt(cols[0])
    except ValueError:
      continue
    if level != 5: continue   # 5 = word-level row
    let text = cols[11]
    if text.len == 0: continue
    var w: OcrWord
    w.text = text
    try:
      w.blockNum = parseInt(cols[2])
      w.lineNum = parseInt(cols[4])
      w.bbox[0] = parseInt(cols[6])
      w.bbox[1] = parseInt(cols[7])
      w.bbox[2] = parseInt(cols[8])
      w.bbox[3] = parseInt(cols[9])
      w.confidence = parseFloat(cols[10])
    except ValueError:
      continue
    result.add w

proc runOcr*(imagePath: string): seq[OcrWord] =
  ## Run Tesseract on `imagePath` and return word-level OCR records.
  ## Bounding boxes are pixels in the image's coordinate system.
  ##
  ## Raises `OcrError` on subprocess failure.
  if not fileExists(imagePath):
    raise newException(OcrError, "OCR image not found: " & imagePath)
  let tesseractBin = resolveTesseractBinary()
  let env = sanitizedEnv(tesseractBin)
  # `stdout` as output base + `tsv` config => Tesseract writes TSV to stdout.
  let p = startProcess(
    command = tesseractBin,
    args = @[
      imagePath,
      "stdout",
      "--psm", "6",
      "-c", "tessedit_create_tsv=1",
      "tsv"
    ],
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OcrError,
      "tesseract exited with code " & $code & ":\n" & output)
  result = parseTsv(output)

proc concatenatedText*(words: seq[OcrWord]): string =
  ## Join all detected words with spaces. Convenience helper for substring
  ## matching used by `waitForText`.
  var pieces: seq[string] = @[]
  for w in words:
    if w.text.len > 0:
      pieces.add(w.text)
  result = pieces.join(" ")
