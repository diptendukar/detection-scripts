#!/usr/bin/env bash
#
# detect-jdk-8392044.sh
#
# Checks whether this host has a JVM exposed to JDK-8392044: the HotSpot
# x86-64 AVX-512 Base64 decodeBlock stub stores a full 64-byte vector past the
# destination buffer when a 1-3 byte input tail ends in '='.
#
# A JVM counts as impacted when all of these hold:
#   1. HotSpot VM: OpenJDK and its builds (Temurin, Corretto, Zulu, Red Hat,
#      Microsoft, Liberica, Oracle JDK, GraalVM JDK). OpenJ9 has no such stub.
#   2. 64-bit x86 JVM (os.arch amd64 / x86_64) on an x86-64 host.
#   3. Version 17.0.6 or later, and older than any fix listed in FIXED_IN.
#   4. The JVM reports AVX-512 VBMI and AVX-512 BW and runs with UseAVX >= 3.
#      That is when HotSpot generates the AVX-512 decode stub.
#   5. Base64 intrinsics are on and the top-tier JIT can use them: not -Xint,
#      not TieredStopAtLevel < 4, not DisableIntrinsic=_base64_decodeBlock.
#
# Conditions 4 and 5 are read from the JVM itself. Each JVM is started with
# -version plus the -XX flags the running process was launched with, so the
# result reflects CPU masking by hypervisors and kernels as well as tuning.
#
# What gets checked:
#   - java on PATH, JAVA_HOME, and common install directories
#   - every running JVM, including JVMs embedded in other programs (libjvm.so)
#   - JVMs in containers (Linux, root, via nsenter)
#   - any java binary passed with -j
#
# Flags are taken from each process's command line and, when readable, its
# JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS and _JAVA_OPTIONS. Flags files
# (-XX:Flags=, -XX:VMOptionsFile=, @argfiles) are not parsed; such JVMs are
# flagged in the output. Only flags that affect the verdict are replayed, so
# probing never loads agents or application code.
#
# Exit codes, for fleet tooling:
#   0  not impacted
#   1  impacted: at least one JVM meets all conditions
#   2  unknown: at least one JVM could not be evaluated and none is impacted
#   3  usage error
#
# The last line of output is always exactly one of:
#   impacted | not impacted | unknown
#
# Works with bash 3.2 (macOS) and later. Run as root for full coverage of
# other users' processes and containers.

set -u
set -f

# Versions that contain the fix, one per feature release, space separated.
# None was public as of 2026-11-16. The highest entry also covers every later
# feature release. Example: "17.0.19 21.0.11 25.0.3 26.0.1"
FIXED_IN="${JDK8392044_FIXED_IN:-}"
PROBE_TIMEOUT="${JDK8392044_PROBE_TIMEOUT:-30}"

QUIET=0
VERBOSE=0
SCAN_PROCS=1
SCAN_DISK=1
EXTRA_JAVAS=""
EXTRA_OPTS="${JDK8392044_JVM_OPTIONS:-}"

usage() {
    cat <<'EOF'
usage: detect-jdk-8392044.sh [-q] [-v] [-j /path/to/java]... [-o "JVM options"]
                             [--no-procs] [--no-disk]

  -q, --quiet      print only the verdict line
  -v, --verbose    print diagnostic detail
  -j, --java PATH  also check this java binary (repeatable)
  -o, --jvm-opts   JVM options to apply when probing installed (not running)
                   JVMs, e.g. "-XX:UseAVX=2"
  --no-procs       skip running processes
  --no-disk        skip installed JVMs on disk

Exit: 0 not impacted, 1 impacted, 2 unknown, 3 usage error.
Env:  JDK8392044_FIXED_IN="17.0.19 21.0.11 ..."  JDK8392044_PROBE_TIMEOUT=30
      JDK8392044_JVM_OPTIONS (same as -o)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -j|--java)
            [ $# -ge 2 ] || { usage >&2; exit 3; }
            EXTRA_JAVAS="$EXTRA_JAVAS$2
"
            shift ;;
        -o|--jvm-opts)
            [ $# -ge 2 ] || { usage >&2; exit 3; }
            EXTRA_OPTS="$2"
            shift ;;
        --no-procs) SCAN_PROCS=0 ;;
        --no-disk) SCAN_DISK=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 3 ;;
    esac
    shift
