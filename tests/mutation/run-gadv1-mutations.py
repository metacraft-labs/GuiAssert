#!/usr/bin/env python3
"""GADV-1 verification gate: gestures and modified drags.

Each arm is a defect in how a gesture or a modified drag is planned; the kill
command builds `guiassert` and runs the live gesture test against a private
Xvfb (linux-xtest), read back from the GTK fixture's own input log. Run it
inside GuiAssert's `nix develop`.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
P = "src/gui_assert/backends/input/linux_plan.nim"
KILL = ["bash", "-euo", "pipefail", "-c",
        "nim c --hints:off -d:release --nimcache:${BUILD_DIR}/nc-cli -o:${BUILD_DIR}/guiassert src/guiassert.nim && "
        "GUIASSERT_CONTRACT_BIN=${BUILD_DIR}/guiassert nim c -r --hints:off --nimcache:${BUILD_DIR}/nc-live "
        "-o:${BUILD_DIR}/tinput tests/live/tinput_linux.nim 'test_gesture_held_keys_and_modified_drag [linux-xtest, gtk3]'"]

ARMS = [
    Arm("G1", P, "      result.add move(st.at)\n      result.add btn(st.button, false)",
        "      result.add move(st.at)\n      result.add btn(st.button, true)", "a release planned as a press"),
    Arm("G2", P, "      for i in countdown(ks.high, 0): result.add key(ks[i], false)",
        "      discard ks", "a key-up omitted"),
    Arm("G3", P, "  result.pressModifiers(mods)\n  let steps = max(1, steps)",
        "  let steps = max(1, steps)",
        "a drag's modifiers never held"),
    Arm("G4", P, "    of gsMove: result.add move(st.to)", "    of gsMove: discard", "a gesture's move dropped"),
]

if __name__ == "__main__":
    main("gadv1", ROOT, ARMS, KILL)
