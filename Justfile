# GuiAssert
#
# `just test`      - run the default test suite (excludes the OCR-dependent
#                    tgui_assert flake, which needs a healthy tesseract
#                    install). Includes the core unit tests and the legacy
#                    import-path check.
# `just test-core` - the pure core's unit tests and its purity checks
#                    (import allowlist, no FFI, links only the C runtime).
#                    The list lives in tests/core_suite.txt so the Windows CI
#                    job, which has no `just` recipe shell, runs the same one.
# `just build-cli` - build/bin/guiassert (every backend for this OS) and
#                    build/bin/guiassert-fixture (-d:guiassertMinimal: the core
#                    and the fixture backends only).
# `just test-live-macos` - the macOS live suites: capture (GS5, TCC-gated)
#                    and OCR (GS6: Apple Vision over files, and over captures).
# `just test-live-linux` - the Linux live suites: capture (GS5): linux-x11 in a
#                    private Xvfb, linux-wlr and linux-portal-pipewire in a
#                    private headless sway, linux-gnome in a private headless
#                    GNOME Shell; OCR (GS6): tesseract over captures from
#                    each of them; and accessibility trees (GS7): linux-atspi
#                    reading invented GTK 3 and GTK 4 forms on the private
#                    AT-SPI bus of a headless sway (scale 1 and 2) and of an
#                    Xvfb (inside `nix develop`).
# `just test-live-tesseract` - the tesseract OCR engine against the pinned
#                    tesseract (GS6; Linux and macOS, inside `nix develop`).
# `just test-parity-linux` - the Linux parity evidence (GS13): the consumer's
#                    Linux computer-use scenarios through the real `guiassert`
#                    in private linux-sway and linux-xvfb sessions; writes
#                    build/parity/linux-parity.json (inside `nix develop`).
# `just test-contract` - the contract suite (tests/contract_suite.txt) against
#                    the REAL built binaries, run once per binary.
# `just lint`      - placeholder; required by the workspace pre-commit
#                    hook.  Add real linters here as they come online.

default: test

# Run every default unit test against the local nim toolchain, then the
# contract suite against the built binaries.
test: && test-contract
    @for f in tnimcache_is_worktree_local tparser ttalking_head tdriver_browser tdriver_vscode tmedia teditor tcapture tappium twindow_layout tinput tpacing tcancel tartifact_project tartifact_pipeline tdesktop_env tcore_types tcore_contract tcore_png tcore_mp4 tcore_shims tmacos_capture tlinux_capture tlinux_tree tlinux_input tlinux_session tswift_helper_cache; do \
      echo "===== $f ====="; \
      nim c -r --hints:off tests/$f.nim || exit 1; \
    done

# The pure core: unit tests plus the purity rule of the desktop-substrate
# spec (§3.2). Runs on every host; no TCC grant, display or network needed.
test-core:
    @for f in $(grep -v '^#' tests/core_suite.txt); do \
      echo "===== $f ====="; \
      nim c -r --hints:off tests/$f.nim || exit 1; \
    done

# The `guiassert` program, built twice from one main (spec §3.4, §9.2). Each
# build keeps its own nimcache so the two defines do not invalidate each other.
build-cli:
    @mkdir -p build/bin
    nim c --hints:off -d:release --nimcache:.nimcache/build-cli/guiassert -o:build/bin/guiassert src/guiassert.nim
    nim c --hints:off -d:release -d:guiassertMinimal --nimcache:.nimcache/build-cli/guiassert-fixture -o:build/bin/guiassert-fixture src/guiassert.nim

# The contract suite: the real `guiassert` and `guiassert serve` with the
# fixture backend selected below them (spec §9.1). It runs once against each
# binary (GUIASSERT_CONTRACT_BIN), so `guiassert-fixture` -- the binary
# consumers' own contract tests use -- is held to the same contract. The list
# lives in tests/contract_suite.txt so the Windows CI job runs the same one.
test-contract: build-cli
    @for bin in guiassert guiassert-fixture; do \
      for f in $(grep -v '^#' tests/contract_suite.txt); do \
        echo "===== $f ($bin) ====="; \
        GUIASSERT_CONTRACT_BIN="$PWD/build/bin/$bin" nim c -r --hints:off tests/contract/$f.nim || exit 1; \
      done; \
    done

