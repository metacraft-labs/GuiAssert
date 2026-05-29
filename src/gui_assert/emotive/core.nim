## Common emotive + avatar configuration shared across talking-head and
## speech-synthesis plugins.
##
## Each commercial / OSS plugin exposes a different surface for tuning the
## resulting render: D-ID has `expressions`, HeyGen Avatar IV exposes an
## `emotion` field, ElevenLabs has `stability`/`similarity_boost`/`style`,
## SadTalker has `--still-mode` and an expression scale, etc.  Rather than
## leak each provider's enum into the YAML, GuiAssert defines a *superset*
## of fields here and leaves the projection onto each plugin's own opts
## shape to the plugin.
##
## Consumers populate a `CommonEmotiveConfig` from the YAML script (or
## hand-built code), pass it through to the chosen provider, and the
## provider translates whichever fields it understands.  Unknown fields
## are silently ignored on the provider side; `extras` carries
## forward-compatible scalar keys for round-tripping.
##
## Avatar preferences live alongside the emotive config in the same
## module because callers usually want both ("happy-Sarah") to travel
## together through the registry.  An `AvatarPreferenceEntry` carries
## (a) a logical role/name that providers can match against their listed
## avatars and (b) explicit per-provider overrides for hand-picked IDs.

import std/[json, options, strutils, tables]

type
  Emotion* = enum
    ## Provider-agnostic emotional register.  Plugins map this onto
    ## whichever subset their backend supports; unmapped values fall
    ## back to `eNeutral`.
    eNeutral = "neutral"
    eHappy = "happy"
    eSad = "sad"
    eAngry = "angry"
    eExcited = "excited"
    eSerious = "serious"
    eFriendly = "friendly"
    eConfident = "confident"
    eThoughtful = "thoughtful"
    eEnergetic = "energetic"
    eCalm = "calm"
    eSurprised = "surprised"

  GestureLevel* = enum
    ## Hand / body motion intensity.  Providers without explicit gesture
    ## control treat this as advisory.
    glNone = "none"
    glSubtle = "subtle"
    glNatural = "natural"
    glExpressive = "expressive"

  BackgroundMode* = enum
    ## Background handling.  `bmAsIs` is the provider default (whatever
    ## the avatar/replica was trained with).  `bmGreenScreen` requests a
    ## solid green canvas for chroma-keying downstream.  `bmTransparent`
    ## requests an alpha-channel render where the backend supports it
    ## (D-ID, HeyGen).  `bmSolidColor` paints `backgroundColor` behind
    ## the presenter.
    bmAsIs = "as_is"
    bmGreenScreen = "green_screen"
    bmTransparent = "transparent"
    bmSolidColor = "solid_color"
    bmTrained = "trained"

  CommonEmotiveConfig* = object
    ## Superset of tunables across talking-head + speech-synthesis
    ## plugins.  Every field is optional so callers can layer overrides
    ## (script default → keyframe override → CLI flag).
    emotion*: Option[Emotion]
    intensity*: Option[float]                  ## 0.0..1.0 — overall expression magnitude
    voiceSpeed*: Option[float]                 ## 0.5..2.0 — playback speed multiplier
    voicePitch*: Option[float]                 ## -10..+10 — semitones
    voiceStability*: Option[float]             ## 0.0..1.0 — ElevenLabs-style
    voiceSimilarityBoost*: Option[float]       ## 0.0..1.0 — ElevenLabs-style
    voiceStyle*: Option[float]                 ## 0.0..1.0 — voice exaggeration
    useSpeakerBoost*: Option[bool]             ## ElevenLabs speaker_boost
    gestures*: Option[GestureLevel]
    eyeContact*: Option[bool]                  ## look-at-camera hint
    headMotion*: Option[float]                 ## 0.0..1.0 — SadTalker-style
    expressionScale*: Option[float]            ## 0.0..2.0 — SadTalker-style
    background*: Option[BackgroundMode]
    backgroundColor*: Option[string]           ## hex e.g. "#00ff00"; used with bmSolidColor
    extras*: Table[string, string]             ## forward-compat scalar keys

  Gender* = enum
    gUnspecified = ""
    gFemale = "female"
    gMale = "male"
    gNonBinary = "non_binary"

  AvatarPreferenceEntry* = object
    ## One entry in the preferred-avatar list.  Matching scores against
    ## the provider-listed avatars by `name`/`tags`/`gender`/`style`;
    ## `perProvider` short-circuits matching with an explicit ID.
    name*: string
    role*: string
    gender*: Gender
    style*: string
    tags*: seq[string]
    perProvider*: Table[string, string]

  AvatarPreferences* = object
    ## Ordered list of preferred avatars (first match wins per
    ## provider) plus an optional fallback name used when nothing in
    ## `preferred` matches.
    preferred*: seq[AvatarPreferenceEntry]
    fallback*: string

  AvatarInfo* = object
    ## Provider-listed avatar / replica / voice metadata.  Built by
    ## each plugin's `listAvatars` / `listVoices` proc.
    id*: string
    name*: string
    gender*: Gender
    description*: string
    tags*: seq[string]
    previewUrl*: string

  EmotiveError* = object of CatchableError

