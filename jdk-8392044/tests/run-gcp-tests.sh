#!/usr/bin/env bash
#
# Tests detect-jdk-8392044-gcp.sh against tests/fake-gcloud and the fixtures
# written below. No Google Cloud account or credentials are used.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../detect-jdk-8392044-gcp.sh"
WORK=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

mkdir -p "$WORK/bin" "$WORK/fx/demo-a" "$WORK/fx/demo-b"
cp "$HERE/fake-gcloud" "$WORK/bin/gcloud"
chmod +x "$WORK/bin/gcloud"
export PATH="$WORK/bin:$PATH"
export FAKE_GCLOUD_DIR="$WORK/fx"
export FAKE_GCLOUD_LOG="$WORK/calls"
unset JDK8392044_FIXED_IN CLOUDSDK_CORE_DISABLE_PROMPTS

verdict() {
    case "$1" in
        0) echo "not impacted" ;;
        1) echo "impacted" ;;
        2) echo "unknown" ;;
        *) echo "" ;;
    esac
}

run() {
    : > "$FAKE_GCLOUD_LOG"
    OUT=$("$@" 2>&1)
    CODE=$?
    LAST=$(printf '%s\n' "$OUT" | sed '/^[[:space:]]*$/d' | tail -1)
}

result() {
    if [ "$1" -eq 1 ]; then
        PASS=$((PASS + 1)); echo "PASS  $2"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  $2"
        printf '%s\n' "$OUT" | sed 's/^/      | /'
    fi
}

assert() {
    local n=$1
    shift
    if [ "$@" ]; then result 1 "$n"; else result 0 "$n"; fi
}

check() {
    local name=$1 want=$2 ok=1 c
    shift 2
    [ "$CODE" = "$want" ] || ok=0
    if [ "$want" != 3 ] && [ "$LAST" != "$(verdict "$want")" ]; then ok=0; fi
    for c in "$@"; do
        printf '%s\n' "$OUT" | grep -qF -- "$c" || ok=0
    done
    result "$ok" "$name"
}

block() {
    printf '%s\n' "$OUT" | awk -v t="$1" '$0 == t { on = 1 } on { print } on && /^  => / { exit }'
}

check_block() {
    local name=$1 title=$2 ok=1 b c
    shift 2
    b=$(block "$title")
    [ -n "$b" ] || ok=0
    for c in "$@"; do
        printf '%s\n' "$b" | grep -qF -- "$c" || ok=0
    done
    result "$ok" "$name"
}

# --------------------------------------------------------------- fixtures ---

F=$WORK/fx
A=$F/demo-a
B=$F/demo-b
echo '[{"projectId":"demo-a"},{"projectId":"demo-b"}]' > "$F/projects.list.json"

# Cloud Run ---------------------------------------------------------------------
svc() { # name image env-json [extra-template-annotations] [labels]
    printf '{"metadata":{"name":"%s","labels":{"cloud.googleapis.com/location":"us-central1"%s}},"spec":{"template":{"metadata":{"annotations":{%s}},"spec":{"containers":[{"image":"%s","env":%s}]}}}}' \
        "$1" "${5:-}" "${4:-}" "$2" "$3"
}
{
    echo '['
    svc api "us-docker.pkg.dev/demo-a/app/api:3f2a" '[{"name":"JAVA_TOOL_OPTIONS","value":"-Xmx1g -Dpw=hunter2"}]' \
        '"run.googleapis.com/base-images":"{\"\":\"us-central1-docker.pkg.dev/serverless-runtimes/google-22/runtimes/java21\"}"'; echo ,
    svc flagged "eclipse-temurin:21.0.5_11-jre" '[{"name":"JAVA_TOOL_OPTIONS","value":"-XX:-UseBASE64Intrinsics"}]'; echo ,
    svc node "node:22" '[]'; echo ,
    svc fn-managed "us-docker.pkg.dev/x/gcf/fn" '[]' '' ',"goog-managed-by":"cloudfunctions"'; echo ,
    svc secret "eclipse-temurin:17" '[{"name":"JAVA_TOOL_OPTIONS","valueFrom":{"secretKeyRef":{"name":"jto","key":"latest"}}}]'; echo ,
    svc j9 "ibm-semeru-runtimes:open-21-jre" '[]'
    echo ']'
} > "$A/run.services.list.json"
cat > "$A/run.jobs.list.json" <<'EOF'
[{"metadata":{"name":"batch","labels":{"cloud.googleapis.com/location":"us-east1"}},
  "spec":{"template":{"spec":{"template":{"spec":{"containers":[{"image":"amazoncorretto:21",
    "command":["java"],"args":["-XX:TieredStopAtLevel=1","-jar","x.jar"]}]}}}}}}]
