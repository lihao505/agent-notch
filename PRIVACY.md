# Agent Notch 隐私说明

生效日期：2026-08-12

Agent Notch 是本地优先的 macOS 应用。

## 应用读取的数据

- 已连接 Agent 的本地会话状态、标题、消息和工具调用；
- 用户在 Agent Notch 中输入的回复与审批选择；
- 为显示用量而读取的本地 Agent 配置或状态；
- 应用设置，例如语言、刘海显示方式和逐会话审批模式。

这些数据用于在本机提供界面和交互，不会发送给 Agent Notch 开发者。回复或审批
可能由对应的第三方 Agent CLI 发送到其服务，适用该服务自身的隐私政策。

应用会按已启用的集成读取以下本地目录；自定义 Claude 配置目录会替代默认路径：

- Claude Code：`~/.claude/projects/` 或用户配置的 Claude `projects/`；
- Codex：`~/.codex/sessions/` 与 `~/.codex/session_index.jsonl`；
- CodeBuddy（Experimental）：`~/.codebuddy/projects/`。

## 应用写入的数据

- macOS `UserDefaults`：语言、显示方式、尺寸、动画和审批模式等偏好；
- `~/Library/Application Support/MultiAgent Notch/active-sessions.json`：活动会话与近期
  完成会话的恢复元数据，包括会话 ID、工作目录、来源、状态和时间；
- `~/.multiagent-notch/approval-policy.json`：全局与逐会话审批模式，不包含凭据；
- `~/.multiagent-notch/bin/`：安装后的本地 Bridge；
- `~/.multiagent-notch/session-cleanup/`：完成任务延迟清理所需的短期 token 与时间；
- `~/.multiagent-notch/session-state/`：供应用中途启动恢复的最小会话状态，包括会话 ID、
  来源、工作目录、PID、TTY、事件、状态和时间戳；不包含 prompt、助手正文或工具输入；
- `~/.multiagent-notch/synthetic-files.txt`：Agent Notch 创建的合成记录路径索引；
- 对非 Claude 集成，Bridge 默认还会在 `~/.claude/projects/` 下创建已登记的合成
  JSONL；存在可读原生记录时界面会优先使用原生记录。合成 JSONL 可能包含用户
  prompt、助手最终文本、工具名称与工具输入，仅用于本机界面回退；设置
  `NOTCH_NO_SYNTHETIC=1` 可关闭此行为。

Bridge 安装器可能修改 `~/.claude/settings.json`（或自定义 Claude 配置）、
`~/.codex/hooks.json` 和 Experimental 的 `~/.codebuddy/settings.json`，并在同目录创建
带时间戳的 `.bak.*` 备份。它只应管理 Agent Notch 自己的精确 Hook 条目。

为弥补 Codex Desktop 偶发漏发回合开始 Hook，应用会只读扫描
`~/.codex/sessions/` 中最近发生写入的 rollout 文件，并读取会话 ID、工作目录、
`task_started`、完成边界和活动时间；不会把这些原生记录复制到新的诊断文件。

## 诊断日志

应用使用 macOS Unified Logging 记录运行状态和错误；诊断元数据可能包含会话 ID 前缀、
Agent 来源、工具名、文件路径或本地命令参数。Bridge 文件日志默认关闭。只有用户在
启动 Agent 的环境中显式设置 `NOTCH_BRIDGE_DEBUG=1` 时，才会写入
`~/.multiagent-notch/logs/<source>.log`；每条最多记录 Hook 原始载荷的前 800 个字符，
因此可能含有 prompt、路径或工具参数。排障结束后应关闭该变量并删除不再需要的日志，
提交 Issue 前也应先脱敏。

## 网络访问

应用不包含产品分析、广告或行为遥测。正式发行版可访问本项目 GitHub Release 的
appcast 来检查更新。源码构建若没有配置独立 Sparkle 公钥，会关闭自动更新。

## 本地文件与卸载

应用可能在 Agent 配置目录写入自己的 Hook，并创建本地状态文件。卸载应用前可在
设置中关闭 Hook；安装器和卸载器只精确移除本项目拥有的条目。用户原有会话和第三方
Hook 不应被删除。`AgentBridge/uninstall.sh` 会移除 `~/.multiagent-notch/` 和路径索引中
由 Agent Notch 创建的合成记录，但会保留 Agent 设置的时间戳备份、macOS UserDefaults
以及 `~/Library/Application Support/MultiAgent Notch/`，方便恢复和审计；如需彻底清理，
用户可在退出应用后手动删除这些剩余项。卸载器不会删除原生 Agent 会话记录。

## 联系

请通过 <https://github.com/lihao505/agent-notch/issues> 提交隐私问题。不要在公开
Issue 中附上会话内容、凭据或其他敏感信息。
