param([string]$Title = "Claude", [string]$Body = "Click to focus", [int]$Timeout = 30, [string]$hWndParam = "", [string]$WinTitle = "")
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pinvoke = @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@
Add-Type -Namespace Win32 -Name WF -ErrorAction SilentlyContinue -MemberDefinition $pinvoke

# Win32 helper: EnumWindows to see ALL windows (Get-Process only returns ONE per PID)
$terminalFinderDef = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class TerminalWindowFinder {
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWinProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    private delegate bool EnumWinProc(IntPtr hWnd, IntPtr lParam);

    [ThreadStatic]
    private static List<IntPtr> _found;
    [ThreadStatic]
    private static int _targetPid;

    private static bool Callback(IntPtr hWnd, IntPtr lParam) {
        if (!IsWindowVisible(hWnd)) return true;
        uint pid;
        GetWindowThreadProcessId(hWnd, out pid);
        if ((int)pid == _targetPid) _found.Add(hWnd);
        return true;
    }

    public static IntPtr[] GetWindowsForPid(int pid) {
        _found = new List<IntPtr>();
        _targetPid = pid;
        EnumWindows(Callback, IntPtr.Zero);
        return _found.ToArray();
    }

    public static string GetWindowTitle(IntPtr hWnd) {
        var sb = new StringBuilder(512);
        GetWindowText(hWnd, sb, 512);
        return sb.ToString();
    }
}
'@
Add-Type -TypeDefinition $terminalFinderDef -ErrorAction SilentlyContinue

function Find-TerminalWindow {
  # Use EnumWindows to see ALL visible terminal windows (not just one from Get-Process)
  try {
    $allWins = @()
    $wtPids = @(Get-Process -Name WindowsTerminal, wt -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Id } | Select-Object -Unique)
    foreach ($wtPid in $wtPids) {
      $wins = [TerminalWindowFinder]::GetWindowsForPid($wtPid)
      foreach ($w in $wins) {
        $title = [TerminalWindowFinder]::GetWindowTitle($w)
        if ($title) { $allWins += @{ hWnd = $w; Title = $title } }
      }
    }
    if ($allWins.Count -eq 0) { return [IntPtr]::Zero }
    if ($allWins.Count -eq 1) { return $allWins[0].hWnd }
    # Prefer foreground if it's a terminal
    $fgWnd = [Win32.WF]::GetForegroundWindow()
    $fgMatch = $allWins | Where-Object { $_.hWnd -eq $fgWnd } | Select-Object -First 1
    if ($fgMatch) { return $fgMatch.hWnd }
    return $allWins[0].hWnd
  } catch {}
  return [IntPtr]::Zero
}

