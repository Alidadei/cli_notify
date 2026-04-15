# Windows CLI Notify Bridge

<div align="center">

**把 Codex / Claude 的回复推送到 Windows 通知、企业微信或 Telegram**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.1.6-green.svg)](VERSION)

</div>

## ✨ 功能特性

- 🖥️ **Windows Toast 通知** - 原生桌面通知，点击跳转到窗口
- 💬 **企业微信/Telegram 推送** - 远程接收通知，不错过重要消息
- 🤖 **Telegram 远程控制** - `/codex`、`/claude` 闭环控制 AI 会话
- 💭 **Telegram 继续对话** - 回复通知直接继续会话（支持图文、Thread）
- 🎛️ **托盘菜单** - 一键开关通道、调试日志
- 🌐 **HTTP 服务端** - 支持多台 Linux Codex 推送到同一台 Windows
- ⚡ **低性能占用** - 内存 8-10 MB（临时），CPU ~0%

## 🚀 快速开始

### 方式 1：使用安装向导（推荐）

1. 在 [GitHub Releases](../../releases) 下载最新 `NotifySetup.exe`
2. 双击运行安装向导
3. 按需勾选：Telegram/企业微信/远程通知服务端/开机自启
4. 安装完成即可使用

> 安装向导会自动处理端口冲突、防火墙配置、URL ACL 等复杂设置。

### 方式 2：手动配置

#### 1. 安装 BurntToast 模块

```powershell
Install-Module -Name BurntToast -Force -Scope CurrentUser
```

#### 2. 复制脚本文件

将本项目 `bin/` 目录复制到 `C:\Users\<用户名>\bin\`：

```powershell
# 创建 bin 目录
New-Item -ItemType Directory -Path "$env:USERPROFILE\bin" -Force | Out-Null

# 复制文件
Copy-Item "bin\*.ps1" -Destination "$env:USERPROFILE\bin\" -Force
Copy-Item "bin\*.vbs" -Destination "$env:USERPROFILE\bin\" -Force
```

#### 3. 配置 Claude Code Hooks

编辑 `C:\Users\<用户名>\.claude\settings.json`，添加以下配置：

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

#### 4. 验证配置

```powershell
& "$env:USERPROFILE\bin\notify.ps1" -Source '测试' -Title 'Hello' -Body '配置成功！'
```

预期结果：右下角弹出通知。

## 📖 详细文档

- [安装配置指南](docs/installation-guide.md) - 完整的安装步骤和配置说明
- [问题排查指南](docs/troubleshooting-toast-notification-issues.md) - 常见问题和解决方案
- [性能分析报告](docs/performance-analysis.md) - 资源占用和优化说明
- [键盘错乱问题分析](docs/bug-toast-click-keyboard-malfunction.md) - 技术细节

## 🔧 高级配置

### 配置企业微信通知

创建 `C:\Users\<用户名>\bin\.env` 文件：

```bash
WECOM_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY
```

### 配置 Telegram 通知

在 `.env` 文件中添加：

```bash
TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN
TELEGRAM_CHAT_ID=YOUR_CHAT_ID
TELEGRAM_PROXY=http://127.0.0.1:7890
```

### 配置托盘图标（可选）

```powershell
Start-Process wscript -ArgumentList "$env:USERPROFILE\bin\notify-tray.vbs" -WindowStyle Hidden
```

开机自启：将快捷方式放入 `shell:startup` 文件夹。

## 💬 Telegram 使用说明

### 基础命令

```
/help              # 查看帮助
/codex <问题>      # 向 Codex 提问
/claude <问题>     # 向 Claude 提问
/codex last <问题> # 向上次会话提问
/claude last <问题>
```

### 继续对话

- **必须回复机器人推送的最新消息**（否则提示"不支持回复"）
- 支持 Thread：自动在同一 Thread 内回复
- 支持图文：图片保存到 `.notify` 目录并注入提示词
- 远程图片：需要 `scp`（OpenSSH）或 PuTTY `pscp.exe`

## 🌐 远程 Linux → Windows 推送

当 Linux 服务器运行 Codex，希望通知回到 Windows：

```bash
curl -fsSL https://raw.githubusercontent.com/RickyAllen00/cli_notify/master/remote/install-codex-notify.sh | bash -s -- \
  --url "http://<Windows_IP>:9412/notify" \
  --token "<与Windows一致的Token>" \
  --host "<服务器标识>" \
  --name "<备注名>"