EOF

# Cloud Run functions -----------------------------------------------------------
cat > "$A/functions.list.json" <<'EOF'
[{"name":"projects/demo-a/locations/us-central1/functions/fn21","environment":"GEN_2",
  "buildConfig":{"runtime":"java21"},"serviceConfig":{"environmentVariables":{"DB_PASSWORD":"hunter2"}}},
 {"name":"projects/demo-a/locations/us-central1/functions/fn17int","environment":"GEN_2",
  "buildConfig":{"runtime":"java17"},"serviceConfig":{"environmentVariables":{"JAVA_TOOL_OPTIONS":"-Xint"}}},
 {"name":"projects/demo-a/locations/europe-west1/functions/fn11","runtime":"java11"},
 {"name":"projects/demo-a/locations/us-central1/functions/py","environment":"GEN_2","buildConfig":{"runtime":"python312"}},
 {"name":"projects/demo-a/locations/us-central1/functions/fnsec","environment":"GEN_2",
  "buildConfig":{"runtime":"java21"},"serviceConfig":{"secretEnvironmentVariables":[{"key":"JAVA_TOOL_OPTIONS","secret":"jto"}]}}]
EOF

# App Engine --------------------------------------------------------------------
cat > "$A/app.versions.list.json" <<'EOF'
[{"service":"default","id":"v1","version":{"servingStatus":"SERVING"}},
 {"service":"api","id":"v2","version":{"servingStatus":"SERVING"}},
 {"service":"py","id":"v3","version":{"servingStatus":"SERVING"}},
 {"service":"flex","id":"v4","version":{"servingStatus":"SERVING"}}]
EOF
echo '{"runtime":"java21","env":"standard","envVariables":{"JAVA_TOOL_OPTIONS":"-Dsecret=hunter2"}}' > "$A/app.versions.describe.v1_default.json"
echo '{"runtime":"java17","env":"standard","entrypoint":{"shell":"java -XX:-UseBASE64Intrinsics -jar app.jar"}}' > "$A/app.versions.describe.v2_api.json"
echo '{"runtime":"python312","env":"standard"}' > "$A/app.versions.describe.v3_py.json"
echo '{"runtime":"java","env":"flexible","runtimeConfig":{"operatingSystem":"ubuntu22","runtimeVersion":"21"}}' > "$A/app.versions.describe.v4_flex.json"

# Compute Engine ----------------------------------------------------------------
vm() { # id name zone machine cpu labels-json metadata-json [status]
    printf '{"id":"%s","name":"%s","zone":"https://www.googleapis.com/compute/v1/projects/demo-a/zones/%s","machineType":"zones/%s/machineTypes/%s","cpuPlatform":"%s","status":"%s","labels":%s,"metadata":{"items":%s}}' \
        "$1" "$2" "$3" "$3" "$4" "$5" "${8:-RUNNING}" "$6" "$7"
}
SS=$(printf '#!/bin/bash\\nexport JAVA_TOOL_OPTIONS=\\"-XX:-UseBASE64Intrinsics -Dkey=hunter2\\"\\n')
{
    echo '['
    vm 1 arm1 us-central1-a t2a-standard-4 "Ampere Altra" '{}' '[]'; echo ,
    vm 2 old1 us-central1-a n2-standard-4 "Intel Cascade Lake" '{}' '[]'; echo ,
    vm 101 hot1 us-central1-a n2-standard-8 "Intel Ice Lake" '{}' '[]'; echo ,
    vm 102 md1 us-central1-a c3-standard-4 "Intel Sapphire Rapids" '{}' "[{\"key\":\"startup-script\",\"value\":\"$SS\"}]"; echo ,
    for n in 1 2 3 4; do
        vm "20$n" "gke-prod-pool-$n" us-central1-b n2-standard-8 "Intel Ice Lake" '{"goog-k8s-cluster-name":"prod-gke"}' '[]'; echo ,
    done
    vm 301 unk1 us-central1-c e2-medium "Unknown CPU Platform" '{}' '[]'; echo ,
    vm 302 off1 us-central1-c c3-standard-4 "Intel Sapphire Rapids" '{}' '[]' TERMINATED
    echo ']'
} > "$A/compute.instances.list.json"
cat > "$A/compute.os-config.inventories.list_us-central1-a.json" <<'EOF'
[{"name":"projects/demo-a/locations/us-central1-a/instances/101/inventory","items":{
   "a":{"installedPackage":{"aptPackage":{"packageName":"openjdk-21-jre-headless","version":"21.0.5+11-1ubuntu1"}}},
   "b":{"installedPackage":{"aptPackage":{"packageName":"ca-certificates-java","version":"20240118"}}}}},
 {"name":"projects/demo-a/locations/us-central1-a/instances/102/inventory","items":{
   "a":{"installedPackage":{"aptPackage":{"packageName":"bash","version":"5.2"}}}}}]
