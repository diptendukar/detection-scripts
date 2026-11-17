#!/usr/bin/env bash
#
# detect-jdk-8392044-gcp.sh
#
# Checks Google Cloud Java runtimes for JDK-8392044 (HotSpot x86-64 AVX-512
# Base64 decodeBlock heap overwrite) from the GCP control plane. Read-only:
# it only calls list and describe APIs, with prompts disabled so gcloud never
# offers to enable an API.
#
# The same five checks as detect-jdk-8392044.sh, evaluated per workload:
#   arch               x86_64 vs arm64 (Cloud Run is x86_64 only)
#   vm                 HotSpot only (OpenJDK, Temurin, Corretto, ...).
#                      OpenJ9 and GCJ are OK; unidentified JVMs are [?]
#   java version       17.0.6 or later, and not at or above FIXED_IN
#   avx-512            AVX-512 VBMI + BW. Compute Engine reports the actual
#                      CPU platform of each VM. Cloud Run, Cloud Run functions
#                      and App Engine do not expose the CPU, so they show [?].
#   base64 intrinsic   from JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS, _JAVA_OPTIONS
#                      and command lines
#
# Unlike AWS Lambda, Google's Java launchers do not limit the JIT: Cloud Run
# functions and source deploys run "java -jar", and App Engine's launcher
# adds only heap and GC flags (checked 2026-11-17 against
# GoogleCloudPlatform/buildpacks and the serverless-runtimes java21 image).
# The intrinsic is in use unless a flag turns it off.
#
# Covered:
#   run        Cloud Run services and jobs: containers, env, command/args,
#              managed Java base images
#   functions  Cloud Run functions (gen1 and gen2): runtime, env
#   appengine  serving App Engine versions, standard and flexible
#   compute    running VMs: CPU platform, Java packages from OS Config
#              inventory, JVM flags in startup scripts; GKE and Dataproc
#              nodes are grouped by cluster
#
# Values of environment variables and instance metadata are never printed.
# They are reduced to the JVM flags that change the verdict before anything
# is shown.
#
# Needs: gcloud and jq, logged in with an account that can read the projects.
#
# Exit codes, for fleet tooling:
#   0  not impacted
#   1  impacted: at least one workload meets all conditions
#   2  unknown: at least one workload could not be evaluated, none impacted
#   3  usage error
#
# The last line of output is always exactly one of:
#   impacted | not impacted | unknown

set -u
set -f

# Versions that contain the fix, one per feature release, space separated.
# None was public as of 2026-11-17. The highest entry also covers every later
# feature release. Example: "17.0.19 21.0.11 25.0.3 26.0.1"
FIXED_IN="${JDK8392044_FIXED_IN:-}"

QUIET=0
VERBOSE=0
SHOW_ALL=0
PROJECTS=""
SERVICES="run functions appengine compute"

usage() {
    cat <<'EOF'
usage: detect-jdk-8392044-gcp.sh [-q] [-v] [-a] [-p PROJECT]... [-s SERVICES]

  -q, --quiet        print only the verdict line
  -v, --verbose      print each gcloud call to stderr
  -a, --all          also print workloads that are OK (default: counted only)
  -p, --project P    project ID to check (repeatable or comma separated);
                     default: every active project the account can list
  -s, --services S   comma separated subset of run,functions,appengine,compute

Credentials come from gcloud (gcloud auth login, or a service account).
Exit: 0 not impacted, 1 impacted, 2 unknown, 3 usage error.
Env:  JDK8392044_FIXED_IN="17.0.19 21.0.11 ..."
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -a|--all) SHOW_ALL=1 ;;
        -p|--project)
            [ $# -ge 2 ] || { usage >&2; exit 3; }
            PROJECTS="$PROJECTS $(printf '%s' "$2" | tr ',' ' ')"
            shift ;;
        -s|--services)
            [ $# -ge 2 ] || { usage >&2; exit 3; }
            SERVICES=$(printf '%s' "$2" | tr ',' ' ')
            for s in $SERVICES; do
                case "$s" in
                    run|functions|appengine|compute) ;;
                    *) echo "unknown service: $s" >&2; usage >&2; exit 3 ;;
                esac
            done
            shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 3 ;;
    esac
    shift
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

for tool in gcloud jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        say "error: $tool not found"
        echo "unknown"; exit 2
    }
done

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t jdk8392044gcp) || { echo unknown; exit 2; }
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/summary"
# Never prompt: gcloud would otherwise offer to enable missing APIs.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

N_IMPACTED=0
N_UNKNOWN=0
N_OK=0
N_DENIED=0

# JVM options that change the verdict. Same list as detect-jdk-8392044.sh.
WL='^-XX:([+-](UseBASE64Intrinsics|UnlockDiagnosticVMOptions|UseCompiler|TieredCompilation|EnableJVMCI|UseJVMCICompiler)|(UseAVX|TieredStopAtLevel|DisableIntrinsic)=[^ ]*)$|^-Xint$'

# jq helper: reduce an option string to the allowed flags, so no other value
# (passwords in -D options, tokens, ...) ever leaves jq.
JQ_WL='def wl: if . == null then "" else [splits("[\\s\"'"'"'`;]+")] | map(select(test($wl))) | join(" ") end;'