```

Windows 侧：在安装向导中勾选"远程通知服务端"。

## 📁 日志位置

```
%LOCALAPPDATA%\notify\notify-YYYYMMDD.log          # 主通知日志
%LOCALAPPDATA%\notify\telegram-bridge.log         # Telegram 桥接日志
%LOCALAPPDATA%\notify\codex-bridge.log             # Codex 桥接日志
%LOCALAPPDATA%\notify\claude-bridge.log            # Claude 桥接日志
%LOCALAPPDATA%\notify\notify-server.log            # HTTP 服务端日志
```

**启用调试日志**：
```powershell
New-Item -ItemType File -Path "$env:USERPROFILE\bin\notify.debug.enabled" -Force
```

## 🔍 常见问题

### Windows 通知无效
- 确认 BurntToast 已安装：`Get-Module -ListAvailable -Name BurntToast`
- **检查专注助手**：设置 → 系统 → 专注助手 → 确保设为"关闭"（否则会拦截所有横幅通知）
- **检查通知权限**：设置 → 系统 → 通知和操作 → 确保"获取来自应用和其他发送者的通知"已开启 → 向下滚动找到 PowerShell，确保其通知和横幅开关已开启
- 确认 Windows 通知服务运行：`Get-Service -Name WpnUserService`
- 快捷打开通知设置：`start ms-settings:notifications`，专注助手设置：`start ms-settings:quiethours`

### 点击通知后键盘错乱
- **已修复**：v0.1.6+ 版本已解决此问题
- 确保使用最新版本的 `notify-toast-wait.ps1`

### 托盘图标不显示
- 检查右下角隐藏图标（^）
- 查看日志：`%LOCALAPPDATA%\notify\tray.log`

### Telegram 无响应
- 确认 Bot Token 和 Chat ID 正确
- 检查代理配置（如需要）
- 查看日志：`%LOCALAPPDATA%\notify\telegram-bridge.log`

### 对话结束时没有通知
- 确认 `settings.json` 中 `hooks` 配置存在
- 检查日志：`%LOCALAPPDATA%\notify\notify-*.log`
- 手动测试：`& "$env:USERPROFILE\bin\notify.ps1" -Source 'Test'`

## 📊 性能说明

通知功能采用**按需创建、自动清理**设计，对性能影响极小：

- **内存占用**：8-10 MB（仅在通知等待点击期间）
- **CPU 占用**：~0%（空闲状态）
- **后台进程**：0-1 个临时进程（自动清理）
- **电池影响**：<0.1%/天（100 次通知）

详细分析：[性能分析报告](docs/performance-analysis.md)

## 🛠️ 维护者指南

### 构建安装包

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-setup.ps1
```

输出：`dist\NotifySetup.exe`

### 发布新版本

1. 更新 `VERSION` 文件
2. 更新 `CHANGELOG.md`
3. 运行发布脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\release.ps1
```

## 📝 更新日志

### v0.1.6 (2026-04-15)
- ✅ **修复**：点击 Toast 通知后键盘错乱问题
- ✅ **修复**：通知内容为空的问题（变量名大小写）
- ✅ **修复**：VBS 参数传递格式问题
- ✅ **新增**：Stop Hook 配置示例
- ✅ **新增**：完整的文档和配置指南

### 更早版本
详见 [CHANGELOG.md](CHANGELOG.md)

## 📄 License

[MIT](LICENSE)

## 🙏 致谢

- [BurntToast](https://github.com/WaterlooWins/BurntToast) - PowerShell Toast 通知模块
- Claude Code / Codex 团队