done

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t jdk8392044) || { echo unknown; exit 2; }
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/cands"
: > "$TMP/procs"

TO=""
if command -v timeout >/dev/null 2>&1; then
    TO="timeout $PROBE_TIMEOUT"
elif command -v gtimeout >/dev/null 2>&1; then
    TO="gtimeout $PROBE_TIMEOUT"
fi

N_IMPACTED=0
N_UNKNOWN=0
N_OK=0

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
dbg() { [ "$VERBOSE" -eq 1 ] && printf 'debug: %s\n' "$*" >&2; return 0; }

report() {
    local status=$1
    shift
    case "$status" in
        impacted) N_IMPACTED=$((N_IMPACTED + 1)); say "[IMPACTED] $*" ;;
        unknown)  N_UNKNOWN=$((N_UNKNOWN + 1));   say "[UNKNOWN]  $*" ;;
        *)        N_OK=$((N_OK + 1));             say "[ok]       $*" ;;
    esac
}

finish() {
    if [ "$N_IMPACTED" -gt 0 ]; then
        echo "impacted"; exit 1
    elif [ "$N_UNKNOWN" -gt 0 ]; then
        echo "unknown"; exit 2
    fi
    [ "$N_OK" -eq 0 ] && say "no JVMs found"
    echo "not impacted"; exit 0
}

HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)
IS_ROOT=0
[ "$(id -u)" = 0 ] && IS_ROOT=1

case "$HOST_ARCH" in
    x86_64|amd64|AMD64) ;;
    *) say "host architecture is $HOST_ARCH, not x86-64"; echo "not impacted"; exit 0 ;;
esac

# AVX-512 VBMI + BW as the OS reports them: yes, no or unknown. Used only when
# a JVM does not log its own CPU features.
host_cpu() {
    local f=""
    case "$HOST_OS" in
        Linux)  f=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) ;;
        Darwin) f=$(sysctl -n machdep.cpu.leaf7_features 2>/dev/null) ;;
    esac
    [ -n "$f" ] || { echo unknown; return; }
    has_vbmi_bw "$f"
}

# $1: feature list separated by spaces or commas, any case, with or without
# underscores (HotSpot says avx512_vbmi, Linux avx512vbmi, macOS AVX512VBMI).
has_vbmi_bw() {
    local f
    f=" $(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '_' | tr ',\t' '  ') "
    case "$f" in *" avx512vbmi "*) ;; *) echo no; return ;; esac
    case "$f" in *" avx512bw "*) echo yes ;; *) echo no ;; esac
}

HOST_CPU=$(host_cpu)
dbg "host $HOST_OS $HOST_ARCH, OS-reported AVX-512 VBMI+BW: $HOST_CPU"

