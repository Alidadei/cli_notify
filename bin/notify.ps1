#requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Source = "Task",
  [string]$Title,
  [string]$Body,
  [string]$WebhookUrl = $env:WECOM_WEBHOOK,
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$PayloadArgs
)

function Read-EnvFile {
  param([string]$path)
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content -Path $path -ErrorAction SilentlyContinue) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    if ($t -match '^\s*export\s+') { $t = $t -replace '^\s*export\s+','' }
    if ($t -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
      $key = $Matches[1].Trim()
      $val = $Matches[2].Trim()
      if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
        if ($val.Length -ge 2) { $val = $val.Substring(1, $val.Length - 2) }
      }
      if ($key) { $map[$key] = $val }
    }
  }
  return $map
}

function Read-YamlFile {
  param([string]$path)
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content -Path $path -ErrorAction SilentlyContinue) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#") -or $t -eq "---") { continue }
    if ($t -match '^\s*([^:#]+?)\s*:\s*(.*?)\s*$') {
      $key = $Matches[1].Trim()
      $val = $Matches[2].Trim()
      if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
        if ($val.Length -ge 2) { $val = $val.Substring(1, $val.Length - 2) }
      }
      if ($key) { $map[$key] = $val }
    }
  }
  return $map
}

function Load-NotifyConfig {
  $paths = @()
  if ($env:NOTIFY_CONFIG_PATH) { $paths += $env:NOTIFY_CONFIG_PATH }
  $paths += (Join-Path $PSScriptRoot ".env")
  $paths += (Join-Path $PSScriptRoot "notify.yml")
  $paths += (Join-Path $PSScriptRoot "notify.yaml")
  foreach ($p in $paths) {
    if (-not (Test-Path $p)) { continue }
    $ext = [IO.Path]::GetExtension($p).ToLower()
    if ($ext -eq ".yml" -or $ext -eq ".yaml") { return (Read-YamlFile -path $p) }
    return (Read-EnvFile -path $p)
  }
  return @{}
}

function Get-NotifySetting {
  param([string]$name, $cfg)
  $v = [Environment]::GetEnvironmentVariable($name, "Process")
  if ($v) { return $v }
  if ($cfg -and $cfg.ContainsKey($name)) { return $cfg[$name] }
  try { return [Environment]::GetEnvironmentVariable($name, "User") } catch { return $null }
}

$notifyConfig = Load-NotifyConfig

# Global mute: env var or disable file
$mute = Get-NotifySetting -name "NOTIFY_MUTE" -cfg $notifyConfig
$flagAll = Join-Path $PSScriptRoot "notify.disabled"
if ((Test-Path $flagAll) -or ($mute -and $mute -ne "0")) { exit 0 }

# Channel toggles
$flagWin = Join-Path $PSScriptRoot "notify.windows.disabled"
$flagWecom = Join-Path $PSScriptRoot "notify.wecom.disabled"
$flagTg = Join-Path $PSScriptRoot "notify.telegram.disabled"
$flagDebug = Join-Path $PSScriptRoot "notify.debug.enabled"
$debugEnabled = Test-Path $flagDebug

# Log setup (keep only 1 day) if debug enabled
$logDir = Join-Path $env:LOCALAPPDATA "notify"
$logFile = Join-Path $logDir ("notify-" + (Get-Date -Format 'yyyyMMdd') + ".log")
$stateFile = Join-Path $logDir "session-map.json"
$tgMapFile = Join-Path $logDir "telegram-map.json"
if ($debugEnabled) {
  try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
  try {
    Get-ChildItem -Path $logDir -Filter "notify-*.log" -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).Date.AddDays(-1) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch {}
}

