# Agent Notch Bridge

把多个 AI coding agent（Claude Code、Codex，以及 Experimental 状态的 CodeBuddy）
统一显示到 **Agent Notch** 的 MacBook 刘海里，作为 Agent Notch 的本地桥接层。

## 为什么可行

Agent Notch 的 socket 服务器(`HookSocketServer`)**与 agent 无关**——只认一段
小 JSON(`session_id / cwd / event / status / tool / tool_input / tool_use_id`),
谁发都能显示;`SessionStore.createSession(from: HookEvent)` 只凭 socket 事件就能
建会话。真正"绑死 Claude"的只有它的钩子安装器和聊天记录读取。

所以本项目 = 一个**规范化 bridge 层**:把每个 agent 的钩子事件翻译成上面这段
JSON,喂给按 macOS 用户隔离的 `/tmp/agent-notch-<uid>.sock`。

```
Claude Code ──(App 自带钩子)──┐
                               ├──► /tmp/agent-notch-<uid>.sock ──► Agent Notch 刘海
Codex ──(notch-bridge.py)──────┘
CodeBuddy ──(notch-bridge.py)──┘
Gemini/Cursor… ──(同一个 bridge, --source xxx)──┘   ← 未来扩展
```

## 目录结构

```
AgentBridge/
├── bin/notch-bridge.py   # 核心:规范化 + 转发 + 权限决策
├── install.sh            # 一键安装(拷到 ~/.multiagent-notch/bin,写各 agent 钩子)
├── uninstall.sh          # 卸载(保留 Claude 原生钩子)
├── tests/                # bridge 合成记录/去重回归测试
├── docs/codex-trust.md   # Codex 的信任/重载一次性步骤
└── README.md
```

## 安装

```bash
bash install.sh
```

在 App 内，只有首次引导选择“启用并开始”或设置中明确打开 Hooks 后才会运行安装；
“跳过”和仅切换 Claude 目录都不会隐式改写 agent 配置。直接运行上面的脚本本身视为
明确授权。自定义 Claude 根目录可通过 `AGENT_NOTCH_CLAUDE_DIR` 或
`CLAUDE_CONFIG_DIR` 传入，App 会自动传递当前设置中选择的目录。

- **Claude**:显示和审批继续使用 Agent Notch 自带钩子；另加
  `--lifecycle-only` 辅助钩子，只维护完成会话的过期 marker，不重复发送 UI 事件。
- **Codex**:写入 `~/.codex/hooks.json`(自动备份、幂等)。**必须**再做
  `docs/codex-trust.md` 里的两步(重启 + 信任),否则不生效。
- **CodeBuddy（Experimental）**:写入 `~/.codebuddy/settings.json` 的 7 个观察钩子；不注册
  权限决策钩子，审批仍由 CodeBuddy 原生界面独占处理。安装后重启一次
  CodeBuddy/WorkBuddy。该适配尚未完成真实完整回合验收。

前提：`/Applications/Agent Notch.app` 已安装并运行。

## 能用 / 局限(MVP)

| 功能 | 状态 |
|---|---|
| 实时状态(处理中 / 运行工具 / 等待) | ✅ Claude/Codex；🧪 CodeBuddy Experimental |
| 多会话并存、终端定位 | ✅ |
| 权限 approve/deny | ✅ 官方格式已核对，已安装 bridge → 刘海按钮 → allow JSON 端到端通过；真实 agent 原生触发仍列入发布前验收 |
| **标题 + 任务行** | ✅ Codex 优先读取真实侧边栏标题与原生 rollout；其他 agent 可用合成 JSONL 回退 |
| 完整聊天记录面板 | ✅ Codex；🧪 CodeBuddy 依赖尚未实机确认的原生 JSONL 路径 |
| 从刘海向 Codex 发消息 | ✅ 直接 `codex exec resume` 续接同一 thread，stdout 即时显示并由原生 rollout 持久化 |
| 从刘海向 CodeBuddy 发消息 | 🧪 Experimental：已实现 `codebuddy --resume <sessionId> --print` 适配，真实完整回合待验收 |
| 按 agent 区分标签 | ✅ 当前 App 直接显示彩色来源标题;Swift fork 另支持列表/聊天原生主题色 |
| 只保留运行中项目 | ✅ 运行/等待审批不设过期；`Stop` 后延迟清理，新活动自动取消 |

