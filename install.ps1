# Hyrule Warriors: Age of Imprisonment (HWAoI Recomp) installer for Windows (driven by NUP Studio)
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Hyrule Warriors Age of Imprisonment",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}
function Say($msg) { Write-Host "[HWAoI-Recomp] $msg" -ForegroundColor Cyan }

if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) {
    Say "error: missing .nup file or game folder: $Nup"
    exit 1
}
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Hyrule Warriors Age of Imprisonment"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$globalMsysInstaller = Join-Path $source "..\..\install_msys2.ps1"
$clang64Prefix = "C:\msys64\clang64"
$clang64Bin = Join-Path $clang64Prefix "bin"

if (-not (Test-Path -LiteralPath (Join-Path $clang64Bin "clang.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "ninja.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Bin "python.exe")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\SDL3\SDL.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vpx\vpx_decoder.h")) -or
    -not (Test-Path -LiteralPath (Join-Path $clang64Prefix "include\vma\vk_mem_alloc.h"))) {
    if (-not (Test-Path -LiteralPath $globalMsysInstaller)) {
        Say "error: MSYS2 missing and global installer not found: $globalMsysInstaller"
        exit 1
    }
    & $globalMsysInstaller -Msys "C:\msys64"
    if ($LASTEXITCODE -ne 0) {
        Say "MSYS2 installation cancelled or failed; stopping recompilation."
        exit 1
    }
}

$pyExe = Join-Path $clang64Bin "python.exe"
$xlateExe = Join-Path $source "bin\totk_xlate.exe"
$xlateId = Join-Path $source "bin\totk_xlate.id"
$ninjaExe = Join-Path $clang64Bin "ninja.exe"
foreach ($req in @($pyExe, $xlateExe, $xlateId, (Join-Path $clang64Bin "clang.exe"), $ninjaExe)) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PATH = "$clang64Bin;" + $env:PATH
$env:CLANG64_PREFIX = "C:/msys64/clang64"
$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"
$env:PYTHON_JIT = "0"

# Pin to E-cores on Intel 13th/14th-gen for heavy Python/C codegen stability
$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 8))
try {
    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    if ($cpuName -match 'Intel.*1[34]\d{3}' -and [Environment]::ProcessorCount -gt 16) {
        $eCoreMask = [int64]0
        for ($c = 16; $c -lt [Math]::Min(63, [Environment]::ProcessorCount); $c++) {
            $eCoreMask = $eCoreMask -bor ([int64]1 -shl $c)
        }
        if ($eCoreMask -gt 0) {
            Say "detected ${cpuName}: pinning codegen & build to E-cores for stability"
            $proc.ProcessorAffinity = [IntPtr]$eCoreMask
            $jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount - 16, 8))
        }
    }
} catch {}

# ---- Global Saves folder (<ParentDir>\Saves\<GameFolderName>) ----
$parentInstallDir = Split-Path -Parent $Dir
$globalSavesRoot = Join-Path $parentInstallDir "Saves"
$globalSaveDir = Join-Path $globalSavesRoot (Split-Path -Leaf $Dir)
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null