function Ensure-NotifyStateDir {
  try {
    if (-not (Test-Path -LiteralPath $logDir)) {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return $true
  } catch {
    return $false
  }
}

function Write-NotifyLog {
  param([string]$Channel, [string]$Status, [string]$Message)
  if (-not $debugEnabled) { return }
  try {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value "$ts [$Channel] $Status $Message"
  } catch {}
}

function Normalize-ProxyUrl {
  param([string]$proxy)
  if ([string]::IsNullOrWhiteSpace($proxy)) { return $null }
  $p = $proxy.Trim()
  if ($p -notmatch '://') {
    if ($p -match '^[^:]+:\d+$') { return ("http://" + $p) }
  }
  return $p
}

# Allow reading webhook from config/User env if not present
if (-not $WebhookUrl) { $WebhookUrl = Get-NotifySetting -name "WECOM_WEBHOOK" -cfg $notifyConfig }

# Telegram config from config/env
$tgToken = Get-NotifySetting -name "TELEGRAM_BOT_TOKEN" -cfg $notifyConfig
$tgChat = Get-NotifySetting -name "TELEGRAM_CHAT_ID" -cfg $notifyConfig
$tgProxy = Normalize-ProxyUrl (Get-NotifySetting -name "TELEGRAM_PROXY" -cfg $notifyConfig)

# Read stdin when invoked as a hook (e.g., Claude Code sends JSON)
$raw = ""
if ([Console]::IsInputRedirected) { $raw = [Console]::In.ReadToEnd() }

$payload = $null
$payloadJson = $null
if ($PayloadArgs -and $PayloadArgs.Count -gt 0) { $payloadJson = ($PayloadArgs -join " ") }
if (-not $payloadJson -and $raw) { $payloadJson = $raw }

function Try-ExtractJson {
  param([string]$s)
  if (-not $s) { return $null }
  $t = $s.Trim()
  if (($t.StartsWith('{') -and $t.EndsWith('}')) -or ($t.StartsWith('[') -and $t.EndsWith(']'))) { return $t }
  $i = $t.IndexOf('{')
  $j = $t.LastIndexOf('}')
  if ($i -ge 0 -and $j -gt $i) { return $t.Substring($i, $j - $i + 1) }
  return $null
}

if ($payloadJson) {
  $extracted = Try-ExtractJson $payloadJson
  if ($extracted) { $payloadJson = $extracted }
}

# Sometimes Codex passes JSON as the first unnamed argument (bound to Title/Body)
if (-not $payloadJson -and $Title) {
  $extracted = Try-ExtractJson $Title
  if ($extracted) { $payloadJson = $extracted; $Title = $null }
}
if (-not $payloadJson -and $Body) {
  $extracted = Try-ExtractJson $Body
  if ($extracted) { $payloadJson = $extracted; $Body = $null }
}

if ($payloadJson) {
  try { $payload = $payloadJson | ConvertFrom-Json } catch {
    try {
      $extracted = Try-ExtractJson $payloadJson
      if ($extracted) { $payload = $extracted | ConvertFrom-Json }
    } catch {}
  }
}

function Get-TranscriptPath {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("transcript_path","transcriptPath")) {
    if ($p.$k) { return [string]$p.$k }
  }
  return $null
}

function Get-TranscriptToolUseIds {
  param($content, [string]$toolName)
  $ids = @()
  foreach ($block in @($content)) {
    if (-not $block) { continue }
    if ($block.type -ne "tool_use") { continue }
    if ($toolName -and [string]$block.name -ne $toolName) { continue }
    if ($block.id) { $ids += [string]$block.id }
  }
  return $ids
}

function Get-TranscriptToolResultIds {
  param($content)
  $ids = @()
  foreach ($block in @($content)) {
    if (-not $block) { continue }
    if ($block.type -ne "tool_result") { continue }
    if ($block.tool_use_id) { $ids += [string]$block.tool_use_id }
  }
  return $ids
}

function Test-TranscriptHasPendingAskUserQuestion {
  param([string]$TranscriptPath)
  if ([string]::IsNullOrWhiteSpace($TranscriptPath)) { return $false }
  if (-not (Test-Path -LiteralPath $TranscriptPath)) { return $false }

  try {
    $lines = @(Get-Content -LiteralPath $TranscriptPath -Tail 400 -ErrorAction Stop)
  } catch {
    return $false
  }

  if ($lines.Count -eq 0) { return $false }

  $pending = @{}
  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $item = $null
    try { $item = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    if (-not $item -or -not $item.message -or -not $item.message.content) { continue }

    $role = [string]$item.message.role
    if ($role -eq "assistant") {
      foreach ($toolUseId in @(Get-TranscriptToolUseIds -content $item.message.content -toolName "AskUserQuestion")) {
        if ($toolUseId) { $pending[$toolUseId] = $true }
      }
      continue
    }

    if ($role -eq "user") {
      foreach ($toolResultId in @(Get-TranscriptToolResultIds -content $item.message.content)) {
        if ($toolResultId -and $pending.ContainsKey($toolResultId)) {
          [void]$pending.Remove($toolResultId)
        }
      }
    }
  }

  return ($pending.Count -gt 0)
}

function Test-ShouldSuppressNotification {
  param($p)
  if (-not $p) { return $false }

  $hookEventName = Get-HookEventName -p $p
  if ($hookEventName -ne "Notification") { return $false }

  $transcriptPath = Get-TranscriptPath -p $p
  if (Test-TranscriptHasPendingAskUserQuestion -TranscriptPath $transcriptPath) { return $true }

  $sessionId = Get-SessionId -p $p
  if (-not (Test-SessionHasRecentAskUserQuestion -sessionId $sessionId)) { return $false }
  return (Test-NotificationLooksLikeAskFollowUp -p $p)
}