# The desktop-environment targets against REAL compositors (Linux, inside
# `nix develop`): a private headless sway, its session bus and settings
# portal. Builds the C helpers under helpers/linux on first use.
test-desktop-env:
    nim c -r --hints:off tests/tdesktop_env_targets.nim
    nim c -r --hints:off tests/tdesktop_env_attach.nim

# The macOS live suites. Capture (GS5): the real `guiassert` with the
# macos-sck / macos-cgwindow backends against the real window server, the
# signed helper bundle and an AppKit fixture app built at test time. Needs
# an unlocked GUI session and the one-time Screen Recording grant for
# ~/Library/Application Support/GuiAssert/GuiAssertCapture.app; without
# them the gated tests FAIL with a BLOCKED line (spec §9.4), never skip.
# OCR (GS6): the apple-vision engine over invented image files (no
# permission needed) and over a capture of a fixture window (gated as above).
# Both suites run even when the first fails (a BLOCKED capture suite must not
# hide the OCR results); the recipe fails when either does.
test-live-macos: build-cli
    @status=0; for f in tcapture_macos tocr_macos; do \
      echo "===== $f ====="; \
      nim c -d:tccLive -r --hints:off tests/live/$f.nim || status=1; \
    done; exit $status

# The Linux live capture suite (GS5): the real `guiassert` with the four
# Linux capture backends against display servers the suite starts for itself
# (a private Xvfb, a private headless sway with PipeWire and the wlroots
# portal, a private headless GNOME Shell), never the operator's display. A
# server that cannot start FAILS its tests with a `GS5-LINUX BLOCKED:` line.
# The OCR suite (GS6, tests/live/tocr_linux.nim) then reads invented labels
# through the same backends with the pinned tesseract (`GS6-LINUX BLOCKED:`
# likewise), and the tree suite (GS7, tests/live/ttree_linux.nim) reads,
# searches and drives invented GTK forms over each session's own AT-SPI bus
# (`GS7-LINUX BLOCKED:` likewise), the input suite (GS8,
# tests/live/tinput_linux.nim) drives them, and the session suite (GS10,
# tests/live/tsession_linux.nim) starts, uses and stops private linux-sway,
# linux-gnome and linux-xvfb sessions through the real binary (with their
# loopback VNC endpoints) and attaches linux-host to a private sway
# (`GS10-LINUX BLOCKED:` likewise). Every suite runs even when an earlier
# one fails; the recipe fails when any does. Run inside `nix develop` (it pins
# every server and tool the suites start).
test-live-linux: build-cli
    @status=0; for f in tcapture_linux tocr_linux ttree_linux tinput_linux tsession_linux; do \
      echo "===== $f ====="; \
      nim c -r --hints:off tests/live/$f.nim || status=1; \
    done; exit $status

# The tesseract OCR engine (GS6) through the real `guiassert`, against the
# tesseract and ffmpeg the flake pins (run inside `nix develop`). Needs no
# permission and no display.
test-live-tesseract: build-cli
    nim c -r --hints:off tests/live/tocr_tesseract.nim

# The Linux parity harness (GS13, tests/parity/linux_parity.sh): every scenario
# of the consumer's Linux computer-use suite, restated in GuiAssert's terms,
# against the invented GTK 3 and GTK 4 application tests/parity/fixtures/
# parity_lab.c in private linux-sway and linux-xvfb sessions it starts with
# `session-start`. Extra arguments go to the harness (`--sessions
# sway,xvfb,gnome`, `--only S1,S4`, `--evidence PATH`).
test-parity-linux *args: build-cli
    GUIASSERT_CONTRACT_BIN="$PWD/build/bin/guiassert" bash tests/parity/linux_parity.sh {{args}}

# Run only the R6 human-cadence pacing tests (pure + deterministic; no TCC).
test-pacing:
    nim c -r --hints:off tests/tpacing.nim

# Build + run the gui-assert-vision CLI's `analyze` on VIDEO, writing the
# 3-level index.json + digest.md + keyframes into OUT (default: vision-out).
analyze VIDEO OUT="vision-out":
    nim c --hints:off -o:src/gui_assert_vision src/gui_assert_vision.nim
    ./src/gui_assert_vision analyze {{VIDEO}} --out {{OUT}}

# Required by the workspace's pre-commit hook (`just lint`).  Add real
# linters here as they come online (e.g. `nim check`).
lint:
    @echo "[lint] no linters configured yet for GuiAssert."
