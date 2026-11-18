# Minimap Reminders by Jordan Mitchell - build and install
#
# Compiles panorama\ with Reduced CSDK 12, packs pak98_dir.vpk, copies it to
# Deadlock\game\citadel\addons\ and makes sure gameinfo.gi loads addons.
# Without the CSDK it installs the prebuilt pak98_dir.vpk kept next to this script.
#
# Usage: double-click build_and_install.bat (or run this script). The item overlay
# also runs it hidden, with Deadlock closed, whenever the sources change.
# Optional: -Csdk "D:\Tools\Reduced_CSDK_12"  -Deadlock "D:\Steam\steamapps\common\Deadlock"  -Log <file>

param([string]$Csdk = "", [string]$Deadlock = "", [string]$Log = "")

$ErrorActionPreference = "Stop"
if ($Log) { try { Start-Transcript -Path $Log -Force | Out-Null } catch { } }
$Addon    = "jm_minimap"
$PakName  = "pak98_dir.vpk"
$Src      = Split-Path -Parent $MyInvocation.MyCommand.Path

# Deadlock install: given, or found through Steam's library list.
function Find-Deadlock {
    $roots = @()
    try { $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath; if ($sp) { $roots += ($sp -replace '/', '\') } } catch { }
    $roots += 'C:\Program Files (x86)\Steam'
    foreach ($r in @($roots)) {
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $roots += ($m.Groups[1].Value -replace '\\\\', '\') }
        }
    }
    foreach ($r in ($roots | Select-Object -Unique)) {
        $d = Join-Path $r 'steamapps\common\Deadlock'
        if (Test-Path (Join-Path $d 'game\citadel\gameinfo.gi')) { return $d }
    }
    return $null
}
function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "`nERROR: $msg" -ForegroundColor Red; if ($Log) { try { Stop-Transcript | Out-Null } catch { } }; exit 1 }

if (-not $Deadlock) { $Deadlock = Find-Deadlock }
if (-not $Deadlock -or -not (Test-Path (Join-Path $Deadlock "game\citadel\gameinfo.gi"))) { Fail "Deadlock install not found. Run with -Deadlock ""<folder>""." }
$Citadel  = Join-Path $Deadlock "game\citadel"
$Addons   = Join-Path $Citadel "addons"
$GameInfo = Join-Path $Citadel "gameinfo.gi"
Write-Host "Deadlock: $Deadlock"

# --- find the CSDK ---
Step "Finding Reduced CSDK 12"
$candidates = @()
if ($Csdk) { $candidates += $Csdk }
$candidates += "C:\Reduced_CSDK_12"
$dirs = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents")
$dirs += (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })
foreach ($dir in $dirs) {
    $candidates += ($dir.TrimEnd("\") + "\Reduced_CSDK_12")
}
$Root = $null
foreach ($c in $candidates) {
    foreach ($r in @($c, ($c.TrimEnd("\") + "\Reduced_CSDK_12"))) {
        if (Test-Path -LiteralPath ($r + "\game\bin_cs2\win64\resourcecompiler.exe") -ErrorAction SilentlyContinue) { $Root = $r; break }
    }
    if ($Root) { break }
}
$Prebuilt = Join-Path $Src $PakName
if (-not $Root -and -not (Test-Path $Prebuilt)) { Fail "Reduced CSDK 12 not found and no prebuilt $PakName next to this script. Extract the CSDK to C:\Reduced_CSDK_12 or run with -Csdk ""<folder>""." }

if (Get-Process -Name "deadlock" -ErrorAction SilentlyContinue) { Fail "Close Deadlock first (mods load at startup and the pak is locked while it runs)." }

if ($Root) {
$Compiler = Join-Path $Root "game\bin_cs2\win64\resourcecompiler.exe"
$Packer   = Join-Path $Root "game\bin\win64\CSDKCfgVPK.exe"
if (-not (Test-Path $Packer)) { Fail "CSDKCfgVPK.exe missing at $Packer" }
Write-Host "CSDK: $Root"

# --- stage sources into the CSDK addon ---
Step "Staging sources"
$Content = Join-Path $Root "content\citadel_addons\$Addon"
$GameOut = Join-Path $Root "game\citadel_addons\$Addon"
foreach ($d in @($Content, $GameOut)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
New-Item -ItemType Directory -Force -Path $Content | Out-Null
Copy-Item (Join-Path $Src "panorama") -Destination $Content -Recurse -Force
$files = Get-ChildItem (Join-Path $Content "panorama") -Recurse -File | Where-Object { $_.Extension -in ".xml", ".css", ".js" }
$files | ForEach-Object { Write-Host "  $($_.FullName.Substring($Content.Length + 1))" }

# --- compile ---
Step "Compiling"
$rcArgs = @()
foreach ($f in $files) { $rcArgs += "-i"; $rcArgs += $f.FullName }
$rcArgs += "-nop4"
& $Compiler @rcArgs
$expected = @("panorama\layout\hud_minimap.vxml_c", "panorama\styles\jm_minimap.vcss_c", "panorama\scripts\jm_minimap.vjs_c")
$missing = $expected | Where-Object { -not (Test-Path (Join-Path $GameOut $_)) }
if ($missing) { Fail ("Compiler did not produce: " + ($missing -join ", ") + ". Scroll up for the compiler's error.") }
Write-Host "Compiled OK" -ForegroundColor Green

# --- pack ---
Step "Packing $PakName"
$tmp = Join-Path $env:TEMP "jm_minimap_build"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$tmpPak = Join-Path $tmp $PakName
& $Packer $GameOut $tmpPak
if (-not (Test-Path $tmpPak)) {
    $alt = Get-ChildItem $tmp -Filter "*.vpk" | Select-Object -First 1
    if ($alt) { $tmpPak = $alt.FullName } else { Fail "Packer did not create a VPK." }
}
Write-Host ("Packed OK ({0:N1} KB)" -f ((Get-Item $tmpPak).Length / 1KB)) -ForegroundColor Green
Copy-Item $tmpPak $Prebuilt -Force   # keep a prebuilt copy for installs without the CSDK
} else {
    Write-Host "Reduced CSDK 12 not found: installing the prebuilt $PakName"
    $tmpPak = $Prebuilt
}

# --- install ---
Step "Installing"
New-Item -ItemType Directory -Force -Path $Addons | Out-Null
Copy-Item $tmpPak (Join-Path $Addons $PakName) -Force
Write-Host "Copied to $Addons\$PakName"

$gi = Get-Content $GameInfo -Raw
if ($gi -notmatch "(?m)^\s*Game\s+citadel/addons\s*$" -or $gi -notmatch "(?m)^\s*Mod\s+citadel\s*$") {
    $backup = "$GameInfo.jm_backup"
    if (-not (Test-Path $backup)) { Copy-Item $GameInfo $backup }
    $gi = [regex]::Replace($gi, "(?m)^\s*(Game\s+citadel/addons|Mod\s+citadel|Write\s+citadel)\s*\r?\n", "")
    $gi = [regex]::Replace($gi, "(?m)^(\s*)Game(\s+)citadel(\r?)$", "`$1Game`$2citadel/addons`$3`n`$1Mod`$2citadel`$3`n`$1Write`$2citadel`$3`n`$1Game`$2citadel`$3", 1)
    Set-Content -Path $GameInfo -Value $gi -NoNewline
    Write-Host "Added addons lines (Game citadel/addons, Mod citadel, Write citadel) to gameinfo.gi (backup: gameinfo.gi.jm_backup)"
} else {
    Write-Host "gameinfo.gi already loads addons"
}

Write-Host "`nDone. Start Deadlock and open Hero Sandbox or a match." -ForegroundColor Yellow
Write-Host "Console check: look for '[MinimapReminders] loaded build' in the console." -ForegroundColor Yellow
if ($Log) { try { Stop-Transcript | Out-Null } catch { } }
exit 0
