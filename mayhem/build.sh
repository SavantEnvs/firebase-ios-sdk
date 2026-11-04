#!/usr/bin/env bash
#
# mayhem/build.sh — builds the Firestore core library directly from its sources (upstream's cmake
# build needs a grpc/protobuf/boringssl superbuild that is neither offline nor necessary for the
# parsing code the harnesses reach), then:
#   1. the 4 libFuzzer harnesses (+ run-once -standalone reproducers) with $SANITIZER_FLAGS, DWARF 3
#   2. the gtest oracle (upstream unit tests + mayhem/oracle_test.cc) with NORMAL flags
# Dependencies come from the image: absl + nanopb tarballs in /opt/toolchains, apt -dev packages.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

ABSL_SRC=/opt/toolchains/absl
RE2_SRC=/opt/toolchains/re2
NANOPB_SRC=/opt/toolchains/nanopb
B="$SRC/build"
rm -rf "$B"
mkdir -p "$B"

# Firestore cannot be built against Debian's absl (ABSL_OPTION_USE_STD_OPTIONAL=0 breaks its mixed
# absl::optional/std::optional use), so absl is built from the tarball Firestore itself pins.
build_absl() { # <name> <flags>
  cmake -S "$ABSL_SRC" -B "$B/$1-absl-b" -G Ninja -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="$2" -DCMAKE_C_FLAGS="$2" -DABSL_PROPAGATE_CXX_STD=ON \
    -DABSL_BUILD_TESTING=OFF -DABSL_USE_EXTERNAL_GOOGLETEST=OFF \
    -DABSL_ENABLE_INSTALL=ON -DCMAKE_INSTALL_PREFIX="$B/$1-absl" >/dev/null
  cmake --build "$B/$1-absl-b" -j"$MAYHEM_JOBS" >/dev/null
  cmake --install "$B/$1-absl-b" >/dev/null
  # re2 (used by Firestore's pipeline expression evaluator) must be built against the same absl, since
  # its public API uses absl::string_view; it installs into the same prefix.
  cmake -S "$RE2_SRC" -B "$B/$1-re2-b" -G Ninja -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="$2" -DCMAKE_PREFIX_PATH="$B/$1-absl" -DRE2_BUILD_TESTING=OFF \
    -DCMAKE_INSTALL_PREFIX="$B/$1-absl" >/dev/null
  cmake --build "$B/$1-re2-b" -j"$MAYHEM_JOBS" >/dev/null
  cmake --install "$B/$1-re2-b" >/dev/null
}

mkdir -p "$B/gen/Firestore/core/src/util"
printf '#define HAVE_OPENSSL_RAND_H 1\n' > "$B/gen/Firestore/core/src/util/config_detected.h"

