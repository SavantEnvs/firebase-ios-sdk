#!/usr/bin/env bash
#
# mayhem/test.sh — RUNs the gtest binary mayhem/build.sh produced (upstream's Firestore core unit
# tests for resource paths, ordered code, hashing, etc. plus mayhem/oracle_test.cc known-answer tests).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/build/firestore_core_tests"
if [ ! -x "$BIN" ]; then
  echo "test.sh: $BIN missing — mayhem/build.sh should have produced it" >&2
  emit_ctrf "gtest" 0 1 0
  exit 1
fi

out="$("$BIN" 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -n 40
passed=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9]*\) test.*/\1/p' | tail -n1)
failed=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9]*\) test.*/\1/p' | tail -n1)
skipped=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]*\) test.*/\1/p' | tail -n1)
passed=${passed:-0}; failed=${failed:-0}; skipped=${skipped:-0}
# A crash or non-zero exit with no parsed failure still counts as one failure.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
emit_ctrf "gtest" "$passed" "$failed" "$skipped"