function Get-TextFromContent {
  param($c)
  if (-not $c) { return $null }
  if ($c -is [string]) { return $c }
  if ($c.text) { return $c.text }
  if ($c.value) { return $c.value }
  if ($c.content) { return (Get-TextFromContent -c $c.content) }
  if ($c -is [System.Collections.IEnumerable]) {
    $parts = @()
    foreach ($x in $c) {
      $t = Get-TextFromContent -c $x
      if ($t) { $parts += $t }
    }
    if ($parts.Count -gt 0) { return ($parts -join " ") }
  }
  return $null
}

function Get-LastAssistantText {
  param($p)
  if (-not $p) { return $null }

  # direct fields
  if ($p.'last-assistant-message') { return $p.'last-assistant-message' }
  if ($p.output_text) { return $p.output_text }

  $containers = @()
  if ($p.messages -is [System.Collections.IEnumerable]) { $containers += ,$p.messages }
  if ($p.output -is [System.Collections.IEnumerable]) { $containers += ,$p.output }
  if ($p.items -is [System.Collections.IEnumerable]) { $containers += ,$p.items }
  if ($p.events -is [System.Collections.IEnumerable]) { $containers += ,$p.events }
  if ($p.turns -is [System.Collections.IEnumerable]) { $containers += ,$p.turns }
  if ($p.data -and $p.data.messages -is [System.Collections.IEnumerable]) { $containers += ,$p.data.messages }
  if ($p.response -and $p.response.output -is [System.Collections.IEnumerable]) { $containers += ,$p.response.output }

  foreach ($arr in $containers) {
    try { $list = @($arr) } catch { continue }
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
      $m = $list[$i]
      if (-not $m) { continue }
      $role = $null
      if ($m.role) { $role = $m.role }
      elseif ($m.author) { $role = $m.author }
      elseif ($m.type -and $m.type -eq 'assistant') { $role = 'assistant' }
      if ($role -ne 'assistant') { continue }

      $content = $null
      if ($m.content) { $content = $m.content }
      elseif ($m.message) { $content = $m.message }
      elseif ($m.text) { $content = $m.text }
      elseif ($m.output_text) { $content = $m.output_text }

      $txt = Get-TextFromContent -c $content
      if ($txt) { return $txt }
    }
  }

  return $null
}

function Get-SessionId {
  param($p)
  if (-not $p) { return "unknown" }
  foreach ($k in @("session_id","session-id","thread_id","thread-id","conversation_id","conversation-id","session")) {
    if ($p.$k) { return $p.$k }
  }
  return "unknown"
}

function Get-ProjectPath {
  param($p)
  if ($p) {
    foreach ($k in @("cwd","workdir","working_dir","project_dir","project_path","repo_root","project_root","workspace","path")) {
      if ($p.$k) { return $p.$k }
    }
  }
  if ($env:CODEX_WORKDIR) { return $env:CODEX_WORKDIR }
  try { return (Get-Location).Path } catch { return "unknown" }
}

function Get-HookEventName {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("hook_event_name","hookEventName","event_name","eventName")) {
    if ($p.$k) { return [string]$p.$k }
  }
  return $null
}

function Get-NotificationTitle {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("title","notification_title","notificationTitle")) {
    if ($p.$k) { return [string]$p.$k }
  }
  return $null
}

function Get-NotificationMessage {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("message","body","notification_message","notificationMessage")) {
    if ($p.$k) { return [string]$p.$k }
  }
  return $null
}

function Get-NotificationType {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("notification_type","notificationType")) {
    if ($p.$k) { return [string]$p.$k }
  }
  return $null
}

function Get-ToolName {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("tool_name","toolName","name")) {
    if ($p.$k) { return [string]$p.$k }
  }
  return $null
}

function Get-ToolInput {
  param($p)
  if (-not $p) { return $null }
  foreach ($k in @("tool_input","toolInput","input")) {
    if ($p.$k) { return $p.$k }
  }
  return $null
}

function Get-AskUserQuestionItems {
  param($p)
  if ((Get-ToolName -p $p) -ne "AskUserQuestion") { return @() }
  $toolInput = Get-ToolInput -p $p
  if (-not $toolInput -or -not $toolInput.questions) { return @() }
  try { return @($toolInput.questions) } catch { return @() }
}

function Get-AskUserQuestionSnippet {
  param($p)
  $questions = Get-AskUserQuestionItems -p $p
  if ($questions.Count -eq 0) { return $null }

  $parts = @()
  foreach ($q in $questions) {
    if (-not $q) { continue }
    $line = $null
    if ($q.question) { $line = ([string]$q.question).Trim() }
    elseif ($q.header) { $line = ([string]$q.header).Trim() }
    if (-not $line) { continue }

    $options = @()
    foreach ($opt in @($q.options)) {
      if (-not $opt) { continue }
      $optLabel = $null
      if ($opt -is [string]) { $optLabel = $opt }
      elseif ($opt.label) { $optLabel = [string]$opt.label }
      if ($optLabel) { $options += $optLabel.Trim() }
    }
    if ($options.Count -gt 0) { $line += " [" + ($options -join "/") + "]" }
    if ($q.multiSelect -eq $true) { $line += " (可多选)" }
    $parts += $line
  }

  if ($parts.Count -eq 0) { return $null }
  return ($parts -join " ; ")
}

