# Toast 通知问题排查经验

## 问题现象

1. 点击 toast 通知后能跳转，但键盘输入错乱（每个按键功能随机）
2. 通知内容为空
3. 通过 notify.ps1 发送的通知看不到
4. 对话结束时没有通知提醒

## 根因分析与修复

### 问题 1：点击后键盘错乱

**根因**：`notify-toast-wait.ps1` 中使用 `keybd_event` 模拟 ALT 键，导致键盘状态在不同线程间不一致。

**原始代码**：
```powershell
[Win32.WF]::keybd_event(0x12, 0, 0x0001, [UIntPtr]::Zero)  # ALT DOWN
Start-Sleep -Milliseconds 50
[Win32.WF]::keybd_event(0x12, 0, 0x0002, [UIntPtr]::Zero)  # ALT UP
```

**问题分析**：
- `keybd_event` 在 `AttachThreadInput` 之前执行
- ALT 事件发送到前台线程的输入队列
- 随后 `AttachThreadInput` 合并线程，导致 ALT 键状态不一致
- Windows 认为 ALT 仍被按住，所有后续按键被解释为 ALT+快捷键

**修复方案**：完全移除 `keybd_event`，只用 TOPMOST 技巧
```powershell
function Focus-ClaudeWindow {
  [Win32.WF]::ShowWindow($hWnd, 9) | Out-Null
  [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null
  Start-Sleep -Milliseconds 100
  [Win32.WF]::SetWindowPos($hWnd, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null
  [Win32.WF]::SwitchToThisWindow($hWnd, $true)
}
```

### 问题 2：通知内容为空

**根因**：变量名大小写错误，`$Snippet` 应该是 `$snippet`。

**位置**：`notify.ps1` 第 475、477 行

**修复**：
```powershell
# 错误
Start-Process wscript -ArgumentList "`"$vbsPath`" `"$Title`" `"$Snippet`" `"$consoleWnd`""

# 正确
Start-Process wscript -ArgumentList "`"$vbsPath`"", "`"$Title`"", "`"$snippet`"", "`"$consoleWnd`""
```

### 问题 3：通过 notify.ps1 发送的通知看不到

**根因**：`Start-Process wscript -ArgumentList` 的参数需要用逗号分隔，而不是一个字符串。

**错误写法**：
```powershell
Start-Process wscript -ArgumentList "`"$vbsPath`" `"$Title`" `"$snippet`" `"$consoleWnd`""
```

**正确写法**：
```powershell
Start-Process wscript -ArgumentList "`"$vbsPath`"", "`"$Title`"", "`"$snippet`"", "`"$consoleWnd`""
```

### 问题 4：对话结束时没有通知

**根因**：`settings.json` 中缺少 `hooks` 配置。

**排查过程**：
1. 检查日志显示 `[windows] ok`，说明通知被触发
2. 但这些是手动测试的通知，不是 hook 触发的
3. 检查 `C:\Users\y\.claude\settings.json` 发现没有 `hooks` 配置

**修复**：在 `settings.json` 中添加 Stop hook 配置
```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "& 'C:\\Users\\y\\bin\\notify.ps1' -Source 'Claude'",
            "shell": "powershell"
          }
        ]
      }
    ]
  }
}
```

## 排查技巧

### 1. 启用调试日志
```powershell
New-Item -ItemType File -Path 'C:\Users\y\bin\notify.debug.enabled' -Force
```
日志位置：`C:\Users\y\AppData\Local\notify\notify-YYYYMMDD.log`

### 2. 检查 BurntToast 模块
```powershell
Get-Module -ListAvailable -Name BurntToast
Get-Command -Name New-BurntToastNotification
```

### 3. 测试 VBS 启动
```powershell
Start-Process wscript -ArgumentList 'vbs路径', '标题', '内容', '0'
```

### 4. 检查 Windows 通知服务
```powershell
Get-Service -Name WpnUserService
```

## 经验教训

1. **`keybd_event` 是高风险 API**，尽量避免使用。窗口 Z-Order 操作是更安全的焦点控制方式
2. **PowerShell 变量名大小写敏感**，`$snippet` ≠ `$Snippet`
3. **`Start-Process -ArgumentList` 需要数组**，参数之间用逗号分隔
4. **Hooks 配置容易被忽略**，检查 settings.json 时要特别注意 `hooks` 字段
5. **分层排查**：先确认脚本本身能工作，再检查调用链路（VBS → PowerShell → notify.ps1 → BurntToast）

## 相关文件

- `bin/notify-toast-wait.ps1` - 核心通知脚本
- `bin/notify-toast-wait.vbs` - 静默启动器
- `bin/notify.ps1` - 主通知调度器
- `C:\Users\y\.claude\settings.json` - Claude Code 配置（包含 hooks）
