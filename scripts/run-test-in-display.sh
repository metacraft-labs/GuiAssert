#!/usr/bin/env bash
# Run the original test command with a real X server on headless Linux.
set -euo pipefail
if [[ "$(uname -s)" == Linux && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
	command -v xvfb-run >/dev/null || { echo 'GuiAssert headless Linux tests require declared xvfb-run' >&2; exit 1; }
	command -v xdpyinfo >/dev/null || { echo 'GuiAssert headless Linux tests require declared xdpyinfo' >&2; exit 1; }
	exec xvfb-run -a bash -e -c '
		xdpyinfo -display "$DISPLAY" >/dev/null
		exec "$@"
	' guiassert-test-display "$@"
fi
exec "$@"
