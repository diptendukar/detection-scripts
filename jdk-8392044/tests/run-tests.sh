#!/usr/bin/env bash
#
# Tests detect-jdk-8392044.sh on a Linux x86-64 host (GitHub ubuntu runner).
#
#   1. Decision logic: tests/fake-java drives every branch.
#   2. Real JDKs: each JAVA_HOME_<n>_X64 is checked against an expected verdict
#      derived independently from that JVM's own CPU log.
#   3. Running JVMs: held at startup with -XX:+PauseAtStartup; command-line
#      and environment flags must be replayed; replaced binaries -> unknown;
#      JVMs embedded via libjvm.so must be found.
#   4. Root only: a JVM in a Docker container must be probed via nsenter.
#   5. Default full-host runs must give consistent exit codes and verdicts.
#
# usage: run-tests.sh [--container-image IMAGE]   (needs passwordless sudo
#        and docker for section 4; skipped otherwise)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../detect-jdk-8392044.sh"
FAKE="$HERE/fake-java"
IMAGE=""
[ "${1:-}" = "--container-image" ] && IMAGE="${2:-}"

PASS=0
FAIL=0
WORK=$(mktemp -d)
PIDS=""
CONTAINER=""

cleanup() {
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    [ -n "$CONTAINER" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

verdict() {
    case "$1" in
        0) echo "not impacted" ;;
        1) echo "impacted" ;;
        2) echo "unknown" ;;
        *) echo "" ;;
    esac
}

# run CMD... : sets OUT, CODE, LAST
run() {
    OUT=$("$@" 2>&1)
    CODE=$?
    LAST=$(printf '%s\n' "$OUT" | sed '/^[[:space:]]*$/d' | tail -1)
}

