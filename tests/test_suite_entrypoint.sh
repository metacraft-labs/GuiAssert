#!/usr/bin/env bash
# Integration contract for GuiAssert's documented full-suite entry point.
#
# The dependency-resolution arm executes the real nimble binary against the
# real package.  The runner arms replace only `nim` with a tiny executable so
# they can force a child failure and count dispatches deterministically without
# compiling the full suite three extra times.  That fake is justified here: the
# subject of those arms is the shell runner's status and population accounting,
# not the Nim compiler or any GuiAssert test.  The ordinary full-suite run keeps
# the real compiler boundary.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
nimble_bin="${GUIASSERT_NIMBLE_BIN:-nimble}"
runner="$repo_root/scripts/run-default-tests.sh"
runner_scratch=""

cleanup() {
  if [[ -n "$runner_scratch" && -d "$runner_scratch" ]]; then
    find "$runner_scratch" -depth -delete
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_nimble_resolution_control() {
  local log rc
  log="$(mktemp "${TMPDIR:-/tmp}/guiassert-nimble-check.XXXXXX")"
  rc=0
  (
    cd "$repo_root"
    "$nimble_bin" check
  ) >"$log" 2>&1 || rc=$?

  if (( rc != 0 )); then
    sed -n '1,80p' "$log" >&2
    unlink "$log"
    if (( rc >= 128 )); then
      fail "nimble dependency resolution terminated by signal (exit $rc)"
    fi
    fail "nimble dependency resolution failed (exit $rc)"
  fi
  unlink "$log"
}

run_runner_controls() {
  [[ -x "$runner" ]] || fail "missing executable full-suite runner: $runner"

  local fake_bin log rc calls partial_manifest partial_nimble_manifest
  runner_scratch="$(mktemp -d "${TMPDIR:-/tmp}/guiassert-runner-contract.XXXXXX")"
  fake_bin="$runner_scratch/bin"
  mkdir -p "$fake_bin"
  log="$runner_scratch/runner.log"

  cat >"$fake_bin/nim" <<'FAKE_NIM'
#!/usr/bin/env bash
set -euo pipefail
self_dir="$(cd "$(dirname "$0")" && pwd -P)"
case " $* " in
  *" /tests/"*|*"/tests/"*)
    printf '%s\n' "$*" >>"${GUIASSERT_FAKE_NIM_LOG:?}"
    fake_rc="${GUIASSERT_FAKE_NIM_EXIT:-0}"
    (( fake_rc == 0 )) || exit "$fake_rc"
    case "$*" in
      *"/tests/tnimcache_is_worktree_local.nim"*)
        echo "nimcache-locality: PASS"
        ;;
      *)
        if [[ "${GUIASSERT_FAKE_NIM_MODE:-passing}" != "zero-cases" ]]; then
          echo "  [OK] synthetic executed case"
        fi
        ;;
    esac
    exit 0
    ;;
esac
old_ifs="$IFS"
IFS=:
for path_dir in $PATH; do
  [[ -d "$path_dir" ]] || continue
  physical_path_dir="$(cd "$path_dir" && pwd -P)"
  if [[ "$physical_path_dir" != "$self_dir" && -x "$path_dir/nim" ]]; then
    IFS="$old_ifs"
    exec "$path_dir/nim" "$@"
  fi