# gj PROJECT ARGS... : JSON on stdout. On failure the error class is in
# $TMP/err_code: SERVICE_DISABLED, NO_APP, PERMISSION_DENIED, ...
gj() {
    local p=$1 code
    shift
    [ "$VERBOSE" -eq 1 ] && printf 'gcloud: %s --project %s\n' "$*" "$p" >&2
    if gcloud "$@" ${p:+--project "$p"} --format=json --quiet 2>"$TMP/err"; then
        # Aggregated lists (compute) exit 0 with a partial or empty result
        # and only warn on stderr when some requests fail. That is a failed
        # listing, not an empty one.
        grep -q 'Some requests did not succeed' "$TMP/err" || return 0
    fi
    if grep -qE 'SERVICE_DISABLED|has not been used in project|it is disabled|is not enabled' "$TMP/err"; then
        code=SERVICE_DISABLED
    elif grep -q 'does not contain an App Engine application' "$TMP/err"; then
        code=NO_APP
    elif grep -qE "Required '[^']*' permission" "$TMP/err"; then
        code=PERMISSION_DENIED
    else
        code=$(grep -oE "PERMISSION_DENIED|UNAUTHENTICATED|NOT_FOUND|FAILED_PRECONDITION|INVALID_ARGUMENT|RESOURCE_EXHAUSTED|UNAVAILABLE|Reauthentication required|refreshing your current auth tokens|do not currently have an active account|Some requests did not succeed" \
            "$TMP/err" | head -1)
        case "$code" in
            Reauth*|refreshing*|*"active account") code=UNAUTHENTICATED ;;
            "Some requests did not succeed") code=PARTIAL_FAILURE ;;
        esac
        [ -n "$code" ] || code=$(grep -v '^ *$' "$TMP/err" | head -1 | sed 's/^ERROR: //' | cut -c1-120)
        [ -n "$code" ] || code="failed"
    fi
    printf '%s' "$code" > "$TMP/err_code"
    return 1
}
err_code() { cat "$TMP/err_code" 2>/dev/null; }

# A listing failed. API off or no App Engine app: nothing runs there.
# Anything else: the service in that project is unknown.
gcp_fail() {
    case "$(err_code)" in
        SERVICE_DISABLED|NO_APP) printf '%s %s off\n' "$1" "$2" >> "$TMP/summary" ;;
        *) api_fail "$1" "$2" "$3" ;;
    esac
}

# ---------------------------------------------------------------- output ---

tally() {
    case "$1" in
        impacted) N_IMPACTED=$((N_IMPACTED + 1)) ;;
        unknown)  N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
        *)        N_OK=$((N_OK + 1)) ;;
    esac
}

mark() {
    case "$1" in
        impacted) echo "[!]" ;;
        ok) echo "OK" ;;
        unknown) echo "[?]" ;;
        *) echo "n/a" ;;
    esac
}

header() {
    say "JDK-8392044 GCP check: HotSpot x86-64 AVX-512 Base64 decode heap overwrite"
    say "legend: [!] impacted | OK not impacted | [?] could not check | n/a not checked"
    say "checks: arch, vm, java version, avx-512, base64 intrinsic. A workload is impacted only if all five show [!]."
}

# One workload is one block. Checks are buffered so OK workloads can be
# counted instead of printed.
B_SVC="" B_REG="" B_TITLE="" B_BODY="" B_IDX=0 B_OKAT="" B_FIRSTOK="" B_UNK=0
NL='
'

begin_block() {
    B_SVC=$1 B_REG=$2 B_TITLE=$3 B_BODY="" B_IDX=0 B_OKAT="" B_FIRSTOK="" B_UNK=0
}

# chk NAME VALUE STATE. After an OK in arch, vm or java version the rest of
# the checks are n/a, as in the host script.
chk() {
    local name=$1 val=$2 st=$3
    B_IDX=$((B_IDX + 1))
    if [ -n "$B_OKAT" ]; then
        val="-" st=na
    fi
    case "$st" in
        ok)
            [ -n "$B_FIRSTOK" ] || B_FIRSTOK=$name
            [ "$B_IDX" -le 3 ] && B_OKAT=$name ;;
        unknown) B_UNK=1 ;;
    esac
    B_BODY="$B_BODY  $name: $val $(mark "$st")$NL"
}

note() { B_BODY="$B_BODY  note: $*$NL"; }

end_block() {
    local res=impacted
    if [ -n "$B_FIRSTOK" ]; then
        res=ok
    elif [ "$B_UNK" -eq 1 ]; then
        res=unknown
    fi
    if [ "$res" = ok ] && [ "$SHOW_ALL" -eq 0 ]; then
        printf '%s %s ok:%s\n' "$B_SVC" "$B_REG" "$B_FIRSTOK" >> "$TMP/summary"
        tally ok
        return
    fi
    say ""
    say "$B_TITLE"
    printf '%s' "$B_BODY" | while IFS= read -r l; do say "$l"; done
    case "$res" in
        impacted) say "  => [!] impacted" ;;
        ok) say "  => OK" ;;
        *) say "  => [?] unknown" ;;
    esac
    tally "$res"
}