function Get-AskUserQuestionLines {
  param($p)
  $questions = Get-AskUserQuestionItems -p $p
  if ($questions.Count -eq 0) { return @() }

  $lines = @()
  for ($i = 0; $i -lt $questions.Count; $i++) {
    $q = $questions[$i]
    if (-not $q) { continue }
    $prefix = if ($q.header) { ([string]$q.header).Trim() } else { "问题" + ($i + 1) }
    if ($q.question) { $lines += ($prefix + ": " + ([string]$q.question).Trim()) }
    else { $lines += $prefix }

    $options = @()
    foreach ($opt in @($q.options)) {
      if (-not $opt) { continue }
      $optLabel = $null
      if ($opt -is [string]) { $optLabel = $opt }
      elseif ($opt.label) { $optLabel = [string]$opt.label }
      if ($optLabel) { $options += $optLabel.Trim() }
    }
    if ($options.Count -gt 0) { $lines += ("选项: " + ($options -join " / ")) }
    if ($q.multiSelect -eq $true) { $lines += "可多选: 是" }
  }

  return $lines
}

function Get-HostName {
  param($p)
  if ($p) {
    foreach ($k in @("host_name","hostName","host_label","hostLabel","host_alias","hostAlias","host_remark","hostRemark")) {
      if ($p.$k) { return $p.$k }
    }
    foreach ($k in @("host","hostname","machine","node","computer")) {
      if ($p.$k) { return $p.$k }
    }
  }
  return $null
}

function Get-HostRaw {
  param($p)
  if ($p) {
    foreach ($k in @("host","hostname","machine","node","computer")) {
      if ($p.$k) { return $p.$k }
    }
  }
  return $null
}

function Normalize-Reply {
  param([string]$text, [int]$max)
  if (-not $text) { return "(无内容)" }
  $t = $text.Trim()
  if ($max -le 0) { return $t }
  $oneLine = ($t -replace '\s+', ' ').Trim()
  if ($oneLine.Length -gt $max) { return $oneLine.Substring(0,$max) + "..." }
  return $oneLine
}

# --- Win32 window focus helpers (for toast click-to-focus) ---
$script:toastActivated = $false
$script:toastWaitScript = Join-Path $PSScriptRoot "notify-toast-wait.ps1"

function Load-SessionMap {
  if (Test-Path $stateFile) {
    try { $state = (Get-Content -Path $stateFile -Raw) | ConvertFrom-Json } catch {}
  }
  if (-not $state) { $state = [pscustomobject]@{} }
  if (-not $state.sessions) { $state | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{}) }
  if (-not $state.codex) { $state | Add-Member -MemberType NoteProperty -Name codex -Value ([pscustomobject]@{}) }
  if (-not $state.claude) { $state | Add-Member -MemberType NoteProperty -Name claude -Value ([pscustomobject]@{}) }
  return $state
}

function Save-SessionMap {
  param($state)
  if (-not $state) { return }
  if (-not (Ensure-NotifyStateDir)) { return }
  try { $state | ConvertTo-Json -Depth 8 | Set-Content -Path $stateFile -Encoding UTF8 } catch {}
}

function Get-SessionMapEntry {
  param($state, [string]$sessionId)
  if (-not $state -or -not $sessionId -or $sessionId -eq "unknown") { return $null }
  try {
    $prop = $state.sessions.PSObject.Properties[$sessionId]
    if ($prop) { return $prop.Value }
  } catch {}
  return $null
}

function Update-SessionMap {
  param([string]$sessionId, [string]$projectPath, [string]$source, [string]$time)
  if (-not $sessionId -or $sessionId -eq "unknown") { return }
  try {
    $state = Load-SessionMap
    $existing = Get-SessionMapEntry -state $state -sessionId $sessionId
    $pendingAskTime = $null
    if ($existing -and $existing.pendingAskTime) { $pendingAskTime = [string]$existing.pendingAskTime }

    $entry = [pscustomobject]@{ cwd = $projectPath; source = $source; time = $time; pendingAskTime = $pendingAskTime }
    $state.sessions | Add-Member -MemberType NoteProperty -Name $sessionId -Value $entry -Force

    if ($source -match 'Codex') { $state.codex = $entry }
    elseif ($source -match 'Claude') { $state.claude = $entry }

    # keep only last 50 sessions
    $entries = @()
    foreach ($p in $state.sessions.PSObject.Properties) {
      $entries += [pscustomobject]@{ Name = $p.Name; Time = $p.Value.time }
    }
    $entries = $entries | Sort-Object Time -Descending
    if ($entries.Count -gt 50) {
      $entries | Select-Object -Skip 50 | ForEach-Object {
        $state.sessions.PSObject.Properties.Remove($_.Name)
      }
    }

    Save-SessionMap -state $state
  } catch {}
}

