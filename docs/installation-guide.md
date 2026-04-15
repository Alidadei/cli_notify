# Claude Code 通知功能配置指南

> 本指南基于 **cli_notify** 项目，一个 Windows CLI 通知桥接工具。
> 项目地址：`https://github.com/<your-repo>/cli_notify`

## 功能说明

本配置指南用于在 Windows 电脑上配置 Claude Code 通知功能，实现以下效果：
- 当 Claude Code 对话结束时，自动发送 Windows 桌面通知
- 点击通知可跳转回 Claude Code 窗口
- 支持多渠道通知（Windows Toast、企业微信、Telegram）
- **性能占用极低**：内存 8-10 MB（临时），CPU ~0%

## 系统要求

- **操作系统**：Windows 10/11
- **PowerShell**：5.1 或更高版本
- **Claude Code**：已安装并正常使用

## 全新电脑配置准备

在全新电脑上配置前，需要准备以下内容：

### 前置条件检查

打开 PowerShell，运行以下命令检查系统环境：

```powershell
# 检查 PowerShell 版本
$PSVersionTable.PSVersion

# 检查 Windows 版本
Get-ComputerInfo

# 检查 Claude Code 是否安装
Get-Command code -ErrorAction SilentlyContinue
```

**预期结果**：
- PowerShell 版本 >= 5.1
- Windows 版本 >= 10.0.1xxxx
- Claude Code 命令可用

### 需要下载/安装的内容

| 项目 | 来源 | 是否必需 | 大小 |
|------|------|----------|------|
| **PowerShellGet** | 系统自带（Win10+） | 必需 | - |
| **BurntToast 模块** | PowerShell Gallery | **必需** | ~1 MB |
| **通知脚本文件** | 从源电脑复制 | **必需** | ~50 KB |
| Claude Code | 官网安装 | 前提条件 | ~200 MB |

### 1. 安装 BurntToast 模块（必需）

BurntToast 是 Windows Toast 通知的 PowerShell 模块，需要从 PowerShell Gallery 下载安装。

```powershell
# 检查是否已安装
Get-Module -ListAvailable -Name BurntToast

# 如果未安装，执行安装
Install-Module -Name BurntToast -Force -Scope CurrentUser
```

**首次安装可能需要**：
- 管理员权限
- 接受 NuGet 提示（自动安装依赖）
- 网络连接（访问 PowerShell Gallery）

**离线安装**（无网络环境）：
```powershell
# 在有网络的电脑上
Save-Module -Name BurntToast -Path ".\BurntToast"

# 复制到目标电脑后
Install-Module -Name BurntToast -Force -Scope CurrentUser -Source ".\BurntToast"
```

### 2. 获取通知脚本文件（必需）

通知脚本来自 **cli_notify** 项目，有以下几种获取方式：

#### 方式 1：从 GitHub 克隆（推荐）

```powershell
# 克隆项目到本地
git clone https://github.com/<your-repo>/cli_notify.git $env:USERPROFILE\cli_notify

# 复制文件到 bin 目录
New-Item -ItemType Directory -Path "$env:USERPROFILE\bin" -Force | Out-Null
Copy-Item "$env:USERPROFILE\cli_notify\bin\*.ps1" -Destination "$env:USERPROFILE\bin\" -Force
Copy-Item "$env:USERPROFILE\cli_notify\bin\*.vbs" -Destination "$env:USERPROFILE\bin\" -Force
```

#### 方式 2：直接复制文件

如果你已经有 cli_notify 项目，直接复制 `bin` 目录：

```powershell
# 从源项目复制
Copy-Item "<源项目路径>\bin\*.ps1" -Destination "$env:USERPROFILE\bin\" -Force
Copy-Item "<源项目路径>\bin\*.vbs" -Destination "$env:USERPROFILE\bin\" -Force
```

#### 方式 3：从 Release 下载

如果项目提供 Release 包，下载解压后复制 `bin` 目录。

**必需文件**：
```
bin/
├── notify.ps1                 # 主通知脚本
├── notify-toast-wait.ps1      # Toast 点击处理
├── notify-toast-wait.vbs      # 静默启动器
```

**可选文件**：
```
bin/
├── notify-tray.ps1            # 托盘图标
├── notify-tray.vbs            # 托盘启动器
├── notify-server.ps1          # 服务器模式
└── notify-server.vbs          # 服务器启动器
```

**文件清单**：
```
cli_notify/
├── bin/                       # 所有通知脚本
│   ├── notify.ps1
│   ├── notify-toast-wait.ps1
│   ├── notify-toast-wait.vbs
│   ├── notify-tray.ps1/vbs
│   ├── notify-server.ps1/vbs
│   ├── telegram-bridge.ps1/vbs
│   └── ... (其他功能脚本)
├── docs/                      # 文档目录
│   ├── installation-guide.md
│   ├── troubleshooting-toast-notification-issues.md
│   ├── bug-toast-click-keyboard-malfunction.md
│   └── performance-analysis.md
├── README.md
├── CHANGELOG.md
└── VERSION
```

