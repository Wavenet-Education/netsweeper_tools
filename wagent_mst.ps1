<#
.SYNOPSIS
    Generates an MST file for Netsweeper Agent.
    Reads arguments from a text file 'wagent-settings.txt'.
#>

param (
    [string]$OriginalMsi  = ".\NSWagent.msi",
    [string]$OutputMst    = ".\NetsweeperConfig.mst",
    [string]$SettingsFile = ".\wagent-settings.txt"
)

$ErrorActionPreference = "Stop"

# --- Helper Function for Absolute Paths ---
function Get-AbsolutePath {
    param([string]$Path)
    if (Test-Path $Path) { return (Resolve-Path $Path).Path }
    else { return Join-Path ((Get-Location).Path) $Path }
}

Write-Host "--- Starting MST Generation (V5: Text File Edition) ---" -ForegroundColor Cyan

# 1. Resolve Paths
try {
    $absOriginalMsi = Get-AbsolutePath $OriginalMsi
    $absMstPath     = Get-AbsolutePath $OutputMst
    $absSettings    = Get-AbsolutePath $SettingsFile

    # Derive Temp path
    $parentDir = Split-Path $absOriginalMsi -Parent
    $baseName  = [System.IO.Path]::GetFileNameWithoutExtension($absOriginalMsi)
    $absTempMsi = Join-Path $parentDir "${baseName}_TEMP.msi"

    Write-Host "Paths:"
    Write-Host "   Original MSI:  $absOriginalMsi"
    Write-Host "   Settings File: $absSettings"
    Write-Host "   Output MST:    $absMstPath"
}
catch {
    Write-Error "Path resolution failed."
    return
}

# 2. Read and Validate Settings File
if (Test-Path $absSettings) {
    Write-Host "Reading settings from file..."
    # -Raw reads it as one string; .Trim() removes accidental spaces/newlines at start/end
    $AgentArgs = (Get-Content -Path $absSettings -Raw).Trim()
    
    # Safety: Replace any internal line breaks with spaces just in case
    $AgentArgs = $AgentArgs -replace "[\r\n]+", " "
    
    if ([string]::IsNullOrWhiteSpace($AgentArgs)) {
        Write-Error "The settings file is empty! Please add your arguments to $SettingsFile"
        return
    }
    Write-Host "   Loaded Args: [$AgentArgs]" -ForegroundColor Cyan
}
else {
    Write-Error "Settings file not found at: $absSettings"
    Write-Error "Please create the file or check the path."
    return
}

# Cleanup variables
$wi = $null; $viewDb = $null; $baseDb = $null; $view = $null; $record = $null

try {
    # 3. Create Temp Copy
    Copy-Item -Path $absOriginalMsi -Destination $absTempMsi -Force

    # 4. Init COM Object
    $wi = New-Object -ComObject WindowsInstaller.Installer
    $viewDb = $wi.OpenDatabase($absTempMsi, 1) # Read/Write

    # 5. Update Property
    $query = "SELECT * FROM `Property` WHERE `Property` = 'NS_WAGENT_ARGS'"
    $view = $viewDb.OpenView($query)
    $view.Execute()
    $record = $view.Fetch()

    if ($record) {
        Write-Host "   Property found. Updating..." -ForegroundColor Yellow
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) | Out-Null
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null
        $record = $null; $view = $null

        $updateQuery = "UPDATE `Property` SET `Value` = '$AgentArgs' WHERE `Property` = 'NS_WAGENT_ARGS'"
        $view = $viewDb.OpenView($updateQuery)
        $view.Execute()
    }
    else {
        Write-Host "   Property not found. Inserting..." -ForegroundColor Green
        if ($view) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null; $view = $null }

        $insertQuery = "INSERT INTO `Property` (`Property`, `Value`) VALUES ('NS_WAGENT_ARGS', '$AgentArgs')"
        $view = $viewDb.OpenView($insertQuery)
        $view.Execute()
    }

    # Cleanup View
    if ($view) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null; $view = $null }

    # 6. Commit & Generate
    $viewDb.Commit()
    $baseDb = $wi.OpenDatabase($absOriginalMsi, 0) 
    $viewDb.GenerateTransform($baseDb, $absMstPath)
    $viewDb.CreateTransformSummaryInfo($baseDb, $absMstPath, 0, 0)

    if (Test-Path $absMstPath) {
        Write-Host "--- SUCCESS! MST created at: $absMstPath ---" -ForegroundColor Green
    } else {
        Write-Error "Script finished but MST file is missing."
    }
}
catch {
    Write-Error "FATAL ERROR: $($_.Exception.Message)"
}
finally {
    Write-Host "   Cleaning up..." -ForegroundColor Gray
    if ($record) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) | Out-Null }
    if ($view)   { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)   | Out-Null }
    if ($baseDb) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($baseDb) | Out-Null }
    if ($viewDb) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($viewDb) | Out-Null }
    if ($wi)     { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($wi)     | Out-Null }
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    if (Test-Path $absTempMsi) { Remove-Item $absTempMsi -Force -ErrorAction SilentlyContinue }

}