function Focus-Window {
  param([IntPtr]$hWnd)
  if ($hWnd -eq [IntPtr]::Zero) { return }
  try {
    $fgWnd = [Win32.WF]::GetForegroundWindow()
    $logPath = Join-Path $env:LOCALAPPDATA "notify\click-focus.log"
    $ts = Get-Date -Format 'HH:mm:ss'
    # Get foreground window info for diagnostics
    $fgTitle = ''
    $fgProc = ''
    try {
      $fgTitle = [TerminalWindowFinder]::GetWindowTitle($fgWnd)
      $fgProcObj = Get-Process | Where-Object { $_.MainWindowHandle -eq $fgWnd } | Select-Object -First 1
      if ($fgProcObj) { $fgProc = "$($fgProcObj.ProcessName)($($fgProcObj.Id))" }
    } catch {}
    if ($fgWnd -eq $hWnd) {
      Add-Content -Path $logPath -Value "$ts FOCUS: already foreground (target=$hWnd)"
      [Win32.WF]::ShowWindow($hWnd, 9) | Out-Null
      return
    }
    # Alt key trick: simulates user input to grant foreground permission
    [Win32.WF]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 10
    [Win32.WF]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 10
    # Minimize then restore to force Windows to redraw and move Z-order
    [Win32.WF]::ShowWindow($hWnd, 6) | Out-Null
    Start-Sleep -Milliseconds 50
    [Win32.WF]::ShowWindow($hWnd, 9) | Out-Null
    Start-Sleep -Milliseconds 50
    # Multi-pronged focus attack
    [Win32.WF]::BringWindowToTop($hWnd) | Out-Null
    $r1 = [Win32.WF]::SetForegroundWindow($hWnd)
    [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
    Start-Sleep -Milliseconds 50
    [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
    [Win32.WF]::SwitchToThisWindow($hWnd, $true)
    # Verify: what's foreground now?
    $fgAfter = [Win32.WF]::GetForegroundWindow()
    $fgAfterTitle = ''
    try { $fgAfterTitle = [TerminalWindowFinder]::GetWindowTitle($fgAfter) } catch {}
    Add-Content -Path $logPath -Value "$ts FOCUS: SetFW=$r1 from(fg=$fgWnd $fgProc '$fgTitle') to(target=$hWnd) after(fg=$fgAfter '$fgAfterTitle')"
  } catch {
    Add-Content -Path $logPath -Value "$ts FOCUS ERROR: $($_.Exception.Message)"
  }
}

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Visible = $true
$icon.Text = "Claude"

$script:clicked = $false
$script:form = $null

$icon.Add_BalloonTipClicked({
    $script:clicked = $true
    # Refresh debounce timer on click
    try {
      $debounceDir = Join-Path $env:LOCALAPPDATA "notify"
      if (-not (Test-Path $debounceDir)) { New-Item -ItemType Directory -Path $debounceDir -Force | Out-Null }
      $debounceFile = Join-Path $debounceDir "last-toast.json"
      @{ time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json | Set-Content -Path $debounceFile -Encoding UTF8
    } catch {}
    # Find target window: prefer exact hWnd (unique), then title, then live search
    $hWnd = [IntPtr]::Zero
    # 1st: Try the EXACT hWnd captured at notification time (most precise)
    if ($hWndParam -and $hWndParam -ne "0") {
      try {
        $candidate = [IntPtr]([long]$hWndParam)
        # Verify via EnumWindows that this hWnd still exists and is a visible WT window
        $stillValid = $false
        $wtPids = @(Get-Process -Name WindowsTerminal, wt -ErrorAction SilentlyContinue |
          ForEach-Object { $_.Id } | Select-Object -Unique)
        foreach ($wp in $wtPids) {
          if ([TerminalWindowFinder]::GetWindowsForPid($wp) -contains $candidate) { $stillValid = $true; break }
        }
        if ($stillValid) { $hWnd = $candidate }
      } catch {}
    }
    # 2nd: Fall back to title match (via EnumWindows — sees all windows)
    if (($hWnd -eq [IntPtr]::Zero) -and $WinTitle -and $WinTitle -ne "") {
      try {
        $wtPids = @(Get-Process -Name WindowsTerminal, wt -ErrorAction SilentlyContinue |
          ForEach-Object { $_.Id } | Select-Object -Unique)
        foreach ($wp in $wtPids) {
          foreach ($w in [TerminalWindowFinder]::GetWindowsForPid($wp)) {
            if ([TerminalWindowFinder]::GetWindowTitle($w) -eq $WinTitle) { $hWnd = $w; break }
          }
          if ($hWnd -ne [IntPtr]::Zero) { break }
        }
      } catch {}
    }
    # 3rd: Last resort — live search via EnumWindows
    if ($hWnd -eq [IntPtr]::Zero) {
      $hWnd = Find-TerminalWindow
    }
    # Debug: log what was found (use EnumWindows for title lookup)
    try {
      $logDir = Join-Path $env:LOCALAPPDATA "notify"
      if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
      $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
      $method = if ($hWndParam -and $hWndParam -ne "0" -and $hWnd -ne [IntPtr]::Zero -and $hWnd.ToString() -eq $hWndParam) { "hWnd-exact" }
                elseif ($WinTitle -and $hWnd -ne [IntPtr]::Zero) { "title-match" }
                else { "live-search" }
      if ($hWnd -ne [IntPtr]::Zero) {
        $wTitle = [TerminalWindowFinder]::GetWindowTitle($hWnd)
        Add-Content -Path (Join-Path $logDir "click-focus.log") -Value "$ts CLICK[$method]: hWnd=$hWnd title='$wTitle' winTitle='$WinTitle'"
      } else {
        Add-Content -Path (Join-Path $logDir "click-focus.log") -Value "$ts CLICK: hWnd=ZERO (no terminal found)"
      }
    } catch {}
    if ($hWnd -ne [IntPtr]::Zero) {
      Focus-Window -hWnd $hWnd
    }
    if ($script:form) { $script:form.Close() }
})

$icon.ShowBalloonTip(30000, $Title, $Body, [System.Windows.Forms.ToolTipIcon]::Info)

$form = New-Object System.Windows.Forms.Form
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false
$form.Opacity = 0
$form.FormBorderStyle = 'None'
$form.Size = New-Object System.Drawing.Size(0, 0)
$script:form = $form

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$startTime = Get-Date
$timer.Add_Tick({
    if ($script:clicked -or ((Get-Date) - $startTime).TotalSeconds -ge $Timeout) {
        $timer.Stop()
        $script:form.Close()
    }
})
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
$icon.Visible = $false
$icon.Dispose()
