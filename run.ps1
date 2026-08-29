$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$src = Join-Path $env:LOCALAPPDATA 'LOTF2\Saved\SaveGames'
$baselineDir = Join-Path $PSScriptRoot 'baseline'
$checksumFile = Join-Path $baselineDir 'checksums.txt'
$idleTimeout = if ($env:LOTF2_IDLE_TIMEOUT) { [int]$env:LOTF2_IDLE_TIMEOUT } else { 60 }
$procMatch = if ($env:LOTF2_PROC_MATCH) { $env:LOTF2_PROC_MATCH } else { 'LOTF2' }
$engineIni = Join-Path $env:LOCALAPPDATA 'LOTF2\Saved\Config\Windows\Engine.ini'

$script:dirty = $false
$script:exited = $false

$script:mutex = $null
$owned = $false
foreach ($mutexName in 'Global\LOTF2SaveScumLoop', 'LOTF2SaveScumLoop') {
    try {
        $script:mutex = New-Object System.Threading.Mutex($false, $mutexName)
        $owned = $script:mutex.WaitOne(0, $false)
        break
    }
    catch { $script:mutex = $null }
}
if (-not $owned) {
    Write-Host "ERROR: another copy of this loop is already running." -ForegroundColor Red
    Write-Host "Close the other instance first, then re-run." -ForegroundColor Yellow
    exit 1
}

function Test-GameRunning {
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $procMatch }
    return ($null -ne $p)
}

function Test-IntroSkip {
    if (-not (Test-Path -LiteralPath $engineIni)) { return $false }
    return (Select-String -LiteralPath $engineIni -Pattern 'GameDefaultMap' -Quiet)
}

function Apply-IntroSkip {
    if (Test-IntroSkip) {
        Write-Host "Intro-skip is already applied - nothing to do." -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path -LiteralPath $engineIni)) {
        Write-Host "ERROR: Engine.ini not found - launch the game once first." -ForegroundColor Red
        return
    }
    $bak = "$engineIni.bak"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $engineIni -Destination $bak }
    Add-Content -LiteralPath $engineIni -Value "`r`n[/Script/EngineSettings.GameMapsSettings]`r`nGameDefaultMap=/Game/World/Character_Creation/LVL_Char_Creation.LVL_Char_Creation" -Encoding UTF8
    Write-Host "Intro-skip APPLIED - cinematics will be skipped. (original kept as Engine.ini.bak)" -ForegroundColor Green
}

function Remove-IntroSkip {
    if (-not (Test-IntroSkip)) {
        Write-Host "Intro-skip is not applied - nothing to remove." -ForegroundColor Yellow
        return
    }
    $bak = "$engineIni.bak"
    $suffix = [Text.Encoding]::UTF8.GetBytes("`r`n[/Script/EngineSettings.GameMapsSettings]`r`nGameDefaultMap=/Game/World/Character_Creation/LVL_Char_Creation.LVL_Char_Creation`r`n")
    $bytes = [IO.File]::ReadAllBytes($engineIni)
    $n = $suffix.Length
    $tailMatches = $false
    if ($bytes.Length -ge $n) {
        $tailMatches = $true
        for ($i = 0; $i -lt $n; $i++) {
            if ($bytes[$bytes.Length - $n + $i] -ne $suffix[$i]) { $tailMatches = $false; break }
        }
    }
    if ($tailMatches) {
        $prefix = New-Object byte[] ($bytes.Length - $n)
        [Array]::Copy($bytes, $prefix, $prefix.Length)
        [IO.File]::WriteAllBytes($engineIni, $prefix)
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
        Write-Host "Intro-skip REMOVED - reverted Engine.ini exactly." -ForegroundColor Green
        return
    }
    $strip = Get-Content -LiteralPath $engineIni | Where-Object {
        $_ -notmatch '^\[/Script/EngineSettings.GameMapsSettings\]$' -and
        $_ -notmatch '^GameDefaultMap='
    }
    Set-Content -LiteralPath $engineIni -Value $strip -Encoding UTF8
    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
    Write-Host "Intro-skip REMOVED - stripped the added lines (the game had also modified the file)." -ForegroundColor Green
}

