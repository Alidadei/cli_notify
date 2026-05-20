#requires -Version 5.1
[CmdletBinding()]
param(
  [int]$PollSeconds = 2,
  [int]$RecentHours = 12,
  [int]$MaxFiles = 50,
  [switch]$RunOnce
)

$script:WatchRoot = Join-Path $env:USERPROFILE ".codex\sessions"
$script:NotifyScript = Join-Path $PSScriptRoot "notify.ps1"
$script:LogDir = Join-Path $env:LOCALAPPDATA "notify"
$script:LogFile = Join-Path $script:LogDir "codex-watch.log"
$script:States = @{}
$script:Notified = @{}
$script:AttentionPattern = '(?is)\b(waiting for|need|requires?)\b.{0,80}\b(your input|your approval|approval|permission|confirmation|selection|choice|pick|continue)\b'

function Initialize-WatchLog {
  try {
    if (-not (Test-Path $script:LogDir)) {
      New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
  } catch {}
}

function Write-WatchLog {
  param([string]$Message)
  try {
    Initialize-WatchLog
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $script:LogFile -Value "$stamp $Message"
  } catch {}
}

function Get-SessionIdFromPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return "unknown" }
  try {
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
  } catch {
    return "unknown"
  }
}

function Get-FileState {
  param([string]$Path)
  if (-not $script:States.ContainsKey($Path)) {
    $script:States[$Path] = @{
      Offset = 0L
      Remainder = ""
      SessionId = (Get-SessionIdFromPath -Path $Path)
      Cwd = $null
    }
  }
  return $script:States[$Path]
}

function Get-TextFromContent {
  param($Content)
  if ($null -eq $Content) { return $null }
  if ($Content -is [string]) { return $Content }
  if ($Content.text) { return [string]$Content.text }
  if ($Content.value) { return [string]$Content.value }
  if ($Content.output_text) { return [string]$Content.output_text }
  if ($Content.message) { return (Get-TextFromContent -Content $Content.message) }
  if ($Content.content) { return (Get-TextFromContent -Content $Content.content) }
  if ($Content -is [System.Collections.IEnumerable]) {
    $parts = @()
    foreach ($item in $Content) {
      $text = Get-TextFromContent -Content $item
      if (-not [string]::IsNullOrWhiteSpace($text)) { $parts += $text.Trim() }
    }
    if ($parts.Count -gt 0) { return ($parts -join " ") }
  }
  return $null
}

function Normalize-Message {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $value = $Text -replace '\r', ' '
  $value = $value -replace '\n+', ' '
  $value = $value -replace '\s{2,}', ' '
  $value = $value.Trim()
  if ($value.Length -gt 400) {
    return ($value.Substring(0, 397) + "...")
  }
  return $value
}

function Get-FunctionArguments {
  param($Item)
  if ($null -eq $Item) { return $null }
  if ($Item.arguments -and $Item.arguments -isnot [string]) { return $Item.arguments }
  if ($Item.function_call -and $Item.function_call.arguments -and $Item.function_call.arguments -isnot [string]) {
    return $Item.function_call.arguments
  }

  $raw = $null
  if ($Item.arguments -is [string]) { $raw = $Item.arguments }
  elseif ($Item.function_call -and $Item.function_call.arguments -is [string]) { $raw = $Item.function_call.arguments }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

  try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-FunctionName {
  param($Item)
  if ($null -eq $Item) { return $null }
  foreach ($name in @($Item.name, $Item.function_name, $Item.functionName)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$name)) { return [string]$name }
  }
  if ($Item.function_call) {
    foreach ($name in @($Item.function_call.name, $Item.function_call.function_name, $Item.function_call.functionName)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$name)) { return [string]$name }
    }
  }
  return $null
}

function Get-UserInputPrompt {
  param($Arguments)
  if ($null -eq $Arguments) { return $null }

  foreach ($value in @($Arguments.question, $Arguments.prompt, $Arguments.message, $Arguments.title)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
      return [string]$value
    }
  }

  if ($Arguments.questions -is [System.Collections.IEnumerable]) {
    foreach ($entry in $Arguments.questions) {
      foreach ($value in @($entry.question, $entry.prompt, $entry.header, $entry.label)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
          return [string]$value
        }
      }
    }
  }

  return $null
}

function Test-NeedsUserAttention {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
  return ($Message -match $script:AttentionPattern)
}

function Register-NotifyKey {
  param(
    [string]$SessionId,
    [string]$Kind,
    [string]$Fingerprint
  )
  $key = "{0}|{1}|{2}" -f $SessionId, $Kind, $Fingerprint
  $now = Get-Date
  $cutoff = $now.AddHours(-12)
  $expired = @()
  foreach ($entry in $script:Notified.GetEnumerator()) {
    if ($entry.Value -lt $cutoff) { $expired += $entry.Key }
  }
  foreach ($item in $expired) {
    [void]$script:Notified.Remove($item)
  }
  if ($script:Notified.ContainsKey($key)) { return $false }
  $script:Notified[$key] = $now
  return $true
}

function Send-CodexNotify {
  param(
    [string]$Title,
    [string]$Message,
    [string]$SessionId,
    [string]$Cwd,
    [string]$Type
  )
  if (-not (Test-Path $script:NotifyScript)) {
    Write-WatchLog "notify script missing: $script:NotifyScript"
    return
  }

  $bodyLines = @()
  $bodyLines += "Session: $SessionId"
  if (-not [string]::IsNullOrWhiteSpace($Cwd)) { $bodyLines += "Project: $Cwd" }
  if (-not [string]::IsNullOrWhiteSpace($Type)) { $bodyLines += "Type: $Type" }
  if (-not [string]::IsNullOrWhiteSpace($Message)) { $bodyLines += "Message: $Message" }
  $body = $bodyLines -join "`n"

  try {
    & $script:NotifyScript -Source "Codex" -Title $Title -Body $body | Out-Null
    Write-WatchLog "sent [$Type] $SessionId"
  } catch {
    Write-WatchLog "notify failed [$Type] $SessionId :: $($_.Exception.Message)"
  }
}

