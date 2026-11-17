#!/usr/bin/env bash
#
# detect-jdk-8392044-aws.sh
#
# Checks AWS-managed Java runtimes for JDK-8392044 (HotSpot x86-64 AVX-512
# Base64 decodeBlock heap overwrite) from the AWS control plane. Read-only:
# it only calls Describe/List/Get APIs.
#
# The same five checks as detect-jdk-8392044.sh, evaluated per workload:
#   arch               x86_64 vs arm64 (function, task, instance type)
#   vm                 HotSpot only (Corretto, Temurin, Zulu, Oracle, ...).
#                      OpenJ9 and GCJ are OK; unidentified JVMs are [?]
#   java version       17.0.6 or later, and not at or above FIXED_IN
#   avx-512            AVX-512 VBMI + BW, by EC2 instance family. Lambda and
#                      Fargate do not expose the CPU, so they show [?].
#   base64 intrinsic   from JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS, _JAVA_OPTIONS,
#                      command lines and platform defaults
#
# Covered:
#   lambda     java17/21/25 runtimes, including the bootstrap's
#              TieredStopAtLevel=1 default and when it is dropped; container
#              image and custom runtime functions that show Java signals
#   ecs        running tasks on EC2, Fargate and ECS Anywhere, with task
#              definition and run-task overrides
#   ec2        running instances: instance family, Java packages from SSM
#              inventory, JVM flags in user data
#   beanstalk  Corretto / Java / Tomcat platforms, environment properties,
#              Tomcat JVM options
#   emr        active clusters: release label default JDK, JAVA_HOME
#              overrides and JVM flags in configurations
#
# Values of environment variables and user data are never printed. They are
# reduced to the JVM flags that change the verdict before anything is shown.
#
# Needs: aws CLI v2 and jq, with credentials for the account to check.
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
REGIONS=""
SERVICES="lambda ecs ec2 beanstalk emr"
LAMBDA_VERSIONS=0

usage() {
    cat <<'EOF'
usage: detect-jdk-8392044-aws.sh [-q] [-v] [-a] [-r REGION]... [-s SERVICES]
                                 [--lambda-versions]

  -q, --quiet        print only the verdict line
  -v, --verbose      print each AWS call to stderr
  -a, --all          also print workloads that are OK (default: counted only)
  -r, --region R     region to check (repeatable or comma separated);
                     default: every region enabled for the account
  -s, --services S   comma separated subset of lambda,ecs,ec2,beanstalk,emr
  --lambda-versions  check every published Lambda version, not only $LATEST

Credentials come from the usual AWS CLI sources (AWS_PROFILE, env, SSO, ...).
Exit: 0 not impacted, 1 impacted, 2 unknown, 3 usage error.
Env:  JDK8392044_FIXED_IN="17.0.19 21.0.11 ..."
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet) QUIET=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -a|--all) SHOW_ALL=1 ;;
        -r|--region)
            [ $# -ge 2 ] || { usage >&2; exit 3; }
            REGIONS="$REGIONS $(printf '%s' "$2" | tr ',' ' ')"
            shift ;;
        -s|--services)
            [ $# -ge 2 ] || { usage >&2; exit 3; }
            SERVICES=$(printf '%s' "$2" | tr ',' ' ')
            for s in $SERVICES; do
                case "$s" in
                    lambda|ecs|ec2|beanstalk|emr) ;;
                    *) echo "unknown service: $s" >&2; usage >&2; exit 3 ;;
                esac
            done
            shift ;;
        --lambda-versions) LAMBDA_VERSIONS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 3 ;;
    esac
    shift
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

for tool in aws jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        say "error: $tool not found"
        echo "unknown"; exit 2
    }
done

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t jdk8392044aws) || { echo unknown; exit 2; }
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/summary"
export AWS_PAGER=""

N_IMPACTED=0
N_UNKNOWN=0
N_OK=0
N_DENIED=0

# JVM options that change the verdict. Same list as detect-jdk-8392044.sh.
WL='^-XX:([+-](UseBASE64Intrinsics|UnlockDiagnosticVMOptions|UseCompiler|TieredCompilation|EnableJVMCI|UseJVMCICompiler)|(UseAVX|TieredStopAtLevel|DisableIntrinsic)=[^ ]*)$|^-Xint$'

# jq helper: reduce an option string to the allowed flags, so no other value
# (passwords in -D options, tokens, ...) ever leaves jq.
JQ_WL='def wl: if . == null then "" else [splits("[\\s\"'"'"'`;]+")] | map(select(test($wl))) | join(" ") end;'

