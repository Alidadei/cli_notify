#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE "bin"),
  [switch]$SkipBurntToast,
  [switch]$SkipClaude,
  [switch]$SkipCodex,
  [switch]$SkipAutostart,
  [switch]$NoStart,
  [switch]$NoTest
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string]$Message)
  Write-Host ("[setup] " + $Message)
}

function Write-WarnStep {
  param([string]$Message)
  Write-Host ("[setup] WARNING: " + $Message) -ForegroundColor Yellow
}

function Assert-Prerequisites {
  param([string]$SourceBin)

  if ($PSVersionTable.PSVersion -lt [version]"5.1") {
    throw "PowerShell 5.1 or newer is required."
  }

  if (-not $IsWindows -and -not $env:WINDIR) {
    throw "This bootstrap only supports Windows."
  }

  $requiredFiles = @(
    "notify.ps1",
    "notify-tray.vbs",
    "codex-watch.ps1",
    "codex-watch.vbs"
  )

  foreach ($name in $requiredFiles) {
    $path = Join-Path $SourceBin $name
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Required file missing: $path"
    }
  }

  if (-not (Get-Command -Name "wscript.exe" -ErrorAction SilentlyContinue)) {
    throw "wscript.exe was not found."
  }
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Backup-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $backupPath = "{0}.bak-{1}" -f $Path, (Get-Date -Format "yyyyMMdd-HHmmss")
  Copy-Item -LiteralPath $Path -Destination $backupPath -Force
  return $backupPath
}

function Normalize-ClaudeHookCommand {
  param([string]$Command)
  if ([string]::IsNullOrWhiteSpace($Command)) { return "" }

  $value = $Command.Trim().ToLowerInvariant()
  $value = $value -replace "\s+", " "
  $value = $value -replace "-source\s+'claude'", "-source claude"
  $value = $value -replace '"', ""
  $value = $value -replace "\s+", " "
  return $value.Trim()
}

function New-ClaudeHookGroup {
  param([string]$Command)
  return [pscustomobject]@{
    hooks = @(
      [pscustomobject]@{
        type = "command"
        command = $Command
        shell = "powershell"
      }
    )
  }
}

function Test-ClaudeHookExists {
  param(
    [object[]]$Groups,
    [string]$Command
  )
  $normalizedTarget = Normalize-ClaudeHookCommand -Command $Command
  foreach ($group in @($Groups)) {
    foreach ($hook in @($group.hooks)) {
      $normalizedCurrent = Normalize-ClaudeHookCommand -Command ([string]$hook.command)
      if ($hook.type -eq "command" -and $hook.shell -eq "powershell" -and $normalizedCurrent -eq $normalizedTarget) {
        return $true
      }
    }
  }
  return $false
}

function Install-BurntToastModule {
  $available = $false
  if (Get-Module -ListAvailable -Name BurntToast) {
    Write-Step "BurntToast already installed."
    return [pscustomobject]@{
      Available = $true
      Message = "already installed"
    }
  }

  Write-Step "Installing BurntToast..."
  try {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    try {
      if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
      }
    } catch {}

    try {
      Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {}

    Install-Module -Name BurntToast -Force -AllowClobber -Scope CurrentUser
  } catch {
    Write-WarnStep ("BurntToast install failed; native toast fallback will be used. " + $_.Exception.Message)
  }

  $available = [bool](Get-Module -ListAvailable -Name BurntToast)
  return [pscustomobject]@{
    Available = $available
    Message = $(if ($available) { "installed" } else { "not available; using native toast fallback" })
  }
}

function Add-VerifyResult {
  param(
    [System.Collections.Generic.List[object]]$Results,
    [string]$Check,
    [string]$Status,
    [string]$Detail
  )
  $Results.Add([pscustomobject]@{
    Check = $Check
    Status = $Status
    Detail = $Detail
  }) | Out-Null
}

function Get-RunEntryValue {
  param([string]$Name)
  $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
  try {
    return (Get-ItemProperty -Path $runKey -Name $Name -ErrorAction Stop).$Name
  } catch {
    return $null
  }
}

function Get-ProcessesMatchingPath {
  param([string]$Path)
  $escaped = [regex]::Escape($Path)
  return @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match $escaped }
  )
}