# "17.0.6", "1.8.0_392", "21", "17.0.6+10", "27.0.1.0.3" -> sortable integer
ver_key() {
    local v=$1
    case "$v" in 1.*) v=${v#1.} ;; esac
    v=$(printf '%s' "$v" | sed 's/[^0-9]/./g; s/\.\.*/./g; s/^\.//')
    local IFS=.
    set -- $v
    echo $(( 10#${1:-0} * 1000000 + 10#${2:-0} * 1000 + 10#${3:-0} ))
}

MIN_KEY=$(ver_key 17.0.6)

is_fixed() {
    local k f fk top=0
    k=$(ver_key "$1")
    for f in $FIXED_IN; do
        fk=$(ver_key "$f")
        [ $((fk / 1000000)) -gt "$top" ] && top=$((fk / 1000000))
        if [ $((fk / 1000000)) -eq $((k / 1000000)) ] && [ "$k" -ge "$fk" ]; then
            return 0
        fi
    done
    [ "$top" -gt 0 ] && [ $((k / 1000000)) -gt "$top" ]
}

# Keep only the options that change the verdict. Reads one token per line.
filter_flags() {
    grep -E '^-XX:([+-](UseBASE64Intrinsics|UnlockDiagnosticVMOptions|UseCompiler|TieredCompilation|EnableJVMCI|UseJVMCICompiler)|(UseAVX|TieredStopAtLevel|DisableIntrinsic)=[^ ]*)$|^-Xint$' || true
}

# $1 output, $2 property name
# Here-strings, not printf pipes: with SIGPIPE ignored (common under fleet
# agents) an early-exiting reader makes printf report write errors.
prop() { sed -n "s/^ *$2 = //p" <<<"$1" | head -1; }

# $1 PrintFlagsFinal output, $2 flag name. Empty ccstr values print as "".
flagval() {
    awk -v n="$2" '$2 == n { v = $4; if (v ~ /^\{/) v = ""; print v; exit }' <<<"$1"
}

# probe LABEL PREFIX JAVA FLAGS NOTE
#   PREFIX: command prefix such as "nsenter -t PID --mount --root", or empty
#   FLAGS:  space separated options from filter_flags
probe() {
    local label=$1 prefix=$2 java=$3 flags=$4 note=$5
    local h o1 o2 ver vm arch k desc useavx b64 comp tiered stop dis cpuline vbmi

    h=$(printf '%s|%s|%s' "$prefix" "$java" "$flags" | cksum | tr -c '0-9\n' _)
    if [ -f "$TMP/$h.1" ]; then
        o1=$(cat "$TMP/$h.1")
    else
        # shellcheck disable=SC2086
        o1=$(env -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS \
            $TO $prefix "$java" -XshowSettings:properties -version 2>&1 </dev/null)
        printf '%s\n' "$o1" > "$TMP/$h.1"
    fi

    ver=$(prop "$o1" java.version)
    vm=$(prop "$o1" java.vm.name)
    arch=$(prop "$o1" os.arch)
    if [ -z "$ver" ]; then
        report unknown "$label $java$note: could not run it: $(head -1 <<<"$o1")"
        return
    fi
    desc="$label $java ($ver, $vm)$note"

    case "$vm" in
        *OpenJ9*|*J9*) report ok "$desc: not HotSpot"; return ;;
    esac
    case "$arch" in
        amd64|x86_64) ;;
        *) report ok "$desc: os.arch=$arch"; return ;;
    esac
    k=$(ver_key "$ver")
    if [ "$k" -lt "$MIN_KEY" ]; then
        report ok "$desc: older than 17.0.6"; return
    fi
    if is_fixed "$ver"; then
        report ok "$desc: fixed version"; return
    fi

    if [ -f "$TMP/$h.2" ]; then
        o2=$(cat "$TMP/$h.2")
    else
        # shellcheck disable=SC2086
        o2=$(env -u JAVA_TOOL_OPTIONS -u _JAVA_OPTIONS -u JDK_JAVA_OPTIONS \
            $TO $prefix "$java" -XX:+IgnoreUnrecognizedVMOptions -XX:+UnlockDiagnosticVMOptions \
            $flags -Xlog:os+cpu=info -XX:+PrintFlagsFinal -version 2>&1 </dev/null)
        printf '%s\n' "$o2" > "$TMP/$h.2"
    fi

    useavx=$(flagval "$o2" UseAVX)
    b64=$(flagval "$o2" UseBASE64Intrinsics)
    comp=$(flagval "$o2" UseCompiler)
    tiered=$(flagval "$o2" TieredCompilation)
    stop=$(flagval "$o2" TieredStopAtLevel)
    dis=$(flagval "$o2" DisableIntrinsic)
    dbg "$java flags[$flags] UseAVX=$useavx b64=$b64 comp=$comp tiered=$tiered stop=$stop dis=$dis"

    case "$useavx" in
        ''|*[!0-9]*) report unknown "$desc: could not read VM flags"; return ;;
    esac
    if [ "$useavx" -lt 3 ]; then
        report ok "$desc: UseAVX=$useavx, AVX-512 stub not generated"; return
    fi

    cpuline=$(grep -m1 'os,cpu.*CPU:' <<<"$o2" | sed 's/^.*CPU://')
    if [ -n "$cpuline" ]; then
        vbmi=$(has_vbmi_bw "$cpuline")
    else
        vbmi=$HOST_CPU
        dbg "$java did not log CPU features; using OS view ($HOST_CPU)"
    fi
    case "$vbmi" in
        no) report ok "$desc: no AVX-512 VBMI/BW visible to the JVM"; return ;;
        unknown) report unknown "$desc: could not determine AVX-512 VBMI support"; return ;;
    esac

    if [ "$b64" = false ]; then
        report ok "$desc: mitigated, -XX:-UseBASE64Intrinsics"; return
    fi
    case "$dis" in
        *_base64_decodeBlock*) report ok "$desc: mitigated, DisableIntrinsic=$dis"; return ;;
    esac
    if [ "$comp" = false ]; then
        report ok "$desc: interpreter only"; return
    fi
    if [ "$tiered" = true ]; then
        case "$stop" in
            [0-3]) report ok "$desc: TieredStopAtLevel=$stop, no top-tier JIT"; return ;;
        esac
    fi

    report impacted "$desc: AVX-512 Base64 decode stub active (UseAVX=$useavx)"
}

