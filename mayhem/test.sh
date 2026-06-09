#!/usr/bin/env bash
# libyaml/mayhem/test.sh — functional oracle for PATCH (GOLDEN-OUTPUT, anti-reward-hacking).
#
# Runs, against the binaries mayhem/build.sh produced with NORMAL flags under build-tests/tests:
#   1) libyaml's 3 in-repo unit tests   (test-version, test-reader, test-nesting)
#   2) libyaml's PRIMARY data-driven oracle — the parser/emitter drivers run against the baked
#      yaml-test-suite corpus, replicating libyaml's own CI (the `run-test-suite` /
#      `run-test-suite-code` branches). Each case COMPARES the driver's emitted event stream to
#      the corpus's golden test.event (parser), the emitted YAML to the golden out.yaml/in.yaml
#      (emitter), and requires error cases to actually error (parser-error). This is byte-for-byte
#      golden comparison: a libyaml patched to a no-op / exit(0) emits empty/wrong output → every
#      case MISMATCHES → failed>0 → non-zero exit. It is NOT "ran without crashing".
#
# Cases libyaml documents as not-yet-supported (the CI blacklists, baked at /opt/run-test-suite-code)
# are counted SKIPPED, never failed — exactly as the upstream CI excludes them.
#
# Does NOT compile: build.sh built everything; this only RUNS it and reports CTRF counts.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# Baked-in corpus + CI blacklists (see mayhem/Dockerfile). Overridable for local runs.
: "${YAML_TEST_SUITE_DIR:=/opt/yaml-test-suite}"
: "${RUN_TEST_SUITE_CODE_DIR:=/opt/run-test-suite-code}"
BLACKLIST_DIR="$RUN_TEST_SUITE_CODE_DIR/blacklist"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

TESTS_DIR="$SRC/build-tests/tests"
[ -d "$TESTS_DIR" ] || { echo "missing $TESTS_DIR — run mayhem/build.sh first" >&2; exit 2; }

PARSER="$TESTS_DIR/run-parser-test-suite"
EMITTER="$TESTS_DIR/run-emitter-test-suite"

passed=0; failed=0; skipped=0

# ---------------------------------------------------------------------------
# 1) The 3 in-repo unit tests (tests/Makefile.am: TESTS=...).
# ---------------------------------------------------------------------------
for t in test-version test-reader test-nesting; do
  bin="$TESTS_DIR/$t"
  [ -x "$bin" ] || { echo "missing test binary $bin — run mayhem/build.sh first" >&2; exit 2; }
  if "$bin"; then echo "PASS unit $t"; passed=$((passed+1)); else echo "FAIL unit $t"; failed=$((failed+1)); fi
done

# ---------------------------------------------------------------------------
# 2) Data-driven golden oracle over the yaml-test-suite corpus.
#    Per-case semantics replicate libyaml's run-test-suite-code .t scripts:
#      libyaml-parser.t        : valid cases (no `error` file) not blacklisted →
#                                run-parser-test-suite in.yaml MUST equal golden test.event
#      libyaml-parser-error.t  : error cases (`error` file present) not blacklisted →
#                                run-parser-test-suite in.yaml MUST exit non-zero
#      libyaml-emitter.t       : valid cases not blacklisted →
#                                run-emitter-test-suite test.event MUST equal out.yaml (or in.yaml)
#    Blacklisted cases are counted SKIPPED.
# ---------------------------------------------------------------------------
if [ ! -x "$PARSER" ] || [ ! -x "$EMITTER" ]; then
  echo "missing data-driven drivers under $TESTS_DIR — run mayhem/build.sh first" >&2; exit 2
fi
if [ ! -d "$YAML_TEST_SUITE_DIR" ]; then
  echo "missing corpus $YAML_TEST_SUITE_DIR — should be baked by mayhem/Dockerfile" >&2; exit 2
fi
for b in libyaml-parser libyaml-parser-error libyaml-emitter; do
  [ -f "$BLACKLIST_DIR/$b" ] || { echo "missing blacklist $BLACKLIST_DIR/$b — baked by Dockerfile" >&2; exit 2; }
done

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

# Blacklisted? (the .t scripts grep the bare case id against the blacklist file).
blacklisted() { grep -q "^$1:" "$BLACKLIST_DIR/$2"; }

cd "$YAML_TEST_SUITE_DIR"
# Case ids are 4-char [A-Z0-9] dirs at the corpus root, each with in.yaml + golden files.
for dir in [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]; do
  [ -d "$dir" ] || continue
  id="$dir"
  [ -e "$dir/in.yaml" ] || continue
  label="$id"; [ -e "$dir/===" ] && label="$id: $(< "$dir/===")"

  if [ -e "$dir/error" ]; then
    # ---- parser-error: driver MUST fail on invalid input ----
    if blacklisted "$id" libyaml-parser-error; then
      echo "SKIP parser-error $label"; skipped=$((skipped+1))
    elif "$PARSER" "$dir/in.yaml" >"$OUT" 2>&1; then
      echo "FAIL parser-error $label (parsed invalid input without error)"; failed=$((failed+1))
    else
      echo "PASS parser-error $label"; passed=$((passed+1))
    fi
  else
    # ---- parser: emitted events MUST equal golden test.event ----
    if blacklisted "$id" libyaml-parser; then
      echo "SKIP parser $label"; skipped=$((skipped+1))
    elif "$PARSER" "$dir/in.yaml" >"$OUT" 2>/dev/null && diff -u "$dir/test.event" "$OUT" >/dev/null; then
      echo "PASS parser $label"; passed=$((passed+1))
    else
      echo "FAIL parser $label (events != golden test.event)"; failed=$((failed+1))
    fi

    # ---- emitter: emitted YAML MUST equal golden out.yaml (or in.yaml) ----
    want="$dir/out.yaml"; [ -e "$want" ] || want="$dir/in.yaml"
    if blacklisted "$id" libyaml-emitter; then
      echo "SKIP emitter $label"; skipped=$((skipped+1))
    elif "$EMITTER" "$dir/test.event" >"$OUT" 2>/dev/null && diff -u "$want" "$OUT" >/dev/null; then
      echo "PASS emitter $label"; passed=$((passed+1))
    else
      echo "FAIL emitter $label (emitted YAML != golden)"; failed=$((failed+1))
    fi
  fi
done

cd "$SRC"
echo "---"
echo "passed=$passed failed=$failed skipped=$skipped"
emit_ctrf "libyaml-test-suite" "$passed" "$failed" "$skipped"