function Wait-ForBackgroundProcesses {
  param(
    [string]$NotifyTrayScriptPath,
    [string]$CodexWatchScriptPath,
    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $trayMatches = Get-ProcessesMatchingPath -Path $NotifyTrayScriptPath
    $watchMatches = Get-ProcessesMatchingPath -Path $CodexWatchScriptPath
    if ($trayMatches.Count -gt 0 -and $watchMatches.Count -gt 0) {
      return [pscustomobject]@{
        Tray = $trayMatches
        Watch = $watchMatches
      }
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)

  return [pscustomobject]@{
    Tray = @()
    Watch = @()
  }
}

function Test-RecentFileActivity {
  param(
    [string]$Path,
    [datetime]$Since
  )

  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    return ($item.LastWriteTime -ge $Since)
  } catch {
    return $false
  }
}

function Wait-ForRecentFileActivity {
  param(
    [string]$Path,
    [datetime]$Since,
    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (Test-RecentFileActivity -Path $Path -Since $Since) { return $true }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)

  return $false
}

function Test-CodexNotifyConfigured {
  param(
    [string]$ConfigPath,
    [string]$NotifyScriptPath
  )

  if (-not (Test-Path -LiteralPath $ConfigPath)) { return $false }
  $content = Get-Content -LiteralPath $ConfigPath -Raw
  $pattern = "(?ms)notify\s*=\s*\[.*?" + [regex]::Escape($NotifyScriptPath) + ".*?'Codex'.*?\]"
  return ($content -match $pattern)
}