# A listing that failed: the whole service in that region is unknown.
api_fail() {
    case "$(err_code)" in
        PERMISSION_DENIED*|UNAUTHENTICATED*) N_DENIED=$((N_DENIED + 1)) ;;
    esac
    begin_block "$1" "$2" "$1 $2"
    chk "api" "$3 failed: $(err_code)" unknown
    end_block
}

skip() { printf '%s %s skip\n' "$1" "$2" >> "$TMP/summary"; }

finish() {
    if [ -s "$TMP/summary" ] && [ "$QUIET" -eq 0 ]; then
        say ""
        say "not shown:"
        awk '
            { k = $1 " " $2; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
            $3 == "skip" { skip[k]++; next }
            $3 == "off" { off[k] = 1; next }
            { sub(/^ok:/, "", $3); r = $3; for (i = 4; i <= NF; i++) r = r " " $i
              ok[k]++; okr[k, r]++; if (!((k, r) in rs)) { rs[k, r] = 1; rl[k] = rl[k] SUBSEP r } }
            END {
                for (i = 1; i <= n; i++) {
                    k = order[i]; s = ""
                    if (ok[k]) {
                        m = split(substr(rl[k], 2), rr, SUBSEP); d = ""
                        for (j = 1; j <= m; j++) d = d (j > 1 ? ", " : "") rr[j] " " okr[k, rr[j]]
                        s = ok[k] " OK (" d ")"
                    }
                    if (skip[k]) s = s (s != "" ? ", " : "") skip[k] " without Java"
                    if (off[k]) s = s (s != "" ? ", " : "") "not in use (API off or no app)"
                    print "  " k ": " s
                }
            }' "$TMP/summary"
    fi
    if [ "$N_DENIED" -gt 0 ]; then
        say ""
        say "note: $N_DENIED listing(s) denied. The account needs the read-only roles listed in README.md (GCP permissions)."
    fi
    if [ "$N_IMPACTED" -gt 0 ]; then
        say ""
        echo "impacted"; exit 1
    elif [ "$N_UNKNOWN" -gt 0 ]; then
        say ""
        echo "unknown"; exit 2
    fi
    [ "$N_OK" -eq 0 ] && { say ""; say "no Java workloads found"; }
    say ""
    echo "not impacted"; exit 0
}

# ------------------------------------------------------------- decisions ---

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

# True when FIXED_IN names a fix for this feature release or an older one,
# so a version with an unknown patch level may or may not have it.
fix_matters() {
    local f
    for f in $FIXED_IN; do
        [ $(($(ver_key "$f") / 1000000)) -le "$1" ] && return 0
    done
    return 1
}

# ver_full VERSION -> V_VAL V_ST
ver_full() {
    local k
    k=$(ver_key "$1")
    if [ "$k" -lt "$MIN_KEY" ]; then
        V_VAL="$1 (< 17.0.6)" V_ST=ok
    elif is_fixed "$1"; then
        V_VAL="$1 (fixed)" V_ST=ok
    else
        V_VAL=$1 V_ST=impacted
    fi
}

# ver_major MAJOR LABEL -> V_VAL V_ST, for runtimes whose patch level the
# control plane does not show. Managed runtimes and current image tags carry
# a patch level well past 17.0.6.
ver_major() {
    local m=$1 label=$2
    case "$m" in 1) m=8 ;; esac
    if [ "$m" -lt 17 ]; then
        V_VAL="$m ($label)" V_ST=ok
    elif fix_matters "$m"; then
        V_VAL="$m ($label, patch level not visible)" V_ST=unknown
    else
        V_VAL="$m ($label)" V_ST=impacted
    fi
}

# ver_any VERSION LABEL: full check when the patch level is known.
ver_any() {
    case "$1" in
        *.*.*) ver_full "$1"; V_VAL="$V_VAL ($2)" ;;
        *) ver_major "${1%%.*}" "$2" ;;
    esac
}

# eval_flags "FLAGS low to high precedence" -> F_ST (impacted|ok) F_VAL F_AVX
eval_flags() {
    local b64=1 comp=1 tiered=1 stop=4 dis="" f
    F_AVX=""
    for f in $1; do
        case "$f" in
            -XX:+UseBASE64Intrinsics) b64=1 ;;
            -XX:-UseBASE64Intrinsics) b64=0 ;;
            -XX:+UseCompiler) comp=1 ;;
            -XX:-UseCompiler|-Xint) comp=0 ;;
            -XX:+TieredCompilation) tiered=1 ;;
            -XX:-TieredCompilation) tiered=0 ;;
            -XX:TieredStopAtLevel=*) stop=${f#*=} ;;
            -XX:DisableIntrinsic=*) dis="$dis${dis:+,}${f#*=}" ;;
            -XX:UseAVX=*) F_AVX=${f#*=} ;;
        esac
    done
    case "$stop" in ''|*[!0-9]*) stop=4 ;; esac
    case "$F_AVX" in *[!0-9]*) F_AVX="" ;; esac
    if [ "$b64" -eq 0 ]; then
        F_ST=ok F_VAL="off (-XX:-UseBASE64Intrinsics)"
    elif printf '%s' ",$dis," | grep -q ',_base64_decodeBlock,'; then
        F_ST=ok F_VAL="off (DisableIntrinsic=$dis)"
    elif [ "$comp" -eq 0 ]; then
        F_ST=ok F_VAL="unused (-Xint)"
    elif [ "$tiered" -eq 1 ] && [ "$stop" -lt 4 ]; then
        F_ST=ok F_VAL="unused (TieredStopAtLevel=$stop)"
    else
        F_ST=impacted F_VAL="on"
    fi
}