# aws REGION ARGS... : JSON on stdout. On failure, the error code is in
# $TMP/err_code and the function returns non-zero.
awsj() {
    local r=$1
    shift
    [ "$VERBOSE" -eq 1 ] && printf 'aws: --region %s %s\n' "$r" "$*" >&2
    if aws --region "$r" --output json "$@" 2>"$TMP/err"; then
        return 0
    fi
    local code
    code=$(sed -n 's/.*An error occurred (\([^)]*\)).*/\1/p' "$TMP/err" | head -1)
    [ -n "$code" ] || code=$(grep -v '^ *$' "$TMP/err" | head -1 | sed 's/^aws: \[ERROR\]: //' | cut -c1-120)
    [ -n "$code" ] || code="failed"
    printf '%s' "$code" > "$TMP/err_code"
    return 1
}
err_code() { cat "$TMP/err_code" 2>/dev/null; }

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
    say "JDK-8392044 AWS check: HotSpot x86-64 AVX-512 Base64 decode heap overwrite"
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
        *AccessDenied*|*UnauthorizedOperation*|*NotAuthorized*|*Forbidden*) N_DENIED=$((N_DENIED + 1)) ;;
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
                    print "  " k ": " s
                }
            }' "$TMP/summary"
    fi
    if [ "$N_DENIED" -gt 0 ]; then
        say ""
        say "note: $N_DENIED listing(s) denied. The role needs the read-only actions listed in README.md (IAM policy)."
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

# AVX-512 VBMI + BW by EC2 instance family: yes, no or unknown.
# yes: Intel Ice Lake and later, AMD Zen 4 and later.
# no:  Intel Skylake/Cascade Lake (AVX-512 without VBMI) and older, AMD Zen 1-3.
family_vbmi() {
    case "${1%%.*}" in
        m6i|m6id|m6in|m6idn|c6i|c6id|c6in|r6i|r6id|r6in|r6idn|x2idn|x2iedn|\
        i4i|hpc6id|trn1|trn1n|m7i|m7i-flex|c7i|c7i-flex|r7i|r7iz|u7i-*|u7in-*|\
        i7i|i7ie|m8i|m8i-flex|c8i|c8i-flex|r8i|r8i-flex|x8i|trn2|p5en|\
        m7a|c7a|r7a|hpc7a|m8a|c8a|r8a)
            echo yes ;;
        m5|m5d|m5n|m5dn|m5zn|m5a|m5ad|c5|c5d|c5n|c5a|c5ad|r5|r5d|r5n|r5dn|r5b|\
        r5a|r5ad|t3|t3a|t2|t1|m4|c4|r4|m3|c3|r3|m1|m2|c1|i3|i3en|i2|d2|d3|d3en|\
        h1|x1|x1e|z1d|x2iezn|g3|g3s|g4dn|g4ad|g5|g6|g6e|gr6|p3|p3dn|p4d|p4de|\
        p5|p5e|inf1|inf2|f1|f2|vt1|dl1|m6a|c6a|r6a|hpc6a|mac1|u-*)
            echo no ;;
        *) echo unknown ;;
    esac
}

# Graviton and Apple-silicon families: arm64.
family_is_arm() {
    case "${1%%.*}" in
        a1|mac2*) return 0 ;;
    esac
    printf '%s' "${1%%.*}" | grep -Eq '^[a-z]+[0-9]+g'
}

