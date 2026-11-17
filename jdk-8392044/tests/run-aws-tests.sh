#!/usr/bin/env bash
#
# Tests detect-jdk-8392044-aws.sh against tests/fake-aws and the fixtures
# written below. No AWS account or credentials are used.
#
# Fixture behaviour follows what the Lambda Java bootstrap actually does
# (public.ecr.aws/lambda/java:17/21/25, checked 2026-11-17):
#   java17/21: TieredStopAtLevel=1 unless JAVA_TOOL_OPTIONS sets TieredCompilation
#   java25:    same, plus only for on-demand init and without
#              AWS_LAMBDA_JAVA_TOOL_OPTIONS

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../detect-jdk-8392044-aws.sh"
WORK=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

mkdir -p "$WORK/bin" "$WORK/fx/us-east-1" "$WORK/fx/us-west-2"
cp "$HERE/fake-aws" "$WORK/bin/aws"
chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH"
export FAKE_AWS_DIR="$WORK/fx"
export FAKE_AWS_LOG="$WORK/calls"
unset JDK8392044_FIXED_IN AWS_PROFILE
export AWS_REGION=us-east-1

verdict() {
    case "$1" in
        0) echo "not impacted" ;;
        1) echo "impacted" ;;
        2) echo "unknown" ;;
        *) echo "" ;;
    esac
}

