$ErrorActionPreference = 'Stop'

$binDir = 'C:\Users\lx\bin'
$sourceDir = 'R:\Code\MY project\cli_notify\bin'

# Create bin directory
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# Copy all ps1 and vbs files
Copy-Item -Path "$sourceDir\*.ps1" -Destination $binDir -Force
Copy-Item -Path "$sourceDir\*.vbs" -Destination $binDir -Force

# List copied files
$files = Get-ChildItem "$binDir\notify*" -File
Write-Host "Files copied to $binDir`: $($files.Count) files"
$files | ForEach-Object { Write-Host "  $($_.Name)" }
