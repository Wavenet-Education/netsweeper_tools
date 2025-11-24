<#
.SYNOPSIS
    Generates an MST for Netsweeper (V11).
    Fixes: "SummaryInfo Stream Leak" which was keeping the Temp MSI locked.
#>

param (
    [string]$OriginalMsi  = ".\nmonitor.msi",
    [string]$OutputMst    = ".\nmonitor-config.mst",
    [string]$SettingsFile = ".\nmonitor-settings.txt"
)

$ErrorActionPreference = "Stop"

# --- Helper: Wait for File Lock to Release ---
function Wait-ForFile {
    param([string]$Path)
    Write-Host "   Waiting for file lock on: $(Split-Path $Path -Leaf)" -NoNewline
    $retries = 0
    while ($retries -lt 10) {
        try {
            # Try to open file stream exclusively to test lock
            $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
            $stream.Close()
            $stream.Dispose()
            Write-Host " [Unlocked]" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "." -NoNewline
            Start-Sleep -Milliseconds 500
            $retries++
            [System.GC]::Collect()
        }
    }
    Write-Host " [Timeout]" -ForegroundColor Red
    return $false
}

function Get-CleanPath {
    param([string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

Write-Host "--- Starting NMonitor MST Generation (V11: Leak Fix) ---" -ForegroundColor Cyan

# 1. Resolve Paths
try {
    $absOriginalMsi = Get-CleanPath $OriginalMsi
    $absMstPath     = Get-CleanPath $OutputMst
    $absSettings    = Get-CleanPath $SettingsFile
    
    $parentDir = Split-Path $absOriginalMsi -Parent
    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($absOriginalMsi)
    $absTempMsi = Join-Path $parentDir "${baseName}_TEMP.msi"

    Write-Host "Paths Resolved."
}
catch { Write-Error "Path resolution failed."; return }

# 2. Load Settings
$ConfigMap = @{}
if (Test-Path $absSettings) {
    $lines = Get-Content -Path $absSettings
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -eq 2) { $ConfigMap[$parts[0].Trim()] = $parts[1].Trim() }
    }
} else { Write-Error "Settings missing."; return }

# ==========================================
# PHASE 1: EDIT TEMP MSI
# ==========================================
Write-Host "[Phase 1] Preparing Temporary MSI..." -ForegroundColor Yellow

if (Test-Path $absTempMsi) { Remove-Item $absTempMsi -Force -ErrorAction SilentlyContinue }
Copy-Item -Path $absOriginalMsi -Destination $absTempMsi -Force
if (Test-Path $absTempMsi) { Unblock-File $absTempMsi -ErrorAction SilentlyContinue }

$wi = New-Object -ComObject WindowsInstaller.Installer
$db = $wi.OpenDatabase($absTempMsi, 1) # Read/Write

try {
    # A. Apply Properties
    foreach ($key in $ConfigMap.Keys) {
        $val = $ConfigMap[$key]
        $view = $db.OpenView("SELECT * FROM `Property` WHERE `Property` = '$key'")
        $view.Execute()
        if ($view.Fetch()) {
             $view.Close()
             $view = $db.OpenView("UPDATE `Property` SET `Value` = '$val' WHERE `Property` = '$key'")
             $view.Execute()
        } else {
             $view.Close()
             $view = $db.OpenView("INSERT INTO `Property` (`Property`, `Value`) VALUES ('$key', '$val')")
             $view.Execute()
        }
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null
    }
    
    # B. Update Package Code (With Leak Fix)
    Write-Host "   Updating Package Code..."
    $sumInfo = $db.SummaryInformation(1) 
    $newGuid = [System.Guid]::NewGuid().ToString("B").ToUpper()
    $sumInfo.Property(9) = $newGuid
    $sumInfo.Persist()
    
    # *** CRITICAL FIX: Release SummaryInfo explicitly ***
    [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($sumInfo) | Out-Null
    $sumInfo = $null

    Write-Host "   Committing..."
    $db.Commit()
}
catch { Write-Error "Phase 1 Failed: $_"; return }
finally {
    if ($sumInfo) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($sumInfo) | Out-Null }
    if ($db)      { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)      | Out-Null }
    if ($wi)      { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($wi)      | Out-Null }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

# ==========================================
# PHASE 2: GENERATE TRANSFORM
# ==========================================
Write-Host "[Phase 2] Generating Transform..." -ForegroundColor Yellow

# Ensure lock is released before proceeding
Wait-ForFile $absTempMsi

$wi = New-Object -ComObject WindowsInstaller.Installer

# I removed the Try/Catch block here so you can see the RAW error if it fails
Write-Host "   Opening Base (ReadOnly)..."
$dbOrig = $wi.OpenDatabase([string]$absOriginalMsi, [int]0)

Write-Host "   Opening Modified (ReadOnly)..."
$dbNew  = $wi.OpenDatabase([string]$absTempMsi, [int]0)

Write-Host "   Diffing..."
$dbNew.GenerateTransform($dbOrig, [string]$absMstPath)
$dbNew.CreateTransformSummaryInfo($dbOrig, [string]$absMstPath, [int]0, [int]0)

if (Test-Path $absMstPath) {
    Write-Host "--- SUCCESS! MST Created at: $absMstPath ---" -ForegroundColor Green
} else {
    Write-Error "Command finished but MST file is missing."
}

# Cleanup
if ($dbOrig) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($dbOrig) | Out-Null }
if ($dbNew)  { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($dbNew)  | Out-Null }
if ($wi)     { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($wi)     | Out-Null }
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()

if (Test-Path $absTempMsi) { Remove-Item $absTempMsi -Force -ErrorAction SilentlyContinue }