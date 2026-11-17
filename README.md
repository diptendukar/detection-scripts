# detection-scripts

Host detection scripts for incident response. Each directory holds one
incident's scripts, a README with the exit-code contract, and tests.

| Directory | What it detects |
|---|---|
| `jdk-8392044/` | JVMs exposed to the HotSpot x86-64 AVX-512 Base64 decode heap overwrite (JDK-8392044) |

CI: `.github/workflows/jdk-8392044-windows.yml` runs the PowerShell detector's
tests on GitHub-hosted Windows runners under Windows PowerShell 5.1 and
PowerShell 7.
