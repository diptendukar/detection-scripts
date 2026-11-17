<#
.SYNOPSIS
    Tests Detect-Jdk8392044.ps1 on a Windows host.

.DESCRIPTION
    1. Decision logic: a fake java.exe (FakeJava.cs) drives every branch.
    2. Real JDKs: each JAVA_HOME_<n>_X64 on the runner is checked against an
       expected verdict derived independently from that JVM's own CPU log.
    3. Running processes: real JVMs held at startup with -XX:+PauseAtStartup
       must be found, and their command-line flags replayed.
    4. A default full-host run must return a consistent exit code and verdict.

.PARAMETER Shell
    The PowerShell that runs the script under test: powershell.exe (5.1) or pwsh.exe.

.PARAMETER FakeJava
    Path to the compiled fake java.exe.
#>
param(
    [Parameter(Mandatory = $true)][string]$Shell,
    [Parameter(Mandatory = $true)][string]$FakeJava
)

$ErrorActionPreference = 'Continue'
$Script = Join-Path (Split-Path $PSScriptRoot) 'Detect-Jdk8392044.ps1'
$script:Failures = 0
$script:Passes = 0
$VerdictFor = @{ 0 = 'not impacted'; 1 = 'impacted'; 2 = 'unknown' }

function Invoke-Detect([string[]]$ScriptArgs, [hashtable]$Env = @{}) {
    $saved = @{}
    foreach ($k in $Env.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Env[$k])
    }
    $out = @(& $Shell -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    return [pscustomobject]@{
        Code = $code
        Out  = $out
        Last = ($out | Where-Object { $_.Trim() } | Select-Object -Last 1)
    }
}

function Assert-Result([string]$Name, $R, [int]$Code, [string]$Contains = '') {
    $ok = ($R.Code -eq $Code) -and ($R.Last -eq $VerdictFor[$Code])
    if ($ok -and $Contains) { $ok = [bool]($R.Out | Where-Object { $_ -like "*$Contains*" }) }
    if ($ok) {
        $script:Passes++
        Write-Host "PASS  $Name"
    } else {
        $script:Failures++
        Write-Host "FAIL  $Name  (want exit $Code '$($VerdictFor[$Code])'$(if ($Contains) { " containing '$Contains'" }); got exit $($R.Code))"
        $R.Out | ForEach-Object { Write-Host "      | $_" }
    }
}

function Get-VerKey([string]$v) {
    if ($v.StartsWith('1.')) { $v = $v.Substring(2) }
    $p = @([regex]::Matches($v, '\d+') | ForEach-Object { [long]$_.Value })
    while ($p.Count -lt 3) { $p += 0 }
    return $p[0] * 1000000 + $p[1] * 1000 + $p[2]
}

# Independent oracle: what this JVM says about itself.
function Get-JvmFacts([string]$JavaExe) {
    $props = @(& $JavaExe -XshowSettings:properties -version 2>&1 | ForEach-Object { "$_" })
    $ver = ($props | Where-Object { $_ -match '^\s*java\.version = ' } | Select-Object -First 1) -replace '^\s*java\.version = ', ''
    $cpu = @(& $JavaExe -Xlog:os+cpu=info -version 2>&1 | ForEach-Object { "$_" }) |
        Where-Object { $_ -match 'os,cpu.*CPU:' } | Select-Object -First 1
    $vbmi = [bool]($cpu -match '(^|[ ,])avx512_vbmi(,|$)') -and [bool]($cpu -match '(^|[ ,])avx512bw(,|$)')
    return [pscustomobject]@{
        Version  = $ver
        Vbmi     = $vbmi
        Impacted = ((Get-VerKey $ver) -ge (Get-VerKey '17.0.6')) -and $vbmi
        CpuLine  = $cpu
    }
}

Write-Host "Shell under test: $Shell"
& $Shell -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' | ForEach-Object { Write-Host "Version: $_" }

# --- 1. Decision logic with the fake JVM -----------------------------------------

Write-Host "`n## Decision logic (fake java.exe)"
$F = @('-NoProcesses', '-NoDisk', '-Java', $FakeJava)