function Invoke-SetupVerification {
  param(
    [string]$InstallDirPath,
    [string]$NotifyScriptPath,
    [string]$NotifyTrayScriptPath,
    [string]$NotifyTrayVbsPath,
    [string]$CodexWatchScriptPath,
    [string]$CodexWatchVbsPath,
    [string]$TrayLogPath,
    [string]$CodexWatchLogPath,
    [datetime]$BackgroundStartTime,
    [bool]$BurntToastAvailable,
    [string]$BurntToastMessage,
    [bool]$SkipClaudeConfig,
    [bool]$SkipCodexConfig,
    [bool]$SkipAutostartConfig,
    [bool]$NoStartPrograms,
    [bool]$NoTestNotification,
    [bool]$TestNotificationSucceeded
  )

  $results = New-Object 'System.Collections.Generic.List[object]'

  foreach ($path in @(
    $NotifyScriptPath,
    $NotifyTrayVbsPath,
    $CodexWatchScriptPath,
    $CodexWatchVbsPath,
    (Join-Path $InstallDirPath ".env")
  )) {
    if (Test-Path -LiteralPath $path) {
      Add-VerifyResult -Results $results -Check ("File " + [System.IO.Path]::GetFileName($path)) -Status "PASS" -Detail $path
    } else {
      Add-VerifyResult -Results $results -Check ("File " + [System.IO.Path]::GetFileName($path)) -Status "FAIL" -Detail ("Missing: " + $path)
    }
  }

  if ($BurntToastAvailable) {
    Add-VerifyResult -Results $results -Check "BurntToast" -Status "PASS" -Detail $BurntToastMessage
  } else {
    Add-VerifyResult -Results $results -Check "BurntToast" -Status "WARN" -Detail $BurntToastMessage
  }

  if ($SkipClaudeConfig) {
    Add-VerifyResult -Results $results -Check "Claude hooks" -Status "WARN" -Detail "Skipped by flag."
  } else {
    $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
    $expectedCommand = "& '" + $NotifyScriptPath + "' -Source 'Claude'"
    if (Test-Path -LiteralPath $settingsPath) {
      try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $stopOk = Test-ClaudeHookExists -Groups @($settings.hooks.Stop) -Command $expectedCommand
        $notificationOk = Test-ClaudeHookExists -Groups @($settings.hooks.Notification) -Command $expectedCommand
        if ($stopOk -and $notificationOk) {
          Add-VerifyResult -Results $results -Check "Claude hooks" -Status "PASS" -Detail $settingsPath
        } else {
          Add-VerifyResult -Results $results -Check "Claude hooks" -Status "FAIL" -Detail "Stop or Notification hook is missing."
        }
      } catch {
        Add-VerifyResult -Results $results -Check "Claude hooks" -Status "FAIL" -Detail $_.Exception.Message
      }
    } else {
      Add-VerifyResult -Results $results -Check "Claude hooks" -Status "FAIL" -Detail ("Missing: " + $settingsPath)
    }
  }

  if ($SkipCodexConfig) {
    Add-VerifyResult -Results $results -Check "Codex notify" -Status "WARN" -Detail "Skipped by flag."
  } else {
    $configPath = Join-Path $env:USERPROFILE ".codex\config.toml"
    if (Test-CodexNotifyConfigured -ConfigPath $configPath -NotifyScriptPath $NotifyScriptPath) {
      Add-VerifyResult -Results $results -Check "Codex notify" -Status "PASS" -Detail $configPath
    } else {
      Add-VerifyResult -Results $results -Check "Codex notify" -Status "FAIL" -Detail ("Missing or incorrect notify block in " + $configPath)
    }
  }

  if ($SkipAutostartConfig) {
    Add-VerifyResult -Results $results -Check "Autostart entries" -Status "WARN" -Detail "Skipped by flag."
  } else {
    $trayRun = Get-RunEntryValue -Name "NotifyTray"
    $watchRun = Get-RunEntryValue -Name "CodexWatch"
    $expectedTray = 'wscript.exe "' + $NotifyTrayVbsPath + '"'
    $expectedWatch = 'wscript.exe "' + $CodexWatchVbsPath + '"'
    if ($trayRun -eq $expectedTray -and $watchRun -eq $expectedWatch) {
      Add-VerifyResult -Results $results -Check "Autostart entries" -Status "PASS" -Detail "NotifyTray and CodexWatch registered."
    } else {
      Add-VerifyResult -Results $results -Check "Autostart entries" -Status "FAIL" -Detail "NotifyTray or CodexWatch run key is missing or incorrect."
    }
  }

  if ($NoStartPrograms) {
    Add-VerifyResult -Results $results -Check "Background start" -Status "WARN" -Detail "Skipped by flag."
  } else {
    $started = Wait-ForBackgroundProcesses -NotifyTrayScriptPath $NotifyTrayScriptPath -CodexWatchScriptPath $CodexWatchScriptPath -TimeoutSeconds 5
    $trayLogOk = Wait-ForRecentFileActivity -Path $TrayLogPath -Since $BackgroundStartTime -TimeoutSeconds 30
    $watchLogOk = Wait-ForRecentFileActivity -Path $CodexWatchLogPath -Since $BackgroundStartTime -TimeoutSeconds 30
    $trayOk = ($started.Tray.Count -gt 0) -or $trayLogOk
    $watchOk = ($started.Watch.Count -gt 0) -or $watchLogOk
    if ($trayOk -and $watchOk) {
      Add-VerifyResult -Results $results -Check "Background start" -Status "PASS" -Detail "NotifyTray and CodexWatch are running."
    } else {
      $detail = "NotifyTray or CodexWatch is not running."
      if (-not $trayOk) { $detail += " tray_log=" + $TrayLogPath }
      if (-not $watchOk) { $detail += " codex_watch_log=" + $CodexWatchLogPath }
      Add-VerifyResult -Results $results -Check "Background start" -Status "FAIL" -Detail $detail
    }
  }

  if ($NoTestNotification) {
    Add-VerifyResult -Results $results -Check "Test notification" -Status "WARN" -Detail "Skipped by flag."
  } elseif ($TestNotificationSucceeded) {
    Add-VerifyResult -Results $results -Check "Test notification" -Status "PASS" -Detail "notify.ps1 executed successfully."
  } else {
    Add-VerifyResult -Results $results -Check "Test notification" -Status "FAIL" -Detail "notify.ps1 test invocation failed."
  }

  return $results
}

function Write-VerificationSummary {
  param([object[]]$Results)

  Write-Host ""
  Write-Host "[setup] Verification summary"
  foreach ($result in $Results) {
    $prefix = ("[{0}]" -f $result.Status)
    switch ($result.Status) {
      "PASS" { Write-Host ($prefix + " " + $result.Check + " - " + $result.Detail) -ForegroundColor Green }
      "WARN" { Write-Host ($prefix + " " + $result.Check + " - " + $result.Detail) -ForegroundColor Yellow }
      default { Write-Host ($prefix + " " + $result.Check + " - " + $result.Detail) -ForegroundColor Red }
    }
  }
}

function Copy-InstallFiles {
  param(
    [string]$SourceBin,
    [string]$TargetBin,
    [string]$EnvTemplate
  )

  Write-Step ("Copying files to " + $TargetBin)
  Ensure-Directory -Path $TargetBin

  Get-ChildItem -Path $SourceBin -File |
    Where-Object { $_.Extension -in @(".ps1", ".vbs") } |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetBin $_.Name) -Force
    }

  $targetEnv = Join-Path $TargetBin ".env"
  if ((Test-Path -LiteralPath $EnvTemplate) -and -not (Test-Path -LiteralPath $targetEnv)) {
    Copy-Item -LiteralPath $EnvTemplate -Destination $targetEnv -Force
  }
}

