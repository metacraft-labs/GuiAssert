## tcore_secret_guard — the visibility rule of secret-guarded frames
## (`core/secret_guard`, spec §7.5, GS17): exact and case-folded matches,
## white space ignored on both sides, a few misread glyphs still visible, one
## more than the budget not, and short or empty secrets refused. Pure core: no
## OCR engine, no frame; the recognized texts are invented, shaped like what
## tesseract returns for a password typed into a plain field.

import std/unittest

import ../src/gui_assert/core/secret_guard

suite "secret_guard (GS17)":
  test "test_secret_visible_exact_and_case_folded":
    check secretVisible("Password Pw4secretX Sign in", "Pw4secretX")
    check secretVisible("PW4SECRETX", "pw4secretx")
    # Non-ASCII letters fold too.
    check secretVisible("ÉCLAIR-ÜBER-9", "éclair-über-9")

  test "test_secret_visible_ignores_white_space":
    # The engine split the typed secret into two words.
    check secretVisible("Name: Pw4se cretX", "Pw4secretX")
    # A secret with a space is found joined.
    check secretVisible("correcthorsebattery", "correct horse battery")

  test "test_secret_visible_tolerates_misread_glyphs":
    # 12 runes: up to 2 may differ (O for Q, l for 1).
    check allowedMismatches(12) == 2
    check secretVisible("field: Ql5secretXyZ", "Q15secretXyZ")      # 1 misread
    check secretVisible("field: Ol5SecretXyZ", "Q15secretXyZ")      # 2 misread (case is not one)
    # One more than the budget is not visible.
    check not secretVisible("field: Ol5Sec4etXyZ", "Q15secretXyZ")  # 3 misread
    # 16 runes: 3 may differ.
    check allowedMismatches(16) == 3
    check secretVisible("Ol5SecretXyZ-8$S", "Q15secretXyZ-8#S")    # 3 misread
    check not secretVisible("Ol5SecretXyZ-B$S", "Q15secretXyZ-8#S") # 4 misread

  test "test_secret_not_visible_in_masked_or_unrelated_text":
    check not secretVisible("Password ********** Sign in", "Pw4secretX")
    check not secretVisible("Enter your password", "Pw4secretX")
    check not secretVisible("", "Pw4secretX")
    # Shorter than the secret: no run to compare.
    check not secretVisible("Pw4secr", "Pw4secretX")

  test "test_short_or_empty_secret_is_refused":
    check secretRunes(" a b c ") == 3
    expect ValueError: discard secretVisible("abc", "abc")
    expect ValueError: discard secretVisible("anything", "")
    expect ValueError: discard secretVisible("anything", " \t\n ")
    # Four runes is enough, and up to seven must match exactly.
    check allowedMismatches(4) == 0 and allowedMismatches(7) == 0
    check allowedMismatches(8) == 1
    check secretVisible("x a1b2 y", "a1b2")
    check not secretVisible("x a1b3 y", "a1b2")
    check not secretVisible("Pw4secX", "Pw4secr")                 # 7 runes, 1 differs