Assert-Result 'default fake 17.0.9 -> impacted' (Invoke-Detect $F) 1 '  => [impacted]'
Assert-Result 'quiet prints verdict only' (Invoke-Detect ($F + '-Quiet')) 1
$r = Invoke-Detect $F
foreach ($want in @('states: [impacted] condition met', 'tests:  arch, vm, java version, avx-512, base64 intrinsic',
        '  arch: amd64 [impacted]', '  vm: OpenJDK 64-Bit Server VM [impacted]', '  java version: 17.0.9 [impacted]',
        '  avx-512: vbmi+bw, UseAVX=3 [impacted]', '  base64 intrinsic: on [impacted]')) {
    Assert-Result "format: '$want'" $r 1 $want
}
$r = Invoke-Detect $F @{ FAKE_VER = '17.0.5' }
Assert-Result 'later tests not checked once ruled out' $r 0 '  avx-512: - [n/a]'
Assert-Result 'multiple -Java paths in one argument' (Invoke-Detect @('-NoProcesses', '-NoDisk', '-Java', "$FakeJava,C:\nope\java.exe")) 1 'C:\nope\java.exe (-Java)'
Assert-Result '17.0.6 boundary -> impacted' (Invoke-Detect $F @{ FAKE_VER = '17.0.6' }) 1
Assert-Result '17.0.5 -> ok' (Invoke-Detect $F @{ FAKE_VER = '17.0.5' }) 0 '(< 17.0.6) [ok]'
Assert-Result '1.8.0_392 -> ok' (Invoke-Detect $F @{ FAKE_VER = '1.8.0_392' }) 0 '(< 17.0.6) [ok]'
Assert-Result '27.0.1.0.3 no fix list -> impacted' (Invoke-Detect $F @{ FAKE_VER = '27.0.1.0.3' }) 1
Assert-Result 'fixed via env' (Invoke-Detect $F @{ FAKE_VER = '21.0.11'; JDK8392044_FIXED_IN = '17.0.19 21.0.11' }) 0 '(fixed) [ok]'
Assert-Result 'below fix via env' (Invoke-Detect $F @{ FAKE_VER = '21.0.10'; JDK8392044_FIXED_IN = '17.0.19 21.0.11' }) 1
Assert-Result 'comma -FixedIn list is split' (Invoke-Detect ($F + @('-FixedIn', '17.0.19,21.0.11')) @{ FAKE_VER = '21.0.10' }) 1
Assert-Result 'later major than top fix' (Invoke-Detect ($F + @('-FixedIn', '17.0.19,25.0.3')) @{ FAKE_VER = '27.0.1' }) 0 '(fixed) [ok]'
Assert-Result 'vbmi2 without vbmi -> ok' (Invoke-Detect $F @{ FAKE_FEATURES = 'avx512f, avx512bw, avx512_vbmi2' }) 0 'avx-512: no vbmi/bw [ok]'
Assert-Result 'vbmi without bw -> ok' (Invoke-Detect $F @{ FAKE_FEATURES = 'avx512f, avx512_vbmi' }) 0 'avx-512: no vbmi/bw [ok]'
Assert-Result 'OpenJ9 -> ok' (Invoke-Detect $F @{ FAKE_VM = 'Eclipse OpenJ9 VM' }) 0 'vm: Eclipse OpenJ9 VM [ok]'
Assert-Result 'aarch64 JVM -> ok' (Invoke-Detect $F @{ FAKE_ARCH = 'aarch64' }) 0 'arch: aarch64 [ok]'
Assert-Result 'x86 32-bit JVM -> ok' (Invoke-Detect $F @{ FAKE_ARCH = 'x86' }) 0 'arch: x86 [ok]'
Assert-Result 'UseAVX=2 (colon form)' (Invoke-Detect ($F + '-JvmOptions:-XX:UseAVX=2')) 0 'avx-512: UseAVX=2 [ok]'
Assert-Result 'UseAVX=2 via env' (Invoke-Detect $F @{ JDK8392044_JVM_OPTIONS = '-XX:UseAVX=2' }) 0 'avx-512: UseAVX=2 [ok]'
Assert-Result 'agent option is not replayed' (Invoke-Detect ($F + '-JvmOptions:-javaagent:C:\nope.jar')) 1
Assert-Result '-UseBASE64Intrinsics' (Invoke-Detect ($F + '-JvmOptions:-XX:-UseBASE64Intrinsics')) 0 'base64 intrinsic: off (-XX:-UseBASE64Intrinsics) [ok]'
Assert-Result 'DisableIntrinsic' (Invoke-Detect ($F + '-JvmOptions:-XX:DisableIntrinsic=_base64_decodeBlock')) 0 'off (DisableIntrinsic=_base64_decodeBlock) [ok]'
Assert-Result '-Xint' (Invoke-Detect ($F + '-JvmOptions:-Xint')) 0 'unused (-Xint) [ok]'
Assert-Result 'TieredStopAtLevel=1' (Invoke-Detect ($F + '-JvmOptions:-XX:TieredStopAtLevel=1')) 0 'unused (TieredStopAtLevel=1) [ok]'
Assert-Result 'JAVA_TOOL_OPTIONS mitigates' (Invoke-Detect $F @{ JAVA_TOOL_OPTIONS = '-XX:-UseBASE64Intrinsics' }) 0 'base64 intrinsic: off (-XX:-UseBASE64Intrinsics) [ok]'
Assert-Result '_JAVA_OPTIONS overrides JAVA_TOOL_OPTIONS' (Invoke-Detect $F @{
        JAVA_TOOL_OPTIONS = '-XX:-UseBASE64Intrinsics'; _JAVA_OPTIONS = '-XX:+UseBASE64Intrinsics' }) 1
