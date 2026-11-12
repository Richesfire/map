# One-click self test. Usage:
#   double-click run_tests.bat
#   or: powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1
# Set GODOT_EXE if the engine is not in a default location.
param(
    [string]$Godot = $env:GODOT_EXE
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$proj = Join-Path $root 'ias'

if (-not $Godot) {
    $candidates = @(
        'C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe',
        'C:\Program Files\Godot\godot.exe',
        'C:\Program Files (x86)\Godot\godot.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $Godot = $c; break }
    }
}
if (-not $Godot -or -not (Test-Path $Godot)) {
    Write-Host 'Godot not found. Set GODOT_EXE to godot.exe' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $proj 'project.godot'))) {
    Write-Host "Godot project not found: $proj" -ForegroundColor Red
    exit 1
}

Write-Host "Godot : $Godot"
Write-Host "Project: $proj"
Write-Host ''

$tests = @(
    @{ Name = 'citytest';   Args = @('--citytest');   Window = $false },
    @{ Name = 'seamtest';   Args = @('--seamtest');   Window = $false },
    @{ Name = 'probe';      Args = @('--probe');      Window = $false },
    @{ Name = 'selftest';   Args = @('--selftest');   Window = $false },
    @{ Name = 'maptest';    Args = @('--maptest');    Window = $false },
    @{ Name = 'bugtest';    Args = @('--bugtest');    Window = $true  },
    @{ Name = 'combattest'; Args = @('--combattest'); Window = $true  }
)

$results = @()
foreach ($t in $tests) {
    Write-Host ("== {0} ==" -f $t.Name) -ForegroundColor Cyan
    $argList = @('--path', $proj)
    if (-not $t.Window) { $argList += @('--headless', '--quit-after', '900') }
    $argList += '--'
    $argList += $t.Args
    if ($t.Window) { $argList += @('--start', '--fresh') }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = (& $Godot @argList 2>&1 | Out-String)
    $sw.Stop()

    $bad = ($out -match 'FAIL') -or ($out -match 'ERROR')
    $ok = -not $bad
    $state = if ($ok) { 'PASS' } else { 'FAIL' }
    $results += [pscustomobject]@{ Test = $t.Name; State = $state; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    if (-not $ok) {
        ($out -split "`n" | Select-String -Pattern 'FAIL|ERROR' | Select-Object -First 3) | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    }
}

Write-Host ''
Write-Host '================ summary ================' -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = ($results | Where-Object { $_.State -ne 'PASS' }).Count
if ($failed -gt 0) {
    Write-Host "$failed test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all tests passed' -ForegroundColor Green