EOF
echo "ERROR: (gcloud.compute.os-config.inventories.list) PERMISSION_DENIED: Permission 'osconfig.inventories.list' denied" \
    > "$A/compute.os-config.inventories.list_us-central1-b.err"
echo "ERROR: (gcloud.compute.os-config.inventories.list) OS Config API has not been used in project demo-a before or it is disabled. reason: SERVICE_DISABLED" \
    > "$A/compute.os-config.inventories.list_us-central1-c.err"

# demo-b: denied, disabled and absent services -------------------------------------
echo "ERROR: (gcloud.run.services.list) PERMISSION_DENIED: Permission 'run.services.list' denied on resource" > "$B/run.services.list.err"
echo "ERROR: (gcloud.run.jobs.list) PERMISSION_DENIED: Permission 'run.jobs.list' denied on resource" > "$B/run.jobs.list.err"
echo "ERROR: (gcloud.functions.list) Cloud Functions API has not been used in project demo-b before or it is disabled." > "$B/functions.list.err"
echo "ERROR: (gcloud.app.versions.list) Project [demo-b] does not contain an App Engine application." > "$B/app.versions.list.err"
# gcloud compute exits 0 with [] when the permission is missing.
echo '[]' > "$B/compute.instances.list.json"
printf "WARNING: Some requests did not succeed.\n - Required 'compute.instances.list' permission for 'projects/demo-b'\n" \
    > "$B/compute.instances.list.warn"

# ------------------------------------------------------------------ tests ---

echo "== full run, demo-a, every workload shown"
run bash "$S" -a -p demo-a
check "demo-a -> impacted" 1 \
    "legend: [!] impacted | OK not impacted | [?] could not check | n/a not checked" \
    "projects: demo-a"
case "$OUT" in *hunter2*|*Dpw=*|*Dsecret*|*Dkey*|*DB_PASSWORD*) ok=0 ;; *) ok=1 ;; esac
result "$ok" "no secret values or non-allowed flags in output"

check_block "run: managed java21 base image" "run demo-a us-central1 service/api" \
    "arch: x86_64 (Cloud Run) [!]" "vm: HotSpot (Google java21 base image) [!]" \
    "java version: 21 (java21 managed base image) [!]" "avx-512: Cloud Run does not expose the CPU [?]" \
    "base64 intrinsic: on [!]" "=> [?] unknown"
check_block "run: intrinsic off -> OK" "run demo-a us-central1 service/flagged" \
    "java version: 21.0.5 (image tag) [!]" "base64 intrinsic: off (-XX:-UseBASE64Intrinsics) OK" "=> OK"
check_block "run: JTO from secret" "run demo-a us-central1 service/secret" \
    "JAVA_TOOL_OPTIONS from a secret, not read [?]"
check_block "run: semeru -> OK" "run demo-a us-central1 service/j9" "vm: OpenJ9 (image) OK"
check_block "run job: command-line TieredStopAtLevel=1" "run demo-a us-east1 job/batch" \
    "base64 intrinsic: unused (TieredStopAtLevel=1) OK"
