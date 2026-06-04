# Changelog

All notable changes to this project will be documented in this file.
This project follows Semantic Versioning.

## 0.1.7
- ✅ **修复**：点击通知后无法跳转到 Windows Terminal 窗口（扩展窗口检测支持 WindowsTerminal / wt）
- ✅ **修复**：Stop 通知后出现多余的 idle_prompt 通知（基于会话状态的去重，30 分钟窗口）
- ✅ **优化**：点击通知刷新去重窗口（点击即确认，从点击时刻重新计时）
- ✅ **优化**：Time-based debounce 从 30s 延长至 120s 作为辅助兜底
- ✅ **新增**：idle_prompt 提醒次数限制（默认 1 次，通过 `NOTIFY_MAX_REMINDERS` 配置），超过后永久静默，避免重复骚扰

## 0.1.6
- 安装完成后自动启动托盘/服务（避免“装完没托盘、没通知”）。
- Telegram 支持代理配置（安装器/配置页/托盘菜单），适配网络受限环境。
- Windows 通知增加 WinRT 原生 Toast 兜底（未安装 BurntToast 也可通知）。

## 0.1.5
- 修复安装向导在 exe 环境下 $PSScriptRoot 为空导致 Path 参数报错。

## 0.1.4
- Fix Telegram reply continuation in topic/thread chats (message_thread_id).
- Improve reply context fallback when Telegram reply metadata is missing.
- Fix bridge launching arguments to prevent prompt truncation.

## 0.1.3
- Improve remote image upload guidance when scp/pscp is missing.

## 0.1.2
- Support Telegram image replies for remote sessions (auto upload).

## 0.1.1
- Add Telegram reply-to-continue for latest session (text/image).

## 0.1.0
- Add EXE installer builder and GUI setup wizard.
- Add GUI configuration entry from tray.
- Add remote server (Linux) batch setup in installer (up to 5 hosts).
- Add Telegram setup help and improved onboarding flow.
