## Codex调用方式

### 基本格式
```bash
cd "项目根目录" && /c/Users/y/AppData/Roaming/npm/codex exec "提示词"
```

**注意**: 本项目已是 git 仓库，无需添加 `--skip-git-repo-check` 参数

### 成功连接的关键经验

1. **使用简短提示词** - 提示词越简短，连接成功率越高
   ```bash
   #  推荐：简短明确
   #  避免：提示词太长超时
   ```
   
2. **无需 --skip-git-repo-check**
   - 本项目已是 git 仓库
   - 直接调用即可，codex 会自动识别

3. **使用后台运行模式**
   - 在Agent工具中设置 `run_in_background=True`
   - 避免因等待而超时

4. **网络fallback机制**
   - codex会自动从WebSocket降级到HTTPS
   - 如果看到"Reconnecting"是正常现象，等待即可

5. **复杂任务分步进行**
   - 将复杂任务拆分成多个简单步骤
   - 每步使用简短的提示词

### 示例
```bash
# 快速验证类（推荐）
/c/Users/y/AppData/Roaming/npm/codex exec "用中文简短总结当前项目的核心功能"

# 如果提示词太长，先写入文件
echo "长提示词内容" > tests/prompt.txt
# 然后在提示词中引用文件路径
```



## 本机限制

本机CPU为4核8线程， 不要一次性运行多个占用CPU的实验！





## 环境配置要求：

配置虚拟环境，环境的名称需要由用户确认。所有配环境产生的文件尽量放在项目目录下的统一文件夹，而不要放到C盘；

本机conda路径在：C:\Users\y\miniconda3\condabin

尽量保证不同机器上环境的可复现性。

## 项目结构维护：

使用不同文件夹来归类不同的文件！保持项目结构整洁清晰！

以下文件夹如果项目目录下没有，则创建！

docs 文件夹：所有用户和agent输出的技术文档和经验总结都放在这里

record 文件夹：放所有的实验结果记录

tests文件夹：所有单独测试或问题验证代码都需要放到这个文件夹

  包括但不限于：

  - 验证类文件（如 verify_*.txt）
  - 测试脚本
  - 问题验证代码
  - 给codex/agent看的验证提示文件

## 通知功能配置指导

当 agent 完成通知功能（cli_notify）的安装配置后，**必须提醒用户检查以下 Windows 系统设置**（这是通知不弹出的最常见原因）：

### 1. 关闭专注助手
- `Win + I` → 系统 → 专注助手，确保设为"关闭"
- 或运行 `start ms-settings:quiethours`
- 专注助手会拦截所有 Toast 横幅通知

### 2. 开启应用通知权限
- `Win + I` → 系统 → 通知和操作，确保"获取来自应用和其他发送者的通知"已开启
- 或运行 `start ms-settings:notifications`
- 找到 PowerShell，确保通知和横幅开关已开启

### 3. 快速验证
完成设置后，用以下命令验证通知是否正常弹出：
```powershell
Import-Module BurntToast; New-BurntToastNotification -Text '测试','通知配置成功！'
```