# ---- 1. Prepare ExeFS & RomFS (supports both .nup and extracted folder) ----
$workRoot = Join-Path $Dir "work"
$exefsDir = Join-Path $workRoot "game\exefs"
$romfsDir = Join-Path $workRoot "game\romfs"
New-Item -ItemType Directory -Force -Path $exefsDir, $romfsDir | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main")) -or -not (Test-Path -LiteralPath (Join-Path $romfsDir "index.json"))) {
    if (Test-Path -LiteralPath $Nup -PathType Container) {
        $srcExefs = if (Test-Path -LiteralPath (Join-Path $Nup "exefs\main")) { Join-Path $Nup "exefs" } else { $Nup }
        $srcRomfs = Join-Path $Nup "romfs"
        if (-not (Test-Path -LiteralPath (Join-Path $srcExefs "main")) -or -not (Test-Path -LiteralPath $srcRomfs)) {
            Say "error: folder must contain exefs/main and romfs/: $Nup"; exit 1
        }
        Say "copying ExeFS and packing RomFS from folder..."
        if (Test-Path -LiteralPath $exefsDir) { Remove-Item -Recurse -Force $exefsDir }
        Copy-Item -LiteralPath $srcExefs -Destination $exefsDir -Recurse -Force
        if (Test-Path -LiteralPath (Join-Path $srcRomfs "romfs.bin")) {
            if (Test-Path -LiteralPath $romfsDir) { Remove-Item -Recurse -Force $romfsDir }
            Copy-Item -LiteralPath $srcRomfs -Destination $romfsDir -Recurse -Force
        } else {
            & $pyExe (Join-Path $source "tools\hwaoi_pack_romfs.py") --dir $srcRomfs --out $romfsDir --exefs $exefsDir
            if ($LASTEXITCODE -ne 0) { Say "hwaoi_pack_romfs.py failed"; exit 1 }
        }
    } else {
        Say "extracting ExeFS and packing RomFS from .nup..."
        $extractTmp = Join-Path $Dir "_extract_tmp"
        if (Test-Path -LiteralPath $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
        & $pyExe (Join-Path $source "tools\extract_nup.py") $Nup --select latest --pack --out $extractTmp
        if ($LASTEXITCODE -ne 0) { Say "extract_nup.py failed"; exit 1 }
        if (Test-Path -LiteralPath $exefsDir) { Remove-Item -Recurse -Force $exefsDir }
        if (Test-Path -LiteralPath $romfsDir) { Remove-Item -Recurse -Force $romfsDir }
        Move-Item -LiteralPath (Join-Path $extractTmp "exefs") -Destination $exefsDir -Force
        Move-Item -LiteralPath (Join-Path $extractTmp "romfs") -Destination $romfsDir -Force
        Remove-Item -Recurse -Force $extractTmp -ErrorAction SilentlyContinue
        & $pyExe -c "
import hashlib, json
from pathlib import Path
idx = Path(r'$romfsDir') / 'index.json'
d = json.loads(idx.read_text(encoding='utf-8'))
exefs = Path(r'$exefsDir')
d['exefs_sha256'] = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(exefs.iterdir()) if f.is_file()}
idx.write_text(json.dumps(d), encoding='utf-8')
"
        if ($LASTEXITCODE -ne 0) { Say "failed to update RomFS index.json"; exit 1 }
    }
}

# ---- 2. Lift ARM64 ExeFS (main, subsdk0, sdk) to C ----
$genDir = Join-Path $workRoot "generated\hwaoi196608"
if (-not (Test-Path -LiteralPath (Join-Path $genDir "hwaoi-generation.json"))) {
    Say "lifting ARM64 code (main, subsdk0, sdk) to C..."
    Push-Location $source
    & $pyExe (Join-Path $source "tools\hwaoi.py") --exefs $exefsDir generate --out $genDir --limit 0 --jobs $jobs --display-settings
    $genRc = $LASTEXITCODE
    Pop-Location
    if ($genRc -ne 0) { Say "hwaoi.py generate failed"; exit 1 }
}

# ---- 3. Compile native Windows executable (hwaoi.exe) ----
$buildDir = Join-Path $workRoot "build\hwaoi196608"
$hwaoiExe = Join-Path $Dir "hwaoi.exe"
$iconSrc = if ($IconPath -and (Test-Path -LiteralPath $IconPath)) { $IconPath } else { Join-Path $source "game_icon.ico" }
if (-not (Test-Path -LiteralPath $hwaoiExe)) {
    Say "compiling hwaoi.exe with Clang64 + Ninja..."
    Push-Location $source
    $buildArgs = @(
        (Join-Path $source "tools\hwaoi.py"),
        "--exefs", $exefsDir,
        "build",
        "--generated", $genDir,
        "--out", $buildDir,
        "--romfs", $romfsDir,
        "--deps", $clang64Prefix,
        "--toolchain", $clang64Prefix,
        "--ninja", $ninjaExe,
        "--jobs", "$jobs"
    )
    if (Test-Path -LiteralPath $iconSrc) { $buildArgs += @("--icon", $iconSrc) }
    & $pyExe @buildArgs
    $buildRc = $LASTEXITCODE
    Pop-Location
    if ($buildRc -ne 0) { Say "hwaoi.py build failed"; exit 1 }

    Copy-Item -LiteralPath (Join-Path $buildDir "hwaoi.exe") -Destination $hwaoiExe -Force
    if (Test-Path -LiteralPath (Join-Path $buildDir "romfs-index.bin")) {
        Copy-Item -LiteralPath (Join-Path $buildDir "romfs-index.bin") -Destination (Join-Path $Dir "romfs-index.bin") -Force
    }
    $finalRomfs = Join-Path $Dir "romfs"
    if (Test-Path -LiteralPath $finalRomfs) { Remove-Item -Recurse -Force $finalRomfs }
    Move-Item -LiteralPath $romfsDir -Destination $finalRomfs -Force
}