# Firestore core minus the Apple/Windows/libdispatch platform files and the network layer.
sources() {
  { ls Firestore/core/src/{util,nanopb,model,model/mutation,immutable,index,local,core,bundle,credentials}/*.cc \
     Firestore/core/src/*.cc Firestore/core/src/api/{expressions,aggregate_expressions,stages,pipeline,realtime_pipeline,ordering,pipeline_result,source}.cc \
     Firestore/Protos/nanopb/*/*.cc Firestore/Protos/nanopb/*/*/*.cc Firestore/Protos/nanopb/*/*/*/*.cc \
     Firestore/core/src/remote/{serializer,bloom_filter,existence_filter,watch_change,remote_event,exponential_backoff,online_state_tracker}.cc \
    2>/dev/null || true; } | grep -v '_apple\|_win\|executor_libdispatch\|log_apple\|secure_random_arc4\|byte_stream_apple\|filesystem_apple'
}

DEFS="-DFIRESTORE_HAVE_CONFIG_DETECTED_H -DPB_FIELD_32BIT -DPB_ENABLE_MALLOC -DPB_NO_PACKED_STRUCTS=1 -DFIRFirestore_VERSION=0"
INCS_SRC="-I$SRC -I$SRC/Firestore/core/include -I$SRC/Firestore/Protos/nanopb -I$NANOPB_SRC -I$B/gen"

# build_lib <name> <flags>: $B/<name>-obj/*.o + $B/<name>/libfirestore_core.a (incl. nanopb runtime)
build_lib() {
  local name="$1" flags="$2" obj="$B/$1-obj"
  mkdir -p "$obj"
  sources | while read -r f; do
    echo "$CXX -std=c++17 -fexceptions $flags $DEFS -I$B/$name-absl/include $INCS_SRC -w -c $f -o $obj/$(echo "$f" | tr / _).o"
  done | xargs -P"$MAYHEM_JOBS" -I{} bash -c '{}'
  for f in pb_common pb_decode pb_encode; do
    $CC $flags $DEFS -c "$NANOPB_SRC/$f.c" -o "$obj/nanopb_$f.o"
  done
  mkdir -p "$B/$name"
  ar rcs "$B/$name/libfirestore_core.a" "$obj"/*.o
}

SYSLIBS="-lleveldb -lssl -lcrypto -lpthread"
absl_libs() { echo "-Wl,--start-group $(ls "$B/$1-absl/lib"/*.a) -Wl,--end-group"; }

# ---------------------------------------------------------------- 1. sanitized fuzz build
SAN="$SANITIZER_FLAGS $DEBUG_FLAGS"
# SanCov for the fuzzed library (Firestore core + nanopb runtime): the harness' own -fsanitize=fuzzer only
# instruments the harness TU, so without this libFuzzer sees only the harness' edges. absl/re2 stay
# uninstrumented (their edges would only dilute the guidance). Skipped when SANITIZER_FLAGS is empty:
# the -standalone reproducers then have no sanitizer runtime to provide the __sanitizer_cov_* callbacks.
if [ -n "$SANITIZER_FLAGS" ]; then : "${SANCOV=-fsanitize=fuzzer-no-link}"; else SANCOV=; fi
build_absl san "$SAN"
build_lib san "$SAN $SANCOV"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
$CXX $SAN -c mayhem/lsan_off.cc -o "$B/lsan_off.o"
$CXX -std=c++17 -fexceptions $SAN $DEFS -I"$B/san-absl/include" $INCS_SRC -w -c mayhem/pipeline_stub.cc -o "$B/pipeline_stub.o"

HARNESS_FLAGS="-std=c++17 -fexceptions $SAN $DEFS -I$B/san-absl/include $INCS_SRC -w"
harness_src() {
  case "$1" in
    serializer|resourcepath) echo mayhem/harnesses/$1_fuzzer.cc ;;
    *) echo "Firestore/fuzzing/$1_fuzzer.cc" ;;
  esac
}
for h in fieldpath resourcepath leveldb serializer; do
  # shellcheck disable=SC2046
  $CXX $HARNESS_FLAGS $LIB_FUZZING_ENGINE "$(harness_src $h)" "$B/lsan_off.o" "$B/pipeline_stub.o" \
    "$B/san/libfirestore_core.a" $(absl_libs san) "$B/san/libfirestore_core.a" $SYSLIBS \
    -o "$SRC/${h}_fuzzer"
  # shellcheck disable=SC2046
  $CXX $HARNESS_FLAGS "$(harness_src $h)" "$B/standalone_main.o" "$B/lsan_off.o" "$B/pipeline_stub.o" \
    "$B/san/libfirestore_core.a" $(absl_libs san) "$B/san/libfirestore_core.a" $SYSLIBS \
    -o "$SRC/${h}_fuzzer-standalone"
done

# ---------------------------------------------------------------- 2. oracle (normal flags)
NORM="-O1 $COVERAGE_FLAGS"
build_absl norm "$NORM"
build_lib norm "$NORM"

TESTS="Firestore/core/test/unit/model/resource_path_test.cc
Firestore/core/test/unit/model/database_id_test.cc
Firestore/core/test/unit/util/ordered_code_test.cc
Firestore/core/test/unit/util/string_util_test.cc
Firestore/core/test/unit/util/bits_test.cc
Firestore/core/test/unit/util/comparison_test.cc
Firestore/core/test/unit/util/hashing_test.cc
Firestore/core/test/unit/util/path_test.cc
Firestore/core/test/unit/util/string_format_test.cc
Firestore/core/test/unit/util/statusor_test.cc
mayhem/oracle_test.cc"
mkdir -p "$B/test-obj"
echo "$TESTS" | while read -r f; do
  echo "$CXX -std=c++17 -fexceptions $NORM $DEFS -I$B/norm-absl/include $INCS_SRC -w -c $f -o $B/test-obj/$(echo "$f" | tr / _).o"
done | xargs -P"$MAYHEM_JOBS" -I{} bash -c '{}'
# shellcheck disable=SC2046
$CXX $NORM "$B"/test-obj/*.o "$B/norm/libfirestore_core.a" $(absl_libs norm) "$B/norm/libfirestore_core.a" \
  -lgmock -lgtest -lgtest_main $SYSLIBS -o "$B/firestore_core_tests"
echo "build.sh: done"
