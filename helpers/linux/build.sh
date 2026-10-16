#!/usr/bin/env bash
# build.sh <out-dir> — compile GuiAssert's Linux desktop-environment helpers
# (`virtual_pointer`, `wm_probe`) into <out-dir>.
#
# Needs the dev shell (`nix develop`): `cc`, `pkg-config`, `wayland-scanner`,
# libwayland-client, and the protocol XML from wayland-protocols and
# wlr-protocols. `gui_assert/desktop_env/helpers` calls this when a helper is
# missing or older than its source.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:?usage: build.sh <out-dir>}"
mkdir -p "$out"
wp="$(pkg-config --variable=pkgdatadir wayland-protocols)"
wlr="$(pkg-config --variable=pkgdatadir wlr-protocols)"
gen="$(mktemp -d)"
trap 'rm -rf "$gen"' EXIT

protocol() { # protocol <xml> <basename>
	[ -f "$1" ] || {
		echo "build.sh: protocol XML not found: $1" >&2
		exit 1
	}
	wayland-scanner client-header "$1" "$gen/$2-client-protocol.h"
	wayland-scanner private-code "$1" "$gen/$2-protocol.c"
}
protocol "$wlr/unstable/wlr-virtual-pointer-unstable-v1.xml" wlr-virtual-pointer-unstable-v1
protocol "$wp/stable/xdg-shell/xdg-shell.xml" xdg-shell
protocol "$wp/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" xdg-decoration-unstable-v1

flags=(-O1 -Wall -Werror -I"$gen")
libs=($(pkg-config --cflags --libs wayland-client))
cc "${flags[@]}" -o "$out/virtual_pointer" "$here/virtual_pointer.c" \
	"$gen/wlr-virtual-pointer-unstable-v1-protocol.c" "${libs[@]}"
cc "${flags[@]}" -o "$out/wm_probe" "$here/wm_probe.c" \
	"$gen/xdg-shell-protocol.c" "$gen/xdg-decoration-unstable-v1-protocol.c" "${libs[@]}"
echo "built $out/virtual_pointer $out/wm_probe"
