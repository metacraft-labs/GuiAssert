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
    @for f in tparser ttalking_head tdriver_browser tdriver_vscode tmedia teditor tcapture tappium twindow_layout tartifact_project tartifact_pipeline; do \
      echo "===== $f ====="; \
      nim c -r --hints:off tests/$f.nim; \
    done

# Required by the workspace's pre-commit hook (`just lint`).  Add real
# linters here as they come online (e.g. `nim check`).
lint:
    @echo "[lint] no linters configured yet for GuiAssert."
