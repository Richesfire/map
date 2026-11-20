# 地图管线一键脚本
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\map_pipeline.ps1 -Test
#   ... -Rebake                          改分类器后重烘 8192 编号图（约 6-8 分钟）
#   ... -Preview -Region 118,122,30,34 -Step 1 -Out $env:TEMP\p.png
#   ... -Shot -Zoom 500 -Lon 118.3 -Lat 36.9 -Out $env:TEMP\s.png
#   ... -Contours                          重新提取全球矢量轮廓（4.9km，约 10 分钟）
param(
    [switch]$Test,
    [switch]$Rebake,
    [switch]$Preview,
    [switch]$Shot,
    [switch]$Contours,
    [string]$Region = "117,122,30,34",
    [int]$Step = 1,
    [double]$Zoom = 120,
    [double]$Lon = 118.3,
    [double]$Lat = 36.9,
    [string]$Out = ""
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$proj = Join-Path $root 'ias'
$godot = $env:GODOT_EXE
if (-not $godot) {
    $c = @(
        'C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe',
        'C:\Program Files\Godot\godot.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $godot = $c
}
$py = $env:PYTHON_EXE
if (-not $py) {
    $py = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
}

if ($Test) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\run_tests.ps1')
    return
}

if ($Contours) {
    & $py -X utf8 (Join-Path $root 'tools\\map\\build_terrain_contours.py') `
        --step 1 --out "$env:TEMP\contours_world.png" `
        --bin (Join-Path $root 'ias-core\data\terrain_contours.bin') `
        --preview 1600 --eps 0.8 --smooth 2
    return
}

if ($Rebake) {
    $t0 = Get-Date
    & $godot --headless --path $proj --script res://tools/bake_landform_id.gd
    "重烘用时 {0:N0} 秒" -f ((Get-Date) - $t0).TotalSeconds
    # 分类器变了 → 细节层缓存作废
    Remove-Item "$env:APPDATA\Godot\app_userdata\秦末 209BC\detail_cache" -Recurse -Force -ErrorAction SilentlyContinue
    return
}

if ($Preview) {
    if (-not $Out) { $Out = "$env:TEMP\terrain_preview.png" }
    & $py -X utf8 (Join-Path $root 'tools\\map\\build_terrain_contours.py') `
        --region $Region --step $Step --out $Out --preview 1200 --eps 0.8 --smooth 2
    return
}

if ($Shot) {
    if (-not $Out) { $Out = "$env:TEMP\map_shot.png" }
    & $godot --path $proj -- --start --fresh --map --mapzoom=$Zoom --mapcenter="$Lon,$Lat" --shots="$Out@40"
    return
}

Write-Host "没有指定动作。用 -Test / -Rebake / -Preview / -Shot / -Contours" -ForegroundColor Yellow