Assert-Result 'missing -Java path -> unknown' (Invoke-Detect @('-NoProcesses', '-NoDisk', '-Java', 'C:\nope\java.exe')) 2 'binary: not a file [unknown]'

# --- 2. Real JDKs on the runner --------------------------------------------------

Write-Host "`n## Real JDKs"
$jdks = @(Get-ChildItem env: | Where-Object { $_.Name -match '^JAVA_HOME_(\d+)_X64$' } |
        Sort-Object { [int]($_.Name -replace '\D', '') } |
        ForEach-Object { Join-Path $_.Value 'bin\java.exe' } | Where-Object { Test-Path $_ })
if ($jdks.Count -eq 0) { $script:Failures++; Write-Host 'FAIL  no JAVA_HOME_<n>_X64 JDKs found on runner' }

$modern = $null
foreach ($j in $jdks) {
    $facts = Get-JvmFacts $j
    Write-Host "JDK $($facts.Version) at $j; JVM CPU line: $($facts.CpuLine)"
    $want = if ($facts.Impacted) { 1 } else { 0 }
    Assert-Result "real JDK $($facts.Version)" (Invoke-Detect @('-NoProcesses', '-NoDisk', '-Java', $j)) $want $facts.Version
    if ((Get-VerKey $facts.Version) -ge (Get-VerKey '17.0.6')) { $modern = $j; $modernFacts = $facts }
}

# --- 3. Running JVMs ---------------------------------------------------------------

function Start-PausedJvm([string]$JavaExe, [string[]]$Flags) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $p = Start-Process -FilePath $JavaExe -WorkingDirectory $dir -PassThru -WindowStyle Hidden `
        -ArgumentList (@('-XX:+UnlockDiagnosticVMOptions', '-XX:+PauseAtStartup') + $Flags + '-version')
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path (Join-Path $dir "vm.paused.$($p.Id)")) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path (Join-Path $dir "vm.paused.$($p.Id)"))) { Write-Host "warning: JVM $($p.Id) never paused" }
    return $p
}

if ($modern) {
    Write-Host "`n## Running JVMs ($modern)"

    $p = Start-PausedJvm $modern @('-XX:UseAVX=2')
    try {
        Assert-Result 'running JVM, command-line UseAVX=2 replayed' (Invoke-Detect @('-NoDisk')) 0 "(pid $($p.Id))"
        Assert-Result 'running JVM reason names UseAVX=2' (Invoke-Detect @('-NoDisk')) 0 'avx-512: UseAVX=2 [ok]'
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

    $p = Start-PausedJvm $modern @()
    try {
        $want = if ($modernFacts.Impacted) { 1 } else { 0 }
        Assert-Result 'running JVM, default flags' (Invoke-Detect @('-NoDisk')) $want "(pid $($p.Id))"
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
} else {
    $script:Failures++
    Write-Host 'FAIL  no JDK >= 17.0.6 on runner for running-process tests'
}

# --- 4. Default full-host run ------------------------------------------------------

Write-Host "`n## Default full-host run"
$r = Invoke-Detect @()
$r.Out | ForEach-Object { Write-Host "      | $_" }
if ($r.Code -in 0, 1, 2 -and $r.Last -eq $VerdictFor[$r.Code]) {
    $script:Passes++; Write-Host "PASS  default run consistent (exit $($r.Code), '$($r.Last)')"
} else {
    $script:Failures++; Write-Host "FAIL  default run inconsistent (exit $($r.Code), last line '$($r.Last)')"
}

Write-Host "`n$($script:Passes) passed, $($script:Failures) failed"
if ($script:Failures -gt 0) { exit 1 }
exit 0