function Configure-ClaudeHooks {
  param([string]$NotifyScriptPath)

  $claudeDir = Join-Path $env:USERPROFILE ".claude"
  $settingsPath = Join-Path $claudeDir "settings.json"
  Ensure-Directory -Path $claudeDir

  $settings = [pscustomobject]@{}
  if (Test-Path -LiteralPath $settingsPath) {
    Backup-File -Path $settingsPath | Out-Null
    $raw = Get-Content -LiteralPath $settingsPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $settings = $raw | ConvertFrom-Json
    }
  }

  if (-not $settings) { $settings = [pscustomobject]@{} }
  if (-not $settings.PSObject.Properties["hooks"]) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
  } elseif (-not $settings.hooks) {
    $settings.hooks = [pscustomobject]@{}
  }

  $command = "& '" + $NotifyScriptPath + "' -Source 'Claude'"

  foreach ($eventName in @("Stop", "Notification")) {
    $existing = $settings.hooks.PSObject.Properties[$eventName]
    if (-not $existing -or -not $existing.Value) {
      $settings.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @((New-ClaudeHookGroup -Command $command))
      continue
    }

    if (-not (Test-ClaudeHookExists -Groups @($existing.Value) -Command $command)) {
      $settings.hooks.$eventName = @($existing.Value) + @((New-ClaudeHookGroup -Command $command))
    }
  }

  $settings | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
  Write-Step ("Claude hooks updated: " + $settingsPath)
}

function New-CodexNotifyBlock {
  param([string]$NotifyScriptPath)

  return @"
notify = [
  'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  '$NotifyScriptPath',
  '-Source',
  'Codex',
]
"@
}

function Configure-CodexNotify {
  param([string]$NotifyScriptPath)

  $codexDir = Join-Path $env:USERPROFILE ".codex"
  $configPath = Join-Path $codexDir "config.toml"
  Ensure-Directory -Path $codexDir

  if (Test-Path -LiteralPath $configPath) {
    Backup-File -Path $configPath | Out-Null
    $content = Get-Content -LiteralPath $configPath -Raw
  } else {
    $content = ""
  }

  $notifyBlock = New-CodexNotifyBlock -NotifyScriptPath $NotifyScriptPath
  $pattern = "(?ms)^notify\s*=\s*\[.*?\]\s*"
  if ($content -match $pattern) {
    $updated = [regex]::Replace($content, $pattern, ($notifyBlock + "`r`n"), 1)
  } else {
    if ([string]::IsNullOrWhiteSpace($content)) {
      $updated = $notifyBlock + "`r`n"
    } else {
      $updated = $notifyBlock + "`r`n" + $content.TrimStart()
    }
  }

  Set-Content -LiteralPath $configPath -Value $updated -Encoding UTF8
  Write-Step ("Codex notify updated: " + $configPath)
}

function Set-AutostartEntry {
  param(
    [string]$Name,
    [string]$Command
  )
  $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
  New-ItemProperty -Path $runKey -Name $Name -Value $Command -PropertyType String -Force | Out-Null
}

