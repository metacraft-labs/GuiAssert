## The visibility rule of secret-guarded frames (spec §7.5, "Secret-guarded
## frames", contract 1.1, GS17): whether a secret a consumer typed is legible
## in the text an OCR engine recognized in a frame.
##
## Both texts lose every white-space character (an engine splits and joins
## words where the font's spacing suggests, and a secret may hold a space)
## and are compared case-insensitively, rune by rune (Unicode simple case
## folding through `unicode.toLower`). The secret is visible when some run of
## the recognized text, as long as the secret, differs from it in at most
## `(n - 4) div 4` runes (`n` the secret's length: none for 4 to 7 runes, one
## for 8 to 11, two for 12 to 15, …): an engine that misreads a glyph or two
## of a password typed into a plain field must still count as having read it,
## while a short secret, which ordinary text matches by chance when a rune
## may differ, must match exactly. A secret shorter than `minSecretRunes` is
## refused, because a run of three characters is found in ordinary text.
##
## The rule only detects; it masks nothing, and it is as good as the engine's
## reading of the frame (spec §7.5).

import std/unicode

const
  minSecretRunes* = 4
    ## The shortest secret the guard accepts (white space removed).

proc foldedRunes(s: string): seq[Rune] =
  ## `s`'s runes without white space, each lower-cased.
  for r in s.runes:
    if not r.isWhiteSpace:
      result.add r.toLower

proc secretRunes*(secret: string): int =
  ## How many runes the guard compares of `secret` (white space removed).
  foldedRunes(secret).len

proc allowedMismatches*(n: int): int =
  ## The differing runes a run of length `n` may have and still count as
  ## the secret.
  max(0, (n - minSecretRunes) div 4)

proc secretVisible*(recognized, secret: string): bool =
  ## Whether `secret` is legible in `recognized` (module doc). A secret
  ## shorter than `minSecretRunes` raises `ValueError`; the caller refuses
  ## it before it reads a frame.
  let s = foldedRunes(secret)
  if s.len < minSecretRunes:
    raise newException(ValueError, "a guarded secret has at least " &
      $minSecretRunes & " characters besides white space")
  let t = foldedRunes(recognized)
  let budget = allowedMismatches(s.len)
  for start in 0 .. t.len - s.len:
    var misses = 0
    for i in 0 ..< s.len:
      if t[start + i] != s[i]:
        inc misses
        if misses > budget: break
    if misses <= budget: return true
  false