# types_check "TYPE ..." -> A_ST A_VAL (arch), X_ST X_VAL (avx-512)
types_check() {
    local t fam yes="" no="" unk="" x86=0 arm=0
    for t in $1; do
        fam=${t%%.*}
        if family_is_arm "$fam"; then
            arm=1
            continue
        fi
        x86=1
        case "$(family_vbmi "$fam")" in
            yes) yes="$yes $fam" ;;
            no) no="$no $fam" ;;
            *) unk="$unk $fam" ;;
        esac
    done
    if [ "$x86" -eq 0 ] && [ "$arm" -eq 1 ]; then
        A_ST=ok A_VAL="arm64"
    elif [ "$x86" -eq 1 ]; then
        A_ST=impacted A_VAL="x86_64"
    else
        A_ST=unknown A_VAL="instance types not visible"
    fi
    yes=$(printf '%s' "$yes" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
    no=$(printf '%s' "$no" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
    unk=$(printf '%s' "$unk" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')
    if [ -n "$yes" ]; then
        X_ST=impacted X_VAL="vbmi+bw ($yes)"
    elif [ -n "$unk" ]; then
        X_ST=unknown X_VAL="family not in table ($unk)"
    elif [ -n "$no" ]; then
        X_ST=ok X_VAL="no vbmi ($no)"
    else
        X_ST=unknown X_VAL="instance types not visible"
    fi
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

# Java packages in SSM inventory: name<TAB>version lines on stdout.
java_packages() {
    jq -r '.Entries[]? | select(.Name != null) | [.Name, (.Version // "")] | @tsv' |
        grep -iE 'corretto|temurin|openjdk|zulu|liberica|semeru|graalvm|sapmachine|dragonwell|java-[0-9]|java-1\.|jdk|jre|java\(tm\)|java se' |
        grep -viE 'javascript|ca-certificates|tzdata|javapackages|java-common|^default-|wrappers|maven|atk-wrapper|jna|-headers|jdk-docs|jdk-src'
}

# ----------------------------------------------------------------- lambda ---

LAMBDA_JQ="$JQ_WL"'
.Functions[] | [
  .FunctionName, (.Version // "$LATEST"), (.Runtime // ""),
  ((.Architectures // ["x86_64"])[0]), (.PackageType // "Zip"),
  (.Environment.Variables.JAVA_TOOL_OPTIONS | wl),
  (.Environment.Variables.JDK_JAVA_OPTIONS | wl),
  (.Environment.Variables._JAVA_OPTIONS | wl),
  (.Environment.Variables.AWS_LAMBDA_JAVA_TOOL_OPTIONS | wl),
  (if .Environment.Variables.AWS_LAMBDA_JAVA_TOOL_OPTIONS == null then "0" else "1" end),
  (.Environment.Variables.AWS_LAMBDA_EXEC_WRAPPER // ""),
  (.Environment.Error.ErrorCode // ""),
  ((.Environment.Variables // {}) | keys
     | map(select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|AWS_LAMBDA_JAVA_TOOL_OPTIONS|JAVA_HOME|JAVA_OPTS)$")))
     | length | tostring),
  (.SnapStart.ApplyOn // "None"),
  (.CapacityProviderConfig.LambdaManagedInstancesCapacityProviderConfig.CapacityProviderArn // ""),
  ([.Layers[]?.Arn | select(test("(?i)java|jdk|jre|corretto|graal"))] | length | tostring)
] | map(if . == "" then "-" else . end) | @tsv'

# The Lambda Java bootstrap (java17, java21, java25; checked 2026-11-17 on the
# public.ecr.aws/lambda/java images) adds "-XX:+TieredCompilation
# -XX:TieredStopAtLevel=1" to the command line, which keeps C2 and with it
# the intrinsic out of use. It leaves that default out when:
#   - JAVA_TOOL_OPTIONS contains -XX:+TieredCompilation or -XX:-TieredCompilation
#   - java25 and later: AWS_LAMBDA_JAVA_TOOL_OPTIONS is set (it then replaces
#     JAVA_TOOL_OPTIONS), or the init type is not on-demand (SnapStart,
#     provisioned concurrency, Lambda Managed Instances)
lambda_defaults() { # MAJOR MODE JTO_TIERED HAS_ALJTO -> 0 when applied
    if [ "$1" -lt 25 ]; then
        [ "$3" -eq 0 ]
    else
        [ "$4" -eq 0 ] && [ "$3" -eq 0 ] && [ "$2" = on-demand ]
    fi
}

scan_lambda() {
    local r=$1 out
    local fn ver rt arch pkg jto jdko jo aljto has_aljto wrap enverr nsig snap cap nlayer
    local extra="" title major modes jto_eff jto_tiered m worst_st worst_val worst_avx
    local first_val dflt_used cpname cpjson types
    [ "$LAMBDA_VERSIONS" -eq 1 ] && extra="--function-version ALL"
    # shellcheck disable=SC2086
    if ! out=$(awsj "$r" lambda list-functions $extra); then
        api_fail lambda "$r" "list-functions"
        return
    fi
    jq -r --arg wl "$WL" "$LAMBDA_JQ" <<<"$out" > "$TMP/lambda" 2>/dev/null || {
        api_fail lambda "$r" "list-functions parse"; return; }
    while IFS="$(printf '\t')" read -r fn ver rt arch pkg jto jdko jo aljto has_aljto wrap enverr nsig snap cap nlayer; do
        [ "$jto" = - ] && jto=""
        [ "$jdko" = - ] && jdko=""
        [ "$jo" = - ] && jo=""
        [ "$aljto" = - ] && aljto=""
        [ "$wrap" = - ] && wrap=""
        [ "$enverr" = - ] && enverr=""
        [ "$cap" = - ] && cap=""
        title="lambda $r $fn"
        [ "$ver" = '$LATEST' ] || title="$title:$ver"

        major=""
        case "$rt" in
            java*) major=$(printf '%s' "${rt#java}" | sed 's/[^0-9].*//') ;;
        esac
        if [ -z "$major" ]; then
            # Container image or custom runtime: Java only if it shows.
            if [ "$nsig" = 0 ] && [ "$nlayer" = 0 ]; then
                skip lambda "$r"
                continue
            fi
            begin_block lambda "$r" "$title"
            if [ "$arch" = arm64 ]; then chk arch arm64 ok; else chk arch "$arch" impacted; fi
            if [ "$pkg" = Image ]; then
                chk vm "container image not inspected" unknown
            else
                chk vm "custom runtime ($rt)" unknown
            fi
            chk "java version" "-" unknown
            eval_flags "$jto $jdko $jo"
            avx_check unknown "Lambda does not expose the CPU" "$F_AVX"
            if [ "$F_ST" = ok ]; then
                chk "base64 intrinsic" "$F_VAL" ok
            else
                chk "base64 intrinsic" "$F_VAL unless the image entrypoint adds flags" unknown
            fi
            end_block
            continue
        fi

        begin_block lambda "$r" "$title"
        if [ "$arch" = arm64 ]; then chk arch arm64 ok; else chk arch "$arch" impacted; fi
        chk vm "Corretto ($rt runtime)" impacted
        ver_major "$major" "$rt managed runtime"
        chk "java version" "$V_VAL" "$V_ST"
        if [ -n "$B_OKAT" ]; then
            chk "avx-512" - na
            chk "base64 intrinsic" - na
            end_block
            continue
        fi

        if [ -n "$enverr" ]; then
            chk "avx-512" "Lambda does not expose the CPU" unknown
            chk "base64 intrinsic" "environment unreadable ($enverr)" unknown
            end_block
            continue
        fi

        has_aljto=${has_aljto:-0}
        if [ "$major" -ge 25 ] && [ "$has_aljto" = 1 ]; then
            jto_eff=$aljto
        else
            jto_eff=$jto
            has_aljto=0
        fi
        jto_tiered=0
        case " $jto_eff " in
            *" -XX:+TieredCompilation "*|*" -XX:-TieredCompilation "*) jto_tiered=1 ;;
        esac

        if [ -n "$cap" ]; then
            modes="lambda-managed-instances"
        elif [ "$snap" = PublishedVersions ] && [ "$ver" != '$LATEST' ]; then
            modes="snap-start"
        else
            modes="on-demand"
            [ "$snap" = PublishedVersions ] && [ "$LAMBDA_VERSIONS" -eq 0 ] && modes="$modes snap-start"
        fi
        if [ -z "$cap" ] && [ "$major" -ge 25 ]; then
            local q="$fn"
            [ "$ver" = '$LATEST' ] || q="$fn:$ver"
            if pc=$(awsj "$r" lambda list-provisioned-concurrency-configs --function-name "$fn"); then
                if [ "$(jq '.ProvisionedConcurrencyConfigs // [] | length' <<<"$pc")" -gt 0 ]; then
                    modes="$modes provisioned-concurrency"
                fi
            else
                note "provisioned concurrency not checked ($(err_code)) for $q"
            fi
        fi

        worst_st="" worst_val="" worst_avx="" first_val="" dflt_used=0
        for m in $modes; do
            local d=""
            if lambda_defaults "$major" "$m" "$jto_tiered" "$has_aljto"; then
                d="-XX:+TieredCompilation -XX:TieredStopAtLevel=1"
            fi
            eval_flags "$jto_eff $jdko $d $jo"
            [ -n "$F_AVX" ] && worst_avx=$F_AVX
            if [ "$F_ST" = impacted ]; then
                if [ -n "$d" ]; then
                    worst_val="on ($m: _JAVA_OPTIONS overrides Lambda's TieredStopAtLevel=1)"
                elif [ "$jto_tiered" -eq 1 ]; then
                    worst_val="on ($m: TieredCompilation in JAVA_TOOL_OPTIONS drops Lambda's TieredStopAtLevel=1)"
                elif [ "$has_aljto" -eq 1 ]; then
                    worst_val="on ($m: AWS_LAMBDA_JAVA_TOOL_OPTIONS drops Lambda's TieredStopAtLevel=1)"
                else
                    worst_val="on ($m: no TieredStopAtLevel=1 default for this init type)"
                fi
                worst_st=impacted
                break
            fi
            if [ -z "$first_val" ]; then
                first_val=$F_VAL
                if [ -n "$d" ] && [ "$F_VAL" = "unused (TieredStopAtLevel=1)" ]; then
                    first_val="unused (Lambda default TieredStopAtLevel=1)"
                    dflt_used=1
                fi
            fi
        done
        [ -n "$worst_st" ] || { worst_st=ok; worst_val=$first_val; }

        if [ -n "$cap" ]; then
            cpname=${cap##*:capacity-provider:}
            if [ ! -f "$TMP/cp_${r}_$cpname" ]; then
                if cpjson=$(awsj "$r" lambda get-capacity-provider --capacity-provider-name "$cpname"); then
                    printf '%s' "$cpjson" > "$TMP/cp_${r}_$cpname"
                else
                    : > "$TMP/cp_${r}_$cpname"
                fi
            fi
            types=$(jq -r '.CapacityProvider.InstanceRequirements.AllowedInstanceTypes // [] | .[]' \
                "$TMP/cp_${r}_$cpname" 2>/dev/null | tr '\n' ' ')
            if [ -n "$types" ]; then
                types_check "$types"
            else
                X_ST=unknown X_VAL="capacity provider $cpname allows any instance type"
            fi
            avx_check "$X_ST" "$X_VAL" "$worst_avx"
        else
            avx_check unknown "Lambda does not expose the CPU" "$worst_avx"
        fi
        if [ "$worst_st" = ok ] && [ "$dflt_used" -eq 1 ] && [ -n "$wrap" ]; then
            chk "base64 intrinsic" "$worst_val, but exec wrapper $wrap can change JAVA_TOOL_OPTIONS" unknown
        else
            chk "base64 intrinsic" "$worst_val" "$worst_st"
        fi
        end_block
    done < "$TMP/lambda"
}

# -------------------------------------------------------------------- ecs ---

ECS_JQ="$JQ_WL"'
def envmap: map({(.name): .value}) | add // {};
($tdm[0]) as $TD | ($cim[0]) as $CI |
[ .tasks[] | . as $t | ($TD[$t.taskDefinitionArn]) as $td | select($td != null) |
  ($CI[$t.containerInstanceArn // ""] // {}) as $ci |
  $td.containerDefinitions[] | . as $c |
  (($t.overrides.containerOverrides // []) | map(select(.name == $c.name)) | .[0] // {}) as $o |
  ((($c.environment // []) | envmap) + (($o.environment // []) | envmap)) as $env |
  (($c.entryPoint // []) + (($o.command // $c.command) // [])) as $argv |
  {
    group: ($t.group // "-" | sub("^service:"; "")),
    launch: ($t.launchType // $t.capacityProviderName // "-"),
    itype: ($ci.type // "-"),
    carch: ($ci.arch // $td.runtimePlatform.cpuArchitecture // "-"),
    name: $c.name, image: ($c.image // "-"),
    jto: ($env.JAVA_TOOL_OPTIONS | wl), jdko: ($env.JDK_JAVA_OPTIONS | wl),
    jo: ($env._JAVA_OPTIONS | wl), jopts: ($env.JAVA_OPTS | wl),
    cmd: ($argv | join(" ") | wl),
    javacmd: (($argv | map(select(test("(^|/)java(\\.exe)?$|(^|[\\s/])java\\s"))) | length) > 0),
    envsig: (($env | keys | map(select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|JAVA_HOME|JAVA_OPTS)$"))) | length) > 0),
    secjava: ([$c.secrets[]?.name | select(test("^(JAVA_TOOL_OPTIONS|_JAVA_OPTIONS|JDK_JAVA_OPTIONS|JAVA_OPTS)$"))] | join(",")),
    envfiles: ((($c.environmentFiles // []) | length) > 0)
  }
] | group_by([.group, .launch, .itype, .carch, .name, .image, .jto, .jdko, .jo, .jopts, .cmd, .secjava]) | .[]
  | (.[0] + {n: length})
  | [.group, .launch, .itype, .carch, .name, .image, .jto, .jdko, .jo, .jopts, .cmd,
     (.javacmd | tostring), (.envsig | tostring), .secjava, (.envfiles | tostring), (.n | tostring)]
  | map(if . == "" then "-" else . end) | @tsv'

# describe in batches of 100: OP KEY REGION CLUSTER FILE_WITH_ARNS OUTPUT
ecs_batches() {
    local op=$1 key=$2 r=$3 c=$4 list=$5 outf=$6 i=0 batch="" a ok=0
    : > "$outf.parts"
    while IFS= read -r a; do
        batch="$batch $a"
        i=$((i + 1))
        if [ "$i" -eq 100 ]; then
            # shellcheck disable=SC2086
            awsj "$r" ecs "$op" --cluster "$c" "$key" $batch >> "$outf.parts" || ok=1
            batch="" i=0
        fi
    done < "$list"
    if [ -n "$batch" ]; then
        # shellcheck disable=SC2086
        awsj "$r" ecs "$op" --cluster "$c" "$key" $batch >> "$outf.parts" || ok=1
    fi
    return $ok
}

scan_ecs() {
    local r=$1 out c cname td
    local group launch itype carch name image jto jdko jo jopts cmd javacmd envsig secjava envfiles n
    if ! out=$(awsj "$r" ecs list-clusters); then
        api_fail ecs "$r" "list-clusters"
        return
    fi
    for c in $(jq -r '.clusterArns[]?' <<<"$out"); do
        cname=${c##*/}
        if ! out=$(awsj "$r" ecs list-tasks --cluster "$c" --desired-status RUNNING); then
            api_fail ecs "$r/$cname" "list-tasks"
            continue
        fi
        jq -r '.taskArns[]?' <<<"$out" > "$TMP/ecs_tasks"
        [ -s "$TMP/ecs_tasks" ] || continue
        if ! ecs_batches describe-tasks --tasks "$r" "$c" "$TMP/ecs_tasks" "$TMP/ecs_dt"; then
            api_fail ecs "$r/$cname" "describe-tasks"
            continue
        fi
        jq -s '{tasks: map(.tasks[]?)}' "$TMP/ecs_dt.parts" > "$TMP/ecs_dt.json"

        jq -r '.tasks[].containerInstanceArn // empty' "$TMP/ecs_dt.json" | sort -u > "$TMP/ecs_ci"
        echo '{}' > "$TMP/ecs_cim.json"
        if [ -s "$TMP/ecs_ci" ]; then
            if ecs_batches describe-container-instances --container-instances "$r" "$c" "$TMP/ecs_ci" "$TMP/ecs_dci"; then
                jq -s '[.[].containerInstances[]? | {(.containerInstanceArn): {
                        type: ([.attributes[]? | select(.name == "ecs.instance-type") | .value][0]),
                        arch: ([.attributes[]? | select(.name == "ecs.cpu-architecture") | .value][0])}}]
                       | add // {}' "$TMP/ecs_dci.parts" > "$TMP/ecs_cim.json"
            fi
        fi

        rm -rf "$TMP/ecs_td"
        mkdir "$TMP/ecs_td"
        for td in $(jq -r '.tasks[].taskDefinitionArn' "$TMP/ecs_dt.json" | sort -u); do
            # Tasks whose definition cannot be read are reported, not dropped.
            local tdf
            tdf="$TMP/ecs_td/$(printf '%s' "$td" | cksum | cut -d' ' -f1).json"
            if ! awsj "$r" ecs describe-task-definition --task-definition "$td" > "$tdf"; then
                rm -f "$tdf"
                api_fail ecs "$r/$cname" "describe-task-definition ${td##*/}"
            fi
        done
        # set -f is on, so no glob: collect the files with find.
        find "$TMP/ecs_td" -name '*.json' -exec cat {} + |
            jq -s 'map({(.taskDefinition.taskDefinitionArn): .taskDefinition}) | add // {}' \
            > "$TMP/ecs_tdm.json" 2>/dev/null || echo '{}' > "$TMP/ecs_tdm.json"

        jq -r --arg wl "$WL" --slurpfile tdm "$TMP/ecs_tdm.json" --slurpfile cim "$TMP/ecs_cim.json" \
            "$ECS_JQ" "$TMP/ecs_dt.json" > "$TMP/ecs_rows" 2>"$TMP/err" || {
            printf 'jq' > "$TMP/err_code"; api_fail ecs "$r/$cname" "task evaluation"; continue; }

        while IFS="$(printf '\t')" read -r group launch itype carch name image jto jdko jo jopts cmd javacmd envsig secjava envfiles n; do
            for v in jto jdko jo jopts cmd secjava itype carch; do
                eval "[ \"\$$v\" = - ] && $v=''"
            done
            image_info "$image"
            if [ "$I_JAVA" -eq 0 ] && [ "$javacmd" = false ] && [ "$envsig" = false ]; then
                skip ecs "$r"
                continue
            fi
            local lt=$launch where=""
            [ -n "$itype" ] && where=", $itype"
            begin_block ecs "$r" "ecs $r $cname/$group $name ($n task$( [ "$n" -gt 1 ] && echo s), $lt$where)"

            # arch
            case "$(printf '%s' "$carch" | tr 'A-Z' 'a-z')" in
                arm64|aarch64) chk arch arm64 ok ;;
                x86_64|amd64) chk arch x86_64 impacted ;;
                *)
                    case "$lt" in
                        FARGATE*) chk arch "x86_64 (Fargate default)" impacted ;;
                        *) chk arch "not visible" unknown ;;
                    esac ;;
            esac

            # vm and version
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

            # avx-512 and flags. Precedence: JAVA_TOOL_OPTIONS < JDK_JAVA_OPTIONS
            # < command line < _JAVA_OPTIONS. JAVA_OPTS only counts if the
            # image's entrypoint passes it to java.
            flags_check "$jto $jdko $cmd $jo" "$jopts" "JAVA_OPTS"
            case "$lt" in
                FARGATE*) avx_check unknown "Fargate does not expose the CPU" "$F_AVX" ;;
                *)
                    if [ -n "$itype" ]; then
                        types_check "$itype"
                        avx_check "$X_ST" "$X_VAL" "$F_AVX"
                    else
                        avx_check unknown "instance type not visible" "$F_AVX"
                    fi ;;
            esac
            if [ -n "$secjava" ] && [ "$F_ST" != ok ]; then
                chk "base64 intrinsic" "$F_VAL; $secjava from a secret, not read" unknown
            else
                chk "base64 intrinsic" "$F_VAL" "$F_ST"
            fi
            [ "$envfiles" = true ] && note "environment files (S3) not read; flags in them are not counted"
            end_block
        done < "$TMP/ecs_rows"
    done
}

# -------------------------------------------------------------------- ec2 ---

decode_b64() { base64 --decode 2>/dev/null || base64 -D 2>/dev/null; }

# user data -> allowed flags (space separated). Nothing else is kept.
userdata_flags() {
    local f="$TMP/ud"
    jq -r '.UserData.Value // empty' | decode_b64 > "$f" 2>/dev/null
    if gzip -t "$f" 2>/dev/null; then
        gzip -dc "$f"
    else
        cat "$f"
    fi | tr -s " \t\r\n\"'\`;" '\n' | grep -E "$WL" | tr '\n' ' ' | sed 's/ *$//'
    rm -f "$f"
}

scan_ec2() {
    local r=$1 out id itype iarch iname pk pv inv ud udf
    if ! out=$(awsj "$r" ec2 describe-instances --filters Name=instance-state-name,Values=running); then
        api_fail ec2 "$r" "describe-instances"
        return
    fi
    jq -r '.Reservations[]?.Instances[]? | [.InstanceId, .InstanceType, (.Architecture // "x86_64"),
           ((.Tags // []) | map(select(.Key == "Name")) | .[0].Value // "-")]
           | map(if . == "" then "-" else . end) | @tsv' <<<"$out" > "$TMP/ec2"
    while IFS="$(printf '\t')" read -r id itype iarch iname; do
        local title="ec2 $r $id"
        [ "$iname" = - ] || title="$title ($iname)"
        title="$title $itype"
        case "$iarch" in arm64*) A_ST=ok ;; *) A_ST=impacted ;; esac
        types_check "$itype"
        if [ "$A_ST" = ok ] || [ "$X_ST" = ok ]; then
            # Ruled out without further calls.
            begin_block ec2 "$r" "$title"
            if [ "$A_ST" = ok ]; then chk arch "$iarch" ok; else chk arch "$iarch" impacted; fi
            chk vm - na
            chk "java version" - na
            chk "avx-512" "$X_VAL" "$X_ST"
            chk "base64 intrinsic" - na
            end_block
            continue
        fi

        udf="" ud=""
        if ud=$(awsj "$r" ec2 describe-instance-attribute --instance-id "$id" --attribute userData); then
            udf=$(userdata_flags <<<"$ud")
        else
            ud="err"
        fi

        if inv=$(awsj "$r" ssm list-inventory-entries --instance-id "$id" --type-name AWS:Application); then
            java_packages <<<"$inv" > "$TMP/ec2_pk"
        else
            inv=""
        fi

        if [ -z "$inv" ] || [ ! -s "$TMP/ec2_pk" ]; then
            begin_block ec2 "$r" "$title"
            chk arch "$iarch" impacted
            if [ -z "$inv" ]; then
                chk vm "no SSM inventory" unknown
            else
                chk vm "no Java package in SSM inventory" unknown
            fi
            chk "java version" "-" unknown
            flags_check "" "$udf" "user data"
            avx_check "$X_ST" "$X_VAL" "$F_AVX"
            chk "base64 intrinsic" "$F_VAL (default; process flags not visible)" "$F_ST"
            [ -n "$inv" ] && note "JDKs from tarballs or containers are not in inventory; run detect-jdk-8392044.sh on the host"
            [ "$ud" = err ] && note "user data not read ($(err_code))"
            end_block
            continue
        fi

        while IFS="$(printf '\t')" read -r pk pv; do
            begin_block ec2 "$r" "$title $pk"
            chk arch "$iarch" impacted
            vm_class "$pk"
            chk vm "$C_VAL ($pk)" "$C_ST"
            pv=$(printf '%s' "$pv" | sed -E 's/^[0-9]+://; s/^([0-9][0-9._]*).*/\1/; s/[._]$//')
            case "$pv" in
                *.*.*) ver_full "$pv" ;;
                [0-9]*) ver_major "${pv%%.*}" "package" ;;
                *) V_VAL="unreadable" V_ST=unknown ;;
            esac
            chk "java version" "$V_VAL" "$V_ST"
            flags_check "" "$udf" "user data"
            avx_check "$X_ST" "$X_VAL" "$F_AVX"
            chk "base64 intrinsic" "$F_VAL (default; process flags not visible)" "$F_ST"
            [ "$ud" = err ] && note "user data not read ($(err_code))"
            end_block
        done < "$TMP/ec2_pk"
    done < "$TMP/ec2"
}

# -------------------------------------------------------------- beanstalk ---

BEANSTALK_JQ="$JQ_WL"'
(.ConfigurationSettings[0].OptionSettings // []) as $o |
def opt($ns; $n): ($o | map(select(.Namespace == $ns and .OptionName == $n)) | .[0].Value);
def envv($n): opt("aws:elasticbeanstalk:application:environment"; $n);
[ (envv("JAVA_TOOL_OPTIONS") | wl), (envv("JDK_JAVA_OPTIONS") | wl), (envv("_JAVA_OPTIONS") | wl),
  (envv("JAVA_OPTS") | wl),
  (opt("aws:elasticbeanstalk:container:tomcat:jvmoptions"; "JVM Options") | wl),
  ((opt("aws:ec2:instances"; "InstanceTypes") // opt("aws:autoscaling:launchconfiguration"; "InstanceType") // "")
     | gsub("[,\\s]+"; " "))
] | map(if . == "" then "-" else . end) | @tsv'

scan_beanstalk() {
    local r=$1 out app env plat major cfg jto jdko jo jopts tom types
    if ! out=$(awsj "$r" elasticbeanstalk describe-environments); then
        api_fail beanstalk "$r" "describe-environments"
        return
    fi
    jq -r '.Environments[]? | select(.Status != "Terminated" and .Status != "Terminating")
           | [.ApplicationName, .EnvironmentName, (.SolutionStackName // .PlatformArn // "-")] | @tsv' \
        <<<"$out" > "$TMP/eb"
    while IFS="$(printf '\t')" read -r app env plat; do
        major=$(printf '%s' "$plat" | sed -nE 's/.*(Corretto|Java)[ _-]?([0-9]+).*/\2/p')
        case "$plat" in
            *Corretto*|*Java*|*Tomcat*|*corretto*|*java*|*tomcat*) ;;
            *) skip beanstalk "$r"; continue ;;
        esac
        begin_block beanstalk "$r" "beanstalk $r $app/$env"
        if ! cfg=$(awsj "$r" elasticbeanstalk describe-configuration-settings \
                --application-name "$app" --environment-name "$env"); then
            chk arch "-" unknown
            chk vm "Corretto ($plat)" impacted
            chk "java version" "-" unknown
            chk "avx-512" "-" unknown
            chk "base64 intrinsic" "configuration not read ($(err_code))" unknown
            end_block
            continue
        fi
        IFS="$(printf '\t')" read -r jto jdko jo jopts tom types <<EOF
$(jq -r --arg wl "$WL" "$BEANSTALK_JQ" <<<"$cfg")
EOF
        for v in jto jdko jo jopts tom types; do
            eval "[ \"\$$v\" = - ] && $v=''"
        done
        types_check "$types"
        chk arch "$A_VAL" "$A_ST"
        chk vm "Corretto ($plat)" impacted
        if [ -n "$major" ]; then
            ver_major "$major" "platform"
            chk "java version" "$V_VAL" "$V_ST"
        else
            chk "java version" "not in platform name" unknown
        fi
        flags_check "$jto $jdko $tom $jo" "$jopts" "JAVA_OPTS"
        avx_check "$X_ST" "$X_VAL" "$F_AVX"
        chk "base64 intrinsic" "$F_VAL" "$F_ST"
        case "$plat" in
            *Tomcat*) ;;
            *) note "Procfile and launch command flags are not visible" ;;
        esac
        end_block
    done < "$TMP/eb"
}

# -------------------------------------------------------------------- emr ---

scan_emr() {
    local r=$1 out id cname cl label rmaj jmaj flags types
    if ! out=$(awsj "$r" emr list-clusters --active); then
        api_fail emr "$r" "list-clusters"
        return
    fi
    jq -r '.Clusters[]? | [.Id, (.Name // "-")] | @tsv' <<<"$out" > "$TMP/emr"
    while IFS="$(printf '\t')" read -r id cname; do
        begin_block emr "$r" "emr $r $id ($cname)"
        if ! cl=$(awsj "$r" emr describe-cluster --cluster-id "$id"); then
            chk arch "-" unknown
            chk vm "Corretto" impacted
            chk "java version" "describe-cluster failed ($(err_code))" unknown
            chk "avx-512" "-" unknown
            chk "base64 intrinsic" "-" unknown
            end_block
            continue
        fi
        label=$(jq -r '.Cluster.ReleaseLabel // ""' <<<"$cl")
        rmaj=$(printf '%s' "$label" | sed -nE 's/^emr-([0-9]+).*/\1/p')
        # JAVA_HOME overrides such as /usr/lib/jvm/java-17-amazon-corretto.x86_64
        jmaj=$(jq -r '[.Cluster.Configurations // [] | .. | strings
                       | capture("(java-|jdk-?|corretto-?)(?<m>[0-9]+)"; "g").m | tonumber
                       | if . == 1 then 8 else . end] | max // empty' <<<"$cl")
        flags=$(jq -r --arg wl "$WL" "$JQ_WL"'[.Cluster.Configurations // [] | .. | strings | wl
                 | select(. != "")] | join(" ")' <<<"$cl")
        types=""
        if out=$(awsj "$r" emr list-instances --cluster-id "$id" --instance-states RUNNING); then
            types=$(jq -r '[.Instances[]?.InstanceType] | unique | .[]' <<<"$out" | tr '\n' ' ')
        fi
        types_check "$types"
        chk arch "$A_VAL" "$A_ST"
        chk vm "Corretto ($label)" impacted
        if [ -n "$jmaj" ]; then
            ver_major "$jmaj" "JAVA_HOME in configurations"
        elif [ -n "$rmaj" ] && [ "$rmaj" -ge 7 ]; then
            ver_major 17 "$label default"
        elif [ -n "$rmaj" ]; then
            ver_major 8 "$label default"
        else
            V_VAL="release label unreadable" V_ST=unknown
        fi
        chk "java version" "$V_VAL" "$V_ST"
        flags_check "" "$flags" "the EMR configuration"
        avx_check "$X_ST" "$X_VAL" "$F_AVX"
        chk "base64 intrinsic" "$F_VAL" "$F_ST"
        end_block
    done < "$TMP/emr"
}

# ------------------------------------------------------------------- main ---

header

HOME_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
if ! ident=$(awsj "$HOME_REGION" sts get-caller-identity); then
    say "error: AWS credentials not usable: $(err_code)"
    echo "unknown"; exit 2
fi
ACCOUNT=$(jq -r '.Account // "?"' <<<"$ident")

# Regions enabled by default in every commercial account (no opt-in).
DEFAULT_REGIONS="us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 eu-central-1
eu-west-1 eu-west-2 eu-west-3 eu-north-1 ap-northeast-1 ap-northeast-2
ap-northeast-3 ap-southeast-1 ap-southeast-2 ap-south-1 sa-east-1"
REGION_NOTE=""
if [ -z "$(printf '%s' "$REGIONS" | tr -d ' ')" ]; then
    if out=$(awsj "$HOME_REGION" ec2 describe-regions); then
        REGIONS=$(jq -r '.Regions[].RegionName' <<<"$out" | sort | tr '\n' ' ')
    elif out=$(awsj "$HOME_REGION" account list-regions \
            --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT); then
        REGIONS=$(jq -r '.Regions[].RegionName' <<<"$out" | sort | tr '\n' ' ')
    else
        REGIONS=$(printf '%s' "$DEFAULT_REGIONS" | tr '\n' ' ')
        REGION_NOTE="note: region listing denied; checking the 17 default regions. Pass -r for opt-in regions."
    fi
fi
REGIONS=$(printf '%s' "$REGIONS" | sed 's/^ *//; s/ *$//; s/  */ /g')

say "account: $ACCOUNT  regions: $REGIONS"
say "services: $SERVICES"
[ -n "$REGION_NOTE" ] && say "$REGION_NOTE"

for r in $REGIONS; do
    for s in $SERVICES; do
        case "$s" in
            lambda) scan_lambda "$r" ;;
            ecs) scan_ecs "$r" ;;
            ec2) scan_ec2 "$r" ;;
            beanstalk) scan_beanstalk "$r" ;;
            emr) scan_emr "$r" ;;
        esac
    done
done

finish