run() {
    : > "$FAKE_AWS_LOG"
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

# assert NAME TEST-ARGS...: pass when [ TEST-ARGS ] holds.
assert() {
    local n=$1
    shift
    if [ "$@" ]; then result 1 "$n"; else result 0 "$n"; fi
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
    result "$ok" "$name"
}

# block TITLE: the lines of one workload block, title through "=>".
block() {
    printf '%s\n' "$OUT" | awk -v t="$1" '$0 == t { on = 1 } on { print } on && /^  => / { exit }'
}

# check_block NAME TITLE [MUST_CONTAIN]...
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
E=$F/us-east-1
W=$F/us-west-2
ACC=111122223333

echo '{"Account":"'$ACC'","Arn":"arn:aws:iam::'$ACC':role/test"}' > "$F/sts.get-caller-identity.json"
echo '{"Regions":[{"RegionName":"us-west-2"},{"RegionName":"us-east-1"}]}' > "$F/ec2.describe-regions.json"

# Lambda ----------------------------------------------------------------------
fn() { # name runtime arch extra-json
    printf '{"FunctionName":"%s","Version":"$LATEST","Runtime":"%s","Architectures":["%s"],"PackageType":"Zip"%s}' \
        "$1" "$2" "$3" "${4:-}"
}
envj() { printf ',"Environment":{"Variables":%s}' "$1"; }
CP_ARN="arn:aws:lambda:us-east-1:$ACC:capacity-provider:cp1"
{
    echo '{"Functions":['
    fn j17-default java17 x86_64; echo ,
    fn j21-jto-tiered java21 x86_64 "$(envj '{"JAVA_TOOL_OPTIONS":"-XX:+TieredCompilation -Djavax.net.ssl.trustStorePassword=hunter2","DB_PASSWORD":"hunter2"}')"; echo ,
    fn j17-arm java17 arm64 "$(envj '{"JAVA_TOOL_OPTIONS":"-XX:-TieredCompilation"}')"; echo ,
    fn j11 java11 x86_64; echo ,
    fn j25-snap java25 x86_64 ',"SnapStart":{"ApplyOn":"PublishedVersions"}'; echo ,
    fn j25-ondemand java25 x86_64; echo ,
    fn j25-pc java25 x86_64; echo ,
    fn j25-aljto java25 x86_64 "$(envj '{"AWS_LAMBDA_JAVA_TOOL_OPTIONS":"-Xmx1g"}')"; echo ,
    fn j21-jo java21 x86_64 "$(envj '{"_JAVA_OPTIONS":"-XX:-TieredCompilation"}')"; echo ,
    fn j21-off java21 x86_64 "$(envj '{"JAVA_TOOL_OPTIONS":"-XX:-TieredCompilation -XX:-UseBASE64Intrinsics"}')"; echo ,
    fn j21-wrapper java21 x86_64 "$(envj '{"AWS_LAMBDA_EXEC_WRAPPER":"/opt/otel-handler"}')"; echo ,
    fn j21-lmi java21 x86_64 ',"CapacityProviderConfig":{"LambdaManagedInstancesCapacityProviderConfig":{"CapacityProviderArn":"'"$CP_ARN"'"}}'; echo ,
    fn j25-lmi java25 x86_64 ',"CapacityProviderConfig":{"LambdaManagedInstancesCapacityProviderConfig":{"CapacityProviderArn":"'"$CP_ARN"'"}}'; echo ,
    fn j21-kms java21 x86_64 ',"Environment":{"Error":{"ErrorCode":"KMSAccessDeniedException","Message":"x"}}'; echo ,
    fn py python3.12 x86_64; echo ,
    echo '{"FunctionName":"img-java","Version":"$LATEST","PackageType":"Image","Architectures":["x86_64"],"Environment":{"Variables":{"JAVA_TOOL_OPTIONS":"-Xmx1g"}}},'
    echo '{"FunctionName":"img-other","Version":"$LATEST","PackageType":"Image","Architectures":["x86_64"]}'
    echo ']}'
} > "$E/lambda.list-functions.json"
for f in j25-snap j25-ondemand j25-aljto; do
    echo '{"ProvisionedConcurrencyConfigs":[]}' > "$E/lambda.list-provisioned-concurrency-configs_$f.json"
done
echo '{"ProvisionedConcurrencyConfigs":[{"FunctionArn":"x:live","Status":"READY"}]}' \
    > "$E/lambda.list-provisioned-concurrency-configs_j25-pc.json"
echo '{"CapacityProvider":{"InstanceRequirements":{"Architectures":["x86_64"],"AllowedInstanceTypes":["m7i.*","m6i.large"]}}}' \
    > "$E/lambda.get-capacity-provider_cp1.json"
echo 'An error occurred (AccessDeniedException) when calling the ListFunctions operation: denied' \
    > "$W/lambda.list-functions.err"

# ECS -------------------------------------------------------------------------
CL="arn:aws:ecs:us-east-1:$ACC:cluster/prod"
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
CK=$(key "_$CL")
echo '{"clusterArns":["'"$CL"'"]}' > "$E/ecs.list-clusters.json"
echo '{"taskArns":["t1","t2","t3","t4","t5","t6","t7","t8","t9"]}' > "$E/ecs.list-tasks$CK.json"
TD="arn:aws:ecs:us-east-1:$ACC:task-definition"
CI="arn:aws:ecs:us-east-1:$ACC:container-instance/prod"
task() { # arn group taskdef launch ci overrides
    printf '{"taskArn":"%s","group":"service:%s","taskDefinitionArn":"%s/%s","launchType":"%s"%s,"overrides":%s}' \
        "$1" "$2" "$TD" "$3" "$4" "${5:+,\"containerInstanceArn\":\"$CI/$5\"}" "${6:-{\}}"
}
{
    echo '{"tasks":['
    task t1 api api:3 FARGATE; echo ,
    task t2 api api:3 FARGATE; echo ,
    task t3 batch batch:1 EC2 ci1; echo ,
    task t4 legacy legacy:2 EC2 ci2; echo ,
    task t5 graviton graviton:1 FARGATE; echo ,
    task t6 j9 j9:1 FARGATE; echo ,
    task t7 hot hot:1 EC2 ci1 '{"containerOverrides":[{"name":"app","environment":[{"name":"JAVA_TOOL_OPTIONS","value":"-XX:+UseBASE64Intrinsics -Dpw=hunter2"}]}]}'; echo ,
    task t8 sec sec:1 FARGATE; echo ,
    task t9 generic generic:1 EC2 ci1
    echo ']}'
} > "$E/ecs.describe-tasks$CK.json"
cat > "$E/ecs.describe-container-instances$CK.json" <<EOF
{"containerInstances":[
 {"containerInstanceArn":"$CI/ci1","attributes":[{"name":"ecs.instance-type","value":"m7i.large"},{"name":"ecs.cpu-architecture","value":"x86_64"}]},
 {"containerInstanceArn":"$CI/ci2","attributes":[{"name":"ecs.instance-type","value":"m5.xlarge"},{"name":"ecs.cpu-architecture","value":"x86_64"}]}]}
EOF
tdef() { # name:rev containers-json extra
    printf '{"taskDefinition":{"taskDefinitionArn":"%s/%s","containerDefinitions":%s%s}}' "$TD" "$1" "$2" "${3:-}" \
        > "$E/ecs.describe-task-definition$(key "_$TD/$1").json"
}
tdef api:3 '[{"name":"app","image":"public.ecr.aws/docker/library/eclipse-temurin:21-jre","environment":[{"name":"JAVA_TOOL_OPTIONS","value":"-Xmx512m -Dpw=hunter2"}]},{"name":"envoy","image":"envoyproxy/envoy:v1.31"}]'
tdef batch:1 '[{"name":"app","image":"'$ACC'.dkr.ecr.us-east-1.amazonaws.com/batch:abc","command":["java","-XX:-UseBASE64Intrinsics","-jar","x.jar"]}]'
tdef legacy:2 '[{"name":"app","image":"amazoncorretto:17.0.13"}]'
tdef graviton:1 '[{"name":"app","image":"eclipse-temurin:21"}]' ',"runtimePlatform":{"cpuArchitecture":"ARM64"}'
tdef j9:1 '[{"name":"app","image":"ibm-semeru-runtimes:open-21-jre"}]'
tdef hot:1 '[{"name":"app","image":"amazoncorretto:21.0.5","environmentFiles":[{"value":"arn:aws:s3:::b/app.env","type":"s3"}]}]'
tdef sec:1 '[{"name":"app","image":"eclipse-temurin:17","secrets":[{"name":"JAVA_TOOL_OPTIONS","valueFrom":"arn:aws:ssm:us-east-1:'$ACC':parameter/jto"}]}]'
tdef generic:1 '[{"name":"app","image":"myorg/app-jre:17"}]'
echo '{"clusterArns":[]}' > "$W/ecs.list-clusters.json"

# EC2 -------------------------------------------------------------------------
inst() { printf '{"InstanceId":"%s","InstanceType":"%s","Architecture":"%s","Tags":[{"Key":"Name","Value":"%s"}]}' "$@"; }
{
    echo '{"Reservations":[{"Instances":['
    inst i-arm m7g.large arm64 graviton; echo ,
    inst i-old m5.large x86_64 old; echo ,
    inst i-hot m7i.large x86_64 hot; echo ,
    inst i-ud c7i.xlarge x86_64 ud; echo ,
    inst i-noinv m6i.large x86_64 noinv; echo ,
    inst i-j8 m7a.large x86_64 j8; echo ,
    inst i-unk zz9.large x86_64 unk
    echo ']}]}'
} > "$E/ec2.describe-instances.json"
apps() { printf '{"Entries":[{"Name":"bash","Version":"5.2"}%s]}' "${2:-}" > "$E/ssm.list-inventory-entries_$1.json"; }
apps i-hot ',{"Name":"java-21-amazon-corretto-headless","Version":"1:21.0.5+11-1.amzn2023"},{"Name":"javapackages-filesystem","Version":"6.0.0"}'
apps i-ud ',{"Name":"openjdk-17-jre-headless","Version":"17.0.13+11-1~22.04"}'
apps i-j8 ',{"Name":"java-1.8.0-amazon-corretto","Version":"1.8.0_432.b06-1"}'
apps i-unk
echo 'An error occurred (InvalidInstanceId) when calling the ListInventoryEntries operation: not managed' \
    > "$E/ssm.list-inventory-entries_i-noinv.err"
UD=$(printf '#!/bin/bash\nexport JAVA_TOOL_OPTIONS="-XX:-UseBASE64Intrinsics -Dsecret=hunter2"\nexport API_KEY=hunter2\n' |
    gzip -c | base64 | tr -d '\n')
echo '{"UserData":{"Value":"'"$UD"'"}}' > "$E/ec2.describe-instance-attribute_i-ud.json"
for i in i-hot i-noinv i-j8 i-unk; do
    echo '{"UserData":{}}' > "$E/ec2.describe-instance-attribute_$i.json"
done
echo '{"Reservations":[]}' > "$W/ec2.describe-instances.json"

# Elastic Beanstalk -----------------------------------------------------------
cat > "$E/elasticbeanstalk.describe-environments.json" <<'EOF'
{"Environments":[
 {"ApplicationName":"shop","EnvironmentName":"shop-c1","Status":"Ready","SolutionStackName":"64bit Amazon Linux 2023 v4.3.0 running Corretto 21"},
 {"ApplicationName":"shop","EnvironmentName":"shop-tc","Status":"Ready","SolutionStackName":"64bit Amazon Linux 2023 v5.4.0 running Tomcat 10 Corretto 17"},
 {"ApplicationName":"shop","EnvironmentName":"shop-docker","Status":"Ready","SolutionStackName":"64bit Amazon Linux 2023 v4.4.0 running Docker"},
 {"ApplicationName":"shop","EnvironmentName":"shop-hot","Status":"Ready","SolutionStackName":"64bit Amazon Linux 2023 v4.3.0 running Corretto 17"},
 {"ApplicationName":"shop","EnvironmentName":"shop-gone","Status":"Terminated","SolutionStackName":"64bit Amazon Linux 2023 v4.3.0 running Corretto 17"}]}
EOF
ebcfg() { # env options-json
    printf '{"ConfigurationSettings":[{"OptionSettings":%s}]}' "$2" > "$E/elasticbeanstalk.describe-configuration-settings_$1.json"
}
ebcfg shop-c1 '[{"Namespace":"aws:ec2:instances","OptionName":"InstanceTypes","Value":"m7i.large,m6i.large"},
 {"Namespace":"aws:elasticbeanstalk:application:environment","OptionName":"JAVA_TOOL_OPTIONS","Value":"-XX:TieredStopAtLevel=1 -Dkey=hunter2"}]'