### 标题、任务行与聊天来源

Codex 会话优先读取 `~/.codex/session_index.jsonl` 的真实侧边栏标题，以及
`~/.codex/sessions/` 中原生 rollout 的用户/助手消息、用量、权限模式和完成边界。
bridge 同时保留一份最小 Claude 格式 JSONL，供缺少原生 rollout 的 agent 或早期事件
回退；Codex/CodeBuddy 的聊天界面会过滤其中的 Bash/Shell 生命周期占位。

- 标题 = 彩色 agent 标记 + Codex 真实侧边栏任务标题；索引尚未生成时回退
  当前 prompt（如 `Codex · 修复登录`）；
  任务行 = 最近一次工具调用(名+参数)。
- 每条合成消息都有稳定 `uuid`,工具块有 `id`;重复投递不会产生重复气泡。
- JSONL 使用紧凑分隔符写入（例如 `"type":"user"`）；这是当前增量解析器的
  字面匹配要求。bridge 会自动迁移本项目以前写出的带空格记录。
- Codex 助手正文来自原生 rollout；子 agent 的 Stop 不混入主聊天。
- 关闭:`export NOTCH_NO_SYNTHETIC=1`。
- 写入的文件记录在 `~/.multiagent-notch/synthetic-files.txt`,`uninstall.sh` 据此清理,
  卸载时只允许删除 `~/.claude/projects/` 目录内的记录，绝不碰其他文件。

### Agent Notch 中途启动恢复

每次生命周期 Hook 都会原子更新
`~/.multiagent-notch/session-state/<会话哈希>.json`，即使 Agent Notch 当时没有运行。
文件只保留恢复工作状态所需的会话 ID、来源、工作目录、PID、TTY、事件、状态和时间戳，
不保存 prompt、助手正文或工具输入。目录权限为 `0700`，快照权限为 `0600`。

Agent Notch 启动时只恢复 24 小时内、PID 仍存活且状态仍为工作的快照；Codex 还会用
原生 rollout 完成边界否决过期的活动快照。旧的审批 Socket 无法跨进程重启继续使用，
因此快照中的 `waiting_for_approval` 只恢复成普通处理中状态，必须等待新的实时审批 Hook。
`Stop` 会留下短期完成状态，保留期结束或 `SessionEnd / SessionExpired` 到来后删除快照。

### 状态触发时序

- Bridge 在执行任何文件或 Socket I/O 前写入 `observed_at`；应用按该时间拒绝迟到的旧
  Hook 改写新状态，但仍保留旧事件的工具完成记录。
- Socket 事件进入单消费者队列，确保同一连接序列中的 `PreToolUse → PermissionRequest
  → PostToolUse → Stop` 按接收顺序处理。
- Codex 原生 rollout 每秒提供回合边界回退；即使 `UserPromptSubmit` 漏发，也会在
  `task_started` 写入后发现新工作。token 计数或同一回合的后续活动不能越过 `Stop`
  重新点亮处理中状态，只有更新的 `task_started` 可以开启下一回合。
- Codex 安装器同时登记 `PreCompact / PostCompact / SessionEnd / SubagentStart /
  SubagentStop`，避免压缩、结束和子代理状态永远没有触发源。

### 完成项目的定时清理

`Stop` 表示当前任务已经完成。bridge 默认让它继续在刘海保留 5 小时，方便查看结果。
运行中的 Agent Notch 由自身周期扫描移除过期会话；bridge 仅写入带 `expires_at` 的 marker，
并在后续事件到来时补发 `ended`，因此不会为每个完成任务启动一个睡眠五小时的进程。
若保留期内同一会话出现新 prompt、工具调用或审批，marker 会立即取消。

- `.processing / .compacting / .waitingForApproval` 等正在工作的项目不设置过期时间，
  因此可以一直保留。
- 调整保留时间：在启动 agent 的环境中设置
  `NOTCH_COMPLETED_TTL=<秒数>`；例如 `60` 表示完成后保留一分钟。
- Claude 使用 lifecycle-only 钩子完成相同行为，不会和 Agent Notch 原生显示/审批钩子冲突。