# ---------------------------------------------------------------------------
# Enum parsing / normalisation
# ---------------------------------------------------------------------------

proc parseEmotion*(s: string): Emotion =
  ## Case-insensitive parse with aliasing.  Unknown values fall back
  ## to `eNeutral` so a typo in YAML doesn't abort a render.
  let n = s.strip.toLowerAscii
  case n
  of "", "neutral", "none": eNeutral
  of "happy", "joy", "joyful", "cheerful": eHappy
  of "sad", "sorrow": eSad
  of "angry", "anger": eAngry
  of "excited", "excitement", "enthusiastic": eExcited
  of "serious", "formal": eSerious
  of "friendly", "warm": eFriendly
  of "confident": eConfident
  of "thoughtful", "pensive": eThoughtful
  of "energetic", "energy": eEnergetic
  of "calm", "relaxed": eCalm
  of "surprised", "surprise": eSurprised
  else: eNeutral

proc parseGesture*(s: string): GestureLevel =
  let n = s.strip.toLowerAscii
  case n
  of "", "none": glNone
  of "subtle", "minimal", "low": glSubtle
  of "natural", "medium", "default": glNatural
  of "expressive", "high", "wide": glExpressive
  else: glNatural

proc parseBackground*(s: string): BackgroundMode =
  let n = s.strip.toLowerAscii
  case n
  of "", "as_is", "as-is", "default": bmAsIs
  of "green_screen", "green-screen", "greenscreen", "chroma": bmGreenScreen
  of "transparent", "alpha": bmTransparent
  of "solid_color", "solid-color", "color", "solid": bmSolidColor
  of "trained", "avatar_default", "replica_default": bmTrained
  else: bmAsIs

proc parseGender*(s: string): Gender =
  let n = s.strip.toLowerAscii
  case n
  of "", "unspecified", "any": gUnspecified
  of "female", "woman", "f": gFemale
  of "male", "man", "m": gMale
  of "non_binary", "non-binary", "nonbinary", "nb", "neutral": gNonBinary
  else: gUnspecified

# ---------------------------------------------------------------------------
# Range helpers — clamp + sentinel handling
# ---------------------------------------------------------------------------

proc clampUnit*(v: float): float =
  ## Clamp to [0, 1].  Used wherever a 0..1 knob is exposed.
  if v < 0.0: 0.0
  elif v > 1.0: 1.0
  else: v

proc clampSemitones*(v: float): float =
  if v < -10.0: -10.0
  elif v > 10.0: 10.0
  else: v

proc clampSpeed*(v: float): float =
  if v < 0.5: 0.5
  elif v > 2.0: 2.0
  else: v

# ---------------------------------------------------------------------------
# Constructors + merging
# ---------------------------------------------------------------------------

proc initEmotive*(): CommonEmotiveConfig =
  ## Empty config — every field is `none`.  Translations treat this as
  ## "use the provider defaults".
  result.extras = initTable[string, string]()

proc overlay*(base, override: CommonEmotiveConfig): CommonEmotiveConfig =
  ## Layer `override` on top of `base`.  Any `some` field in `override`
  ## wins; everything else is inherited.  Used to fold per-keyframe
  ## overrides into the script-level default.
  result = base
  if override.emotion.isSome: result.emotion = override.emotion
  if override.intensity.isSome: result.intensity = override.intensity
  if override.voiceSpeed.isSome: result.voiceSpeed = override.voiceSpeed
  if override.voicePitch.isSome: result.voicePitch = override.voicePitch
  if override.voiceStability.isSome: result.voiceStability = override.voiceStability
  if override.voiceSimilarityBoost.isSome:
    result.voiceSimilarityBoost = override.voiceSimilarityBoost
  if override.voiceStyle.isSome: result.voiceStyle = override.voiceStyle
  if override.useSpeakerBoost.isSome: result.useSpeakerBoost = override.useSpeakerBoost
  if override.gestures.isSome: result.gestures = override.gestures
  if override.eyeContact.isSome: result.eyeContact = override.eyeContact
  if override.headMotion.isSome: result.headMotion = override.headMotion
  if override.expressionScale.isSome:
    result.expressionScale = override.expressionScale
  if override.background.isSome: result.background = override.background
  if override.backgroundColor.isSome:
    result.backgroundColor = override.backgroundColor
  if result.extras.len == 0:
    result.extras = initTable[string, string]()
  for k, v in override.extras:
    result.extras[k] = v