function Handle-JsonLine {
  param(
    [string]$Path,
    [string]$Line
  )
  if ([string]::IsNullOrWhiteSpace($Line)) { return }

  try {
    $item = $Line | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-WatchLog "json parse failed for $Path"
    return
  }

  $state = Get-FileState -Path $Path
  if ($item.session_id) { $state.SessionId = [string]$item.session_id }
  elseif ($item.sessionId) { $state.SessionId = [string]$item.sessionId }
  if ($item.cwd) { $state.Cwd = [string]$item.cwd }
  elseif ($item.workdir) { $state.Cwd = [string]$item.workdir }

  $sessionId = $state.SessionId
  if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = (Get-SessionIdFromPath -Path $Path) }
  $cwd = $state.Cwd

  $eventType = [string]$item.type
  $subType = [string]$item.subtype
  $name = Get-FunctionName -Item $item
  $arguments = Get-FunctionArguments -Item $item

  $sandbox = $null
  if ($arguments -and $arguments.sandbox_permissions) { $sandbox = [string]$arguments.sandbox_permissions }

  $contentText = Normalize-Message (Get-TextFromContent -Content $item.content)
  if (-not $contentText) { $contentText = Normalize-Message (Get-TextFromContent -Content $item.message) }
  if (-not $contentText) { $contentText = Normalize-Message (Get-TextFromContent -Content $item.output_text) }

  if ($eventType -eq "response_item" -and $subType -eq "function_call" -and $sandbox -eq "require_escalated") {
    $fingerprint = Normalize-Message ("$name $($arguments | ConvertTo-Json -Compress -Depth 5)")
    if (Register-NotifyKey -SessionId $sessionId -Kind "approval" -Fingerprint $fingerprint) {
      $detail = Normalize-Message (Get-TextFromContent -Content $arguments.justification)
      if (-not $detail) { $detail = "Approval requested for a privileged command." }
      Send-CodexNotify -Title "Codex needs approval" -Message $detail -SessionId $sessionId -Cwd $cwd -Type "approval"
    }
    return
  }

  if ($eventType -eq "function_call" -and $name -eq "request_user_input") {
    $prompt = Normalize-Message (Get-UserInputPrompt -Arguments $arguments)
    if (-not $prompt) { $prompt = "Codex is waiting for your choice." }
    if (Register-NotifyKey -SessionId $sessionId -Kind "request_user_input" -Fingerprint $prompt) {
      Send-CodexNotify -Title "Codex needs your input" -Message $prompt -SessionId $sessionId -Cwd $cwd -Type "input"
    }
    return
  }

  $role = [string]$item.role
  $looksAssistant = ($role -eq "assistant" -or $eventType -eq "response_item")
  if ($looksAssistant -and (Test-NeedsUserAttention -Message $contentText)) {
    if (Register-NotifyKey -SessionId $sessionId -Kind "attention" -Fingerprint $contentText) {
      Send-CodexNotify -Title "Codex is waiting on you" -Message $contentText -SessionId $sessionId -Cwd $cwd -Type "attention"
    }
  }
}

function Process-SessionFile {
  param([System.IO.FileInfo]$File)
  if ($null -eq $File) { return }

  $path = $File.FullName
  $state = Get-FileState -Path $path

  try {
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $length = $stream.Length
      if ($state.Offset -gt $length) {
        $state.Offset = 0L
        $state.Remainder = ""
      }
      $stream.Seek($state.Offset, [System.IO.SeekOrigin]::Begin) | Out-Null

      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
      try {
        $chunk = $reader.ReadToEnd()
      } finally {
        $reader.Dispose()
      }

      $state.Offset = $stream.Position
    } finally {
      $stream.Dispose()
    }
  } catch {
    Write-WatchLog "read failed for $path :: $($_.Exception.Message)"
    return
  }

  if ([string]::IsNullOrEmpty($chunk) -and [string]::IsNullOrEmpty($state.Remainder)) { return }

  $combined = $state.Remainder + $chunk
  $state.Remainder = ""
  $lines = $combined -split "`r?`n", -1
  if ($combined -notmatch "(`r`n|`n)$") {
    $state.Remainder = $lines[-1]
    if ($lines.Count -gt 1) {
      $lines = $lines[0..($lines.Count - 2)]
    } else {
      $lines = @()
    }
  }

  foreach ($line in $lines) {
    Handle-JsonLine -Path $path -Line $line
  }
}

function Scan-RecentSessions {
  if (-not (Test-Path $script:WatchRoot)) {
    Write-WatchLog "watch root missing: $script:WatchRoot"
    return
  }

  $cutoff = (Get-Date).AddHours(-1 * [Math]::Abs($RecentHours))
  $files = Get-ChildItem -Path $script:WatchRoot -Recurse -File -Filter "*.jsonl" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $cutoff } |
    Sort-Object LastWriteTime -Descending

  if ($MaxFiles -gt 0) {
    $files = @($files | Select-Object -First $MaxFiles)
  } else {
    $files = @($files)
  }

  foreach ($file in $files) {
    Process-SessionFile -File $file
  }
}

Write-WatchLog "codex-watch start poll=$PollSeconds recentHours=$RecentHours maxFiles=$MaxFiles runOnce=$RunOnce"

do {
  Scan-RecentSessions
  if ($RunOnce) { break }
  Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
} while ($true)