### Socket 隔离与迁移

Agent Notch 不再占用上游的 `/tmp/claude-island.sock`，默认地址为
`/tmp/agent-notch-<uid>.sock`。UID 隔离避免多用户冲突，独立名称也允许与旧应用并存；
服务端只会清理当前用户拥有的失效 socket，不会删除活跃 socket、普通文件或符号链接。
如需测试专用地址，可让应用与 bridge 同时设置 `AGENT_NOTCH_SOCKET=/tmp/...`。

### Swift 原生多 agent 主题

当前仓库实现已让 socket 正式解析 `source`,并将
agent 标签/主题色用于会话列表、聊天标题、助手消息标记和处理中动画。配色:
Claude 橙、Codex 绿、CodeBuddy 珊瑚红、Gemini 蓝、Cursor 紫。

Swift fork 的聊天输入也按来源分流：Claude/CLI agent 仍通过 tmux 发送，Codex Desktop
会话在 `.idle/.waitingForInput` 时运行
`codex exec resume --all --skip-git-repo-check <threadId> -`。消息从 stdin 传入，
CodeBuddy 会话的 Experimental 适配运行 `codebuddy --resume <sessionId> --print`。
两者的消息都从 stdin 传入，不会暴露在进程参数中；发送期间防重复提交，失败时保留
输入并显示错误。CodeBuddy 的参数、原生记录路径和完成边界仍以真实版本验收结果为准。
正在处理、压缩或等待审批的会话不会并发 resume。

### 当前安装版的 Codex 刘海回复

Agent Notch 直接执行 `codex exec resume --all --skip-git-repo-check
<threadId> -`，通过 stdin 发送消息并把 CLI stdout 作为即时回复。真实 Codex rollout
随后用于持久化聊天，不再建立隐藏 tmux relay，也不会制造重复的 agent 进程或伪会话。
升级安装时只清理本项目旧版的 `multiagent-notch-codex-*` relay，不碰用户自己的 tmux。

> **事件范围**:Codex 只注册它 0.145.0 支持的事件——观察类 6 个
> (SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Stop / SubagentStop)
> + 可选的 PermissionRequest。`Notification` 不在 Codex 有效事件列表内,已移除。

## PermissionRequest:决策钩子独占，观察钩子异步共存

Codex 会**并发执行所有**匹配的 PermissionRequest 钩子,等全部结束才汇总,且
**任一 `deny` 覆盖所有 `allow`**。所以若多个工具都注册审批钩子,会一起阻塞——
最慢的那个(如 vibe-island 的 7200s)可能把整个回合卡住约 2 小时。

因此会返回 allow/deny 的审批钩子应当**独占**；纯观察类钩子可共存。安装器的策略:

- Claude Code：从 `PermissionRequest` 精确迁出已知 Vibe Island 决策命令；若仍有
  任何未知同步决策 Hook，则移除/不注册 Agent Notch 的原生决策 Hook。其他 Vibe Island
  观察事件与 statusLine 默认保留。
- Codex：同样默认精确迁出已知 Vibe Island `PermissionRequest` 命令；仅精确识别
  AgentWatch 的通知钩子，将它改为 `async: true` 后共存（官方行为保证
  异步钩子不能审批/拒绝，因此也不会阻塞本次审批）。若存在其他未知钩子，则**不注册**
  本项目决策钩子并打印冲突；无 `command`、未知类型和畸形 entry 也一律视为冲突。
  当前 Vibe Island 的已知 Codex `Stop` 命令会向 codex 0.145 返回不兼容 JSON，真实
  回合会显示红色 hook failure，因此安装器也只精确迁出这条失效的 Stop 命令；其余
  Vibe Island 观察事件默认保留。
- 显式迁移只移除你指定的旧命令。不要把配置内容直接拼成 shell 命令；可先通过
  `read -r` 读取为纯数据，再作为一个引用完整的参数传入：
  ```bash
  IFS= read -r -p 'Exact hook command: ' conflict_command
  ./install.sh --migrate-permission "$conflict_command"   # 可重复
  unset conflict_command
  ```
- `--replace-vibe-island`:**彻底替代 vibe-island** —— 从 Claude 与 Codex 配置中
  精确移除已知的 Vibe Island bridge 命令，并在精确命中时移除 Claude 的 Vibe Island
  statusLine。两份配置都会先备份；同名第三方 wrapper 不会被子串误删。