ebcfg shop-tc '[{"Namespace":"aws:autoscaling:launchconfiguration","OptionName":"InstanceType","Value":"t4g.small"},
 {"Namespace":"aws:elasticbeanstalk:container:tomcat:jvmoptions","OptionName":"JVM Options","Value":"-Xmx1g"}]'
ebcfg shop-hot '[{"Namespace":"aws:ec2:instances","OptionName":"InstanceTypes","Value":"c7i.large"}]'
echo '{"Environments":[]}' > "$W/elasticbeanstalk.describe-environments.json"

# EMR -------------------------------------------------------------------------
echo '{"Clusters":[{"Id":"j-1","Name":"spark7"},{"Id":"j-2","Name":"old6"},{"Id":"j-3","Name":"m5j17"}]}' \
    > "$E/emr.list-clusters.json"
echo '{"Cluster":{"ReleaseLabel":"emr-7.2.0","Configurations":[{"Classification":"spark-defaults","Properties":{"spark.executor.extraJavaOptions":"-XX:-UseBASE64Intrinsics -Dtoken=hunter2"}}]}}' \
    > "$E/emr.describe-cluster_j-1.json"
echo '{"Cluster":{"ReleaseLabel":"emr-6.15.0"}}' > "$E/emr.describe-cluster_j-2.json"
echo '{"Cluster":{"ReleaseLabel":"emr-6.15.0","Configurations":[{"Classification":"hadoop-env","Configurations":[{"Classification":"export","Properties":{"JAVA_HOME":"/usr/lib/jvm/java-17-amazon-corretto.x86_64"}}]}]}}' \
    > "$E/emr.describe-cluster_j-3.json"
