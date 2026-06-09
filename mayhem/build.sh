#!/usr/bin/env bash
# libyaml/mayhem/build.sh — autotools build (ASan+UBSan) of libyaml + 9 libFuzzer harnesses
# (each also built as a non-fuzzer -standalone reproducer), plus libyaml's own test suite built
# with NORMAL flags (a separate, clean build) so mayhem/test.sh only RUNS it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV (overridable). SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# --build-arg SANITIZER_FLAGS= is honored (builds with NO sanitizers, the program's natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# libyaml's autotools build is in-tree (no VPATH once the srcdir is configured), so we build the
# test suite FIRST with NORMAL flags, stash the runnable check programs, `make distclean`, THEN do
# the sanitized build the harnesses link against.

# ---------------------------------------------------------------------------
# 0) Build libyaml's own test suite with the project's NORMAL flags (no sanitizers) and stash the
#    check programs where test.sh looks (build-tests/tests/), so test.sh only RUNS them and stays
#    an honest functional oracle for PATCH.
# ---------------------------------------------------------------------------
./bootstrap
# Static-only so the check programs are self-contained binaries (no libyaml.so dependency that the
# later sanitized rebuild would clobber); test.sh then just runs them.
./configure --disable-shared --enable-static
make "-j$MAYHEM_JOBS"
# The 3 in-repo unit tests (tests/Makefile.am TESTS=) PLUS the two data-driven drivers
# (run-parser-test-suite / run-emitter-test-suite) that libyaml's own CI uses to exercise the
# parser/emitter against the yaml-test-suite corpus. test.sh runs all of them.
make "-j$MAYHEM_JOBS" -C tests \
  test-version test-reader test-nesting \
  run-parser-test-suite run-emitter-test-suite
mkdir -p "$SRC/build-tests/tests"
for t in test-version test-reader test-nesting run-parser-test-suite run-emitter-test-suite; do
  # With a static-only build the top-level name is usually the real binary; if libtool still made it
  # a wrapper, the real one is under .libs/. Pick whichever is a real ELF executable.
  if file "$SRC/tests/.libs/$t" 2>/dev/null | grep -q ELF; then
    cp "$SRC/tests/.libs/$t" "$SRC/build-tests/tests/$t"
  else
    cp "$SRC/tests/$t" "$SRC/build-tests/tests/$t"
  fi
done
make distclean

# ---------------------------------------------------------------------------
# 1) Build libyaml itself WITH $SANITIZER_FLAGS so the fuzzed code is instrumented.
#    Autotools, in-tree; produces the static lib at src/.libs/libyaml.a.
# ---------------------------------------------------------------------------
./bootstrap
./configure CC="$CC" CFLAGS="$SANITIZER_FLAGS"
make "-j$MAYHEM_JOBS"

# ---------------------------------------------------------------------------
# 2) Build each fuzz harness TWICE: once as the libFuzzer binary (/mayhem/<fuzzer>),
#    once as a non-fuzzer standalone reproducer (/mayhem/<fuzzer>-standalone) linking
#    $STANDALONE_FUZZ_MAIN. The harnesses are plain C (LLVMFuzzerTestOneInput), so $CC
#    links both; the standalone main is a C file with C linkage that resolves it directly.
#    Harnesses include "yaml.h" (include/) and "yaml_write_handler.h" (mayhem/).
# ---------------------------------------------------------------------------
LIBA="$SRC/src/.libs/libyaml.a"
for harness in "$SRC"/mayhem/*_fuzzer.c; do
  name=$(basename -s .c "$harness")

  $CC $SANITIZER_FLAGS -I"$SRC/include" -I"$SRC/mayhem" \
      "$harness" $LIB_FUZZING_ENGINE "$LIBA" -o "/mayhem/$name"

  $CC $SANITIZER_FLAGS -I"$SRC/include" -I"$SRC/mayhem" \
      "$harness" "$STANDALONE_FUZZ_MAIN" "$LIBA" -o "/mayhem/$name-standalone"
done
