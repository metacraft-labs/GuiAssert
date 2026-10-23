#!/usr/bin/env bash
# linux_parity.sh — the Linux parity evidence of GS13
# (Planned-Work/Desktop-Substrate.milestones.org).
#
# Builds the guiassert binaries (`just build-cli`) and runs the parity
# harness, tests/parity/linux_parity.nim: the real `guiassert` driving the
# invented GTK 3 and GTK 4 application tests/parity/fixtures/parity_lab.c in
# private linux-sway and linux-xvfb sessions it starts itself, through the
# scenarios of the Linux computer-use suite of GuiAssert's desktop consumer,
# restated in GuiAssert's terms. Prints one result line per scenario and run,
# writes the evidence file (schema guiassert-parity/1) and exits non-zero when
# any scenario fails.
#
# Usage: tests/parity/linux_parity.sh [--evidence PATH] [--sessions sway,xvfb[,gnome]]
#                                     [--toolkits gtk3,gtk4] [--only S1,S4,...]
#
# Runs inside GuiAssert's `nix develop` (it re-enters it when started outside),
# which pins every server, toolkit and tool the sessions start.
# GUIASSERT_CONTRACT_BIN names a prebuilt guiassert and skips the build.

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "linux_parity.sh: Linux only" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"

if [[ -z "${GUI_ASSERT_ATSPI_BUS_LAUNCHER:-}" ]]; then
  exec nix develop "$repo_root" --command bash "$repo_root/tests/parity/linux_parity.sh" "$@"
fi

if [[ -z "${GUIASSERT_CONTRACT_BIN:-}" ]]; then
  just build-cli
fi

exec nim c -r --hints:off tests/parity/linux_parity.nim "$@"