# flags_check HARD SOFT SOFTSRC -> base64 check, plus UseAVX in F_AVX.
# HARD flags certainly reach the JVM. SOFT flags were found in a place that
# may or may not apply to the JVM in question (user data, EMR configuration,
# JAVA_OPTS); if only they turn the intrinsic off, the answer is [?].
flags_check() {
    local hard=$1 soft=$2 src=$3 avx
    eval_flags "$hard"
    avx=$F_AVX
    if [ "$F_ST" = impacted ] && [ -n "$soft" ]; then
        eval_flags "$hard $soft"
        if [ "$F_ST" = ok ]; then
            F_ST=unknown F_VAL="$F_VAL only if $src reaches the JVM"
        elif [ -n "$F_AVX" ] && [ "$F_AVX" -lt 3 ] && { [ -z "$avx" ] || [ "$avx" -ge 3 ]; }; then
            F_ST=unknown F_VAL="on; UseAVX=$F_AVX only if $src reaches the JVM"
        fi
    fi
    F_AVX=$avx
}

# avx_check X_ST X_VAL UseAVX: a UseAVX below 3 rules AVX-512 out.
avx_check() {
    if [ -n "$3" ] && [ "$3" -lt 3 ]; then
        chk "avx-512" "UseAVX=$3" ok
    else
        chk "avx-512" "$2" "$1"
    fi
}

# vm_class NAME -> C_ST C_VAL. Only HotSpot is affected, so a JVM counts as
# [!] only when its name identifies a HotSpot build. OpenJ9 and GCJ have no
# such stub. Azul Prime replaces C2 with its own JIT and is not verified.
# A bare "jdk"/"jre"/"java" with no vendor is [?].
HOTSPOT_RE='corretto|temurin|adoptopenjdk|openjdk|zulu|liberica|sapmachine|graalvm|dragonwell|microsoft|msopenjdk|oracle|java\(tm\)|java se|java [0-9]+ update|^jdk-[0-9]|/jdk-[0-9]'
vm_class() {
    local lc
    lc=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    if printf '%s' "$lc" | grep -Eq 'semeru|openj9|j9|ibm-java'; then
        C_ST=ok C_VAL="OpenJ9"
    elif printf '%s' "$lc" | grep -Eq 'gcj'; then
        C_ST=ok C_VAL="GCJ"
    elif printf '%s' "$lc" | grep -Eq 'zing|prime'; then
        C_ST=unknown C_VAL="Azul Prime, not HotSpot C2"
    elif printf '%s' "$lc" | grep -Eq "$HOTSPOT_RE"; then
        C_ST=impacted C_VAL="HotSpot"
    elif printf '%s' "$lc" | grep -Eq 'jdk|jre|java'; then
        C_ST=unknown C_VAL="vendor not visible"
    else
        C_ST=unknown C_VAL="not identified"
    fi
}

# image_info IMAGE -> I_JAVA (1 if the image looks like Java) I_VER (version
# from the tag, or empty). vm_class gives the VM.
JDK_RE='corretto|temurin|openjdk|zulu|liberica|sapmachine|graalvm|dragonwell|semeru|jdk|jre|java'
image_info() {
    local img repo tag lc name
    img=${1%%@*}
    tag=""
    repo=$img
    case "${img##*/}" in *:*) tag=${img##*:}; repo=${img%:*} ;; esac
    name=${repo##*/}
    lc=$(printf '%s' "$img" | tr 'A-Z' 'a-z')
    I_JAVA=0
    printf '%s' "$lc" | grep -Eq "$JDK_RE" && I_JAVA=1
    I_VER=$(printf '%s' "$tag" | tr 'A-Z' 'a-z' |
        sed -nE "s/.*($JDK_RE)-?([0-9]+(\.[0-9]+)*).*/\2/p")
    if [ -z "$I_VER" ] && printf '%s' "$name" | tr 'A-Z' 'a-z' | grep -Eq "$JDK_RE"; then
        I_VER=$(printf '%s' "$tag" | sed -nE 's/^([0-9]+(\.[0-9]+)*).*/\1/p')
    fi
}

# AVX-512 VBMI + BW by the CPU platform Compute Engine reports for a running
# VM ("Intel Ice Lake", "AMD Genoa", ...): yes, no, arm or unknown.
cpu_platform_vbmi() {
    case "$1" in
        *"Ice Lake"*|*"Sapphire Rapids"*|*"Emerald Rapids"*|*"Granite Rapids"*|*Genoa*|*Turin*)
            echo yes ;;
        *"Cascade Lake"*|*Skylake*|*Broadwell*|*Haswell*|*"Ivy Bridge"*|*"Sandy Bridge"*|*Rome*|*Milan*)
            echo no ;;
        *Axion*|*Ampere*|*Altra*|*Arm*|*ARM*) echo arm ;;
        *) echo unknown ;;
    esac
}