# ---------------------------------------------------------------------------
# JSON serialisation (round-trips through YAML/JSON metadata blocks)
# ---------------------------------------------------------------------------

proc emotiveFromJson*(node: JsonNode): CommonEmotiveConfig =
  ## Decode a JSON object — typically the YAML `emotive_defaults` block
  ## or a per-keyframe `emotive` override.  Missing keys → `none`;
  ## unknown keys are stuffed into `extras` for forward compatibility.
  result = initEmotive()
  if node.isNil or node.kind != JObject:
    return
  for k, v in node:
    case k.toLowerAscii
    of "emotion":
      if v.kind == JString:
        result.emotion = some(parseEmotion(v.getStr))
    of "intensity":
      if v.kind in {JFloat, JInt}:
        result.intensity = some(clampUnit(v.getFloat))
    of "voice_speed", "voicespeed":
      if v.kind in {JFloat, JInt}:
        result.voiceSpeed = some(clampSpeed(v.getFloat))
    of "voice_pitch", "voicepitch":
      if v.kind in {JFloat, JInt}:
        result.voicePitch = some(clampSemitones(v.getFloat))
    of "voice_stability", "stability":
      if v.kind in {JFloat, JInt}:
        result.voiceStability = some(clampUnit(v.getFloat))
    of "voice_similarity_boost", "similarity_boost":
      if v.kind in {JFloat, JInt}:
        result.voiceSimilarityBoost = some(clampUnit(v.getFloat))
    of "voice_style", "style":
      if v.kind in {JFloat, JInt}:
        result.voiceStyle = some(clampUnit(v.getFloat))
    of "use_speaker_boost", "speaker_boost":
      if v.kind == JBool:
        result.useSpeakerBoost = some(v.getBool)
    of "gestures":
      if v.kind == JString:
        result.gestures = some(parseGesture(v.getStr))
    of "eye_contact":
      if v.kind == JBool:
        result.eyeContact = some(v.getBool)
    of "head_motion", "headmotion":
      if v.kind in {JFloat, JInt}:
        result.headMotion = some(clampUnit(v.getFloat))
    of "expression_scale", "expressionscale":
      if v.kind in {JFloat, JInt}:
        let raw = v.getFloat
        let cl =
          if raw < 0.0: 0.0
          elif raw > 2.0: 2.0
          else: raw
        result.expressionScale = some(cl)
    of "background":
      if v.kind == JString:
        result.background = some(parseBackground(v.getStr))
    of "background_color", "backgroundcolor":
      if v.kind == JString:
        result.backgroundColor = some(v.getStr)
    else:
      case v.kind
      of JString: result.extras[k] = v.getStr
      of JInt: result.extras[k] = $v.getInt
      of JFloat: result.extras[k] = $v.getFloat
      of JBool: result.extras[k] = $v.getBool
      else: discard

proc toJson*(c: CommonEmotiveConfig): JsonNode =
  ## Serialise to a JSON object using the same key shape as
  ## `emotiveFromJson` reads.
  result = newJObject()
  if c.emotion.isSome: result["emotion"] = %($c.emotion.get)
  if c.intensity.isSome: result["intensity"] = %c.intensity.get
  if c.voiceSpeed.isSome: result["voice_speed"] = %c.voiceSpeed.get
  if c.voicePitch.isSome: result["voice_pitch"] = %c.voicePitch.get
  if c.voiceStability.isSome:
    result["voice_stability"] = %c.voiceStability.get
  if c.voiceSimilarityBoost.isSome:
    result["voice_similarity_boost"] = %c.voiceSimilarityBoost.get
  if c.voiceStyle.isSome: result["voice_style"] = %c.voiceStyle.get
  if c.useSpeakerBoost.isSome:
    result["use_speaker_boost"] = %c.useSpeakerBoost.get
  if c.gestures.isSome: result["gestures"] = %($c.gestures.get)
  if c.eyeContact.isSome: result["eye_contact"] = %c.eyeContact.get
  if c.headMotion.isSome: result["head_motion"] = %c.headMotion.get
  if c.expressionScale.isSome:
    result["expression_scale"] = %c.expressionScale.get
  if c.background.isSome: result["background"] = %($c.background.get)
  if c.backgroundColor.isSome:
    result["background_color"] = %c.backgroundColor.get
  for k, v in c.extras:
    if not result.hasKey(k):
      result[k] = %v

# ---------------------------------------------------------------------------
# Avatar preferences — parsing + matching
# ---------------------------------------------------------------------------

