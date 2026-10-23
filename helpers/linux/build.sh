#!/usr/bin/env bash
# build.sh <out-dir> — compile GuiAssert's Linux helpers into <out-dir>:
# `virtual_pointer` and `wm_probe` (the desktop-environment targets),
# `x11_probe` (the linux-x11 capture backend's enumeration and its live
# tests' fixture window), `portal_screencast` (the linux-portal-pipewire
# capture backend) and `wlr_screencopy` (the linux-wlr capture backend's
# recorder), and the input backends' `wayland_input` (linux-wlr-virtual,
# and the keymap reader of linux-mutter), `xtest_input` (linux-xtest) and
# `uinput_input` (linux-uinput).
#
# Needs the dev shell (`nix develop`): `cc`, `pkg-config`, `wayland-scanner`,
# libwayland-client, the protocol XML from wayland-protocols and
# wlr-protocols (and the virtual-keyboard protocol, which no package ships,
# vendored under protocols/), libxkbcommon, libX11 with libXres and libXtst,
# GIO and libpipewire. `gui_assert/desktop_env/helpers`
# calls this when a helper is missing or older than its source.
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
protocol "$wlr/unstable/wlr-screencopy-unstable-v1.xml" wlr-screencopy-unstable-v1
protocol "$wp/stable/xdg-shell/xdg-shell.xml" xdg-shell
protocol "$wp/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" xdg-decoration-unstable-v1
protocol "$wp/unstable/xdg-output/xdg-output-unstable-v1.xml" xdg-output-unstable-v1
protocol "$here/protocols/virtual-keyboard-unstable-v1.xml" virtual-keyboard-unstable-v1

flags=(-O1 -Wall -Werror -I"$gen")
libs=($(pkg-config --cflags --libs wayland-client))
cc "${flags[@]}" -o "$out/virtual_pointer" "$here/virtual_pointer.c" \
	"$gen/wlr-virtual-pointer-unstable-v1-protocol.c" "${libs[@]}"
cc "${flags[@]}" -o "$out/wm_probe" "$here/wm_probe.c" \
	"$gen/xdg-shell-protocol.c" "$gen/xdg-decoration-unstable-v1-protocol.c" "${libs[@]}"
cc "${flags[@]}" -o "$out/x11_probe" "$here/x11_probe.c" $(pkg-config --cflags --libs x11 xres)
cc "${flags[@]}" -o "$out/portal_screencast" "$here/portal_screencast.c" \
	$(pkg-config --cflags --libs gio-unix-2.0 libpipewire-0.3) -lpthread
cc "${flags[@]}" -o "$out/wlr_screencopy" "$here/wlr_screencopy.c" \
	"$gen/wlr-screencopy-unstable-v1-protocol.c" "${libs[@]}"
cc "${flags[@]}" -o "$out/wayland_input" "$here/wayland_input.c" \
	"$gen/wlr-virtual-pointer-unstable-v1-protocol.c" "$gen/virtual-keyboard-unstable-v1-protocol.c" \
	"$gen/xdg-output-unstable-v1-protocol.c" "${libs[@]}" $(pkg-config --cflags --libs xkbcommon)
cc "${flags[@]}" -o "$out/xtest_input" "$here/xtest_input.c" $(pkg-config --cflags --libs x11 xtst)
cc "${flags[@]}" -o "$out/uinput_input" "$here/uinput_input.c"
echo "built $out/virtual_pointer $out/wm_probe $out/x11_probe $out/portal_screencast $out/wlr_screencopy $out/wayland_input $out/xtest_input $out/uinput_input"
