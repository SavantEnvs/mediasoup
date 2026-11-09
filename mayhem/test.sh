#!/usr/bin/env bash
#
# mayhem/test.sh — runs mediasoup's own Catch2 worker test suite (built by mayhem/build.sh with the
# project's normal flags) and reports CTRF counts. Asserts behavior: every TEST_CASE is a set of
# REQUIRE/CHECK known-answer checks over the parsers, RTP/RTCP/STUN/SCTP/BWE logic, etc.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
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

RUNNER="$SRC/worker/out/test-build/mediasoup-worker-test"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing — mayhem/build.sh should have built it" >&2
  emit_ctrf "catch2" 0 1 0
  exit 1
fi

# The suite's workdir is the worker source root (upstream's meson `test()` does the same).
cd "$SRC/worker"
OUT="$(mktemp)"
"$RUNNER" --colour-mode=none > "$OUT" 2>&1
RC=$?
tail -n 15 "$OUT"

# Catch2 summary: "All tests passed (A assertions in N test cases)" or
# "test cases: N | P passed | F failed [| S skipped]".
passed=0 ; failed=0 ; skipped=0
if grep -q '^All tests passed' "$OUT"; then
  passed="$(sed -n 's/^All tests passed (.* in \([0-9]*\) test case.*/\1/p' "$OUT" | tail -n 1)"
else
  line="$(grep -E '^test cases:' "$OUT" | tail -n 1)"
  passed="$(printf '%s' "$line" | sed -n 's/.*| *\([0-9]*\) passed.*/\1/p')"
  failed="$(printf '%s' "$line" | sed -n 's/.*| *\([0-9]*\) failed.*/\1/p')"
  skipped="$(printf '%s' "$line" | sed -n 's/.*| *\([0-9]*\) skipped.*/\1/p')"
fi
: "${passed:=0}" "${failed:=0}" "${skipped:=0}"

# A non-zero exit with no parsed failure (crash, abort mid-suite) is still a failure.
if [ "$RC" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
# No test ran at all is a failure too.
if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi

emit_ctrf "catch2" "$passed" "$failed" "$skipped"