echo '{"Instances":[{"InstanceType":"m7i.xlarge"},{"InstanceType":"m7i.xlarge"}]}' > "$E/emr.list-instances_j-1.json"
echo '{"Instances":[{"InstanceType":"m7i.xlarge"}]}' > "$E/emr.list-instances_j-2.json"
echo '{"Instances":[{"InstanceType":"m5.xlarge"}]}' > "$E/emr.list-instances_j-3.json"
echo '{"Clusters":[]}' > "$W/emr.list-clusters.json"

# ------------------------------------------------------------------ tests ---

echo "== full run, us-east-1, every workload shown"
run bash "$S" -a -r us-east-1
check "us-east-1 -> impacted" 1 \
    "legend: [!] impacted | OK not impacted | [?] could not check | n/a not checked" \
    "account: $ACC  regions: us-east-1"
case "$OUT" in *hunter2*|*trustStorePassword*|*Dpw=*|*Dsecret*|*Dtoken*|*Dkey*|*API_KEY*) ok=0 ;; *) ok=1 ;; esac
result "$ok" "no secret values or non-allowed flags in output"

check_block "lambda java17 default: Lambda C1 default" "lambda us-east-1 j17-default" \
    "vm: Corretto (java17 runtime) [!]" "java version: 17 (java17 managed runtime) [!]" \
    "avx-512: Lambda does not expose the CPU [?]" \
    "base64 intrinsic: unused (Lambda default TieredStopAtLevel=1) OK" "=> OK"
