## Finding ffmpeg and naming files to it: what every GuiAssert module that
## runs ffmpeg or ffprobe shares (capture, OCR preprocessing, video analysis,
## the media backend, and video composition).

import std/os

type
  MediaCompositionError* = object of CatchableError
    ## Raised when ffmpeg cannot be invoked, exits non-zero, or fails to
    ## produce the requested output file.

proc resolveFfmpegBinary*(): string =
  ## Locate an `ffmpeg` binary on disk. Honors the `FFMPEG_BIN` environment
  ## variable (must point at an executable), otherwise falls back to the
  ## first `ffmpeg` on `PATH`. Raises `MediaCompositionError` if no binary
  ## is found.
  let envBin = getEnv("FFMPEG_BIN")
  if envBin.len > 0:
    if not fileExists(envBin):
      raise newException(
        MediaCompositionError,
        "FFMPEG_BIN points at " & envBin & " but no file exists there."
      )
    return envBin
  let p = findExe("ffmpeg")
  if p.len == 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg not found on PATH and FFMPEG_BIN is unset."
    )
  return p

func ffmpegInputUrl*(path: string): string =
  ## The argument to give ffmpeg or ffprobe for the input FILE at `path`:
  ## the path behind the `file:` protocol
  ## (https://ffmpeg.org/ffmpeg-protocols.html#file). Given raw, a name that
  ## starts with `-` is read as an option (ffprobe's input is positional),
  ## and a name such as `pipe:0`, `concat:a|b` or `http://…` selects another
  ## protocol; behind `file:` each is read as the file it names, relative to
  ## the current directory when `path` is relative (ffmpeg strips exactly one
  ## `file:` and opens the rest as a path). Every ffmpeg / ffprobe invocation
  ## in GuiAssert that reads a caller's file passes it through here.
  ##
  ## Deliberately not made absolute: that would read the current directory,
  ## an effect (and an `OSError`) the pure argv builders of `video_analysis`
  ## and `vision_windows` must not acquire (their signatures are part of the
  ## frozen legacy API, `tests/tcore_shims.nim`).
  "file:" & path
