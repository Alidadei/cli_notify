$ErrorActionPreference = 'Stop'

# Use actual AppData Roaming path (F:\AppData for user lx)
$appDataPath = [Environment]::GetFolderPath('ApplicationData')
Write-Host "AppData Roaming: $appDataPath"

# Standard PS module path under AppData
$moduleBase = Join-Path $appDataPath 'WindowsPowerShell\Modules'
$btPath = Join-Path $moduleBase 'BurntToast'

Write-Host "Target path: $btPath"

# Create directory
New-Item -ItemType Directory -Path (Join-Path $btPath '1.1.0') -Force | Out-Null

# Copy using robocopy
$source = 'C:\BurntToastTmp\BurntToast'
robocopy $source $btPath /E /R:1 /W:1 /NP

# Ensure this path is in PSModulePath
$userModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
if (-not $userModulePath) { $userModulePath = '' }
if ($userModulePath -notlike "*$moduleBase*") {
    $newPath = if ($userModulePath) { "$userModulePath;$moduleBase" } else { $moduleBase }
    [Environment]::SetEnvironmentVariable('PSModulePath', $newPath, 'User')
    Write-Host "Added to PSModulePath: $moduleBase"
}

# Update current session
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'User') + ';' + [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')

# Verify
if (Get-Module -ListAvailable -Name BurntToast) {
    Write-Host ""
    Write-Host "=== SUCCESS: BurntToast installed ===" -ForegroundColor Green
    Get-Module -ListAvailable -Name BurntToast | ForEach-Object {
        Write-Host "  Version: $($_.Version)" -ForegroundColor Cyan
        Write-Host "  Path: $($_.ModuleBase)" -ForegroundColor Cyan
    }
} else {
    Write-Host "WARNING: Module not auto-detected, checking files..."
    if (Test-Path $btPath) {
        $count = (Get-ChildItem $btPath -Recurse -File).Count
        Write-Host "  Files found: $count"
    }
}