check_block "lambda JTO TieredCompilation drops default" "lambda us-east-1 j21-jto-tiered" \
    "base64 intrinsic: on (on-demand: TieredCompilation in JAVA_TOOL_OPTIONS drops Lambda's TieredStopAtLevel=1) [!]" \
    "=> [?] unknown"
check_block "lambda arm64 -> OK" "lambda us-east-1 j17-arm" "arch: arm64 OK" "avx-512: - n/a" "=> OK"
check_block "lambda java11 -> OK" "lambda us-east-1 j11" "java version: 11 (java11 managed runtime) OK" "=> OK"
check_block "lambda java25 SnapStart" "lambda us-east-1 j25-snap" \
    "base64 intrinsic: on (snap-start: no TieredStopAtLevel=1 default for this init type) [!]"
check_block "lambda java25 on-demand -> OK" "lambda us-east-1 j25-ondemand" \
    "base64 intrinsic: unused (Lambda default TieredStopAtLevel=1) OK" "=> OK"
check_block "lambda java25 provisioned concurrency" "lambda us-east-1 j25-pc" \
    "base64 intrinsic: on (provisioned-concurrency: no TieredStopAtLevel=1 default for this init type) [!]"
check_block "lambda java25 AWS_LAMBDA_JAVA_TOOL_OPTIONS" "lambda us-east-1 j25-aljto" \
    "on (on-demand: AWS_LAMBDA_JAVA_TOOL_OPTIONS drops Lambda's TieredStopAtLevel=1) [!]"
check_block "lambda _JAVA_OPTIONS overrides" "lambda us-east-1 j21-jo" \
    "on (on-demand: _JAVA_OPTIONS overrides Lambda's TieredStopAtLevel=1) [!]"
check_block "lambda intrinsic off" "lambda us-east-1 j21-off" \
    "base64 intrinsic: off (-XX:-UseBASE64Intrinsics) OK" "=> OK"
check_block "lambda exec wrapper -> unknown" "lambda us-east-1 j21-wrapper" \
    "exec wrapper /opt/otel-handler can change JAVA_TOOL_OPTIONS [?]" "=> [?] unknown"
check_block "lambda managed instances java21 -> OK" "lambda us-east-1 j21-lmi" \
    "avx-512: vbmi+bw (m6i m7i) [!]" "base64 intrinsic: unused (Lambda default TieredStopAtLevel=1) OK" "=> OK"
check_block "lambda managed instances java25 -> impacted" "lambda us-east-1 j25-lmi" \
    "avx-512: vbmi+bw (m6i m7i) [!]" \
    "base64 intrinsic: on (lambda-managed-instances: no TieredStopAtLevel=1 default for this init type) [!]" \
    "=> [!] impacted"
check_block "lambda KMS env -> unknown" "lambda us-east-1 j21-kms" \
    "base64 intrinsic: environment unreadable (KMSAccessDeniedException) [?]"
check_block "lambda image with Java env -> unknown" "lambda us-east-1 img-java" \
    "vm: container image not inspected [?]" "=> [?] unknown"
b=$(block "lambda us-east-1 py")$(block "lambda us-east-1 img-other")
assert "lambda without Java signals skipped" -z "$b"