function Set-SessionAskUserQuestionState {
  param(
    [string]$sessionId,
    [bool]$Pending,
    [string]$time
  )
  if (-not $sessionId -or $sessionId -eq "unknown") { return }
  try {
    $state = Load-SessionMap
    $existing = Get-SessionMapEntry -state $state -sessionId $sessionId
    $entry = if ($existing) {
      [pscustomobject]@{
        cwd = $existing.cwd
        source = $existing.source
        time = $(if ($time) { $time } elseif ($existing.time) { [string]$existing.time } else { $null })
        pendingAskTime = $(if ($Pending) { $time } else { $null })
      }
    } else {
      [pscustomobject]@{
        cwd = $null
        source = $null
        time = $time
        pendingAskTime = $(if ($Pending) { $time } else { $null })
      }
    }
    $state.sessions | Add-Member -MemberType NoteProperty -Name $sessionId -Value $entry -Force
    if ($entry.source -match 'Codex') { $state.codex = $entry }
    elseif ($entry.source -match 'Claude') { $state.claude = $entry }
    Save-SessionMap -state $state
  } catch {}
}

function Test-SessionHasRecentAskUserQuestion {
  param(
    [string]$sessionId,
    [int]$MaxAgeSeconds = 180
  )
  if (-not $sessionId -or $sessionId -eq "unknown") { return $false }
  try {
    $state = Load-SessionMap
    $entry = Get-SessionMapEntry -state $state -sessionId $sessionId
    if (-not $entry -or -not $entry.pendingAskTime) { return $false }
    $pendingTime = [datetime]::Parse([string]$entry.pendingAskTime)
    return (((Get-Date) - $pendingTime).TotalSeconds -le $MaxAgeSeconds)
  } catch {
    return $false
  }
}

function Test-NotificationLooksLikeAskFollowUp {
  param($p)
  if (-not $p) { return $false }

  $notificationType = [string](Get-NotificationType -p $p)
  if ($notificationType -match '^elicitation_') { return $true }

  $parts = @()
  foreach ($value in @((Get-NotificationTitle -p $p), (Get-NotificationMessage -p $p))) {
    if ($value) { $parts += ([string]$value).ToLowerInvariant() }
  }
  if ($parts.Count -eq 0) { return $false }

  $text = $parts -join " "
  return ($text -match 'waiting.+(response|reply|input|answer)' -or
          $text -match 'awaiting.+(response|reply|input|answer)' -or
          $text -match 'need.+(response|reply|input|answer)' -or
          $text -match 'requires?.+(response|reply|input|answer)' -or
          $text -match '等待.*(回复|回覆|回答|输入)' -or
          $text -match '需要.*(回复|回覆|回答|输入)')
}

function Load-TelegramMap {
  if (Test-Path $tgMapFile) {
    try { return (Get-Content -Path $tgMapFile -Raw) | ConvertFrom-Json } catch {}
  }
  $state = [pscustomobject]@{}
  $state | Add-Member -MemberType NoteProperty -Name messages -Value ([pscustomobject]@{})
  $state | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{})
  return $state
}

function Save-TelegramMap {
  param($state)
  if (-not (Ensure-NotifyStateDir)) { return }
  try { $state | ConvertTo-Json -Depth 8 | Set-Content -Path $tgMapFile -Encoding UTF8 } catch {}
}

function Get-TelegramThreadId {
  param([string]$sessionId)
  if (-not $sessionId) { return $null }
  if (-not (Test-Path $tgMapFile)) { return $null }
  try {
    $state = (Get-Content -Path $tgMapFile -Raw) | ConvertFrom-Json
    if (-not $state -or -not $state.sessions) { return $null }
    $prop = $state.sessions.PSObject.Properties[$sessionId]
    if ($prop -and $prop.Value.thread_id) { return $prop.Value.thread_id }
  } catch {}
  return $null
}