# The same by machine family, for when no CPU platform is reported. Families
# that span several CPU generations (n2, e2, n1, ...) are unknown on purpose.
family_vbmi() {
    case "$1" in
        c3|c3d|c4|c4d|n4|n4d|m3|m4|h3|z3|a3|x4|c4-*) echo yes ;;
        c2|c2d|n2d|t2d|m1|m2|a2|g2) echo no ;;
        t2a|c4a|n4a) echo arm ;;
        *) echo unknown ;;
    esac
}

# Java packages in OS Config inventory: id<TAB>name<TAB>version lines.
inventory_packages() {
    jq -r '(if type == "array" then . else [.] end)[]
        | (.name // "" | capture("instances/(?<id>[^/]+)/inventory") | .id) as $id
        | (.items // {}) | to_entries[] | .value.installedPackage // empty
        | (.yumPackage // .aptPackage // .zypperPackage // .googetPackage // .windowsApplication // {})
        | [$id, (.packageName // .displayName // ""), (.version // .displayVersion // "")] | @tsv' |
        grep -iE '	[^	]*(corretto|temurin|openjdk|zulu|liberica|semeru|graalvm|sapmachine|dragonwell|java-[0-9]|java-1\.|jdk|jre|java\(tm\)|java se)' |
        grep -viE '	[^	]*(javascript|ca-certificates|tzdata|javapackages|java-common|default-j|wrappers|maven|atk-wrapper|jna|-headers|jdk-docs|jdk-src)'
}

# Shared per-container evaluation for Cloud Run services and jobs.
RUN_JQ="$JQ_WL"'
def envmap: map({(.name): (if .valueFrom then null else .value end)}) | add // {};
def secretnames: map(select(.valueFrom.secretKeyRef) | .name);
def javabase: (.metadata.annotations["run.googleapis.com/base-images"] // ""
               | capture("runtimes/java(?<m>[0-9]+)").m) // "";
(if type == "array" then . else [.] end)[]
| select((.metadata.labels["goog-managed-by"] // "") != "cloudfunctions")
| . as $s
| ($s.metadata.labels["cloud.googleapis.com/location"] // $s.metadata.namespace // "-") as $loc
| (if $kind == "job" then $s.spec.template.spec.template.spec else $s.spec.template.spec end) as $ps
| ($s.spec.template | javabase) as $jb1 | ($s | javabase) as $jb2
| $ps.containers[]? | . as $c
| (($c.env // []) | envmap) as $env
| ((($c.command // []) + ($c.args // []))) as $argv
| [ $loc, $s.metadata.name, ($c.name // "-"), ($c.image // "-"),
    ($env.JAVA_TOOL_OPTIONS | wl), ($env.JDK_JAVA_OPTIONS | wl), ($env._JAVA_OPTIONS | wl), ($env.JAVA_OPTS | wl),
    ($argv | join(" ") | wl),
    ((($argv | map(select(test("(^|/)java$|(^|[\\s/])java\\s"))) | length) > 0) | tostring),
    ((($env | keys | map(select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|JAVA_HOME|JAVA_OPTS)$"))) | length) > 0) | tostring),
    ((($c.env // []) | secretnames | map(select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|JAVA_OPTS)$")))) | join(",")),
    (if $jb1 != "" then $jb1 else $jb2 end)
  ] | map(if . == "" then "-" else . end) | @tsv'

# ------------------------------------------------------------------- run ---

scan_run() {
    local p=$1 kind out
    local loc name cname image jto jdko jo jopts cmd javacmd envsig secjava jb
    for kind in service job; do
        if ! out=$(gj "$p" run "${kind}s" list); then
            gcp_fail run "$p" "run ${kind}s list"
            continue
        fi
        jq -r --arg wl "$WL" --arg kind "$kind" "$RUN_JQ" <<<"$out" > "$TMP/run" 2>"$TMP/err" || {
            printf 'parse error' > "$TMP/err_code"; api_fail run "$p" "run ${kind}s list"; continue; }
        while IFS="$(printf '\t')" read -r loc name cname image jto jdko jo jopts cmd javacmd envsig secjava jb; do
            for v in jto jdko jo jopts cmd secjava jb cname; do
                eval "[ \"\$$v\" = - ] && $v=''"
            done
            image_info "$image"
            if [ -z "$jb" ] && [ "$I_JAVA" -eq 0 ] && [ "$javacmd" = false ] && [ "$envsig" = false ]; then
                skip run "$p"
                continue
            fi
            begin_block run "$p" "run $p $loc $kind/$name${cname:+ $cname}"
            chk arch "x86_64 (Cloud Run)" impacted
            if [ -n "$jb" ]; then
                chk vm "HotSpot (Google java$jb base image)" impacted
                ver_major "$jb" "java$jb managed base image"
                chk "java version" "$V_VAL" "$V_ST"
            else
                vm_class "$image"
                if [ "$C_VAL" = "not identified" ]; then
                    chk vm "image not inspected" unknown
                else
                    chk vm "$C_VAL (image)" "$C_ST"
                fi
                if [ -n "$I_VER" ]; then
                    ver_any "$I_VER" "image tag"
                    chk "java version" "$V_VAL" "$V_ST"
                else
                    chk "java version" "not in image tag" unknown
                fi
            fi
            flags_check "$jto $jdko $cmd $jo" "$jopts" "JAVA_OPTS"
            avx_check unknown "Cloud Run does not expose the CPU" "$F_AVX"
            if [ -n "$secjava" ] && [ "$F_ST" != ok ]; then
                chk "base64 intrinsic" "$F_VAL; $secjava from a secret, not read" unknown
            else
                chk "base64 intrinsic" "$F_VAL" "$F_ST"
            fi
            end_block
        done < "$TMP/run"
    done
}

# ------------------------------------------------------------- functions ---

FUNCTIONS_JQ="$JQ_WL"'
(if type == "array" then . else [.] end)[]
| ((.serviceConfig.environmentVariables // .environmentVariables) // {}) as $env
| ([(.serviceConfig.secretEnvironmentVariables // .secretEnvironmentVariables // [])[]?.key]
   | map(select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS)$"))) | join(",")) as $sec
| [ (.name | split("/") | .[3] // "-"), (.name | split("/") | last),
    (.buildConfig.runtime // .runtime // "-"), (.environment // "GEN_1"),
    ($env.JAVA_TOOL_OPTIONS | wl), ($env.JDK_JAVA_OPTIONS | wl), ($env._JAVA_OPTIONS | wl), $sec
  ] | map(if . == "" then "-" else . end) | @tsv'

scan_functions() {
    local p=$1 out loc name rt gen jto jdko jo sec major
    if ! out=$(gj "$p" functions list); then
        gcp_fail functions "$p" "functions list"
        return
    fi
    jq -r --arg wl "$WL" "$FUNCTIONS_JQ" <<<"$out" > "$TMP/fn" 2>"$TMP/err" || {
        printf 'parse error' > "$TMP/err_code"; api_fail functions "$p" "functions list"; return; }
    while IFS="$(printf '\t')" read -r loc name rt gen jto jdko jo sec; do
        for v in jto jdko jo sec; do
            eval "[ \"\$$v\" = - ] && $v=''"
        done
        case "$rt" in
            java*) major=$(printf '%s' "${rt#java}" | sed 's/[^0-9].*//') ;;
            *) skip functions "$p"; continue ;;
        esac
        begin_block functions "$p" "functions $p $loc $name ($gen)"
        chk arch "x86_64 (Cloud Run functions)" impacted
        chk vm "HotSpot ($rt runtime)" impacted
        ver_major "$major" "$rt managed runtime"
        chk "java version" "$V_VAL" "$V_ST"
        eval_flags "$jto $jdko $jo"
        avx_check unknown "Cloud Run functions do not expose the CPU" "$F_AVX"
        if [ -n "$sec" ] && [ "$F_ST" != ok ]; then
            chk "base64 intrinsic" "$F_VAL; $sec from a secret, not read" unknown
        else
            chk "base64 intrinsic" "$F_VAL" "$F_ST"
        fi
        end_block
    done < "$TMP/fn"
}

# ------------------------------------------------------------- appengine ---

APPENGINE_JQ="$JQ_WL"'
[ (.runtime // "-"), (.env // "standard"),
  (.runtimeConfig.runtimeVersion // .runtimeConfig.runtime_version // "-"),
  (.envVariables.JAVA_TOOL_OPTIONS | wl), (.envVariables.JDK_JAVA_OPTIONS | wl),
  (.envVariables._JAVA_OPTIONS | wl), (.envVariables.JAVA_OPTS | wl),
  (.entrypoint.shell // "" | wl),
  ((((.envVariables // {}) | keys | map(select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|JAVA_HOME|JAVA_OPTS)$"))) | length) > 0) | tostring)
] | map(if . == "" then "-" else . end) | @tsv'

scan_appengine() {
    local p=$1 out svc ver d rt envn rtv jto jdko jo jopts ep envsig major
    if ! out=$(gj "$p" app versions list --filter=SERVING_STATUS=SERVING); then
        gcp_fail appengine "$p" "app versions list"
        return
    fi
    jq -r '.[]? | select((.version.servingStatus // .serving_status // "SERVING") == "SERVING")
           | [.service, .id] | @tsv' <<<"$out" > "$TMP/gae" 2>"$TMP/err" || {
        printf 'parse error' > "$TMP/err_code"; api_fail appengine "$p" "app versions list"; return; }
    while IFS="$(printf '\t')" read -r svc ver; do
        if ! d=$(gj "$p" app versions describe "$ver" --service "$svc"); then
            begin_block appengine "$p" "appengine $p $svc/$ver"
            chk "api" "app versions describe failed: $(err_code)" unknown
            end_block
            continue
        fi
        IFS="$(printf '\t')" read -r rt envn rtv jto jdko jo jopts ep envsig <<EOF
$(jq -r --arg wl "$WL" "$APPENGINE_JQ" <<<"$d")
EOF
        for v in jto jdko jo jopts ep rtv; do
            eval "[ \"\$$v\" = - ] && $v=''"
        done
        major=""
        case "$rt" in
            java[0-9]*) major=$(printf '%s' "${rt#java}" | sed 's/[^0-9].*//') ;;
            java) major=$(printf '%s' "$rtv" | sed 's/[^0-9].*//') ;;
            custom) [ "$envsig" = true ] || { skip appengine "$p"; continue; } ;;
            *) skip appengine "$p"; continue ;;
        esac
        begin_block appengine "$p" "appengine $p $svc/$ver ($envn)"
        chk arch "x86_64 (App Engine)" impacted
        if [ "$rt" = custom ]; then
            chk vm "custom runtime image not inspected" unknown
            chk "java version" "-" unknown
        else
            chk vm "HotSpot ($rt runtime)" impacted
            if [ -n "$major" ]; then
                ver_major "$major" "$rt${rtv:+ $rtv} managed runtime"
                chk "java version" "$V_VAL" "$V_ST"
            else
                chk "java version" "runtime version not set" unknown
            fi
        fi
        flags_check "$jto $jdko $ep $jo" "$jopts" "JAVA_OPTS"
        avx_check unknown "App Engine does not expose the CPU" "$F_AVX"
        chk "base64 intrinsic" "$F_VAL" "$F_ST"
        end_block
    done < "$TMP/gae"
}

# --------------------------------------------------------------- compute ---

COMPUTE_JQ="$JQ_WL"'
(if type == "array" then . else [.] end)[] | select((.status // "RUNNING") == "RUNNING")
| [ (.id // "-" | tostring), .name, (.zone // "-" | split("/") | last),
    (.machineType // "-" | split("/") | last), (.cpuPlatform // "-"),
    (.labels["goog-k8s-cluster-name"] // "-"), (.labels["goog-dataproc-cluster-name"] // "-"),
    ([.metadata.items[]? | select(.key | test("startup|user-data|user_data")) | .value | wl
      | select(. != "")] | join(" "))
  ] | map(if . == "" then "-" else . end) | @tsv'

cluster_note() {
    case "$1" in
        gke:*) echo "GKE node (cluster ${1#gke:}): JVMs run in pods, which GCP APIs do not show; run detect-jdk-8392044.sh as root on the node or as a privileged DaemonSet" ;;
        dataproc:*) echo "Dataproc node (cluster ${1#dataproc:}): Spark and Hadoop JVMs; run detect-jdk-8392044.sh on the node" ;;
    esac
}

scan_compute() {
    local p=$1 out id name zone mt cpu gke dp md fam st zones z inv_ok="" invst
    if ! out=$(gj "$p" compute instances list --filter=status=RUNNING); then
        gcp_fail compute "$p" "compute instances list"
        return
    fi
    jq -r --arg wl "$WL" "$COMPUTE_JQ" <<<"$out" > "$TMP/gce" 2>"$TMP/err" || {
        printf 'parse error' > "$TMP/err_code"; api_fail compute "$p" "compute instances list"; return; }

    # First pass: rule out by CPU; collect zones that still need inventory.
    : > "$TMP/gce_cand"
    while IFS="$(printf '\t')" read -r id name zone mt cpu gke dp md; do
        fam=${mt%%-*}
        st=$(cpu_platform_vbmi "$cpu")
        [ "$st" = unknown ] && st=$(family_vbmi "$fam")
        if [ "$st" = arm ] || [ "$st" = no ]; then
            begin_block compute "$p" "compute $p $zone $name $mt"
            if [ "$st" = arm ]; then
                chk arch "arm64 ($cpu)" ok
            else
                chk arch x86_64 impacted
            fi
            chk vm - na
            chk "java version" - na
            [ "$st" = no ] && chk "avx-512" "no vbmi ($cpu)" ok
            [ "$st" = arm ] && chk "avx-512" - na
            chk "base64 intrinsic" - na
            end_block
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$zone" "$mt" "$cpu" "$gke" "$dp" "$md" "$st" >> "$TMP/gce_cand"
    done < "$TMP/gce"

    # OS Config inventory, one call per zone.
    : > "$TMP/gce_pk"
    : > "$TMP/gce_invst"
    zones=$(cut -f3 "$TMP/gce_cand" | sort -u)
    for z in $zones; do
        if out=$(gj "$p" compute os-config inventories list --location "$z" --view full); then
            inventory_packages <<<"$out" >> "$TMP/gce_pk"
            printf '%s\tok\n' "$z" >> "$TMP/gce_invst"
        else
            printf '%s\t%s\n' "$z" "$(err_code)" >> "$TMP/gce_invst"
            case "$(err_code)" in PERMISSION_DENIED*) inv_ok=denied ;; esac
        fi
    done
    [ "${inv_ok:-}" = denied ] && N_DENIED=$((N_DENIED + 1))

    : > "$TMP/gce_groups"
    while IFS="$(printf '\t')" read -r id name zone mt cpu gke dp md st; do
        [ "$md" = - ] && md=""
        local cl=""
        [ "$gke" = - ] || cl="gke:$gke"
        [ "$dp" = - ] || cl="dataproc:$dp"
        local title="compute $p $zone $name $mt"
        if [ "$st" = yes ]; then X_ST=impacted X_VAL="vbmi+bw ($cpu)"; else X_ST=unknown X_VAL="CPU platform not known ($cpu, $mt)"; fi
        invst=$(awk -F '\t' -v z="$zone" '$1 == z { print $2; exit }' "$TMP/gce_invst")
        if [ "$invst" = ok ] && grep -q "^$id	" "$TMP/gce_pk"; then
            grep "^$id	" "$TMP/gce_pk" | while IFS="$(printf '\t')" read -r _ pk pv; do
                printf '%s\t%s\t%s\n' "$pk" "$pv" "$title"
            done > "$TMP/gce_one"
            while IFS="$(printf '\t')" read -r pk pv _; do
                begin_block compute "$p" "$title $pk"
                chk arch x86_64 impacted
                vm_class "$pk"
                chk vm "$C_VAL ($pk)" "$C_ST"
                pv=$(printf '%s' "$pv" | sed -E 's/^[0-9]+://; s/^([0-9][0-9._]*).*/\1/; s/[._]$//')
                case "$pv" in
                    *.*.*) ver_full "$pv" ;;
                    [0-9]*) ver_major "${pv%%.*}" "package" ;;
                    *) V_VAL="unreadable" V_ST=unknown ;;
                esac
                chk "java version" "$V_VAL" "$V_ST"
                flags_check "" "$md" "the startup script"
                avx_check "$X_ST" "$X_VAL" "$F_AVX"
                chk "base64 intrinsic" "$F_VAL (default; process flags not visible)" "$F_ST"
                [ -n "$cl" ] && note "$(cluster_note "$cl")"
                end_block
            done < "$TMP/gce_one"
            continue
        fi
        [ "$invst" = ok ] && invst=nojava
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${cl:--}" "${mt%%-*}" "$cpu" "${md:--}" "$invst" "$st" "$title" >> "$TMP/gce_groups"
    done < "$TMP/gce_cand"
    gce_group_blocks "$p"
}

# One block per group of VMs with the same [?] result.
gce_group_blocks() {
    local p=$1 key cl fam cpu md invst st n title names
    cut -f1-6 "$TMP/gce_groups" | sort | uniq -c | sed 's/^ *//' > "$TMP/gce_gkeys"
    while IFS= read -r key; do
        n=${key%% *}
        key=${key#* }
        IFS="$(printf '\t')" read -r cl fam cpu md invst st <<EOF
$key
EOF
        [ "$md" = - ] && md=""
        names=$(awk -F '\t' -v k="$key" '{ kk = $1; for (i = 2; i <= 6; i++) kk = kk "\t" $i } kk == k { n = split($7, t, " "); print t[4] }' \
            "$TMP/gce_groups")
        if [ "$n" -eq 1 ]; then
            title=$(awk -F '\t' -v k="$key" '{ kk = $1; for (i = 2; i <= 6; i++) kk = kk "\t" $i } kk == k { print $7; exit }' \
                "$TMP/gce_groups")
        else
            title="compute $p"
            [ "$cl" = - ] || title="$title $cl"
            title="$title $fam ($cpu, $n instances)"
        fi
        begin_block compute "$p" "$title"
        chk arch x86_64 impacted
        case "$invst" in
            nojava) chk vm "no Java package in OS inventory" unknown ;;
            PERMISSION_DENIED*) chk vm "OS inventory denied ($invst)" unknown ;;
            SERVICE_DISABLED) chk vm "OS Config API not enabled" unknown ;;
            *) chk vm "no OS inventory ($invst)" unknown ;;
        esac
        chk "java version" "-" unknown
        if [ "$st" = yes ]; then X_ST=impacted X_VAL="vbmi+bw ($cpu)"; else X_ST=unknown X_VAL="CPU platform not known ($cpu, $fam)"; fi
        flags_check "" "$md" "the startup script"
        avx_check "$X_ST" "$X_VAL" "$F_AVX"
        chk "base64 intrinsic" "$F_VAL (default; process flags not visible)" "$F_ST"
        [ "$invst" = nojava ] && note "JDKs from tarballs or containers are not in inventory; run detect-jdk-8392044.sh on the host"
        [ "$cl" = - ] || note "$(cluster_note "$cl")"
        if [ "$n" -gt 1 ]; then
            note "instances: $(printf '%s\n' "$names" | head -3 | tr '\n' ' ' | sed 's/ $//')$( [ "$n" -gt 3 ] && echo " +$((n - 3)) more")"
        fi
        end_block
    done < "$TMP/gce_gkeys"
}

# ------------------------------------------------------------------- main ---

header

if [ -z "$(printf '%s' "$PROJECTS" | tr -d ' ')" ]; then
    if out=$(gj "" projects list --filter=lifecycleState:ACTIVE); then
        PROJECTS=$(jq -r '.[].projectId' <<<"$out" | sort | tr '\n' ' ')
    else
        if [ "$(err_code)" = UNAUTHENTICATED ]; then
            say "error: gcloud is not logged in (run: gcloud auth login)"
            echo "unknown"; exit 2
        fi
        PROJECTS=$(gcloud config get-value project 2>/dev/null)
        [ -n "$PROJECTS" ] || {
            say "error: cannot list projects ($(err_code)) and no default project set; pass -p"
            echo "unknown"; exit 2
        }
    fi
fi
PROJECTS=$(printf '%s' "$PROJECTS" | sed 's/^ *//; s/ *$//; s/  */ /g')
[ -n "$PROJECTS" ] || { say "no projects visible to this account"; say ""; echo "unknown"; exit 2; }

say "projects: $PROJECTS"
say "services: $SERVICES"

for p in $PROJECTS; do
    for s in $SERVICES; do
        case "$s" in
            run) scan_run "$p" ;;
            functions) scan_functions "$p" ;;
            appengine) scan_appengine "$p" ;;
            compute) scan_compute "$p" ;;
        esac
    done
done

finish
