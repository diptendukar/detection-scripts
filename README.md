# detection-scripts

Host detection scripts for incident response. Each directory holds one
incident's scripts and a README with usage and the exit-code contract.

Instructions for individual incident scripts are contained within their respective directories.

Where possible, detections are written to be fleet-policy compatible - known unaffected hosts should return a 0 exit code, affected (or undetermined) hosts will have a nonzero exit code.

| Directory | What it detects |
|---|---|
| `CVE-2026-114938/` | JVMs exposed to the HotSpot x86-64 AVX-512 Base64 decode heap overwrite (CVE-2026-114938, JDK-8392044) |
