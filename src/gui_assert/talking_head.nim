## Talking-head provider interface (plugin contract).
##
## Wraps the various AI / non-AI providers that turn a narration WAV +
## portrait image into an animated talking-head MP4.  The marketing
## runner composes this MP4 into the bottom-right corner of the final
## demo video via `media.composeVideoWithOverlay`.
##
## ## Plugin model
##
## GuiAssert ships a small, lightweight built-in: the `stock_avatar`
## provider (a `testsrc2` placeholder, used by CI dry runs and any
## script that does not opt into a heavier model).  Every other
## provider lives in its own sibling repo — for example
## `GuiAssert-SadTalker`, `GuiAssert-MuseTalk`, `GuiAssert-Did`,
## `GuiAssert-HeyGen` — so callers only pay the dependency cost of
## the providers they actually use.
##
## Each plugin imports `gui_assert/talking_head` (or the lighter
## `gui_assert/talking_head/core` if it does not need the built-in
## stock provider), constructs a `TalkingHeadProvider` value with its
## own `name`, `isAvailable`, and `generate` procs, and registers it
## into a `TalkingHeadRegistry` at runtime.  The runner then looks up
## providers by their YAML-facing string name
## (`metadata.talking_head.provider`) — there is no hardcoded enum
## inside GuiAssert.
##
## ## Module layout
##
##   * `gui_assert/talking_head/core` — types, registry, helpers
##     (`cacheKeyFor`, `applyCache`, `optsFromMetadata`).  No
##     ffmpeg/subprocess code; safe for header-only plugin authors.
##   * `gui_assert/talking_head/stock_avatar` — the built-in
##     `stock_avatar` provider.  Shells out to ffmpeg.
##   * `gui_assert/talking_head` (this module) — re-exports both and
##     adds `newRegistry()`, which returns a registry with
##     `stock_avatar` already registered.

import ./talking_head/core
import ./talking_head/stock_avatar

export core
export stock_avatar

proc newRegistry*(): TalkingHeadRegistry =
  ## Returns a registry with the built-in `stock_avatar` provider
  ## already registered.  Plugins layer more providers via
  ## `registerProvider`.
  result = newEmptyRegistry()
  registerProvider(result, newStockAvatarProvider())