done
IFS="$old_ifs"
echo "fake nim: no real compiler found for nimble's own script" >&2
exit 127
FAKE_NIM
  chmod +x "$fake_bin/nim"

  rc=0
  PATH="$fake_bin:$PATH" \
    GUIASSERT_FAKE_NIM_LOG="$runner_scratch/failing.calls" \
    GUIASSERT_FAKE_NIM_EXIT=23 \
    "$nimble_bin" test >"$log" 2>&1 || rc=$?
  (( rc != 0 )) || fail "the documented entry point masked a child compiler failure"
  if ! grep -q 'tests/tnimcache_is_worktree_local.nim' "$runner_scratch/failing.calls"; then
    sed -n '1,80p' "$log" >&2
    fail "the failure control did not reach the suite runner"
  fi
  ! grep -q 'passed' "$log" || fail "the failed runner printed a success verdict"

  : >"$runner_scratch/passing.calls"
  PATH="$fake_bin:$PATH" \
    GUIASSERT_FAKE_NIM_LOG="$runner_scratch/passing.calls" \
    GUIASSERT_FAKE_NIM_EXIT=0 \
    bash "$runner" --units-only >"$log" 2>&1 ||
      fail "the runner rejected its complete declared unit-test population"
  calls="$(wc -l <"$runner_scratch/passing.calls" | tr -d ' ')"
  [[ "$calls" == "20" ]] ||
    fail "complete unit population dispatched $calls compiler calls, expected 20"
  grep -q '20/20 unit test files passed' "$log" ||
    fail "the runner did not attest its complete unit-test population"

  : >"$runner_scratch/nimble.calls"
  PATH="$fake_bin:$PATH" \
    GUIASSERT_FAKE_NIM_LOG="$runner_scratch/nimble.calls" \
    GUIASSERT_FAKE_NIM_EXIT=0 \
    bash "$runner" --nimble >"$log" 2>&1 ||
      fail "the runner rejected the package task's declared population"
  calls="$(wc -l <"$runner_scratch/nimble.calls" | tr -d ' ')"
  [[ "$calls" == "19" ]] ||
    fail "nimble population dispatched $calls compiler calls, expected 19"
  grep -q '19/19 nimble unit test files passed' "$log" ||
    fail "the runner did not attest the package task's complete population"

  : >"$runner_scratch/zero-case.calls"
  rc=0
  PATH="$fake_bin:$PATH" \
    GUIASSERT_FAKE_NIM_LOG="$runner_scratch/zero-case.calls" \
    GUIASSERT_FAKE_NIM_EXIT=0 \
    GUIASSERT_FAKE_NIM_MODE=zero-cases \
    bash "$runner" --units-only >"$log" 2>&1 || rc=$?
  (( rc != 0 )) || fail "the runner accepted test files that executed zero cases"
  grep -q 'produced zero executed test cases' "$log" ||
    fail "the zero-case failure did not name the missing runtime population"
  calls="$(wc -l <"$runner_scratch/zero-case.calls" | tr -d ' ')"
  [[ "$calls" == "2" ]] ||
    fail "zero-case control dispatched $calls compiler calls, expected 2"
  ! grep -q 'passed' "$log" ||
    fail "the zero-case runner printed a success verdict"

  partial_manifest="$runner_scratch/partial-suite.txt"
  sed '$d' "$repo_root/tests/default_suite.txt" >"$partial_manifest"
  : >"$runner_scratch/partial.calls"
  rc=0
  PATH="$fake_bin:$PATH" \
    GUIASSERT_FAKE_NIM_LOG="$runner_scratch/partial.calls" \
    bash "$runner" --check-unit-manifest "$partial_manifest" \
      >"$log" 2>&1 || rc=$?
  (( rc != 0 )) || fail "the runner accepted a partial declared population"
  [[ ! -s "$runner_scratch/partial.calls" ]] ||
    fail "the runner started tests before rejecting a partial population"
  grep -q 'declares 19 entries; expected 20' "$log" ||
    fail "the partial-population failure did not diagnose both counts"

  partial_nimble_manifest="$runner_scratch/partial-nimble-suite.txt"
  sed '$d' "$repo_root/tests/nimble_suite.txt" >"$partial_nimble_manifest"
  : >"$runner_scratch/partial-nimble.calls"
  rc=0
  PATH="$fake_bin:$PATH" \
    GUIASSERT_FAKE_NIM_LOG="$runner_scratch/partial-nimble.calls" \
    bash "$runner" --check-nimble-manifest "$partial_nimble_manifest" \
      >"$log" 2>&1 || rc=$?
  (( rc != 0 )) || fail "the runner accepted a partial nimble population"
  [[ ! -s "$runner_scratch/partial-nimble.calls" ]] ||
    fail "the runner started tests before rejecting a partial nimble population"
  grep -q 'declares 18 entries; expected 19' "$log" ||
    fail "the partial nimble failure did not diagnose both counts"

  cleanup
  runner_scratch=""
}

case "${1:-}" in
  "")
    run_nimble_resolution_control
    run_runner_controls
    echo "PASS: documented entry point resolves dependencies and the suite runner is honest"
    ;;
  --runner-only)
    run_runner_controls
    echo "PASS: the suite runner preserves failures and enforces its population"
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac
