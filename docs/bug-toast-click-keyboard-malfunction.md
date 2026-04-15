# Bug: Toast 点击跳转后键盘错乱

## 现象

Toast 气泡通知能正确弹出并显示内容。点击 toast 后能跳转到 Claude Code 窗口，但此后计算机键盘输入会失效并出现严重错乱——每个按键的功能变成随机的（例如按 `j` 变成菜单快捷键行为）。如果不点击 toast，则一切正常。

## 根因

位于 `bin/notify-toast-wait.ps1` 的 `Focus-ClaudeWindow` 函数中，三处代码共同导致了此问题：

### 1. `keybd_event` ALT 键模拟（主因）

```powershell
# 原始代码（第 32-35 行）
[Win32.WF]::keybd_event(0x12, 0, 0x0001, [UIntPtr]::Zero)  # ALT DOWN
Start-Sleep -Milliseconds 50
[Win32.WF]::keybd_event(0x12, 0, 0x0002, [UIntPtr]::Zero)  # ALT UP
Start-Sleep -Milliseconds 50
```

这段代码的目的是模拟按一下 ALT 键，骗过 Windows 的前台窗口限制（`SetForegroundWindow` 只允许前台进程设置新的前台窗口，模拟 ALT 键让 Windows 认为发生了用户输入）。

**问题在于调用顺序**：`keybd_event` 在 `AttachThreadInput` 之前执行。

- `keybd_event` 是全局输入事件注入，会被分发到当前前台线程的输入队列
- ALT DOWN 事件发送到线程 A（通知中心/桌面）的输入队列
- 50ms sleep 期间，线程 A 可能处理了 ALT DOWN，进入菜单模式
- ALT UP 事件也发到线程 A
- 随后 `AttachThreadInput` 将 PowerShell 线程与线程 A 的输入队列合并
- 此时 ALT 键状态在不同线程间不一致：线程 A 可能仍认为 ALT 处于按下状态
- `SetForegroundWindow` 切换焦点到 Claude 窗口（线程 B），但线程 B 的键盘状态可能继承了错误的状态
- 最终结果：Windows 认为 ALT 键仍处于按下状态

**当 Windows 认为 ALT 被按住时**：所有后续按键被解释为 `ALT+按键`（菜单加速键），表现为"每个按键功能随机"——这正是用户描述的现象。

### 2. `AttachThreadInput` 缺少 finally 保护（次要原因）

```powershell
# 原始代码（第 40-46 行）— 没有 try/finally
if ($fgTid -ne 0 -and $fgTid -ne $myTid) {
    [Win32.WF]::AttachThreadInput($myTid, $fgTid, $true) | Out-Null
}
[Win32.WF]::SetForegroundWindow($hWnd) | Out-Null
if ($fgTid -ne 0 -and $fgTid -ne $myTid) {
    [Win32.WF]::AttachThreadInput($myTid, $fgTid, $false) | Out-Null   # 如果上面出错，这行不会执行
}
```

`AttachThreadInput($true)` 将两个线程的输入队列合并。如果 `SetForegroundWindow` 抛出异常，`AttachThreadInput($false)` 永远不会执行，导致两个线程永久共享输入队列——键盘输入被路由到错误的窗口。

外层虽然有 `catch {}`，但它是空的，静默吞掉了所有异常。

### 3. 空 catch 块掩盖错误

```powershell
} catch {}   # 第 51 行
```

所有异常被静默忽略，包括 `AttachThreadInput` detach 失败的情况，使得问题难以被发现和调试。

## 修复方案

### 核心思路

将 `keybd_event` 移到 `AttachThreadInput` 之后执行，确保 ALT 键事件在统一的合并输入队列中完成：

```powershell
function Focus-ClaudeWindow {
  param([IntPtr]$hWnd)
  if ($hWnd -eq [IntPtr]::Zero) { return }
  try {
    [Win32.WF]::ShowWindow($hWnd, 9) | Out-Null

    $fgWnd = [Win32.WF]::GetForegroundWindow()
    $dummy = [uint32]0
    $fgTid = [Win32.WF]::GetWindowThreadProcessId($fgWnd, [ref]$dummy)
    $myTid = [Win32.WF]::GetCurrentThreadId()

    $attached = $false
    if ($fgTid -ne 0 -and $fgTid -ne $myTid) {
      $attached = [Win32.WF]::AttachThreadInput($myTid, $fgTid, $true)
    }

    try {
      # ALT 键事件在合并的输入队列中执行，状态一致
      [Win32.WF]::keybd_event(0x12, 0, 0x0001, [UIntPtr]::Zero)
      [Win32.WF]::keybd_event(0x12, 0, 0x0002, [UIntPtr]::Zero)
      [Win32.WF]::SetForegroundWindow($hWnd) | Out-Null
    } finally {
      # 确保始终 detach
      if ($attached) {
        [Win32.WF]::AttachThreadInput($myTid, $fgTid, $false) | Out-Null
      }
    }

    # TOPMOST 技巧作为额外保障
    [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
    Start-Sleep -Milliseconds 100
    [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
    [Win32.WF]::SwitchToThisWindow($hWnd, $true)
  } catch {}
}
```

### 关键改动

| 改动 | 原因 |
|------|------|
| `keybd_event` 移到 `AttachThreadInput` 之后 | ALT 键事件在合并队列中完成，DOWN/UP 状态一致 |
| 去掉 `keybd_event` 之间的 Sleep | DOWN/UP 背靠背完成，不给窗口进入菜单模式的时间 |
| `AttachThreadInput` detach 用 `try/finally` 保护 | 确保即使出错也能正确 detach |
| 追踪 `$attached` 状态 | 只在 attach 确实成功时才执行 detach |

### 顺序对比

```
原始（有 bug）:
  keybd_event(ALT DOWN) → Sleep → keybd_event(ALT UP) → Sleep → AttachThreadInput → SetForegroundWindow → DetachThreadInput

修复后:
  AttachThreadInput → keybd_event(ALT DOWN) → keybd_event(ALT UP) → SetForegroundWindow → DetachThreadInput (in finally)
```

## 关联问题

排查过程中还发现 `Find-ClaudeWindow` 函数按 `"Claude Code"` 匹配 `cmd.exe` 的窗口标题，但实际标题格式为 `"? <任务描述>"`（不含 "Claude Code"），导致窗口查找始终失败。此问题需要一并修复。

## 经验总结

1. **`keybd_event` 是危险的 API** —— 它向全局输入队列注入事件，在多线程环境下极易导致键盘状态不一致
2. **`AttachThreadInput` 必须配对使用** —— 任何在 attach 之后、detach 之前的代码都必须用 `try/finally` 保护
3. **模拟按键与线程输入队列的交互顺序至关重要** —— 必须在队列合并后再注入事件
4. **Windows 的每个线程有独立的键盘状态** —— 合并/拆分队列时状态可能不一致
