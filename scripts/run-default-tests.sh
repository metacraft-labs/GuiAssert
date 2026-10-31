#!/usr/bin/env bash
# One full-suite runner shared by `nimble test` and `just test`.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
default_unit_manifest="$repo_root/tests/default_suite.txt"
nimble_unit_manifest="$repo_root/tests/nimble_suite.txt"
contract_manifest="$repo_root/tests/contract_suite.txt"
readonly expected_default_unit_tests=20
readonly expected_nimble_unit_tests=19
readonly expected_contract_tests=8
manifest_entries=()
active_log=""
last_case_count=0

cleanup_active_log() {
  if [[ -n "$active_log" && -f "$active_log" ]]; then
    unlink "$active_log"
  fi
  active_log=""
}
trap cleanup_active_log EXIT

fail() {
  echo "GuiAssert test runner: $*" >&2
  exit 1
}

capture_child() {
  local rc=0

  cleanup_active_log
  active_log="$(mktemp "${TMPDIR:-/tmp}/guiassert-test-output.XXXXXX")"
  if "$@" >"$active_log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  cat "$active_log"
  if (( rc != 0 )); then
    cleanup_active_log
    return "$rc"
  fi
}

run_unittest_invocation() {
  local label="$1"
  shift

  capture_child "$@"
  last_case_count="$(grep -Ec '^[[:space:]]*\[OK\]' "$active_log" || true)"
  (( last_case_count > 0 )) ||
    fail "$label produced zero executed test cases"
  cleanup_active_log
}

run_custom_invocation() {
  local label="$1"
  local expected_marker="$2"
  shift 2
  local marker_count

  capture_child "$@"
  marker_count="$(grep -Fxc "$expected_marker" "$active_log" || true)"
  (( marker_count == 1 )) ||
    fail "$label produced $marker_count positive verdicts; expected 1"
  cleanup_active_log
}

load_manifest() {
  local manifest="$1"
  local expected="$2"
  local label="$3"
  local source_dir="$4"
  local entry previous

  [[ -f "$manifest" ]] || fail "$label manifest does not exist: $manifest"
  manifest_entries=()
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] || continue
    [[ "$entry" =~ ^[A-Za-z0-9_]+$ ]] ||
      fail "$label manifest has an invalid entry: $entry"
    for previous in "${manifest_entries[@]:-}"; do
      [[ "$previous" != "$entry" ]] ||
        fail "$label manifest repeats entry: $entry"
    done
    [[ -f "$source_dir/$entry.nim" ]] ||
      fail "$label manifest entry has no source: $source_dir/$entry.nim"
    manifest_entries+=("$entry")
  done <"$manifest"

  if (( ${#manifest_entries[@]} != expected )); then
    fail "$label manifest declares ${#manifest_entries[@]} entries; expected $expected"
  fi
}

run_unit_tests() {
  local manifest="$1"
  local expected="$2"
  local label="$3"
  local entry executed=0 unittest_cases=0 custom_verdicts=0
  load_manifest "$manifest" "$expected" "$label" "$repo_root/tests"
  local entries=("${manifest_entries[@]}")

  for entry in "${entries[@]}"; do
    echo "===== $entry ====="
    if [[ "$entry" == "tnimcache_is_worktree_local" ]]; then
      run_custom_invocation "$entry" "nimcache-locality: PASS" \
        nim c -r --hints:off "$repo_root/tests/$entry.nim"
      custom_verdicts=$((custom_verdicts + 1))
    else
      run_unittest_invocation "$entry" \
        nim c -r --hints:off "$repo_root/tests/$entry.nim"
      unittest_cases=$((unittest_cases + last_case_count))
    fi
    executed=$((executed + 1))
  done

  (( executed == expected )) ||
    fail "executed $executed $label files; expected $expected"
  (( unittest_cases > 0 )) || fail "the unit suite executed zero unittest cases"
  (( custom_verdicts == 1 )) ||
    fail "the unit suite produced $custom_verdicts custom verdicts; expected 1"
  echo "$executed/$expected $label files passed ($unittest_cases unittest cases, $custom_verdicts custom verdict)"
}

build_cli() {
  mkdir -p "$repo_root/build/bin"
  nim c --hints:off -d:release \
    --nimcache:"$repo_root/.nimcache/build-cli/guiassert" \
    -o:"$repo_root/build/bin/guiassert" "$repo_root/src/guiassert.nim"
  nim c --hints:off -d:release -d:guiassertMinimal \
    --nimcache:"$repo_root/.nimcache/build-cli/guiassert-fixture" \
    -o:"$repo_root/build/bin/guiassert-fixture" "$repo_root/src/guiassert.nim"
}

run_contract_tests() {
  local bin entry executed=0 unittest_cases=0
  load_manifest "$contract_manifest" "$expected_contract_tests" \
    "contract-test" "$repo_root/tests/contract"
  local entries=("${manifest_entries[@]}")

  for bin in guiassert guiassert-fixture; do
    [[ -x "$repo_root/build/bin/$bin" ]] ||
      fail "contract binary does not exist: $repo_root/build/bin/$bin"
    for entry in "${entries[@]}"; do
      echo "===== $entry ($bin) ====="
      GUIASSERT_CONTRACT_BIN="$repo_root/build/bin/$bin" \
        run_unittest_invocation "$entry ($bin)" \
          nim c -r --hints:off "$repo_root/tests/contract/$entry.nim"
      unittest_cases=$((unittest_cases + last_case_count))
      executed=$((executed + 1))
    done
  done

  (( executed == expected_contract_tests * 2 )) ||
    fail "executed $executed contract test files; expected $((expected_contract_tests * 2))"
  (( unittest_cases > 0 )) || fail "the contract suite executed zero unittest cases"
  echo "$executed/$((expected_contract_tests * 2)) contract test invocations passed ($unittest_cases unittest cases)"
}

case "${1:-}" in
  "")
    run_unit_tests "$default_unit_manifest" "$expected_default_unit_tests" "unit test"
    build_cli
    run_contract_tests
    echo "$((expected_default_unit_tests + expected_contract_tests * 2))/$((expected_default_unit_tests + expected_contract_tests * 2)) declared test invocations passed"
    ;;
  --nimble)
    run_unit_tests "$nimble_unit_manifest" "$expected_nimble_unit_tests" \
      "nimble unit test"
    ;;
  --units-only)
    run_unit_tests "$default_unit_manifest" "$expected_default_unit_tests" "unit test"
    ;;
  --build-only)
    build_cli
    ;;
  --contract-only)
    run_contract_tests
    ;;
  --check-unit-manifest)
    [[ -n "${2:-}" ]] || fail "--check-unit-manifest requires a path"
    load_manifest "$2" "$expected_default_unit_tests" "unit-test" "$repo_root/tests"
    ;;
  --check-nimble-manifest)
    [[ -n "${2:-}" ]] || fail "--check-nimble-manifest requires a path"
    load_manifest "$2" "$expected_nimble_unit_tests" "nimble-unit-test" \
      "$repo_root/tests"
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac
