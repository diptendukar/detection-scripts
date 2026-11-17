# JDK-8392044 host detection

Fleet checks for the HotSpot x86-64 AVX-512 Base64 `decodeBlock` stub heap
overwrite. A 1-3 byte tail ending in `=` makes the stub store 64 bytes past
the destination buffer.

| Script | Platforms |
|---|---|
| `detect-jdk-8392044.sh` | Linux, macOS; bash 3.2+ |
| `Detect-Jdk8392044.ps1` | Windows; PowerShell 5.1 and 7 |

## What counts as impacted

All five conditions must hold for at least one JVM on the host:

1. HotSpot VM: any OpenJDK build, Oracle JDK, or GraalVM JDK. OpenJ9 is not affected.
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
states: [impacted] condition met | [ok] condition not met, JVM safe | [unknown] could not check | [n/a] not checked
tests:  arch, vm, java version, avx-512, base64 intrinsic. A JVM is impacted only if all five are [impacted].
host:   Linux x86_64

/usr/lib/jvm/temurin-17-jdk-amd64/bin/java (pid 4242, container)
  arch: amd64 [impacted]
  vm: OpenJDK 64-Bit Server VM [impacted]
  java version: 17.0.21 [impacted]
  avx-512: vbmi+bw, UseAVX=3 [impacted]
  base64 intrinsic: on [impacted]
  => [impacted]

impacted
```

Each JVM is one block. The title line names the binary and where it came
from: `installed`, `pid N`, `container`, `embedded in <program>`, `-j`. A JVM
that cannot be probed gets a single test line instead, e.g.
`binary: replaced on disk after start, restart it [unknown]`. `-q` / `-Quiet`
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

## Testing

CI runs on every change under `jdk-8392044/`:

- `jdk-8392044-windows.yml`: `tests/Run-Tests.ps1` under Windows PowerShell
  5.1 and PowerShell 7 on `windows-latest`.
- `jdk-8392044-linux.yml`: shellcheck, then `tests/run-tests.sh` on
  `ubuntu-latest` and `ubuntu-22.04`.

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
