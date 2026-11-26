#!/usr/bin/env bash
# The dev shell's ffmpeg ($FFMPEG_BIN) lists x11grab among its devices on
# Linux, so a binding can record an X window with ffmpeg. The default nixpkgs
# ffmpeg has none; flake.nix puts ffmpeg-full in the shell on Linux.
set -euo pipefail
[ "$(uname -s)" = Linux ] || { echo "dev-shell ffmpeg: not Linux, x11grab not required"; exit 0; }
ff="${FFMPEG_BIN:-ffmpeg}"
if "$ff" -hide_banner -devices 2>/dev/null | grep -qE '^ *D[ E]* +x11grab '; then
	echo "dev-shell ffmpeg: $ff lists x11grab"
else
	echo "dev-shell ffmpeg: $ff has no x11grab device (ffmpeg -devices)" >&2
	exit 1
fi
