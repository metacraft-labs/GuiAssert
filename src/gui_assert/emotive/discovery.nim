## Shared types for plugin avatar discovery + dry-run validation.
##
## Each commercial plugin should expose:
##
##   proc listAvatars*(apiKey, apiBase: string): seq[AvatarInfo]
##   proc dryRunValidate*(opts): DryRunReport
##
## …so consumers (and the codetracer-marketing runner) can pick the
## best-matching avatar and surface obvious problems (missing key,
## unknown avatar, insufficient quota, invalid voice ID) before
## kicking off a multi-minute render.

import std/strutils
import ./core

type
  DryRunSeverity* = enum
    drInfo = "info"
    drWarning = "warning"
    drError = "error"

  DryRunIssue* = object
    ## One finding from a dry-run check.  `severity = drError` means
    ## the request would be rejected by the backend; consumers should
    ## abort or surface the issue before kicking off a live render.
    severity*: DryRunSeverity
    field*: string         ## dotted path to the offending key, e.g. "voice_id"
    message*: string       ## one-line human-readable description

  DryRunReport* = object
    ## Aggregated dry-run output.  `ok` is true iff there are zero
    ## `drError` issues; warnings and info entries don't flip the flag.
    provider*: string
    ok*: bool
    issues*: seq[DryRunIssue]
    quotaRemaining*: string  ## e.g. "12 credits" or "" if unknown

  ProviderCapabilities* = object
    ## Self-description used to route a `CommonEmotiveConfig` onto a
    ## subset the backend actually supports.  Populated by each plugin
    ## as a const; consumers can branch on it for fan-out.
    supportsEmotion*: bool
    supportsHeadMotion*: bool
    supportsExpressionScale*: bool
    supportsGreenScreen*: bool
    supportsTransparentBg*: bool
    supportsAudioInput*: bool      ## false for HeyGen / Synthesia / Tavus
    supportsTextInput*: bool       ## true for HeyGen / Synthesia / Tavus
    supportsVoiceTuning*: bool     ## stability / similarity_boost / style
    supportsGestures*: bool
    supportsEyeContact*: bool
    supportedEmotions*: seq[string]  ## empty == "any of the Emotion enum"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc newDryRunReport*(provider: string): DryRunReport =
  DryRunReport(provider: provider, ok: true, issues: @[], quotaRemaining: "")

proc addIssue*(r: var DryRunReport, severity: DryRunSeverity,
               field, message: string) =
  ## Append an issue to the report and flip `ok` to false when the
  ## severity is `drError`.
  r.issues.add DryRunIssue(severity: severity, field: field,
                           message: message)
  if severity == drError:
    r.ok = false

proc errCount*(r: DryRunReport): int =
  for it in r.issues:
    if it.severity == drError: inc result

proc warnCount*(r: DryRunReport): int =
  for it in r.issues:
    if it.severity == drWarning: inc result

proc summary*(r: DryRunReport): string =
  ## One-line summary suitable for logging.
  let errs = r.errCount
  let warns = r.warnCount
  let qr = if r.quotaRemaining.len > 0:
             " quota=" & r.quotaRemaining
           else: ""
  result = "[" & r.provider & "] ok=" & $r.ok &
           " errors=" & $errs & " warnings=" & $warns & qr

# ---------------------------------------------------------------------------
# Capability-aware emotion mapping
# ---------------------------------------------------------------------------

proc mapEmotion*(c: ProviderCapabilities, e: Emotion): string =
  ## Project an internal Emotion onto a string this provider supports.
  ## When `supportedEmotions` is empty the provider is assumed to
  ## accept the verbatim string form; otherwise unknown values fall
  ## back to "neutral".
  let s = $e
  if c.supportedEmotions.len == 0: return s
  let lc = s.toLowerAscii
  for opt in c.supportedEmotions:
    if opt.toLowerAscii == lc:
      return opt
  for opt in c.supportedEmotions:
    if opt.toLowerAscii == "neutral":
      return opt
  result = c.supportedEmotions[0]
