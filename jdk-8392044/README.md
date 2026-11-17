# JDK-8392044 host detection

Fleet checks for the HotSpot x86-64 AVX-512 Base64 `decodeBlock` stub heap
overwrite. A 1-3 byte tail ending in `=` makes the stub store 64 bytes past
the destination buffer.

| Script | Platforms |
|---|---|
| `detect-jdk-8392044.sh` | Linux, macOS; bash 3.2+ |
| `Detect-Jdk8392044.ps1` | Windows; PowerShell 5.1 and 7 |
| `detect-jdk-8392044-aws.sh` | AWS control plane (Lambda, ECS/Fargate, EC2, Beanstalk, EMR); aws CLI v2 + jq |

## What counts as impacted

All five conditions must hold for at least one JVM on the host:

1. HotSpot VM: any OpenJDK build, Oracle JDK, or GraalVM JDK. Only HotSpot
   generates the stub. OpenJ9 and GCJ are `OK`. Azul Prime (Zing), which
   replaces C2 with its own JIT, and any VM name not recognized as HotSpot
   are `[?]`, never `[!]`.
2. x86-64 JVM on an x86-64 host.
3. Version 17.0.6 or later, and not at or above a version listed in `FIXED_IN`.
4. The JVM reports `avx512_vbmi` and `avx512bw`, and `UseAVX >= 3`.
5. Base64 intrinsics are on and C2/JVMCI can compile. These turn it off:
   `-XX:-UseBASE64Intrinsics`, `-XX:DisableIntrinsic=_base64_decodeBlock`,
   `-Xint`, `-XX:TieredStopAtLevel` below 4.

The scripts read conditions 4 and 5 from the JVM itself. They run each JVM
with `-version`, `-Xlog:os+cpu` and `-XX:+PrintFlagsFinal`, and replay the
flags each running process was started with. The answer therefore reflects
hypervisor CPU masking as well as `UseAVX` tuning. Only whitelisted flags are
replayed, so a probe never loads an agent or any application code.

## Output

```
JDK-8392044 check: HotSpot x86-64 AVX-512 Base64 decode heap overwrite
legend: [!] impacted | OK not impacted | [?] could not check | n/a not checked
checks: arch, vm, java version, avx-512, base64 intrinsic. A JVM is impacted only if all five show [!].
host:   Linux x86_64

/usr/lib/jvm/temurin-17-jdk-amd64/bin/java (pid 4242, container)
  arch: amd64 [!]
  vm: OpenJDK 64-Bit Server VM [!]
  java version: 17.0.21 [!]
  avx-512: vbmi+bw, UseAVX=3 [!]
  base64 intrinsic: on [!]
  => [!] impacted

impacted
```

Each JVM is one block. Each check ends in `[!]` (points to impacted), `OK`
(rules this JVM out), `[?]` (could not check) or `n/a` (not checked, because
an earlier check already ruled the JVM out). The title line names the binary
and where it came from: `installed`, `pid N`, `container`,
`embedded in <program>`, `-j`. A JVM that cannot be probed gets a single
check line instead, e.g.
`binary: replaced on disk after start, restart it [?]`. `-q` / `-Quiet`
prints only the verdict line.

## Exit codes

| Code | Last line | Meaning |
|---|---|---|
| 0 | `not impacted` | no JVM meets all conditions, or no JVM was found |
| 1 | `impacted` | at least one JVM meets all conditions |
| 2 | `unknown` | at least one JVM could not be evaluated and none is impacted |
| 3 | (usage) | bad arguments (bash only) |

`powershell.exe` also exits 1 when it rejects the arguments before the script
runs. Treat exit 1 as impacted only when the last line is `impacted`.

## Usage

```sh
sudo ./detect-jdk-8392044.sh            # per-JVM lines, then the verdict
sudo ./detect-jdk-8392044.sh -q         # verdict only
./detect-jdk-8392044.sh -j /srv/app/jdk/bin/java -o "-XX:UseAVX=2"
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Detect-Jdk8392044.ps1 -Quiet
.\Detect-Jdk8392044.ps1 -Java 'D:\apps\jdk\bin\java.exe' -JvmOptions:'-XX:UseAVX=2'
```

