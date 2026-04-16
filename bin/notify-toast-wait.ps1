param([string]$Title = "Claude", [string]$Body = "Click to focus", [int]$Timeout = 30, [string]$hWndParam = "")
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$pinvoke = @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@
Add-Type -Namespace Win32 -Name WF -ErrorAction SilentlyContinue -MemberDefinition $pinvoke

function Find-ClaudeWindow {
  try {
    # Find all cmd.exe with "Claude" in title and visible window
    $procs = Get-Process -Name cmd -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'Claude' }

    if ($procs) {
      # If multiple Claude Code windows, find the most recently active one
      if ($procs.Count -gt 1) {
        # Get current foreground window
        $fgWnd = [Win32.WF]::GetForegroundWindow()
        # Check if foreground window is a Claude Code window
        $fgProc = $procs | Where-Object { $_.MainWindowHandle -eq $fgWnd }
        if ($fgProc) {
          return $fgProc[0].MainWindowHandle
        }
        # If foreground is not Claude Code, find the one with latest activity
        # Use the one with most recent CPU time as a heuristic
        $mostActive = $procs | Sort-Object { -($_.CPU) } | Select-Object -First 1
        return $mostActive.MainWindowHandle
      }
      return $procs[0].MainWindowHandle
    }

    # Fallback: any cmd.exe with a visible window
    $procs = Get-Process -Name cmd -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }
    if ($procs) {
      if ($procs.Count -gt 1) {
        # Return the one with most recent CPU time
        $mostActive = $procs | Sort-Object { -($_.CPU) } | Select-Object -First 1
        return $mostActive.MainWindowHandle
      }
      return $procs[0].MainWindowHandle
    }
  } catch {}
  return [IntPtr]::Zero
}

function Focus-ClaudeWindow {
  param([IntPtr]$hWnd)
  if ($hWnd -eq [IntPtr]::Zero) { return }
  try {
    [Win32.WF]::ShowWindow($hWnd, 9) | Out-Null
    # TOPMOST trick to bring window to front without keybd_event
    [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
    Start-Sleep -Milliseconds 100
    [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
    [Win32.WF]::SwitchToThisWindow($hWnd, $true)
  } catch {}
}

$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.SystemIcons]::Information
$icon.Visible = $true
$icon.Text = "Claude"

$script:clicked = $false
$script:form = $null

$icon.Add_BalloonTipClicked({
    $script:clicked = $true
    if ($hWndParam -and $hWndParam -ne "0") {
      $hWnd = [IntPtr]([long]$hWndParam)
    } else {
      $hWnd = Find-ClaudeWindow
    }
    Focus-ClaudeWindow -hWnd $hWnd
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
