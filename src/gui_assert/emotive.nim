## Umbrella module re-exporting the common emotive + avatar contract.
##
## Plugins and consumers should `import gui_assert/emotive`; the split
## into `emotive/core.nim` (types + helpers) mirrors the layout used by
## `talking_head/` and `speech_synthesis/` so future plugins can layer
## their own helpers without crowding the umbrella.

import emotive/core
export core