resolve() {
    readlink -f "$1" 2>/dev/null || realpath "$1" 2>/dev/null || printf '%s\n' "$1"
}

add_cand() {
    local r
    [ -f "$1" ] && [ -x "$1" ] || return 0
    r=$(resolve "$1")
    grep -qxF "$r" "$TMP/cands" || printf '%s\n' "$r" >> "$TMP/cands"
}

discover_disk() {
    local j p
    j=$(command -v java 2>/dev/null) || j=""
    # On macOS /usr/bin/java is a stub that may prompt to install a JDK.
    if [ -n "$j" ] && ! { [ "$HOST_OS" = Darwin ] && [ "$j" = /usr/bin/java ]; }; then
        add_cand "$j"
    fi
    [ -n "${JAVA_HOME:-}" ] && add_cand "$JAVA_HOME/bin/java"
    set +f
    for p in /usr/lib/jvm/*/bin/java /usr/java/*/bin/java /usr/local/java/*/bin/java \
             /opt/*/bin/java /opt/*/*/bin/java /opt/*/*/*/bin/java \
             /usr/local/opt/openjdk*/bin/java /usr/local/Cellar/openjdk*/*/bin/java \
             /Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java \
             /root/.sdkman/candidates/java/*/bin/java /home/*/.sdkman/candidates/java/*/bin/java \
             /root/.jdks/*/bin/java /home/*/.jdks/*/bin/java \
             /Users/*/Library/Java/JavaVirtualMachines/*/Contents/Home/bin/java; do
        add_cand "$p"
    done
    set -f
}

# One line per process: pid, prefix, java, flags, note; separated by \037.
SEP=$(printf '\037')

proc_line() { printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$SEP" "$2" "$SEP" "$3" "$SEP" "$4" "$SEP" "$5" >> "$TMP/procs"; }

flagfile_note() {
    if grep -qE '^-XX:(Flags|VMOptionsFile)=|^@' ; then
        printf ' [flags file or @argfile not parsed]'
    fi
}

scan_procs_linux() {
    local d pid exe argv0 java note lib flags prefix ns self_ns envr
    self_ns=$(readlink /proc/self/ns/mnt 2>/dev/null) || self_ns=""
    set +f
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [ "$pid" = "$$" ] && continue
        [ -r "$d/cmdline" ] || continue
        argv0=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)
        exe=$(readlink "$d/exe" 2>/dev/null) || exe=""
        note=""
        case "$exe" in
            */java|*/java" (deleted)")
                java=$exe ;;
            "")
                case "$argv0" in
                    /*/java) java=$argv0; note=" [exe unreadable, used argv[0]]" ;;
                    java|*/java) report unknown "pid $pid ($argv0): cannot resolve its java binary; run as root"; continue ;;
                    *) continue ;;
                esac ;;
            *)
                lib=$(grep -m1 -o '/[^ ]*/libjvm\.so' "$d/maps" 2>/dev/null) || continue
                [ -n "$lib" ] || continue
                java="${lib%/lib/*/libjvm.so}/bin/java"
                note=" [JVM embedded in $exe]" ;;
        esac
        case "$java" in
            *" (deleted)")
                report unknown "pid $pid: running JVM ${java% (deleted)} was replaced on disk after start; restart it or check the old version"
                continue ;;
        esac

        envr=""
        [ -r "$d/environ" ] && envr=$(tr '\0' '\n' < "$d/environ" 2>/dev/null)
        # Option precedence: JAVA_TOOL_OPTIONS < JDK_JAVA_OPTIONS < command line < _JAVA_OPTIONS
        flags=$( {
            printf '%s\n' "$envr" | sed -n 's/^JAVA_TOOL_OPTIONS=//p' | tr ' \t' '\n\n'
            printf '%s\n' "$envr" | sed -n 's/^JDK_JAVA_OPTIONS=//p' | tr ' \t' '\n\n'
            tr '\0' '\n' < "$d/cmdline"
            printf '%s\n' "$envr" | sed -n 's/^_JAVA_OPTIONS=//p' | tr ' \t' '\n\n'
        } | filter_flags | tr '\n' ' ')
        note="$note$(tr '\0' '\n' < "$d/cmdline" | flagfile_note)"

        prefix=""
        ns=$(readlink "$d/ns/mnt" 2>/dev/null) || ns=""
        if [ -n "$ns" ] && [ -n "$self_ns" ] && [ "$ns" != "$self_ns" ]; then
            if [ "$IS_ROOT" -eq 1 ] && command -v nsenter >/dev/null 2>&1; then
                prefix="nsenter -t $pid --mount --root"
                note="$note [container]"
            else
                report unknown "pid $pid $java: JVM in a container; run as root with nsenter available"
                continue
            fi
        fi
        proc_line "$pid" "$prefix" "$java" "$flags" "$note"
    done
    set -f
}

