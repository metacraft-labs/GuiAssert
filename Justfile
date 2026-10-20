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
# `just test-live-macos` - the TCC-gated macOS live capture suite (GS5).
# `just test-contract` - the contract suite (tests/contract_suite.txt) against
#                    the REAL built binaries, run once per binary.
# `just lint`      - placeholder; required by the workspace pre-commit
#                    hook.  Add real linters here as they come online.

default: test

# Run every default unit test against the local nim toolchain, then the
# contract suite against the built binaries.
test: && test-contract
    @for f in tnimcache_is_worktree_local tparser ttalking_head tdriver_browser tdriver_vscode tmedia teditor tcapture tappium twindow_layout tinput tpacing tartifact_project tartifact_pipeline tdesktop_env tcore_types tcore_contract tcore_png tcore_mp4 tcore_shims tmacos_capture; do \
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

# The macOS live capture suite (GS5): the real `guiassert` with the
# macos-sck / macos-cgwindow backends against the real window server, the
# signed helper bundle and an AppKit fixture app built at test time. Needs
# an unlocked GUI session and the one-time Screen Recording grant for
# ~/Library/Application Support/GuiAssert/GuiAssertCapture.app; without
# them the gated tests FAIL with a BLOCKED line (spec §9.4), never skip.
test-live-macos: build-cli
    nim c -d:tccLive -r --hints:off tests/live/tcapture_macos.nim

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