**复制方法**：
- **方法 1**：使用 U 盘/网络共享复制整个 `bin` 文件夹
- **方法 2**：使用 PowerShell 远程复制
- **方法 3**：从 Git 仓库克隆（如果有）

### 3. 检查 PowerShell 执行策略

确保允许运行 PowerShell 脚本：

```powershell
# 检查当前执行策略
Get-ExecutionPolicy -List

# 如果限制为 Restricted，设置为 RemoteSigned
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

**执行策略说明**：
- `Restricted`：不允许运行任何脚本（需要修改）
- `RemoteSigned`：允许本地脚本，远程脚本需要签名（推荐）
- `Unrestricted`：允许所有脚本（不推荐）

### 4. 验证环境准备

运行以下命令验证所有前置条件：

```powershell
Write-Host "=== 环境检查 ===" -ForegroundColor Green

# 1. PowerShell 版本
Write-Host "PowerShell 版本: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan

# 2. BurntToast 模块
$bt = Get-Module -ListAvailable -Name BurntToast
if ($bt) {
    Write-Host "BurntToast: 已安装 (版本: $($bt.Version))" -ForegroundColor Green
} else {
    Write-Host "BurntToast: 未安装" -ForegroundColor Red
}

# 3. bin 目录
$binDir = Join-Path $env:USERPROFILE "bin"
if (Test-Path $binDir) {
    $files = Get-ChildItem $binDir -Filter "notify*.ps1"
    Write-Host "bin 目录: 存在 (通知脚本: $($files.Count) 个)" -ForegroundColor Green
} else {
    Write-Host "bin 目录: 不存在" -ForegroundColor Red
}

# 4. 执行策略
$policy = Get-ExecutionPolicy -Scope CurrentUser
Write-Host "执行策略: $policy" -ForegroundColor Cyan

Write-Host "=== 检查完成 ===" -ForegroundColor Green
```

### 全新电脑配置清单

在全新电脑上配置前，请确认：

- [ ] Windows 10/11 操作系统
- [ ] PowerShell 5.1 或更高版本
- [ ] 已安装 Claude Code
- [ ] 已安装 BurntToast 模块
- [ ] 已复制通知脚本文件到 `bin` 目录
- [ ] PowerShell 执行策略允许运行脚本

完成以上准备后，即可继续下面的配置步骤。

### 1. 复制文件到目标目录

将以下文件复制到目标电脑的 `C:\Users\<用户名>\bin\` 目录：

```
bin/
├── notify.ps1                 # 主通知脚本
├── notify-toast-wait.ps1      # Toast 点击处理脚本
├── notify-toast-wait.vbs      # 静默启动器
├── notify-tray.ps1            # 托盘图标（可选）
├── notify-tray.vbs            # 托盘启动器（可选）
├── notify-server.ps1          # 服务器模式（可选）
└── notify-server.vbs          # 服务器启动器（可选）
```

**执行命令**：
```powershell
# 创建 bin 目录（如果不存在）
New-Item -ItemType Directory -Path "$env:USERPROFILE\bin" -Force | Out-Null

