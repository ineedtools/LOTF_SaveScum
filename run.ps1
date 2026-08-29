$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$src = Join-Path $env:LOCALAPPDATA 'LOTF2\Saved\SaveGames'
$baselineDir = Join-Path $PSScriptRoot 'baseline'
$checksumFile = Join-Path $baselineDir 'checksums.txt'
$idleTimeout = if ($env:LOTF2_IDLE_TIMEOUT) { [int]$env:LOTF2_IDLE_TIMEOUT } else { 60 }
$procMatch = if ($env:LOTF2_PROC_MATCH) { $env:LOTF2_PROC_MATCH } else { 'LOTF2' }

$script:dirty = $false
$script:exited = $false

function Test-GameRunning {
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $procMatch }
    return ($null -ne $p)
}

function Backup-Save {
    Write-Host ""
    Write-Host ">> Creating baseline snapshot..." -ForegroundColor Cyan
    if (Test-Path -LiteralPath $baselineDir) { Remove-Item -LiteralPath $baselineDir -Recurse -Force }
    New-Item -ItemType Directory -Path $baselineDir -Force | Out-Null
    Get-ChildItem -LiteralPath $src -File -Force | Copy-Item -Destination $baselineDir
    Get-ChildItem -LiteralPath $baselineDir -File | Sort-Object Name | ForEach-Object {
        $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        "$h  $($_.Name)"
    } | Set-Content -LiteralPath $checksumFile -Encoding Ascii
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
    exit $Code
}

function Wait-ForGameClose {
    Write-Host ""
    Write-Host "======== CLAIM PHASE ========" -ForegroundColor Cyan
    Write-Host "1. Launch the game."
    Write-Host "2. Open ALL your reward bundles in inventory."
    Write-Host "3. Wait ~15 seconds for the server to sync."
    Write-Host "4. Alt+F4 to quit (do NOT quit via the menu)."
    Write-Host ""
    Write-Host "Waiting for the game to start..." -ForegroundColor Yellow

    $appeared = $false
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