function Update-TelegramMap {
  param(
    [string]$sessionId,
    [string]$source,
    [string]$cwd,
    [string]$hostRaw,
    [string]$hostName,
    [string]$messageId,
    [string]$time
  )
  if (-not $sessionId -or -not $messageId) { return }
  $state = Load-TelegramMap
  if (-not $state.messages) { $state | Add-Member -MemberType NoteProperty -Name messages -Value ([pscustomobject]@{}) -Force }
  if (-not $state.sessions) { $state | Add-Member -MemberType NoteProperty -Name sessions -Value ([pscustomobject]@{}) -Force }

  $entry = [pscustomobject]@{ session_id = $sessionId; source = $source; cwd = $cwd; host = $hostRaw; host_name = $hostName; time = $time }
  $state.messages | Add-Member -MemberType NoteProperty -Name $messageId -Value $entry -Force

  $threadId = $null
  try {
    $existing = $state.sessions.PSObject.Properties[$sessionId]
    if ($existing -and $existing.Value.thread_id) { $threadId = $existing.Value.thread_id }
  } catch {}
  $sentry = [pscustomobject]@{
    latest_message_id = $messageId
    source = $source
    cwd = $cwd
    host = $hostRaw
    host_name = $hostName
    time = $time
    thread_id = $threadId
  }
  $state.sessions | Add-Member -MemberType NoteProperty -Name $sessionId -Value $sentry -Force

  # keep only last 200 messages
  try {
    $entries = @()
    foreach ($p in $state.messages.PSObject.Properties) {
      $entries += [pscustomobject]@{ Name = $p.Name; Time = $p.Value.time }
    }
    $entries = $entries | Sort-Object Time -Descending
    if ($entries.Count -gt 200) {
      $entries | Select-Object -Skip 200 | ForEach-Object {
        $state.messages.PSObject.Properties.Remove($_.Name)
      }
    }
  } catch {}

  Save-TelegramMap -state $state
}

if (Test-ShouldSuppressNotification -p $payload) {
  Write-NotifyLog -Channel "invoke" -Status "skip" -Message "suppressed duplicate AskUserQuestion notification"
  exit 0
}

$sessionId = Get-SessionId -p $payload
$projectPath = Get-ProjectPath -p $payload
$endTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Update-SessionMap -sessionId $sessionId -projectPath $projectPath -source $Source -time $endTime
$hookEventName = Get-HookEventName -p $payload
$notificationType = Get-NotificationType -p $payload
$notificationMessage = Get-NotificationMessage -p $payload
$toolName = Get-ToolName -p $payload
$isAskUserQuestion = ($hookEventName -eq "PreToolUse" -and $toolName -eq "AskUserQuestion")
$askUserQuestionLines = @()
if ($isAskUserQuestion) { $askUserQuestionLines = Get-AskUserQuestionLines -p $payload }
if ($isAskUserQuestion) {
  Set-SessionAskUserQuestionState -sessionId $sessionId -Pending $true -time $endTime
} elseif ($hookEventName -eq "Stop") {
  Set-SessionAskUserQuestionState -sessionId $sessionId -Pending $false -time $endTime
}

$maxReply = 0  # 0 = no truncation
try {
  $v = Get-NotifySetting -name "NOTIFY_MAX_REPLY" -cfg $notifyConfig
  if ($v) { $maxReply = [int]$v }
} catch {}

$rawSnippet = $null
if ($isAskUserQuestion) {
  $rawSnippet = Get-AskUserQuestionSnippet -p $payload
} elseif ($hookEventName -eq "Notification") {
  $rawSnippet = $notificationMessage
} else {
  $rawSnippet = Get-LastAssistantText -p $payload
}
$snippet = Normalize-Reply -text $rawSnippet -max $maxReply

# If no meaningful reply, use project name as brief status (zero overhead)
if (-not $snippet -or $snippet -eq "(无内容)") {
  if ($isAskUserQuestion) {
    if ($Source -match 'Claude') { $snippet = "Claude 正在等待你的回答" }
    elseif ($Source) { $snippet = "$Source 正在等待你的回答" }
    else { $snippet = "等待你的回答" }
  } else {
    $pName = if ($projectPath) { Split-Path -Leaf $projectPath } else { $null }
    $snippet = if ($pName) { "$pName 已完成" } else { "任务已完成" }
  }
}

if ($payload) {
  if ($isAskUserQuestion) {
    if ($Source -match 'Claude') { $Title = "Claude 正在提问" }
    elseif ($Source -match 'Codex') { $Title = "Codex 正在提问" }
    elseif (-not $Title) { $Title = "$Source 正在提问" }
  } elseif ($hookEventName -eq "Notification") {
    $payloadTitle = Get-NotificationTitle -p $payload
    if ($payloadTitle) { $Title = $payloadTitle }
    elseif ($Source -match 'Claude') { $Title = "Claude 需要你的处理" }
    elseif ($Source -match 'Codex') { $Title = "Codex 需要你的处理" }
    elseif (-not $Title) { $Title = "$Source 需要你的处理" }
  } else {
    if ($Source -match 'Codex') { $Title = "Codex 已回复" }
    elseif ($Source -match 'Claude') { $Title = "Claude 已回复" }
    elseif (-not $Title) { $Title = "$Source 已回复" }
  }
} else {
  if (-not $Title -or $Title -match '^\s*[{[]' -or $Title -match '"type"\s*:') {
    if ($Source -match 'Codex') { $Title = "Codex 已回复" }
    elseif ($Source -match 'Claude') { $Title = "Claude 已回复" }
    else { $Title = "$Source 已回复" }
  }
}