function Backup-Save {
    Write-Host ""
    Write-Host ">> Creating baseline snapshot..." -ForegroundColor Cyan
    $tmp = "$baselineDir.new"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Get-ChildItem -LiteralPath $src -File -Force | Copy-Item -Destination $tmp
    Get-ChildItem -LiteralPath $tmp -File | Sort-Object Name | ForEach-Object {
        $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        "$h  $($_.Name)"
    } | Set-Content -LiteralPath (Join-Path $tmp 'checksums.txt') -Encoding Ascii
    if (Test-Path -LiteralPath $baselineDir) { Remove-Item -LiteralPath $baselineDir -Recurse -Force }
    Rename-Item -LiteralPath $tmp -NewName 'baseline'
    $script:dirty = $false
    Write-Host "Baseline saved:" -ForegroundColor Green
    Write-Host "  $baselineDir"
}

function Restore-Save {
    Write-Host ""
    Write-Host ">> Restoring baseline..." -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $baselineDir)) {
        Write-Host "No baseline found. Press R at the next prompt to create one." -ForegroundColor Red
        return $false
    }
    if (Test-GameRunning) {
        Write-Host "Game is still running. Close it fully first." -ForegroundColor Red
        return $false
    }
    $files = Get-ChildItem -LiteralPath $baselineDir -File | Where-Object { $_.Name -ne 'checksums.txt' }
    foreach ($f in $files) {
        $target = Join-Path $src $f.Name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Copy-Item -LiteralPath $f.FullName -Destination $target
    }
    $bad = $false
    Get-Content -LiteralPath $checksumFile | ForEach-Object {
        if ($_ -match '^([0-9A-Fa-f]{64})  (.+)$') {
            $expected = $matches[1].ToUpper()
            $name = $matches[2]
            $live = Join-Path $src $name
            $actual = (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash
            if ($actual -ne $expected) {
                Write-Host "  MISMATCH: $name" -ForegroundColor Red
                $bad = $true
            }
        }
    }
    if ($bad) {
        Write-Host "RESTORE FAILED - do not launch the game. Investigate." -ForegroundColor Red
        return $false
    }
    $script:dirty = $false
    Write-Host "Restore OK. All files verified." -ForegroundColor Green
    return $true
}

function Exit-Safe {
    param([int]$Code = 0, [string]$Msg = '')
    if ($script:exited) { return }
    $script:exited = $true
    if ($Msg) { Write-Host $Msg }
    if ($script:dirty) {
        Write-Host ""
        Write-Host ">> Auto-protect: bundles were claimed but not yet re-synced." -ForegroundColor Yellow
        if (Test-GameRunning) {
            Write-Host "WARNING: the game is still running with the claimed bundles in the live save." -ForegroundColor Red
            Write-Host "Alt+F4 it first, then re-run - the script restores the bundles automatically." -ForegroundColor Yellow
        } else {
            Write-Host "Restoring the baseline before exit so no bundles go to waste..." -ForegroundColor Yellow
            $ok = Restore-Save
            if ($ok) { Write-Host "Bundles protected. Safe to close this window." -ForegroundColor Green }
        }
    }
    if ($script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch { }
        $script:mutex.Dispose()
        $script:mutex = $null
    }
    exit $Code
}