# check NAME WANT_CODE [MUST_CONTAIN]...
check() {
    local name=$1 want=$2 ok=1 c
    shift 2
    [ "$CODE" = "$want" ] || ok=0
    if [ "$want" != 3 ] && [ "$LAST" != "$(verdict "$want")" ]; then ok=0; fi
    for c in "$@"; do
        printf '%s\n' "$OUT" | grep -qF -- "$c" || ok=0
    done
    # Fleet agents often run scripts with SIGPIPE ignored; stray write
    # errors on stderr are a failure.
    if printf '%s\n' "$OUT" | grep -qE 'Broken pipe|write error'; then ok=0; fi
    if [ "$ok" -eq 1 ]; then
        PASS=$((PASS + 1))
        echo "PASS  $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL  $name (want exit $want '$(verdict "$want")' containing [$*]; got exit $CODE)"
        printf '%s\n' "$OUT" | sed 's/^/      | /'
    fi
}

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# Independent oracle: sets F_VER, F_CPU, F_WANT for java $1.
facts() {
    F_VER=$("$1" -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java\.version = //p' | head -1)
    F_CPU=$("$1" -Xlog:os+cpu=info -version 2>&1 | grep -m1 'os,cpu.*CPU:' || true)
    F_WANT=0
    if printf '%s' "$F_CPU" | grep -qE '(^|[ ,])avx512_vbmi(,|$)' &&
        printf '%s' "$F_CPU" | grep -qE '(^|[ ,])avx512bw(,|$)' &&
        ver_ge "$F_VER" 17.0.6; then
        F_WANT=1
    fi
}

# start_paused JAVA [FLAGS...] : starts a JVM held at startup; sets PAUSED_PID
start_paused() {
    local java=$1 d
    shift
    d=$(mktemp -d "$WORK/p.XXXX")
    (cd "$d" && exec "$java" -XX:+UnlockDiagnosticVMOptions -XX:+PauseAtStartup "$@" -version >/dev/null 2>&1) &
    PAUSED_PID=$!
    PIDS="$PIDS $PAUSED_PID"
    for _ in $(seq 1 120); do
        [ -e "$d/vm.paused.$PAUSED_PID" ] && return 0
        sleep 0.25
    done
    echo "warning: JVM $PAUSED_PID never paused"
}

stop() { kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

echo "bash: $BASH_VERSION"
grep -m1 'model name' /proc/cpuinfo

# --- 1. Decision logic ----------------------------------------------------------

echo
echo "## Decision logic (fake java)"
F=(bash "$S" --no-procs --no-disk -j "$FAKE")

run "${F[@]}";                                         check "default fake 17.0.9 -> impacted" 1 "AVX-512 Base64 decode stub active"
run "${F[@]}" -q;                                      check "quiet prints verdict only" 1
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] || { FAIL=$((FAIL + 1)); echo "FAIL  quiet printed more than one line"; }
run env FAKE_VER=17.0.6 "${F[@]}";                     check "17.0.6 boundary -> impacted" 1
run env FAKE_VER=17.0.5 "${F[@]}";                     check "17.0.5 -> ok" 0 "older than 17.0.6"
run env FAKE_VER=1.8.0_392 "${F[@]}";                  check "1.8.0_392 -> ok" 0 "older than 17.0.6"
run env FAKE_VER=27.0.1.0.3 "${F[@]}";                 check "27.0.1.0.3 no fix list -> impacted" 1
run env FAKE_VER=21.0.11 JDK8392044_FIXED_IN="17.0.19 21.0.11" "${F[@]}"; check "fixed via env" 0 "fixed version"
run env FAKE_VER=21.0.10 JDK8392044_FIXED_IN="17.0.19 21.0.11" "${F[@]}"; check "below fix via env" 1
run env FAKE_VER=27.0.1 JDK8392044_FIXED_IN="17.0.19 25.0.3" "${F[@]}";   check "later major than top fix" 0 "fixed version"
run env FAKE_FEATURES="avx512f, avx512bw, avx512_vbmi2" "${F[@]}"; check "vbmi2 without vbmi -> ok" 0 "no AVX-512 VBMI/BW"
run env FAKE_FEATURES="avx512f, avx512_vbmi" "${F[@]}";            check "vbmi without bw -> ok" 0 "no AVX-512 VBMI/BW"
run env FAKE_VM="Eclipse OpenJ9 VM" "${F[@]}";         check "OpenJ9 -> ok" 0 "not HotSpot"
run env FAKE_ARCH=aarch64 "${F[@]}";                   check "aarch64 JVM -> ok" 0 "os.arch=aarch64"
run env FAKE_ARCH=i386 "${F[@]}";                      check "32-bit JVM -> ok" 0 "os.arch=i386"
HOST_VBMI=0
grep -m1 '^flags' /proc/cpuinfo | grep -qw avx512vbmi && grep -m1 '^flags' /proc/cpuinfo | grep -qw avx512bw && HOST_VBMI=1
run env FAKE_NOCPULOG=1 "${F[@]}";                     check "no CPU log falls back to OS view (host VBMI=$HOST_VBMI)" "$HOST_VBMI"
run "${F[@]}" -o "-XX:UseAVX=2";                       check "-o UseAVX=2" 0 "UseAVX=2"
run env JDK8392044_JVM_OPTIONS="-XX:UseAVX=2" "${F[@]}"; check "UseAVX=2 via env" 0 "UseAVX=2"
run env JDK8392044_JVM_OPTIONS="-XX:UseAVX=2" "${F[@]}" -o "-XX:UseAVX=3"; check "-o overrides env" 1
run "${F[@]}" -o "-javaagent:/nope.jar -XX:+UseBASE64Intrinsics"; check "agent option is not replayed" 1
run "${F[@]}" -o "-XX:-UseBASE64Intrinsics";           check "-UseBASE64Intrinsics" 0 "mitigated"
run "${F[@]}" -o "-XX:DisableIntrinsic=_base64_decodeBlock"; check "DisableIntrinsic" 0 "mitigated, DisableIntrinsic"
run "${F[@]}" -o "-Xint";                              check "-Xint" 0 "interpreter only"
run "${F[@]}" -o "-XX:TieredStopAtLevel=1";            check "TieredStopAtLevel=1" 0 "TieredStopAtLevel=1"
run env JAVA_TOOL_OPTIONS=-XX:-UseBASE64Intrinsics "${F[@]}"; check "JAVA_TOOL_OPTIONS mitigates" 0 "mitigated"
run env JAVA_TOOL_OPTIONS=-XX:-UseBASE64Intrinsics _JAVA_OPTIONS=-XX:+UseBASE64Intrinsics "${F[@]}"; check "_JAVA_OPTIONS overrides JAVA_TOOL_OPTIONS" 1
run bash "$S" --no-procs --no-disk -j /nope/java;      check "missing -j path -> unknown" 2 "not an executable file"
run bash "$S" --bogus;                                 check "bad argument -> 3" 3
run bash "$S" -j;                                      check "-j without value -> 3" 3

# --- 2. Real JDKs --------------------------------------------------------------

echo
echo "## Real JDKs"
MODERN=""
for var in $(env | grep -oE '^JAVA_HOME_[0-9]+_X64' | sort -t_ -k3 -n); do
    j="${!var}/bin/java"
    [ -x "$j" ] || continue
    facts "$j"
    echo "JDK $F_VER at $j; JVM CPU line: ${F_CPU:-(none)}"
    run bash "$S" --no-procs --no-disk -j "$j"
    check "real JDK $F_VER" "$F_WANT" "$F_VER"
    if ver_ge "$F_VER" 17.0.6; then MODERN=$j; MODERN_WANT=$F_WANT; fi
done
if [ -z "$MODERN" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL  no JDK >= 17.0.6 found via JAVA_HOME_<n>_X64"
    exit 1
fi

# --- 3. Running JVMs ------------------------------------------------------------

echo
echo "## Running JVMs ($MODERN)"
P=(bash "$S" --no-disk)

start_paused "$MODERN" -XX:UseAVX=2
run "${P[@]}"; check "running JVM, command-line UseAVX=2 replayed" 0 "pid $PAUSED_PID " "UseAVX=2, AVX-512 stub not generated"
stop "$PAUSED_PID"

export JAVA_TOOL_OPTIONS=-XX:UseAVX=2
start_paused "$MODERN"
unset JAVA_TOOL_OPTIONS
run "${P[@]}"; check "running JVM, JAVA_TOOL_OPTIONS from /proc environ replayed" 0 "pid $PAUSED_PID " "UseAVX=2"
stop "$PAUSED_PID"

start_paused "$MODERN"
run "${P[@]}"; check "running JVM, default flags" "$MODERN_WANT" "pid $PAUSED_PID "
stop "$PAUSED_PID"

# A JDK upgraded under a running JVM: the old binary is gone.
cp -a "$(dirname "$(dirname "$MODERN")")" "$WORK/jdk-copy"
start_paused "$WORK/jdk-copy/bin/java"
rm -rf "$WORK/jdk-copy"
run "${P[@]}"; check "running JVM whose binary was deleted -> unknown" 2 "pid $PAUSED_PID" "replaced on disk"
stop "$PAUSED_PID"

# A JVM embedded in a non-java process.
LIBJVM="$(dirname "$(dirname "$MODERN")")/lib/server/libjvm.so"
if cc -o "$WORK/embed-jvm" "$HERE/embed-jvm.c" -ldl 2>"$WORK/cc.err"; then
    "$WORK/embed-jvm" "$LIBJVM" &
    EPID=$!
    PIDS="$PIDS $EPID"
    sleep 2
    run "${P[@]}"; check "embedded libjvm.so found" "$MODERN_WANT" "pid $EPID " "[JVM embedded in $WORK/embed-jvm]"
    stop "$EPID"
else
    FAIL=$((FAIL + 1)); echo "FAIL  could not build embed-jvm"; sed 's/^/      | /' "$WORK/cc.err"
fi

# --- 4. Container JVM via nsenter (root) ---------------------------------------

echo
echo "## Container JVM"
if [ -n "$IMAGE" ] && sudo -n true 2>/dev/null && command -v docker >/dev/null; then
    CONTAINER=$(docker run -d --rm -w /tmp "$IMAGE" \
        java -XX:+UnlockDiagnosticVMOptions -XX:+PauseAtStartup -XX:UseAVX=2 -version)
    CPID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")
    for _ in $(seq 1 120); do
        docker exec "$CONTAINER" sh -c 'ls /tmp/vm.paused.* >/dev/null 2>&1' && break
        sleep 0.5
    done
    run sudo -n bash "$S" --no-disk
    check "container JVM probed via nsenter" 0 "pid $CPID " "[container]" "UseAVX=2"

    run bash "$S" --no-disk
    check "container JVM without root -> unknown" 2 "pid $CPID"
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    CONTAINER=""
else
    echo "SKIP  container test (needs --container-image, passwordless sudo and docker)"
fi

# --- 5. Default full-host runs ------------------------------------------------------
# Run with SIGPIPE ignored, as many fleet agents do. Pipes inside the script
# must not then leak "write error: Broken pipe" to stderr.
IGNPIPE=(bash -c 'trap "" PIPE; exec bash "$0" "$@"' "$S")

echo
echo "## Default full-host runs"
for mode in user root; do
    if [ "$mode" = root ]; then
        sudo -n true 2>/dev/null || { echo "SKIP  root run"; continue; }
        run sudo -n "${IGNPIPE[@]}"
    else
        run "${IGNPIPE[@]}"
    fi
    printf '%s\n' "$OUT" | sed 's/^/      | /'
    if [ "$CODE" -le 2 ] && [ "$LAST" = "$(verdict "$CODE")" ] &&
        ! printf '%s\n' "$OUT" | grep -qE 'Broken pipe|write error'; then
        PASS=$((PASS + 1)); echo "PASS  default $mode run consistent (exit $CODE, '$LAST')"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  default $mode run inconsistent (exit $CODE, last line '$LAST')"
    fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