scan_procs_darwin() {
    local pid comm flags note
    ps -axo pid=,comm= 2>/dev/null | while read -r pid comm; do
        case "$comm" in */java) ;; *) continue ;; esac
        [ "$pid" = "$$" ] && continue
        flags=$(ps -o args= -p "$pid" 2>/dev/null | tr ' ' '\n' | filter_flags | tr '\n' ' ')
        note=$(ps -o args= -p "$pid" 2>/dev/null | tr ' ' '\n' | flagfile_note)
        if [ ! -x "$comm" ]; then
            printf 'gone%s%s\n' "$SEP" "$pid $comm" >> "$TMP/procs"
            continue
        fi
        proc_line "$pid" "" "$comm" "$flags" "$note"
    done
}

# Installed JVMs
DISK_FLAGS=$( {
    printf '%s\n' "${JAVA_TOOL_OPTIONS:-}" "${JDK_JAVA_OPTIONS:-}" | tr ' \t' '\n\n'
    printf '%s\n' "$EXTRA_OPTS" | tr ' \t' '\n\n'
    printf '%s\n' "${_JAVA_OPTIONS:-}" | tr ' \t' '\n\n'
} | filter_flags | tr '\n' ' ')

[ "$SCAN_DISK" -eq 1 ] && discover_disk
printf '%s' "$EXTRA_JAVAS" | while IFS= read -r j; do
    [ -n "$j" ] || continue
    if [ -f "$j" ] && [ -x "$j" ]; then add_cand "$j"; else echo "missing:$j" >> "$TMP/cands"; fi
done

# Running JVMs are collected before any probe starts, so probes never see
# each other.
if [ "$SCAN_PROCS" -eq 1 ]; then
    case "$HOST_OS" in
        Linux)  scan_procs_linux ;;
        Darwin) scan_procs_darwin ;;
        *)      say "process scan not supported on $HOST_OS" ;;
    esac
    [ "$IS_ROOT" -eq 1 ] || say "note: not root; other users' processes and containers may be missed"
fi

while IFS= read -r j; do
    case "$j" in
        missing:*) report unknown "${j#missing:}: not an executable file"; continue ;;
    esac
    probe "installed" "" "$j" "$DISK_FLAGS" ""
done < "$TMP/cands"

while IFS="$SEP" read -r pid prefix java flags note; do
    if [ "$pid" = gone ]; then
        report unknown "pid $prefix: binary no longer on disk; restart it or check the old version"
        continue
    fi
    probe "pid $pid" "$prefix" "$java" "$flags" "$note"
done < "$TMP/procs"

finish