**替代 vibe-island 的一键命令**(本项目就是为此而生):
```bash
./install.sh --replace-vibe-island
```

安装器遇到损坏的 JSON 会失败并保留原文件，不会把它当作空配置覆盖；新建 settings
权限为 `0600`，现有 settings 符号链接会保留并原子更新其目标文件。

决策 wire 格式已按当前官方 Codex Hooks 文档核对，且与本机 codex 0.145.0 schema 一致:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
 "decision":{"behavior":"allow"}}}
```

其他 agent 若格式不同,在 `bin/notch-bridge.py` 的 `DECISION_FORMATTERS`
里按 `--source` 注册一个格式化函数即可。

## 刘海审批何时会弹

Agent Notch 将选择写入 `~/.multiagent-notch/approval-policy.json`。Claude 原生 hook 与
通用 bridge 都读取相同策略，并支持全局默认及每个 session 的覆盖：`ask` 显示单次审批；
`auto` 只有在 bridge 成功连接当前运行的 Agent Notch 时才允许，应用退出、崩溃或 socket
不可达时会输出空决策并回退 agent 原生审批；`trusted` 是用户明确选择的跨重启信任，允许
应用离线时继续批准普通工具。`AskUserQuestion` 与 `ExitPlanMode` 永远保留人工交互。若
agent 自己处于绕过审批模式且根本不发 PermissionRequest，则不会出现审批卡。

**Codex** `permission_mode`(以及全局 `approval_policy`):
| 模式 | 会不会问 | 刘海审批 |
|---|---|---|
| `default` / `acceptEdits` | 风险动作会问 | ✅ 弹,可在刘海批 |
| `plan` | 只读规划,基本不执行 | 视情况 |
| `dontAsk` / `bypassPermissions`、`--full-auto`、`--dangerously-bypass-approvals-and-sandbox` | **不问** | ❌ 不弹(无 PermissionRequest,符合预期) |

即：想使用 Agent Notch 的 ask/auto/trusted 策略，需要让 agent 保持会产生
PermissionRequest 的普通模式；agent 自己的完全绕过模式没有事件可供 bridge 接管。

流程:agent 触发 PermissionRequest → bridge 阻塞 → 你在刘海点 allow/deny → bridge 用 agent
认的格式回写。你若 90s 内不点,bridge `exit 0`,agent 回退到它自己的终端提示；
Agent Notch 随后关闭过期 socket 并清除僵尸审批状态。

安装器的“owner”判断只覆盖本次编辑的用户配置文件。Codex 插件、项目级或托管配置，
以及 Claude 的其他配置层，仍可能在运行时提供额外 PermissionRequest 钩子；安装输出
不会再把用户配置文件内的 owner 表述成全局独占。发布验收应检查 agent 实际加载的全部层。

## 超时

Codex bridge 与 Claude 原生 hook 的 PermissionRequest 内层等待均为 90s，严格小于
外层 105s，确保 hook 自己先 `exit 0` 回退原生审批，而非被 agent 杀掉。
Codex 可用 `NOTCH_PERMISSION_TIMEOUT` 覆盖内层等待；非法值回退默认值，有限数值会被
限制在 `0.1...90s`，不能越过 105s 外层预算。非权限事件的 socket 发送用短超时
(`NOTCH_SEND_TIMEOUT`,默认 5s，限制在 `0.1...5s`),避免卡住回合。

## 扩展新 agent(路线图)

1. 找到该 agent 的钩子配置文件(如 Gemini `~/.gemini/settings.json`)。
2. 在 `install.sh` 里加一段,注册
   `/usr/bin/python3 ~/.multiagent-notch/bin/notch-bridge.py --source <name>`。
3. 若事件名不在 stdin,用 `--event <Name>` 兜底。
4. 若权限决策格式不同,在 `DECISION_FORMATTERS` 注册。

## 调试

```bash
# 在启动 agent 的环境里设置,bridge 会把每次调用写日志
export NOTCH_BRIDGE_DEBUG=1
cat ~/.multiagent-notch/logs/<source>.log
```

## 卸载

```bash
bash uninstall.sh
```