check_block "ecs fargate temurin, 2 tasks grouped" "ecs us-east-1 prod/api app (2 tasks, FARGATE)" \
    "arch: x86_64 (Fargate default) [!]" "vm: HotSpot (image) [!]" "java version: 21 (image tag) [!]" \
    "avx-512: Fargate does not expose the CPU [?]" "base64 intrinsic: on [!]" "=> [?] unknown"
b=$(printf '%s\n' "$OUT" | grep -c 'envoy')
assert "ecs non-Java sidecar skipped" "$b" -eq 0
check_block "ecs command-line flag" "ecs us-east-1 prod/batch app (1 task, EC2, m7i.large)" \
    "vm: image not inspected [?]" "avx-512: vbmi+bw (m7i) [!]" \
    "base64 intrinsic: off (-XX:-UseBASE64Intrinsics) OK" "=> OK"
check_block "ecs m5 -> OK" "ecs us-east-1 prod/legacy app (1 task, EC2, m5.xlarge)" \
    "java version: 17.0.13 (image tag) [!]" "avx-512: no vbmi (m5) OK"
check_block "ecs ARM64 fargate -> OK" "ecs us-east-1 prod/graviton app (1 task, FARGATE)" "arch: arm64 OK"
check_block "ecs semeru -> OK" "ecs us-east-1 prod/j9 app (1 task, FARGATE)" "vm: OpenJ9 (image) OK"
check_block "ecs override env, m7i -> impacted" "ecs us-east-1 prod/hot app (1 task, EC2, m7i.large)" \
    "java version: 21.0.5 (image tag) [!]" "base64 intrinsic: on [!]" \
    "note: environment files (S3) not read" "=> [!] impacted"
check_block "ecs JTO from secret -> unknown" "ecs us-east-1 prod/sec app (1 task, FARGATE)" \
    "JAVA_TOOL_OPTIONS from a secret, not read [?]"
check_block "ecs vendorless jre image -> vm unknown" "ecs us-east-1 prod/generic app (1 task, EC2, m7i.large)" \
    "vm: vendor not visible (image) [?]" "=> [?] unknown"

check_block "ec2 graviton -> OK" "ec2 us-east-1 i-arm (graviton) m7g.large" "arch: arm64 OK"
check_block "ec2 m5 -> OK" "ec2 us-east-1 i-old (old) m5.large" "avx-512: no vbmi (m5) OK"
check_block "ec2 corretto 21 on m7i -> impacted" \
    "ec2 us-east-1 i-hot (hot) m7i.large java-21-amazon-corretto-headless" \
    "vm: HotSpot (java-21-amazon-corretto-headless) [!]" "java version: 21.0.5 [!]" \
    "base64 intrinsic: on (default; process flags not visible) [!]" "=> [!] impacted"
b=$(printf '%s\n' "$OUT" | grep -c 'javapackages')
assert "ec2 non-JDK java packages ignored" "$b" -eq 0
check_block "ec2 gzip user data flag -> unknown" \
    "ec2 us-east-1 i-ud (ud) c7i.xlarge openjdk-17-jre-headless" \
    "java version: 17.0.13 [!]" \
    "off (-XX:-UseBASE64Intrinsics) only if user data reaches the JVM (default; process flags not visible) [?]"
check_block "ec2 no SSM -> unknown" "ec2 us-east-1 i-noinv (noinv) m6i.large" "vm: no SSM inventory [?]"
check_block "ec2 java 8 -> OK" "ec2 us-east-1 i-j8 (j8) m7a.large java-1.8.0-amazon-corretto" \
    "java version: 1.8.0_432 (< 17.0.6) OK"
check_block "ec2 unknown family" "ec2 us-east-1 i-unk (unk) zz9.large" \
    "vm: no Java package in SSM inventory [?]" "avx-512: family not in table (zz9) [?]"
grep -q 'i-arm\|i-old' "$FAKE_AWS_LOG"; result $? "ec2 ruled-out instances get no further calls"

check_block "beanstalk TieredStopAtLevel=1 -> OK" "beanstalk us-east-1 shop/shop-c1" \
    "arch: x86_64 [!]" "java version: 21 (platform) [!]" "avx-512: vbmi+bw (m6i m7i) [!]" \
    "base64 intrinsic: unused (TieredStopAtLevel=1) OK" "=> OK"
