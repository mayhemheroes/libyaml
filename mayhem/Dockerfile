# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/mayhemheroes/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed YEAR-MONTH base (shared by all integrations in that
# period). Bump deliberately; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/mayhemheroes/base:2026-06

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# To change it for a build (e.g. ASan-only, or add MSan): --build-arg SANITIZER_FLAGS="...".
# Declare it WITHOUT a default (no '='): an undefaulted ARG lets the base ENV flow through to
# build.sh when not passed, and an explicit --build-arg overrides it. (An empty default — `=` —
# would instead shadow the base ENV and silently wipe the sanitizers.)
ARG SANITIZER_FLAGS
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# Bake the data-driven oracle corpus into the image at BUILD time (network OK here), so
# mayhem/test.sh runs fully OFFLINE. libyaml's own CI tests the parser/emitter against the
# yaml-test-suite corpus, pinned per-master-commit via the `run-test-suite` branch's
# conf/pin.tsv + the test code/whitelists on the `run-test-suite-code` branch. For this
# repo's master HEAD the pin resolves to:
#   yaml-test-suite data ref : data-2020-02-11   (the per-case in.yaml/test.event/===/error)
#   run-test-suite-code      : 67365dd2af265f17ba6ee0832c1411e4fd80ac0b  (the blacklists)
# We clone the corpus to /opt/yaml-test-suite and the blacklists to /opt/run-test-suite-code;
# test.sh replicates the CI per-case comparison against these (golden-output, see test.sh).
# Re-pin SOURCE_DATE_EPOCH first for reproducible apt (repro-sources-list.sh ships in base).
ARG YAML_TEST_SUITE_DATA_REF=data-2020-02-11
ARG RUN_TEST_SUITE_CODE_REF=67365dd2af265f17ba6ee0832c1411e4fd80ac0b
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends ca-certificates git \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch "$YAML_TEST_SUITE_DATA_REF" \
      https://github.com/yaml/yaml-test-suite /opt/yaml-test-suite \
 && git -C /tmp clone --no-checkout --filter=blob:none \
      https://github.com/yaml/libyaml /opt/run-test-suite-code-git \
 && git -C /opt/run-test-suite-code-git checkout "$RUN_TEST_SUITE_CODE_REF" -- blacklist \
 && mkdir -p /opt/run-test-suite-code \
 && cp -r /opt/run-test-suite-code-git/blacklist /opt/run-test-suite-code/blacklist \
 && rm -rf /opt/run-test-suite-code-git /opt/yaml-test-suite/.git \
 && chown -R 2000:2000 /opt/yaml-test-suite /opt/run-test-suite-code
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
