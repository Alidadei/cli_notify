# Bug: 多窗口时跳转到错误的 Claude Code 窗口

## 现象

当打开多个 Claude Code 窗口时，点击通知后无法正确跳转到当前活跃的窗口，而是随机跳转到其中一个窗口。

## 根因

`Find-ClaudeWindow` 函数在找到多个 Claude Code 窗口时，直接返回第一个（`$procs[0]`），没有考虑哪个窗口是当前活跃的。

**原始代码**：
```powershell
$procs = Get-Process -Name cmd -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'Claude' }
if ($procs) { return $procs[0].MainWindowHandle }
```

## 修复方案

改进窗口查找逻辑，优先选择当前活跃的窗口：

```powershell
function Find-ClaudeWindow {
  try {
    $procs = Get-Process -Name cmd -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'Claude' }

    if ($procs) {
      # If multiple Claude Code windows, find the most recently active one
      if ($procs.Count -gt 1) {
        # Priority 1: Check if current foreground window is Claude Code
        $fgWnd = [Win32.WF]::GetForegroundWindow()
        $fgProc = $procs | Where-Object { $_.MainWindowHandle -eq $fgWnd }
        if ($fgProc) {
          return $fgProc[0].MainWindowHandle
        }
        # Priority 2: Use CPU time as heuristic for recent activity
        $mostActive = $procs | Sort-Object { -($_.CPU) } | Select-Object -First 1
        return $mostActive.MainWindowHandle
      }
      return $procs[0].MainWindowHandle
    }
    # ... fallback logic
  } catch {}
  return [IntPtr]::Zero
}
```

## 优先级逻辑

1. **优先检查前台窗口**：如果当前前台窗口是 Claude Code，直接使用它
2. **CPU 时间启发式**：使用累计 CPU 时间判断最近活跃的窗口
3. **降级到单一窗口**：如果只有一个窗口，直接返回

## 测试方法

1. 打开两个或多个 Claude Code 窗口
2. 在其中一个窗口中保持活跃
3. 触发通知（对话结束或手动测试）
4. 点击通知，验证是否跳转到当前活跃的窗口

## 修复时间

2026-04-16

## 相关文件

- `bin/notify-toast-wait.ps1` - `Find-ClaudeWindow` 函数
