## Pure tests for the common emotive + avatar preference contract.

import std/[json, options, strutils, tables, unittest]
import gui_assert/emotive

# ---------------------------------------------------------------------------
# Enum parsing
# ---------------------------------------------------------------------------

suite "emotive enum parsing":

  test "parseEmotion handles canonical + alias + empty input":
    check parseEmotion("happy") == eHappy
    check parseEmotion("Joyful") == eHappy
    check parseEmotion("CHEERFUL") == eHappy
    check parseEmotion("") == eNeutral
    check parseEmotion("nope") == eNeutral
    check parseEmotion("serious") == eSerious
    check parseEmotion("pensive") == eThoughtful

  test "parseGesture maps high/medium/low synonyms":
    check parseGesture("none") == glNone
    check parseGesture("minimal") == glSubtle
    check parseGesture("default") == glNatural
    check parseGesture("expressive") == glExpressive
    check parseGesture("garbage") == glNatural

  test "parseBackground maps documented synonyms":
    check parseBackground("green_screen") == bmGreenScreen
    check parseBackground("greenscreen") == bmGreenScreen
    check parseBackground("chroma") == bmGreenScreen
    check parseBackground("transparent") == bmTransparent
    check parseBackground("alpha") == bmTransparent
    check parseBackground("solid") == bmSolidColor
    check parseBackground("trained") == bmTrained
    check parseBackground("") == bmAsIs

  test "parseGender groups documented aliases":
    check parseGender("female") == gFemale
    check parseGender("Woman") == gFemale
    check parseGender("male") == gMale
    check parseGender("non-binary") == gNonBinary
    check parseGender("") == gUnspecified

# ---------------------------------------------------------------------------
# Range clamping
# ---------------------------------------------------------------------------

suite "emotive range helpers":

  test "clampUnit clamps to [0, 1]":
    check clampUnit(-0.5) == 0.0
    check clampUnit(0.0) == 0.0
    check clampUnit(0.5) == 0.5
    check clampUnit(1.0) == 1.0
    check clampUnit(2.0) == 1.0

  test "clampSemitones clamps to [-10, 10]":
    check clampSemitones(-12.0) == -10.0
    check clampSemitones(0.0) == 0.0
    check clampSemitones(10.0) == 10.0
    check clampSemitones(15.0) == 10.0

  test "clampSpeed clamps to [0.5, 2.0]":
    check clampSpeed(0.1) == 0.5
    check clampSpeed(1.0) == 1.0
    check clampSpeed(3.0) == 2.0

# ---------------------------------------------------------------------------
# JSON round-trip
# ---------------------------------------------------------------------------

suite "emotive JSON parse + serialise":

  test "decode + re-encode preserves canonical keys":
    let src = %*{
      "emotion": "happy",
      "intensity": 0.7,
      "voice_speed": 1.1,
      "voice_pitch": -2.0,
      "voice_stability": 0.5,
      "voice_similarity_boost": 0.85,
      "voice_style": 0.3,
      "use_speaker_boost": true,
      "gestures": "natural",
      "eye_contact": true,
      "head_motion": 0.4,
      "expression_scale": 1.2,
      "background": "green_screen",
      "background_color": "#00ff00",
    }
    let cfg = emotiveFromJson(src)
    check cfg.emotion == some(eHappy)
    check cfg.intensity == some(0.7)
    check cfg.voiceSpeed == some(1.1)
    check cfg.voicePitch == some(-2.0)
    check cfg.voiceStability == some(0.5)
    check cfg.voiceSimilarityBoost == some(0.85)
    check cfg.voiceStyle == some(0.3)
    check cfg.useSpeakerBoost == some(true)
    check cfg.gestures == some(glNatural)
    check cfg.eyeContact == some(true)
    check cfg.headMotion == some(0.4)
    check cfg.expressionScale == some(1.2)
    check cfg.background == some(bmGreenScreen)
    check cfg.backgroundColor == some("#00ff00")
    let encoded = cfg.toJson
    check encoded["emotion"].getStr == "happy"
    check encoded["background"].getStr == "green_screen"
    check encoded["gestures"].getStr == "natural"

  test "decode tolerates aliased keys":
    let src = %*{
      "voicespeed": 1.5,
      "voicepitch": 3.0,
      "stability": 0.2,
      "similarity_boost": 0.9,
      "style": 0.4,
      "headmotion": 0.7,
      "expressionscale": 0.5,
    }
    let cfg = emotiveFromJson(src)
    check cfg.voiceSpeed == some(1.5)
    check cfg.voicePitch == some(3.0)
    check cfg.voiceStability == some(0.2)
    check cfg.voiceSimilarityBoost == some(0.9)
    check cfg.voiceStyle == some(0.4)
    check cfg.headMotion == some(0.7)
    check cfg.expressionScale == some(0.5)

  test "decode drops out-of-range floats via clamp":
    let src = %*{"intensity": 1.4, "voice_pitch": -42.0, "voice_speed": 0.1}
    let cfg = emotiveFromJson(src)
    check cfg.intensity == some(1.0)
    check cfg.voicePitch == some(-10.0)
    check cfg.voiceSpeed == some(0.5)

  test "unknown keys land in extras":
    let src = %*{"emotion": "calm", "vendor_x_field": "abc"}
    let cfg = emotiveFromJson(src)
    check cfg.emotion == some(eCalm)
    check "vendor_x_field" in cfg.extras
    check cfg.extras["vendor_x_field"] == "abc"

  test "nil/non-object inputs yield an empty config":
    let cfg1 = emotiveFromJson(nil)
    check cfg1.emotion.isNone
    let cfg2 = emotiveFromJson(%[1, 2, 3])
    check cfg2.intensity.isNone