proc avatarEntryFromJson*(node: JsonNode): AvatarPreferenceEntry =
  result.tags = @[]
  result.perProvider = initTable[string, string]()
  result.gender = gUnspecified
  if node.isNil or node.kind != JObject: return
  for k, v in node:
    case k.toLowerAscii
    of "name":
      if v.kind == JString: result.name = v.getStr
    of "role":
      if v.kind == JString: result.role = v.getStr
    of "gender":
      if v.kind == JString: result.gender = parseGender(v.getStr)
    of "style":
      if v.kind == JString: result.style = v.getStr
    of "tags":
      if v.kind == JArray:
        for t in v.items:
          if t.kind == JString: result.tags.add t.getStr
    of "per_provider", "providers", "ids":
      if v.kind == JObject:
        for pn, pv in v:
          if pv.kind == JString:
            result.perProvider[pn.toLowerAscii] = pv.getStr

proc avatarPrefsFromJson*(node: JsonNode): AvatarPreferences =
  result.preferred = @[]
  if node.isNil: return
  if node.kind == JArray:
    for it in node.items:
      result.preferred.add avatarEntryFromJson(it)
    return
  if node.kind != JObject: return
  for k, v in node:
    case k.toLowerAscii
    of "preferred":
      if v.kind == JArray:
        for it in v.items:
          result.preferred.add avatarEntryFromJson(it)
    of "fallback":
      if v.kind == JString: result.fallback = v.getStr

proc tagSetOverlap(a, b: seq[string]): int =
  ## Count of case-insensitive tag matches.
  if a.len == 0 or b.len == 0: return 0
  for x in a:
    let xl = x.strip.toLowerAscii
    for y in b:
      if y.strip.toLowerAscii == xl:
        inc result

proc scoreAvatar*(entry: AvatarPreferenceEntry, candidate: AvatarInfo): int =
  ## Higher = better match.  An explicit `perProvider` match short-
  ## circuits to `int.high` upstream; this proc handles the
  ## name/gender/style/tag heuristic for the no-override path.
  if entry.name.len > 0 and
     candidate.name.strip.toLowerAscii ==
       entry.name.strip.toLowerAscii:
    result += 100
  elif entry.name.len > 0 and
       entry.name.strip.toLowerAscii in candidate.name.strip.toLowerAscii:
    result += 60
  if entry.gender != gUnspecified and entry.gender == candidate.gender:
    result += 20
  if entry.style.len > 0 and
     entry.style.strip.toLowerAscii in candidate.description.toLowerAscii:
    result += 15
  result += tagSetOverlap(entry.tags, candidate.tags) * 10

proc matchPreferredAvatar*(prefs: AvatarPreferences, providerName: string,
                           available: seq[AvatarInfo]): Option[AvatarInfo] =
  ## Walk `prefs.preferred` in order; first explicit `perProvider`
  ## hit returns immediately, otherwise the highest-scoring heuristic
  ## match per entry wins (with a non-zero score threshold).  Falls
  ## back to a name-substring match against `prefs.fallback`.
  let pn = providerName.toLowerAscii
  for entry in prefs.preferred:
    if pn in entry.perProvider:
      let id = entry.perProvider[pn]
      for a in available:
        if a.id == id or a.name == id:
          return some(a)
      var injected = AvatarInfo(id: id, name: id)
      injected.gender = entry.gender
      injected.tags = entry.tags
      return some(injected)
    var best = -1
    var picked: AvatarInfo
    for a in available:
      let s = scoreAvatar(entry, a)
      if s > best:
        best = s
        picked = a
    if best >= 60:
      return some(picked)
  if prefs.fallback.len > 0:
    let fb = prefs.fallback.strip.toLowerAscii
    for a in available:
      if a.id.toLowerAscii == fb or a.name.toLowerAscii == fb:
        return some(a)
      if fb in a.name.toLowerAscii or fb in a.id.toLowerAscii:
        return some(a)
  none(AvatarInfo)

# ---------------------------------------------------------------------------
# Convenience: stuff translation results into a TalkingHeadOpts-like
# providerSettings JsonNode.  Plugins call these to build the
# `providerSettings` field they pass through to their generate proc.
# ---------------------------------------------------------------------------

proc setIfMissing*(j: JsonNode, key: string, value: JsonNode) =
  ## Write `value` into `j[key]` only if `j` doesn't already have the
  ## key set to a non-null value.  Used by translation procs so caller
  ## overrides (already in `providerSettings`) take precedence over
  ## emotive defaults.
  if j.isNil or j.kind != JObject: return
  if not j.hasKey(key) or j[key].isNil or j[key].kind == JNull:
    j[key] = value
