# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/savantenvs/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed DATE-tagged base (YYYYMMDD; shared by all integrations
# minted against it). Use the current dated tag; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/savantenvs/base:20261023

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
# Coverage (optional, off by default): instrument the TEST build to measure how much of the project
# the suite exercises — --build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping".
# Empty by default (no effect on the normal oracle build); build.sh appends it to the test build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# If mayhem/build.sh needs EXTRA apt packages, install them as root before the build
# (re-pin to SOURCE_DATE_EPOCH first for reproducibility — repro-sources-list.sh ships
# in the base):
#   USER root
#   RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
#       apt-get update && apt-get install -yq --no-install-recommends <pkgs> \
#    && rm -rf /var/lib/apt/lists/*
#   USER mayhem

# Build dependencies, installed as root before the (air-gapped) build. Firestore's cmake superbuild is
# not used (it downloads grpc/protobuf/boringssl); the sources build directly against apt -dev headers
# plus the tarballs Firestore pins for absl and nanopb (cmake/external/*.cmake, same sha256) and re2 2024-07-02,
# unpacked here so mayhem/build.sh needs no network.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        ca-certificates curl cmake ninja-build libgrpc++-dev libleveldb-dev libssl-dev \
        libgtest-dev libgmock-dev \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; mkdir -p /opt/toolchains/absl /opt/toolchains/nanopb /opt/toolchains/re2; \
    curl -fsSL -o /tmp/absl.tgz https://github.com/abseil/abseil-cpp/archive/20240722.1.tar.gz; \
    echo "40cee67604060a7c8794d931538cb55f4d444073e556980c88b6c49bb9b19bb7  /tmp/absl.tgz" | sha256sum -c -; \
    tar -xzf /tmp/absl.tgz -C /opt/toolchains/absl --strip-components=1; \
    curl -fsSL -o /tmp/nanopb.tgz https://github.com/nanopb/nanopb/archive/nanopb-0.3.9.8.tar.gz; \
    echo "2047ff111ca408c9b3c06a6774b723c1b1c9e31dc2320c61ee3abce93359eb30  /tmp/nanopb.tgz" | sha256sum -c -; \
    tar -xzf /tmp/nanopb.tgz -C /opt/toolchains/nanopb --strip-components=1; \
    curl -fsSL -o /tmp/re2.tgz https://github.com/google/re2/archive/refs/tags/2024-07-02.tar.gz; \
    echo "eb2df807c781601c14a260a507a5bb4509be1ee626024cb45acbd57cb9d4032b  /tmp/re2.tgz" | sha256sum -c -; \
    tar -xzf /tmp/re2.tgz -C /opt/toolchains/re2 --strip-components=1; \
    rm -f /tmp/absl.tgz /tmp/nanopb.tgz /tmp/re2.tgz; chmod -R a+rX /opt/toolchains/absl /opt/toolchains/nanopb /opt/toolchains/re2

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Anything a Dockerfile step materializes into the tree (downloaded fixtures, generated headers,
# vendored deps) MUST be committed or (re)created by build.sh: rlenv's patch grader runs
# `git clean -ffdX` before every graded build, so a gitignored, untracked file is gone by then and
# every honest patch scores zero (SPEC §6.2 item 16; verify-repo.sh checks it).
#
# OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). Bases minted with /opt/mayhem/ccache/prefill
# run the build under rlenv's pinned ccache, so the patch grader's first (otherwise cold) rebuild is
# warm — this is what keeps large C/C++ targets inside the build time limit. Older bases fall back to
# the plain build; a missing or stale pre-fill only costs a cold cache. Never enable ccache in
# build.sh or via ENV/PATH, and keep the compiler resolving by name (CC=clang) or nothing is cached.
RUN if [ -x /opt/mayhem/ccache/prefill ]; then /opt/mayhem/ccache/prefill bash mayhem/build.sh; \
    else bash mayhem/build.sh; fi

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
