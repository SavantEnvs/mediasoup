#!/usr/bin/env bash
#
# mayhem/build.sh — builds the mediasoup worker fuzzer (one libFuzzer binary, seven areas selected by
# MS_FUZZ_* env vars in the Mayhemfiles), its standalone reproducer, and the Catch2 test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Offline-safe: the Meson wraps
# are pre-fetched into $MESON_PACKAGE_CACHE_DIR by the Dockerfile; re-runnable on a clean tree.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS SRC

cd "$SRC/worker"

# Space-separated flags -> Meson array literal ("[]" when empty).
meson_array() {
  local out="" f
  for f in $1; do out+="${out:+,}'$f'"; done
  printf '[%s]' "$out"
}

# configure_build <dir> <extra meson args…>: fresh setup, or --reconfigure when the dir already exists
# (so changed flags are always re-applied on a re-run).
configure_build() {
  local dir="$1"; shift
  local mode=()
  [ -f "$dir/meson-info/meson-info.json" ] && mode=(--reconfigure)
  meson setup "${mode[@]}" --buildtype release -Db_ndebug=true "$@" "$dir"
}

# 1) The test suite first, with the project's NORMAL flags (no sanitizers, no instrumentation), so
#    mayhem/test.sh only runs it. Left at worker/out/test-build/mediasoup-worker-test.
configure_build out/test-build -Dms_build_tests=true \
  "-Dc_args=$(meson_array "$COVERAGE_FLAGS")" "-Dcpp_args=$(meson_array "$COVERAGE_FLAGS")" \
  "-Dc_link_args=$(meson_array "$COVERAGE_FLAGS")" "-Dcpp_link_args=$(meson_array "$COVERAGE_FLAGS")"
ninja -C out/test-build -j"$MAYHEM_JOBS" mediasoup-worker-test

# 2) The fuzzer, with the project and every subproject built under $SANITIZER_FLAGS + $DEBUG_FLAGS.
#    -fno-sanitize=function: OpenSSL's lhash/err tables call through casted function pointers, which
#    UBSan's function check turns into an abort on every input. Upstream's meson.build hard-codes
#    -fsanitize=address,undefined,fuzzer (and -g) on the fuzzer executable itself, so that part of the
#    sanitizer set cannot be switched off from here.
FLAGS="$SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS"
configure_build out/fuzzer-build -Dms_build_fuzzer=true -Db_sanitize=address -Db_lundef=false \
  "-Dc_args=$(meson_array "$FLAGS")" "-Dcpp_args=$(meson_array "$FLAGS")" \
  "-Dc_link_args=$(meson_array "$FLAGS")" "-Dcpp_link_args=$(meson_array "$FLAGS")"
# keeprsp preserves the link command, which is re-used below to relink with lsan_off.o and the standalone main.
ninja -C out/fuzzer-build -j"$MAYHEM_JOBS" -d keeprsp mediasoup-worker-fuzzer

# 3) Relink the fuzzer with the LSan off-switch, and a standalone (non-libFuzzer) reproducer.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o out/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o out/standalone_main.o

read -ra LINK_ARGS < out/fuzzer-build/mediasoup-worker-fuzzer.rsp || true  # no trailing newline => read returns 1
FUZZ_ARGS=() ; STANDALONE_ARGS=() ; skip=0
for a in "${LINK_ARGS[@]}"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -o) skip=1 ;;
    -fsanitize=address,undefined,fuzzer) FUZZ_ARGS+=("$a"); STANDALONE_ARGS+=(-fsanitize=address,undefined) ;;
    *) FUZZ_ARGS+=("$a"); STANDALONE_ARGS+=("$a") ;;
  esac
done
(
  cd out/fuzzer-build
  $CXX "${FUZZ_ARGS[@]}" ../lsan_off.o -o "$SRC/mediasoup-worker-fuzzer"
  $CXX "${STANDALONE_ARGS[@]}" ../lsan_off.o ../standalone_main.o -o "$SRC/mediasoup-worker-fuzzer-standalone"
)
