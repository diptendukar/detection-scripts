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

## Testing done (2026-11-16)

- bash: an amd64 container (Temurin 21, Rosetta, so no AVX-512) checked the
  installed and running-process paths and replay of `JAVA_TOOL_OPTIONS` from
  `/proc/<pid>/environ`. A fake JVM fed real HotSpot output formats through
  every decision branch, version boundary, the fixed-version list, flag
  precedence and OpenJ9.
- PowerShell: the same fake-JVM matrix ran on native arm64 pwsh 7, with the
  host-architecture gate bypassed in a scratch copy. Still untested: Windows
  PowerShell 5.1, the Windows-only discovery (CIM processes, `jvm.dll`
  modules, Procrun registry), and any real AVX-512 VBMI hardware.