b=$(printf '%s\n' "$OUT" | grep -cE 'service/(node|fn-managed)')
assert "run: non-Java and function-managed services not shown" "$b" -eq 0

check_block "functions: java21 default -> on" "functions demo-a us-central1 fn21 (GEN_2)" \
    "vm: HotSpot (java21 runtime) [!]" "java version: 21 (java21 managed runtime) [!]" \
    "avx-512: Cloud Run functions do not expose the CPU [?]" "base64 intrinsic: on [!]"
check_block "functions: -Xint -> OK" "functions demo-a us-central1 fn17int (GEN_2)" \
    "base64 intrinsic: unused (-Xint) OK"
check_block "functions: gen1 java11 -> OK" "functions demo-a europe-west1 fn11 (GEN_1)" \
    "java version: 11 (java11 managed runtime) OK"
check_block "functions: secret JTO" "functions demo-a us-central1 fnsec (GEN_2)" \
    "JAVA_TOOL_OPTIONS from a secret, not read [?]"
b=$(block "functions demo-a us-central1 py (GEN_2)")
assert "functions: python skipped" -z "$b"

check_block "appengine: java21 standard" "appengine demo-a default/v1 (standard)" \
    "vm: HotSpot (java21 runtime) [!]" "avx-512: App Engine does not expose the CPU [?]" "base64 intrinsic: on [!]"
check_block "appengine: entrypoint flag -> OK" "appengine demo-a api/v2 (standard)" \
    "base64 intrinsic: off (-XX:-UseBASE64Intrinsics) OK"
check_block "appengine: flexible java 21" "appengine demo-a flex/v4 (flexible)" \
    "java version: 21 (java 21 managed runtime) [!]"
b=$(block "appengine demo-a py/v3 (standard)")
assert "appengine: python skipped" -z "$b"

check_block "compute: Ampere -> OK" "compute demo-a us-central1-a arm1 t2a-standard-4" "arch: arm64 (Ampere Altra) OK"
check_block "compute: Cascade Lake -> OK" "compute demo-a us-central1-a old1 n2-standard-4" \
    "avx-512: no vbmi (Intel Cascade Lake) OK"
check_block "compute: Ice Lake + OpenJDK 21 package -> impacted" \
    "compute demo-a us-central1-a hot1 n2-standard-8 openjdk-21-jre-headless" \
    "vm: HotSpot (openjdk-21-jre-headless) [!]" "java version: 21.0.5 [!]" \
    "avx-512: vbmi+bw (Intel Ice Lake) [!]" "=> [!] impacted"
b=$(printf '%s\n' "$OUT" | grep -c 'ca-certificates-java')
assert "compute: non-JDK java packages ignored" "$b" -eq 0
check_block "compute: startup-script flag -> unknown" "compute demo-a us-central1-a md1 c3-standard-4" \
    "vm: no Java package in OS inventory [?]" \
    "off (-XX:-UseBASE64Intrinsics) only if the startup script reaches the JVM (default; process flags not visible) [?]"
check_block "compute: GKE nodes grouped, inventory denied" "compute demo-a gke:prod-gke n2 (Intel Ice Lake, 4 instances)" \
    "vm: OS inventory denied (PERMISSION_DENIED) [?]" "avx-512: vbmi+bw (Intel Ice Lake) [!]" \
    "note: GKE node (cluster prod-gke)" "note: instances: gke-prod-pool-1 gke-prod-pool-2 gke-prod-pool-3 +1 more"
check_block "compute: unknown CPU, OS Config off" "compute demo-a us-central1-c unk1 e2-medium" \
    "vm: OS Config API not enabled [?]" "avx-512: CPU platform not known (Unknown CPU Platform, e2) [?]"
b=$(printf '%s\n' "$OUT" | grep -c 'off1')
assert "compute: stopped VM ignored" "$b" -eq 0
assert "compute: one inventory call per candidate zone" \
    "$(grep -c 'os-config inventories list' "$FAKE_GCLOUD_LOG")" = 3

if grep -vE '^(projects list|config get-value|run (services|jobs) list|functions list|app versions (list|describe)|compute instances list|compute os-config inventories list)( |$)' \
        "$FAKE_GCLOUD_LOG" | grep -q .; then ok=0; else ok=1; fi