# Only push host (optional) + session id + project path + end time + last reply
$hostRaw = Get-HostRaw -p $payload
$hostLabel = Get-HostName -p $payload
if (-not $hostRaw) {
  $hostRaw = Get-NotifySetting -name "NOTIFY_HOST" -cfg $notifyConfig
  if (-not $hostRaw -and $env:COMPUTERNAME) { $hostRaw = $env:COMPUTERNAME }
}
if (-not $hostLabel) {
  $hostLabel = Get-NotifySetting -name "NOTIFY_HOST_NAME" -cfg $notifyConfig
}
$hostName = $hostLabel
if (-not $hostName) { $hostName = $hostRaw }
$hostLine = $null
if ($hostName) { $hostLine = "主机: $hostName" }

$bodyLines = @()
if ($isAskUserQuestion) {
  if ($hostLine) { $bodyLines += $hostLine }
  $bodyLines += "会话ID: $sessionId"
  $bodyLines += "项目: $projectPath"
  $bodyLines += "时间: $endTime"
  foreach ($line in $askUserQuestionLines) {
    if ($line) { $bodyLines += $line }
  }
  if ($askUserQuestionLines.Count -eq 0 -and $snippet) { $bodyLines += ("提示: " + $snippet) }
} elseif ($hookEventName -eq "Notification") {
  if ($hostLine) { $bodyLines += $hostLine }
  $bodyLines += "会话ID: $sessionId"
  $bodyLines += "项目: $projectPath"
  $bodyLines += "时间: $endTime"
  if ($notificationType) { $bodyLines += "类型: $notificationType" }
  if ($notificationMessage) { $bodyLines += ("提示: " + $notificationMessage.Trim()) }
  if ($bodyLines.Count -eq 0 -and $snippet) { $bodyLines += $snippet }
} else {
  if ($hostLine) { $bodyLines += $hostLine }
  $bodyLines += "会话ID: $sessionId"
  $bodyLines += "项目: $projectPath"
  $bodyLines += "结束: $endTime"

  # Only include reply content if it's meaningful (not "(无内容)")
  if ($snippet -and $snippet -ne "(无内容)") {
    $bodyLines += "回复: $snippet"
  }

  # If no meaningful content, add a brief status instead
  if (-not $snippet -or $snippet -eq "(无内容)") {
    $projectName = Split-Path -Leaf $projectPath
    if ($projectName) {
      $bodyLines += "状态: $projectName 已完成"
    } else {
      $bodyLines += "状态: 任务已完成"
    }
  }
}

$Body = $bodyLines -join "`n"
$channelText = if ($Title) { $Title + "`n" + $Body } else { $Body }

Write-NotifyLog -Channel "invoke" -Status "ok" -Message "$Source"

