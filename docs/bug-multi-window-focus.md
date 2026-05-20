# Bug: 多窗口时跳转到错误的 Claude Code 窗口

## 现象

当打开多个 Claude Code 窗口时，点击通知后无法正确跳转到发出通知的那个窗口，而是随机跳转到其中一个窗口。

## 根因

`GetConsoleWindow()` 在 hook 上下文中返回 0（hook 由 Claude Code 启动的 PowerShell 执行，无控制台窗口）。因此 toast-wait.ps1 收到的 `hWndParam` 为 "0"，被迫使用 `Find-ClaudeWindow` 猜测目标窗口。

`Find-ClaudeWindow` 的旧启发式方法（前台窗口检查 + CPU 时间排序）在多窗口场景下不可靠：
1. 用户点击 toast 时，前台窗口是通知中心，不是任何一个 Claude Code 窗口
2. CPU 时间值极小（0.05 vs 0.02），无法有效区分活跃度
3. 排序结果是随机的

## 修复方案

**核心思路**：从当前 PowerShell 进程向上遍历进程树，找到 cmd.exe 祖进程的窗口句柄。这是确定性的，不需要任何启发式猜测。

### notify.ps1 — 获取窗口句柄

```powershell
# Walk process tree to find the cmd.exe ancestor window (deterministic)
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
```

### 进程链路

```
cmd.exe (窗口句柄 = 目标) → node.exe (Claude Code) → powershell.exe (hook) → notify.ps1
```

notify.ps1 从 `$PID` 开始向上走，直到找到 cmd.exe 祖进程，其 `MainWindowHandle` 就是正确的窗口。

### toast-wait.ps1 — 三级回退策略

1. **进程树遍历**（优先）：从自身进程树向上找 cmd.exe 祖先
2. **窗口标题匹配**：找标题含 "Claude" 的 cmd 窗口（单窗口直接用，多窗口用前台/CPU 启发式）
3. **任意 cmd 窗口**：最后的降级

## 为什么这次能彻底修复

- **确定性**：进程树遍历与进程链路一一对应，不依赖任何启发式
- **零开销**：`Get-CimInstance` 只查询少量进程，不枚举所有窗口
- **兼容性**：即使进程树遍历失败（如非标准部署），仍有三级回退

## 测试方法

1. 打开两个或多个 Claude Code 窗口
2. 在其中一个窗口中完成任务，等待通知弹出
3. 点击通知，验证是否跳转到**发出通知的那个窗口**（而非其他窗口）
4. 在另一个窗口重复测试

## 修复历史

- 2026-04-16：首次修复（前台窗口 + CPU 启发式，不可靠）
- 2026-04-16：二次修复（进程树遍历，确定性方案）

## 相关文件

- `bin/notify.ps1` — 获取并传递窗口句柄
- `bin/notify-toast-wait.ps1` — `Find-ClaudeWindow` 函数
- `bin/notify-toast-wait.vbs` — 传递 hWnd 参数