# ---------------------------------------------------------------------------
# Overlay (per-keyframe override on top of script defaults)
# ---------------------------------------------------------------------------

suite "emotive overlay":

  test "override wins on fields it sets, base wins elsewhere":
    var base = initEmotive()
    base.emotion = some(eNeutral)
    base.intensity = some(0.5)
    base.voiceSpeed = some(1.0)
    base.extras["vendor_x"] = "base"
    var ovr = initEmotive()
    ovr.emotion = some(eExcited)
    ovr.voicePitch = some(2.0)
    ovr.extras["vendor_y"] = "ovr"
    let merged = overlay(base, ovr)
    check merged.emotion == some(eExcited)
    check merged.intensity == some(0.5)
    check merged.voiceSpeed == some(1.0)
    check merged.voicePitch == some(2.0)
    check merged.extras["vendor_x"] == "base"
    check merged.extras["vendor_y"] == "ovr"

  test "empty overlay returns base":
    var base = initEmotive()
    base.emotion = some(eHappy)
    base.intensity = some(0.8)
    let merged = overlay(base, initEmotive())
    check merged.emotion == some(eHappy)
    check merged.intensity == some(0.8)

# ---------------------------------------------------------------------------
# Avatar preferences
# ---------------------------------------------------------------------------

suite "avatar preferences parse":

  test "list form populates `preferred` in order":
    let raw = %*[
      {"name": "Sarah", "gender": "female", "tags": ["warm", "studio"]},
      {"name": "Daniel", "gender": "male"},
    ]
    let prefs = avatarPrefsFromJson(raw)
    check prefs.preferred.len == 2
    check prefs.preferred[0].name == "Sarah"
    check prefs.preferred[0].gender == gFemale
    check prefs.preferred[0].tags == @["warm", "studio"]
    check prefs.preferred[1].gender == gMale

  test "object form with explicit per-provider overrides":
    let raw = %*{
      "preferred": [
        {
          "name": "Anna",
          "role": "presenter",
          "gender": "female",
          "style": "studio",
          "per_provider": {
            "heygen": "Daisy-inskirt-20220818",
            "synthesia": "anna_costume1_cameraA",
          }
        }
      ],
      "fallback": "default",
    }
    let prefs = avatarPrefsFromJson(raw)
    check prefs.preferred.len == 1
    check prefs.preferred[0].name == "Anna"
    check prefs.preferred[0].role == "presenter"
    check prefs.preferred[0].perProvider["heygen"] ==
      "Daisy-inskirt-20220818"
    check prefs.preferred[0].perProvider["synthesia"] ==
      "anna_costume1_cameraA"
    check prefs.fallback == "default"

# ---------------------------------------------------------------------------
# Avatar matching
# ---------------------------------------------------------------------------

proc mkAvatar(id, name, descr: string; gender: Gender = gUnspecified;
              tags: seq[string] = @[]): AvatarInfo =
  AvatarInfo(id: id, name: name, description: descr, gender: gender,
             tags: tags)

suite "avatar matching":

  let available = @[
    mkAvatar("av_1", "Sarah", "Warm studio presenter", gFemale,
             @["studio", "warm"]),
    mkAvatar("av_2", "Daniel", "Casual male host", gMale, @["casual"]),
    mkAvatar("av_3", "Anna", "Formal studio woman", gFemale,
             @["studio", "formal"]),
  ]

  test "explicit perProvider override short-circuits":
    var entry = AvatarPreferenceEntry(name: "Anna")
    entry.perProvider = {"heygen": "av_3"}.toTable
    let prefs = AvatarPreferences(preferred: @[entry])
    let hit = matchPreferredAvatar(prefs, "heygen", available)
    check hit.isSome
    check hit.get.id == "av_3"

  test "no override falls back to name + gender + tag scoring":
    var entry = AvatarPreferenceEntry(name: "Sarah", gender: gFemale,
                                      tags: @["warm"])
    let prefs = AvatarPreferences(preferred: @[entry])
    let hit = matchPreferredAvatar(prefs, "heygen", available)
    check hit.isSome
    check hit.get.id == "av_1"

  test "second preferred entry wins when first has no match":
    let prefs = AvatarPreferences(preferred: @[
      AvatarPreferenceEntry(name: "Nonexistent"),
      AvatarPreferenceEntry(name: "Anna", gender: gFemale),
    ])
    let hit = matchPreferredAvatar(prefs, "heygen", available)
    check hit.isSome
    check hit.get.id == "av_3"

  test "fallback name resolves when nothing in preferred matches":
    let prefs = AvatarPreferences(preferred: @[
      AvatarPreferenceEntry(name: "Nope"),
    ], fallback: "daniel")
    let hit = matchPreferredAvatar(prefs, "heygen", available)
    check hit.isSome
    check hit.get.id == "av_2"

  test "returns none when nothing matches and no fallback":
    let prefs = AvatarPreferences(preferred: @[
      AvatarPreferenceEntry(name: "Nothing")
    ])
    let hit = matchPreferredAvatar(prefs, "heygen", available)
    check hit.isNone

# ---------------------------------------------------------------------------
# setIfMissing convenience
# ---------------------------------------------------------------------------

suite "setIfMissing":

  test "writes when key absent":
    let j = newJObject()
    setIfMissing(j, "voice_id", %"sarah")
    check j["voice_id"].getStr == "sarah"

  test "preserves caller-supplied value":
    let j = %*{"voice_id": "caller"}
    setIfMissing(j, "voice_id", %"sarah")
    check j["voice_id"].getStr == "caller"

  test "tolerates nil / non-object input":
    setIfMissing(nil, "k", %"v")
    let arr = %*[1, 2, 3]
    setIfMissing(arr, "k", %"v")
    check arr.kind == JArray