# 复制文件（从源目录复制到目标目录）
# 请将 <源目录> 替换为实际路径
Copy-Item "<源目录>\bin\*.ps1" -Destination "$env:USERPROFILE\bin\" -Force
Copy-Item "<源目录>\bin\*.vbs" -Destination "$env:USERPROFILE\bin\" -Force
```

### 2. 安装 BurntToast 模块（推荐）

BurntToast 提供 Windows 10/11 原生 Toast 通知支持：

```powershell
Install-Module -Name BurntToast -Force -Scope CurrentUser
```

**验证安装**：
```powershell
Get-Module -ListAvailable -Name BurntToast
```

### 3. 配置 Claude Code Hooks

创建或编辑 Claude Code 配置文件：

**配置文件路径**：`C:\Users\<用户名>\.claude\settings.json`

**添加以下配置**：
```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "& 'C:\\Users\\<用户名>\\bin\\notify.ps1' -Source 'Claude'",
            "shell": "powershell"
          }
        ]
      }
    ]
  }
}
```

**注意**：
- 将 `<用户名>` 替换为实际用户名
- 如果 `settings.json` 已有其他配置，请合并 `hooks` 字段，不要覆盖整个文件
- 路径中的反斜杠需要转义为 `\\`

**完整配置示例**：
```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "your-token-here"
  },
  "enabledPlugins": {
    "github@claude-plugins-official": true
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "& 'C:\\Users\\yourname\\bin\\notify.ps1' -Source 'Claude'",
            "shell": "powershell"
          }
        ]
      }
    ]
  }
}
```

### 4. 验证配置

#### 4.1 测试通知脚本

```powershell
& "$env:USERPROFILE\bin\notify.ps1" -Source '测试' -Title '配置验证' -Body '如果你看到这条通知，说明配置成功！'
```

**预期结果**：右下角应该弹出通知，显示标题"配置验证"和内容文本。

#### 4.2 测试 Hook

1. 打开 Claude Code
2. 开始一个新对话
3. 输入任意任务（如"数到10"）
4. 等待任务完成或点击停止按钮
5. 检查是否收到通知

**预期结果**：对话结束时应该弹出通知。

## 高级配置（可选）

### 配置企业微信通知

创建环境变量或配置文件：

**方法 1：环境变量**
```powershell
[System.Environment]::SetEnvironmentVariable('WECOM_WEBHOOK', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY', 'User')
```

**方法 2：配置文件**
在 `C:\Users\<用户名>\bin\` 目录创建 `.env` 文件：
```
WECOM_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY
```

### 配置 Telegram 通知

在 `.env` 文件中添加：
```
TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN
TELEGRAM_CHAT_ID=YOUR_CHAT_ID
TELEGRAM_PROXY=http://127.0.0.1:7890
```

### 配置托盘图标（可选）

托盘图标提供手动控制通知的开关：

**启动托盘**：
```powershell
Start-Process wscript -ArgumentList "$env:USERPROFILE\bin\notify-tray.vbs" -WindowStyle Hidden
```

**开机自启动**：
将托盘启动快捷方式放入 `shell:startup` 文件夹。

## 故障排查

### 问题 1：通知不显示

**检查 Windows 通知服务**：
```powershell
Get-Service -Name WpnUserService
```

如果服务未运行，启动它：
```powershell
Start-Service -Name WpnUserService
Set-Service -Name WpnUserService -StartupType Automatic
```

**检查 Windows 通知设置**：
1. 打开"设置" → "系统" → "通知和操作"
2. 确保"获取来自应用和其他发送者的通知"已开启
3. 允许 PowerShell 或 Windows Script Host 显示通知

### 问题 2：通知显示但点击后键盘错乱

这是已知问题，已在 `notify-toast-wait.ps1` 中修复。确保使用最新版本的文件。

### 问题 3：对话结束时没有通知

**启用调试日志**：
```powershell
New-Item -ItemType File -Path "$env:USERPROFILE\bin\notify.debug.enabled" -Force
```

**查看日志**：
```powershell
Get-Content "$env:LOCALAPPDATA\notify\notify-*.log" -Tail 20
```

**检查 Hook 配置**：
确认 `settings.json` 中 `hooks` 字段存在且格式正确。

### 问题 4：Hook 执行报错

**手动测试 Hook 命令**：
```powershell
& 'C:\Users\<用户名>\bin\notify.ps1' -Source 'Claude'
```

如果报错，检查：
1. PowerShell 执行策略：`Get-ExecutionPolicy`
2. 文件路径是否正确
3. 文件权限是否正确

## 文件清单

**必需文件**：
- `notify.ps1` - 主通知脚本，必须放在 bin 目录
- `notify-toast-wait.ps1` - Toast 点击处理
- `notify-toast-wait.vbs` - 静默启动器

**可选文件**：
- `notify-tray.ps1` / `notify-tray.vbs` - 托盘图标
- `notify-server.ps1` / `notify-server.vbs` - 服务器模式

**配置文件**：
- `C:\Users\<用户名>\.claude\settings.json` - Claude Code 配置（需添加 hooks）
- `C:\Users\<用户名>\bin\.env` - 通知渠道配置（可选）

## 卸载

1. **删除 Hook 配置**：从 `settings.json` 中移除 `hooks` 字段
2. **删除文件**：
   ```powershell
   Remove-Item "$env:USERPROFILE\bin\notify*.ps1"
   Remove-Item "$env:USERPROFILE\bin\notify*.vbs"
   ```
3. **卸载 BurntToast**（可选）：
   ```powershell
   Uninstall-Module -Name BurntToast
   ```

## 版本信息

- 当前版本：基于 cli_notify 项目
- 最后更新：2026-04-15
- 兼容性：Claude Code Desktop, Claude Code CLI

## 技术支持

如遇到问题，请检查：
1. 调试日志：`$env:LOCALAPPDATA\notify\notify-*.log`
2. Windows 事件查看器：Windows 日志 → 应用程序
3. PowerShell 错误输出

相关文档：
- `docs/bug-toast-click-keyboard-malfunction.md` - 键盘错乱问题分析
- `docs/troubleshooting-toast-notification-issues.md` - 排查经验