function Stop-ProcessesByPattern {
  param([string]$Pattern)
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $Pattern } |
    ForEach-Object {
      try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Start-BackgroundPrograms {
  param(
    [string]$NotifyTrayVbs,
    [string]$CodexWatchVbs
  )

  Stop-ProcessesByPattern -Pattern "notify-tray\.ps1|notify-tray\.vbs"
  Stop-ProcessesByPattern -Pattern "codex-watch\.ps1|codex-watch\.vbs"
  Start-Sleep -Seconds 1

  if (Test-Path -LiteralPath $NotifyTrayVbs) {
    Start-Process -FilePath "wscript.exe" -ArgumentList ('"' + $NotifyTrayVbs + '"') -WindowStyle Hidden | Out-Null
  }
  if (Test-Path -LiteralPath $CodexWatchVbs) {
    Start-Process -FilePath "wscript.exe" -ArgumentList ('"' + $CodexWatchVbs + '"') -WindowStyle Hidden | Out-Null
  }
}

$repoRoot = Split-Path -Parent $PSCommandPath
$sourceBin = Join-Path $repoRoot "bin"
$envTemplate = Join-Path $repoRoot ".env.example"
$notifyScriptPath = Join-Path $InstallDir "notify.ps1"
$notifyTrayScriptPath = Join-Path $InstallDir "notify-tray.ps1"
$notifyTrayVbs = Join-Path $InstallDir "notify-tray.vbs"
$codexWatchScriptPath = Join-Path $InstallDir "codex-watch.ps1"
$codexWatchVbs = Join-Path $InstallDir "codex-watch.vbs"
$trayLogPath = Join-Path $env:LOCALAPPDATA "notify\tray.log"
$codexWatchLogPath = Join-Path $env:LOCALAPPDATA "notify\codex-watch.log"
$backgroundStartTime = Get-Date

Assert-Prerequisites -SourceBin $sourceBin

Write-Step "Starting Windows bootstrap..."
Copy-InstallFiles -SourceBin $sourceBin -TargetBin $InstallDir -EnvTemplate $envTemplate

$burntToastInfo = [pscustomobject]@{
  Available = [bool](Get-Module -ListAvailable -Name BurntToast)
  Message = $(if ([bool](Get-Module -ListAvailable -Name BurntToast)) { "already installed" } else { "not requested" })
}
if (-not $SkipBurntToast) {
  $burntToastInfo = Install-BurntToastModule
}

if (-not $SkipClaude) {
  Configure-ClaudeHooks -NotifyScriptPath $notifyScriptPath
}

if (-not $SkipCodex) {
  Configure-CodexNotify -NotifyScriptPath $notifyScriptPath
}

if (-not $SkipAutostart) {
  Set-AutostartEntry -Name "NotifyTray" -Command ('wscript.exe "' + $notifyTrayVbs + '"')
  Set-AutostartEntry -Name "CodexWatch" -Command ('wscript.exe "' + $codexWatchVbs + '"')
  Write-Step "Autostart enabled for NotifyTray and CodexWatch."
}

if (-not $NoStart) {
  Write-Step "Starting tray and CodexWatch..."
  $backgroundStartTime = Get-Date
  Start-BackgroundPrograms -NotifyTrayVbs $notifyTrayVbs -CodexWatchVbs $codexWatchVbs
}

$testNotificationSucceeded = $false
if (-not $NoTest) {
  Write-Step "Sending test notification..."
  try {
    & $notifyScriptPath -Source "Setup" -Title "cli_notify ready" -Body "Windows bootstrap completed." | Out-Null
    $testNotificationSucceeded = $true
  } catch {
    Write-WarnStep ("Test notification failed: " + $_.Exception.Message)
  }
}

$verification = Invoke-SetupVerification `
  -InstallDirPath $InstallDir `
  -NotifyScriptPath $notifyScriptPath `
  -NotifyTrayScriptPath $notifyTrayScriptPath `
  -NotifyTrayVbsPath $notifyTrayVbs `
  -CodexWatchScriptPath $codexWatchScriptPath `
  -CodexWatchVbsPath $codexWatchVbs `
  -TrayLogPath $trayLogPath `
  -CodexWatchLogPath $codexWatchLogPath `
  -BackgroundStartTime $backgroundStartTime `
  -BurntToastAvailable $burntToastInfo.Available `
  -BurntToastMessage $burntToastInfo.Message `
  -SkipClaudeConfig ([bool]$SkipClaude) `
  -SkipCodexConfig ([bool]$SkipCodex) `
  -SkipAutostartConfig ([bool]$SkipAutostart) `
  -NoStartPrograms ([bool]$NoStart) `
  -NoTestNotification ([bool]$NoTest) `
  -TestNotificationSucceeded $testNotificationSucceeded

Write-VerificationSummary -Results $verification

$failCount = @($verification | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = @($verification | Where-Object { $_.Status -eq "WARN" }).Count

if ($failCount -gt 0) {
  throw ("Verification failed with {0} failing check(s)." -f $failCount)
}

$passCount = @($verification | Where-Object { $_.Status -eq "PASS" }).Count
Write-Step ("Done. " + ((@(
  ("pass=" + $passCount),
  ("warn=" + $warnCount),
  ("fail=" + $failCount)
) -join ", ")))
Write-Host ""
Write-Host ("InstallDir : " + $InstallDir)
Write-Host ("Claude     : " + ($(if ($SkipClaude) { "skipped" } else { "configured" })))
Write-Host ("Codex      : " + ($(if ($SkipCodex) { "skipped" } else { "configured" })))
Write-Host ("Autostart  : " + ($(if ($SkipAutostart) { "skipped" } else { "enabled" })))
Write-Host ("StartNow   : " + ($(if ($NoStart) { "no" } else { "yes" })))