Use the colon form for `-JvmOptions`. Alternatively, set
`JDK8392044_JVM_OPTIONS`, which both scripts read.

Once fixed builds ship, set `JDK8392044_FIXED_IN` (space separated, e.g.
`"17.0.19 21.0.11 25.0.3"`) or edit the default in each script. The highest
entry also covers every later feature release. As of 2026-11-16 there is no
public fix.

## Coverage

| | bash (Linux) | bash (macOS) | PowerShell (Windows) |
|---|---|---|---|
| `java` on PATH, `JAVA_HOME`, common install dirs | yes | yes | yes, plus JavaSoft registry |
| Running `java` processes | yes | yes | yes |
| Embedded JVMs (`libjvm.so` / `jvm.dll`) | yes | no | yes, incl. Procrun options from the registry |
| Process environment (`JAVA_TOOL_OPTIONS` etc.) | yes, as root | no | machine-level vars only |
| JVMs in containers | yes, root + `nsenter` | no | no |
| JVM binary replaced since start | reported `unknown` | reported `unknown` | not detected |

Not parsed: `-XX:Flags=`, `-XX:VMOptionsFile=`, `@argfiles`. JVMs that use
them are tagged in the output.

## AWS managed runtimes

`detect-jdk-8392044-aws.sh` applies the same five checks to workloads it can
see through read-only AWS APIs. Output, markers and exit codes match the
host scripts. Workloads that are OK are counted under `not shown:`; `-a`
prints them too.

```sh
AWS_PROFILE=prod ./detect-jdk-8392044-aws.sh             # all enabled regions
./detect-jdk-8392044-aws.sh -r us-east-1,eu-west-1 -s lambda,ecs -q
```

| Service | Read from | Not visible |
|---|---|---|
| Lambda | runtime, architecture, `JAVA_TOOL_OPTIONS`, `AWS_LAMBDA_JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS`, SnapStart, provisioned concurrency, Managed Instances capacity provider | CPU (`[?]`, except Managed Instances), container image contents |
| ECS / Fargate | running tasks: image tag, task definition and run-task override env, command, container instance type | Fargate CPU (`[?]`), image `ENV`, S3 environment files, secret values |
| EC2 | instance family, Java packages in SSM inventory, JVM flags in user data, EKS cluster tags | per-process flags, tarball and container JDKs, pods on EKS nodes |
| Elastic Beanstalk | platform (Corretto/Java/Tomcat), environment properties, Tomcat JVM options, instance types | Procfile flags |
| EMR | release label default JDK, `JAVA_HOME` overrides, flags in configurations, running instance types | per-daemon flags |

Lambda's Java bootstrap (java17, java21 and java25, checked against
`public.ecr.aws/lambda/java` on 2026-11-17) adds
`-XX:+TieredCompilation -XX:TieredStopAtLevel=1`, which keeps the intrinsic
unused. The bootstrap omits that default, and the function goes back to C2
with the intrinsic in use, when:

- `JAVA_TOOL_OPTIONS` contains `-XX:+TieredCompilation` or
  `-XX:-TieredCompilation` (all versions);
- `_JAVA_OPTIONS` overrides it (all versions);
- java25: `AWS_LAMBDA_JAVA_TOOL_OPTIONS` is set, or the init type is
  SnapStart, provisioned concurrency or Lambda Managed Instances.

AVX-512 is decided by EC2 instance family: Intel Ice Lake and later and AMD
Zen 4 and later have VBMI. Families not in the table are `[?]`. Flags found
somewhere that may not reach the JVM (user data, EMR configurations,
`JAVA_OPTS`) can only move a check to `[?]`, never to `OK`. Environment
values and user data are reduced to the allowed JVM flags before anything is
printed, so secrets in them never reach the output.

### IAM permissions