foreach ($dll in @("SDL3.dll", "libiconv-2.dll", "libopus-0.dll")) {
    $dllSrc = Join-Path $clang64Bin $dll
    if (Test-Path -LiteralPath $dllSrc) {
        Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $Dir $dll) -Force
    }
}
Copy-Item -LiteralPath $xlateExe -Destination (Join-Path $Dir "totk_xlate.exe") -Force
Copy-Item -LiteralPath $xlateId -Destination (Join-Path $Dir "totk_xlate.id") -Force

# ---- 4. Pre-launch UI, config, shortcuts & Windows uninstaller ----
$repoRoot = Resolve-Path (Join-Path $source "..\..\..")
$launcherUiSrc = $LauncherUiPath
if (-not $launcherUiSrc -or -not (Test-Path -LiteralPath $launcherUiSrc)) {
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}
$isLauncherExe = $launcherUiSrc -match "\.exe$"
$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$launchConfigPath = Join-Path $Dir "launch_options.json"
$tplPath = Join-Path $source "launch_options_template.json"
if (Test-Path -LiteralPath $tplPath) {
    $tpl = Get-Content -LiteralPath $tplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl | Add-Member -NotePropertyName "working_dir" -NotePropertyValue $Dir -Force
    $tpl | Add-Member -NotePropertyName "rom_path" -NotePropertyValue $Nup -Force
    $tpl | Add-Member -NotePropertyName "command" -NotePropertyValue @($hwaoiExe, "--play-experimental") -Force
    if (-not $tpl.env) {
        $tpl | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $tpl.env | Add-Member -NotePropertyName "TOTK_PROFILE_DIR" -NotePropertyValue $globalSaveDir -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($launchConfigPath, ($tpl | ConvertTo-Json -Depth 10), $utf8NoBom)
}

$iconDst = Join-Path $Dir "game_icon.ico"
if (Test-Path -LiteralPath $iconSrc) { Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force }
$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) { Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force }

$runner = Join-Path $Dir "hwaoi.cmd"
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} else {
@"
@echo off
cd /d "$Dir"
set "TOTK_PROFILE_DIR=$globalSaveDir"
set "TOTK_FULLSCREEN=0"
set "TOTK_WINDOW_MODE=windowed"
set "TOTK_WINDOW_SIZE=1280x720"
"$hwaoiExe" --play-experimental %*
"@ | Set-Content -Encoding ASCII $runner
}

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Hyrule Warriors Age of Imprisonment" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port (F11 Fullscreen)"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 5. Clean up temporary build files ----
Say "cleaning up temporary build files in $Dir..."
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
}

# ---- 6. Register in Windows Installed Apps + create uninstaller ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous désinstaller $safeShortcutName ?`n`nLe dossier d'installation et les raccourcis seront supprimés.`nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprimés.",
    "Désinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
if (Test-Path -LiteralPath "$desktopLnk") { Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$startMenuDir") { Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$uninstRegPath") {
    Remove-Item -LiteralPath "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
}
Set-Location `$env:TEMP
Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 1 /nobreak >nul & rmdir /s /q ``"$Dir``"" -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

$sizeKb = [int](((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
New-Item -Path $uninstRegPath -Force | Out-Null
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp (NUP Studio)"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value "$iconDst,0" }
$uninstCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $sizeKb -Type DWord

Say "installed. Start the game from the Start menu or the desktop shortcut (windowed by default, F11 for fullscreen)."