function Wait-ForGameClose {
    Write-Host ""
    Write-Host "======== CLAIM PHASE ========" -ForegroundColor Cyan
    if (Test-GameRunning) {
        Write-Host "Game is still running from the last check."
        Write-Host "Open ALL your reward bundles in inventory, wait ~15 seconds for a sync."
        Write-Host "Then Alt+F4 to quit (do NOT quit via the menu) - I will detect it."
    } else {
        Write-Host "1. Launch the game."
        Write-Host "2. Open ALL your reward bundles in inventory."
        Write-Host "3. Wait ~15 seconds for the server to sync."
        Write-Host "4. Alt+F4 to quit (do NOT quit via the menu)."
    }
    Write-Host ""
    Write-Host "Waiting for the game to start..." -ForegroundColor Yellow

    $appeared = Test-GameRunning
    $script:dirty = $appeared
    $since = Get-Date
    $emptyCount = 0
    while ($true) {
        if (Test-GameRunning) {
            if (-not $appeared) {
                $appeared = $true
                $script:dirty = $true
                Write-Host "Game detected. Waiting for you to claim + Alt+F4..." -ForegroundColor Yellow
            }
            $since = Get-Date
        } elseif ($appeared) {
            Write-Host "Game closed. Proceeding." -ForegroundColor Green
            return
        }
        if (-not $appeared -and ((Get-Date) - $since).TotalSeconds -gt $idleTimeout) {
            Write-Host ""
            $resp = Read-Host "Never saw the game run. [c] continue anyway, [q] quit"
            if ($resp -match '^q') { Exit-Safe 0 }
            if ($resp -match '^c') { Write-Host "Skipping claim phase." -ForegroundColor Yellow; return }
            if ($resp -eq '') {
                $emptyCount++
                if ($emptyCount -ge 5) { Exit-Safe 0 "No input detected - quitting." }
            } else {
                $emptyCount = 0
            }
            $since = Get-Date
        }
        Start-Sleep -Seconds 2
    }
}

Clear-Host
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host "  LOTF2 Save-Scum Loop" -ForegroundColor Magenta
Write-Host "=================================================" -ForegroundColor Magenta
Write-Host ""

if (Test-GameRunning) {
    Exit-Safe 1 "ERROR: the game is still running. Close it fully, then re-run."
}
if (-not (Test-Path -LiteralPath $src)) {
    Exit-Safe 1 "ERROR: save folder not found: $src"
}

if (Test-Path -LiteralPath $baselineDir) {
    Write-Host "An existing baseline is present."
    $rr = Read-Host "Refresh baseline from the current save state? [Enter=keep, r=refresh]"
    if ($rr -match '^r') { Backup-Save }
} else {
    Write-Host "No baseline yet - grabbing one from the current save state." -ForegroundColor Yellow
    Backup-Save
}

Write-Host ""
Write-Host "======== INTRO-SKIP ========" -ForegroundColor Cyan
if (Test-IntroSkip) {
    Write-Host "Status: APPLIED - launches skip the cinematics."
    $tk = Read-Host "[Enter] keep it, [t] remove it"
    if ($tk -match '^t') { Remove-IntroSkip }
} else {
    Write-Host "Status: NOT applied."
    $tk = Read-Host "[Enter] skip this, [t] apply it (skips cinematics)"
    if ($tk -match '^t') { Apply-IntroSkip }
}

Write-Host ""
Write-Host "Baseline : $baselineDir"
Write-Host "Everywhere: Enter = accept default, q = quit, r = refresh baseline."
Write-Host "Safeguard: exiting mid-cycle auto-restores the bundles."
Write-Host ""

$cycle = 0
try {
    while ($true) {
        $cycle++
        Write-Host ("----- CYCLE {0} -----" -f $cycle) -ForegroundColor Magenta

        Wait-ForGameClose

        Write-Host ""
        $r = Read-Host "Restore the baseline now? [Enter=yes, n=skip, q=quit]"
        if ($r -match '^q') { Exit-Safe 0 "Bye." }
        if ($r -notmatch '^n') {
            if (-not (Restore-Save)) { Exit-Safe 1 }
        } else {
            Write-Host "Restore skipped."
        }

        Write-Host ""
        Write-Host "======== VERIFY ========" -ForegroundColor Cyan
        Write-Host "Relaunch the game and check:"
        Write-Host "  - bundles are back in inventory"
        Write-Host "  - shrine balance is still HIGHER"
        Write-Host ""
        $v = Read-Host "Result? (y)es worked, (n)o, balance reverted, (r)efresh baseline, (q)uit"
        switch ($v) {
            { $_ -match '^n' } {
                Exit-Safe 1 "Balance reverted -> the dupe is patched or the currency is`nlocal-only on your version. STOP - your save is intact."
            }
            { $_ -match '^r' } { Backup-Save }
            { $_ -match '^q' } { Exit-Safe 0 "Bye." }
            default { }
        }
    }
} finally {
    Exit-Safe 0
}