All calls are read-only. The AWS managed policy `ReadOnlyAccess` covers
them; a minimal policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Resource": "*",
    "Action": [
      "sts:GetCallerIdentity", "ec2:DescribeRegions", "account:ListRegions",
      "lambda:ListFunctions", "lambda:ListProvisionedConcurrencyConfigs",
      "lambda:GetCapacityProvider",
      "ecs:ListClusters", "ecs:ListTasks", "ecs:DescribeTasks",
      "ecs:DescribeContainerInstances", "ecs:DescribeTaskDefinition",
      "ec2:DescribeInstances", "ec2:DescribeInstanceAttribute",
      "ssm:ListInventoryEntries",
      "elasticbeanstalk:DescribeEnvironments",
      "elasticbeanstalk:DescribeConfigurationSettings",
      "emr:ListClusters", "emr:DescribeCluster", "emr:ListInstances"
    ]
  }]
}
```

`lambda:ListFunctions`, `ecs:DescribeTaskDefinition`,
`ec2:DescribeInstanceAttribute` (user data) and
`elasticbeanstalk:DescribeConfigurationSettings` return environment values,
which can include secrets. The script keeps only the allowed JVM flags, but
the role itself can read those values, so grant it with that in mind. Lambda
environments encrypted with a customer-managed KMS key also need
`kms:Decrypt`; without it those functions show `[?]`.

Denied listings show as `[?]` per service and region, followed by a count.
If `ec2:DescribeRegions` and `account:ListRegions` are both denied, the
script checks the 17 default-enabled regions and says so.

EC2 instances with the same `[?]` result (an EKS node group, an auto scaling
group) are grouped into one block with an instance count. EKS nodes are
recognised by their cluster tags; their JVMs run in pods, so run the host
script as root on the node (it reaches containers through `nsenter`) or as a
privileged DaemonSet.

For anything left at `[?]`, run the host script on the instance, e.g. through
SSM Run Command or ECS Exec. Not covered: EKS (use the host script as a
DaemonSet), App Runner, Glue, Managed Flink, EMR Serverless.

## Testing

CI runs on every change under `jdk-8392044/`:

- `jdk-8392044-windows.yml`: `tests/Run-Tests.ps1` under Windows PowerShell
  5.1 and PowerShell 7 on `windows-latest`.
- `jdk-8392044-linux.yml`: shellcheck, then `tests/run-tests.sh` and
  `tests/run-aws-tests.sh` on `ubuntu-latest` and `ubuntu-22.04`.

`run-aws-tests.sh` runs the AWS script against `tests/fake-aws`, which
serves fixtures for each Lambda init mode and flag source, ECS on Fargate,
EC2 and ARM64, EC2 inventory and gzip user data, Beanstalk and EMR. It also
checks that no secret value appears in the output and that only read-only
APIs are called. It needs no AWS account.

Both harnesses use the same four layers:

1. A fake JVM (`FakeJava.cs` / `fake-java`) drives every decision branch,
   version boundary, fixed-version case and flag-precedence rule.
2. Every runner JDK (8 to 25) is checked against the verdict derived from
   that JVM's own `-Xlog:os+cpu` output.
3. JVMs held at startup with `-XX:+PauseAtStartup` must be found, and their
   command-line flags replayed. Linux also checks flags from `/proc` environ,
   a deleted binary (`unknown`), an embedded `libjvm.so` (`embed-jvm.c`), and
   a Docker-container JVM via `nsenter`, both as root and as non-root.
4. Default full-host runs must exit with a code that matches the last line.
   On Linux these runs have SIGPIPE ignored, and any `Broken pipe` output
   fails the test.

Runner CPUs vary between runs: AMD EPYC 7763 (Zen 3, no AVX-512) or
EPYC 9V74/9V45 (Zen 4, AVX-512 VBMI). On Zen 4, the real Temurin 17/21/25
JDKs report `impacted`. Not covered by CI: macOS, bash 3.2, Procrun
services on Windows.
