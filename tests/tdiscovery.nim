## Pure tests for the dry-run / capability discovery shared types.

import std/[strutils, unittest]
import gui_assert/emotive

suite "DryRunReport":

  test "fresh report is ok with no issues":
    let r = newDryRunReport("did")
    check r.ok
    check r.issues.len == 0
    check r.provider == "did"

  test "addIssue with drError flips ok to false":
    var r = newDryRunReport("did")
    r.addIssue(drError, "api_key", "DID_API_KEY is not set")
    check not r.ok
    check r.errCount == 1
    check r.issues[0].field == "api_key"

  test "warnings and info entries leave ok=true":
    var r = newDryRunReport("did")
    r.addIssue(drWarning, "voice", "low-confidence match")
    r.addIssue(drInfo, "quota", "12 credits remaining")
    check r.ok
    check r.warnCount == 1
    check r.errCount == 0

  test "summary mentions the provider + counts":
    var r = newDryRunReport("heygen")
    r.addIssue(drError, "voice_id", "unknown")
    r.addIssue(drWarning, "avatar_id", "fallback used")
    r.quotaRemaining = "100 credits"
    let s = r.summary
    check "[heygen]" in s
    check "ok=false" in s
    check "errors=1" in s
    check "warnings=1" in s
    check "quota=100 credits" in s

suite "ProviderCapabilities.mapEmotion":

  test "empty supportedEmotions yields the verbatim Emotion string":
    let caps = ProviderCapabilities(supportedEmotions: @[])
    check mapEmotion(caps, eHappy) == "happy"
    check mapEmotion(caps, eThoughtful) == "thoughtful"

  test "matches case-insensitive against the supported list":
    let caps = ProviderCapabilities(
      supportedEmotions: @["Neutral", "Happy", "Serious"])
    check mapEmotion(caps, eHappy) == "Happy"
    check mapEmotion(caps, eSerious) == "Serious"

  test "falls back to Neutral when the requested emotion is unsupported":
    let caps = ProviderCapabilities(
      supportedEmotions: @["Neutral", "Happy"])
    check mapEmotion(caps, eAngry) == "Neutral"

  test "falls back to first option when there is no Neutral":
    let caps = ProviderCapabilities(
      supportedEmotions: @["Energetic", "Calm"])
    check mapEmotion(caps, eAngry) == "Energetic"