result "$ok" "only read-only calls"

echo "== denied, disabled and absent services"
run bash "$S" -p demo-b
check "demo-b -> unknown" 2 "api: run services list failed: PERMISSION_DENIED [?]" \
    "functions demo-b: not in use (API off or no app)" "appengine demo-b: not in use (API off or no app)" \
    "api: compute instances list failed: PERMISSION_DENIED [?]" "note: 3 listing(s) denied."
cp "$B/compute.instances.list.warn" "$WORK/warn.keep"
echo 'WARNING: Some requests did not succeed.' > "$B/compute.instances.list.warn"
run bash "$S" -p demo-b -s compute
check "partial compute listing -> unknown" 2 "api: compute instances list failed: PARTIAL_FAILURE [?]"
cp "$WORK/warn.keep" "$B/compute.instances.list.warn"

echo "== projects and options"
run bash "$S"
check "projects from projects list" 1 "projects: demo-a demo-b"
mv "$F/projects.list.json" "$F/projects.list.off"
echo "ERROR: (gcloud.projects.list) PERMISSION_DENIED" > "$F/projects.list.err"
run env FAKE_GCLOUD_PROJECT=demo-a bash "$S" -s functions
check "project listing denied -> default project" 2 "projects: demo-a"
run env FAKE_GCLOUD_PROJECT= bash "$S"
check "no projects visible -> unknown" 2 "error: cannot list projects (PERMISSION_DENIED) and no default project set; pass -p"
echo "ERROR: (gcloud.projects.list) You do not currently have an active account selected." > "$F/projects.list.err"
run bash "$S"
check "not logged in -> unknown" 2 "error: gcloud is not logged in (run: gcloud auth login)"
rm -f "$F/projects.list.err"
mv "$F/projects.list.off" "$F/projects.list.json"

run bash "$S" -p demo-a
check "OK workloads counted, not shown" 1 "not shown:" "run demo-a: " "1 without Java"
b=$(block "run demo-a us-central1 service/flagged")
assert "OK block hidden without -a" -z "$b"
run bash "$S" -q -p demo-a
check "quiet prints one line" 1
assert "quiet output is exactly one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1

run env JDK8392044_FIXED_IN="17.0.19 21.0.11" bash "$S" -a -p demo-a -s functions
check "FIXED_IN: managed patch level not visible" 2 \
    "java version: 21 (java21 managed runtime, patch level not visible) [?]"
run env JDK8392044_FIXED_IN="21.0.5" bash "$S" -a -p demo-a -s compute
check_block "FIXED_IN covers 21.0.5 package" \
    "compute demo-a us-central1-a hot1 n2-standard-8 openjdk-21-jre-headless" "java version: 21.0.5 (fixed) OK"

for f in run.services.list functions.list compute.instances.list app.versions.list; do
    mv "$A/$f.json" "$A/$f.keep"
    echo '{"not json' > "$A/$f.json"
    sv=${f%%.*}
    [ "$sv" = app ] && sv=appengine
    run bash "$S" -p demo-a -s "$sv"
    check "malformed $sv listing -> unknown, not OK" 2 "parse error [?]"
    mv "$A/$f.keep" "$A/$f.json"
done

# The AWS and GCP scripts are standalone but must decide identically.
fn_body() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$2"; }
drift=""
for f in ver_key is_fixed fix_matters ver_full ver_major ver_any eval_flags flags_check \
         avx_check vm_class image_info begin_block chk note end_block; do
    a=$(fn_body "$f" "$HERE/../detect-jdk-8392044-aws.sh")
    g=$(fn_body "$f" "$S")
    if [ -z "$a" ] || [ "$a" != "$g" ]; then drift="$drift $f"; fi
done
for v in WL JQ_WL HOTSPOT_RE JDK_RE; do
    [ "$(grep "^$v=" "$HERE/../detect-jdk-8392044-aws.sh")" = "$(grep "^$v=" "$S")" ] || drift="$drift $v"
done
OUT="differs:$drift"
assert "AWS and GCP decision code identical" -z "$drift"

run bash "$S" -s nope
check "bad service -> 3" 3
run bash "$S" --bogus
check "bad argument -> 3" 3

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