check_block "beanstalk tomcat on graviton -> OK" "beanstalk us-east-1 shop/shop-tc" "arch: arm64 OK"
check_block "beanstalk corretto 17 on c7i -> impacted" "beanstalk us-east-1 shop/shop-hot" \
    "java version: 17 (platform) [!]" "base64 intrinsic: on [!]" \
    "note: Procfile and launch command flags are not visible" "=> [!] impacted"
b=$(block "beanstalk us-east-1 shop/shop-docker")$(block "beanstalk us-east-1 shop/shop-gone")
assert "beanstalk docker and terminated skipped" -z "$b"

check_block "emr 7 spark flag -> unknown" "emr us-east-1 j-1 (spark7)" \
    "java version: 17 (emr-7.2.0 default) [!]" "avx-512: vbmi+bw (m7i) [!]" \
    "only if the EMR configuration reaches the JVM [?]" "=> [?] unknown"
check_block "emr 6 java 8 -> OK" "emr us-east-1 j-2 (old6)" "java version: 8 (emr-6.15.0 default) OK"
check_block "emr 6 JAVA_HOME 17 on m5 -> OK" "emr us-east-1 j-3 (m5j17)" \
    "java version: 17 (JAVA_HOME in configurations) [!]" "avx-512: no vbmi (m5) OK" "=> OK"

if grep -vE ' (lambda (list-functions|list-provisioned-concurrency-configs|get-capacity-provider)|ecs (list-clusters|list-tasks|describe-tasks|describe-container-instances|describe-task-definition)|ec2 (describe-instances|describe-instance-attribute|describe-regions)|ssm list-inventory-entries|elasticbeanstalk (describe-environments|describe-configuration-settings)|emr (list-clusters|describe-cluster|list-instances)|sts get-caller-identity)( |$)' \
        "$FAKE_AWS_LOG" | grep -q .; then
    ok=0
else
    ok=1
fi
result "$ok" "only read-only API calls"

echo "== default output and options"
run bash "$S" -r us-east-1
check "OK workloads counted, not shown" 1 "not shown:" "lambda us-east-1: " "ec2 us-east-1: " \
    "1 without Java"
b=$(block "lambda us-east-1 j17-default")
assert "OK block hidden without -a" -z "$b"

run bash "$S" -q -r us-east-1
check "quiet prints one line" 1
assert "quiet output is exactly one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1

run bash "$S" -r us-west-2
check "denied listing -> unknown" 2 "api: list-functions failed: AccessDeniedException [?]"

run bash "$S"
check "regions from describe-regions" 1 "regions: us-east-1 us-west-2"

run bash "$S" -s lambda -r us-east-1
check "service filter" 1 "services: lambda"
grep -q ' ecs \| ec2 \| emr ' "$FAKE_AWS_LOG"; result $? "service filter limits calls"

run env JDK8392044_FIXED_IN="17.0.19 21.0.11 25.0.3" bash "$S" -a -s lambda,beanstalk -r us-east-1
check "FIXED_IN: managed patch level not visible" 2 \
    "java version: 21 (java21 managed runtime, patch level not visible) [?]"
check_block "FIXED_IN full version still decides" "lambda us-east-1 j11" "java version: 11 (java11 managed runtime) OK"

run env JDK8392044_FIXED_IN="21.0.5" bash "$S" -a -s ecs -r us-east-1
check_block "FIXED_IN covers 21.0.5 image tag" "ecs us-east-1 prod/hot app (1 task, EC2, m7i.large)" \
    "java version: 21.0.5 (fixed) (image tag) OK"

run bash "$S" -s nope
check "bad service -> 3" 3
run bash "$S" --bogus
check "bad argument -> 3" 3

run env PATH="/usr/bin:/bin" bash -c 'mkdir -p "$0/nobin"; PATH="$0/nobin:/usr/bin:/bin"; command -v aws >/dev/null && exit 9; bash "$1"' "$WORK" "$S"
if [ "$CODE" = 9 ]; then
    echo "SKIP  missing aws CLI (aws is installed system-wide)"
else
    check "missing aws CLI -> unknown" 2 "error: aws not found"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
