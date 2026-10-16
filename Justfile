# GuiAssert
#
# `just test`   - run the default test suite (excludes the OCR-dependent
#                 tgui_assert flake, which needs a healthy tesseract
#                 install).
# `just lint`   - placeholder; required by the workspace pre-commit
#                 hook.  Add real linters here as they come online.

default: test

# Run every default unit test against the local nim toolchain.
test:
    @for f in tnimcache_is_worktree_local tparser ttalking_head tdriver_browser tdriver_vscode tmedia teditor tcapture tappium twindow_layout tinput tpacing tartifact_project tartifact_pipeline tdesktop_env; do \
      echo "===== $f ====="; \
      nim c -r --hints:off tests/$f.nim; \
    done

# The desktop-environment targets against REAL compositors (Linux, inside
# `nix develop`): a private headless sway, its session bus and settings
# portal. Builds the C helpers under helpers/linux on first use.
test-desktop-env:
    nim c -r --hints:off tests/tdesktop_env_targets.nim
    nim c -r --hints:off tests/tdesktop_env_attach.nim

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