# Windows toast
if (Test-Path $flagWin) {
  Write-NotifyLog -Channel "windows" -Status "skip" -Message "disabled"
} else {
  try {
    if (Get-Module -ListAvailable -Name BurntToast) {
      Import-Module BurntToast -ErrorAction Stop
      $cmd = Get-Command -Name New-BurntToastNotification -ErrorAction Stop
      $params = $cmd.Parameters.Keys

      if ($params -contains 'ActivatedAction' -and (Test-Path $script:toastWaitScript)) {
        # Show toast via background process that handles click-to-focus
        $script:toastActivated = $true
        # Walk process tree to find the cmd.exe ancestor window (deterministic, no guessing)
        $consoleWnd = "0"
        try {
          $walkPid = $PID
          for ($depth = 0; $depth -lt 10; $depth++) {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$walkPid" -ErrorAction SilentlyContinue
            if (-not $cim) { break }
            $ppid = $cim.ParentProcessId
            if (-not $ppid -or $ppid -eq $walkPid) { break }
            $pp = Get-Process -Id $ppid -ErrorAction SilentlyContinue
            if ($pp -and $pp.ProcessName -eq 'cmd' -and $pp.MainWindowHandle -ne [IntPtr]::Zero) {
              $consoleWnd = $pp.MainWindowHandle.ToString()
              break
            }
            $walkPid = $ppid
          }
        } catch {}
        $vbsPath = Join-Path $PSScriptRoot "notify-toast-wait.vbs"
        Write-NotifyLog -Channel "debug" -Status "info" -Message "Title='$Title' SnippetLength=$($snippet.Length) hWnd=$consoleWnd"
        if (Test-Path $vbsPath) {
          Start-Process wscript -ArgumentList "`"$vbsPath`"", "`"$Title`"", "`"$snippet`"", "`"$consoleWnd`"" -WindowStyle Hidden
        } else {
          $psArgs = "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File `"$($script:toastWaitScript)`"", "-Title `"$Title`"", "-Body `"$snippet`"", "-hWndParam `"$consoleWnd`""
          Start-Process powershell -ArgumentList $psArgs -WindowStyle Hidden
        }
      } else {
        New-BurntToastNotification -Text $Title, $Body | Out-Null
      }
      Write-NotifyLog -Channel "windows" -Status "ok" -Message $Title
    } else {
      function Send-NativeToast {
        param([string]$Title, [string]$Body)
        try {
          [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
          $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
          $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)
          $nodes = $xml.GetElementsByTagName("text")
          if ($nodes.Count -ge 1) { $nodes.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null }
          if ($nodes.Count -ge 2) { $nodes.Item(1).AppendChild($xml.CreateTextNode($Body)) | Out-Null }
          $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
          $toast.ExpirationTime = (Get-Date).AddSeconds(30)
          $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Windows PowerShell")
          $notifier.Show($toast)
          return $true
        } catch {
          return $false
        }
      }

      if (Send-NativeToast -Title $Title -Body $Body) {
        Write-NotifyLog -Channel "windows" -Status "ok" -Message $Title
      } else {
        Write-NotifyLog -Channel "windows" -Status "skip" -Message "BurntToast not installed"
      }
    }
  } catch {
    Write-NotifyLog -Channel "windows" -Status "fail" -Message $_.Exception.Message
  }
}

# WeCom Markdown
if (Test-Path $flagWecom) {
  Write-NotifyLog -Channel "wecom" -Status "skip" -Message "disabled"
} else {
  if ($WebhookUrl) {
    $content = $channelText
    $payloadOut = @{ msgtype = "markdown"; markdown = @{ content = $content } } | ConvertTo-Json -Depth 5
    try {
      Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json; charset=utf-8' -Body $payloadOut | Out-Null
      Write-NotifyLog -Channel "wecom" -Status "ok" -Message $Title
    } catch {
      Write-NotifyLog -Channel "wecom" -Status "fail" -Message $_.Exception.Message
    }
  } else {
    Write-NotifyLog -Channel "wecom" -Status "skip" -Message "Webhook not set"
  }
}

# Telegram
if (Test-Path $flagTg) {
  Write-NotifyLog -Channel "telegram" -Status "skip" -Message "disabled"
} else {
  if ($tgToken -and $tgChat) {
    $tgText = $channelText
    $tgUri = "https://api.telegram.org/bot$tgToken/sendMessage"
    $tgThreadId = Get-TelegramThreadId -sessionId $sessionId

    function Send-TgChunk {
      param([string]$text)
      $tgPayload = @{ chat_id = $tgChat; text = $text }
      if ($tgThreadId) {
        try { $tgPayload.message_thread_id = [int]$tgThreadId } catch {}
      }
      $tgPayload = $tgPayload | ConvertTo-Json
      $irmArgs = @{ Method = 'Post'; Uri = $tgUri; ContentType = 'application/json; charset=utf-8'; Body = $tgPayload }
      if ($tgProxy) { $irmArgs.Proxy = $tgProxy }
      $resp = Invoke-RestMethod @irmArgs
      try {
        if ($resp -and $resp.result -and $resp.result.message_id) { return [string]$resp.result.message_id }
      } catch {}
      return $null
    }

    try {
      $maxLen = 3500
      if ($tgText.Length -le $maxLen) {
        $mid = Send-TgChunk -text $tgText
        if ($mid) { Update-TelegramMap -sessionId $sessionId -source $Source -cwd $projectPath -hostRaw $hostRaw -hostName $hostName -messageId $mid -time $endTime }
      } else {
        for ($i = 0; $i -lt $tgText.Length; $i += $maxLen) {
          $len = [Math]::Min($maxLen, $tgText.Length - $i)
          $part = $tgText.Substring($i, $len)
          $mid = Send-TgChunk -text $part
          if ($mid) { Update-TelegramMap -sessionId $sessionId -source $Source -cwd $projectPath -hostRaw $hostRaw -hostName $hostName -messageId $mid -time $endTime }
        }
      }
      Write-NotifyLog -Channel "telegram" -Status "ok" -Message $Title
    } catch {
      Write-NotifyLog -Channel "telegram" -Status "fail" -Message $_.Exception.Message
    }
  } else {
    Write-NotifyLog -Channel "telegram" -Status "skip" -Message "Token or chat id not set"
  }
}
