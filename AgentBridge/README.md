# Agent Notch Bridge

把多个 AI coding agent(Claude Code、Codex、CodeBuddy，可扩展 Gemini/Cursor…)统一显示到
**Agent Notch** 的 MacBook 刘海里，作为 Agent Notch 的本地桥接层。

## 为什么可行

Agent Notch 的 socket 服务器(`HookSocketServer`)**与 agent 无关**——只认一段
小 JSON(`session_id / cwd / event / status / tool / tool_input / tool_use_id`),
谁发都能显示;`SessionStore.createSession(from: HookEvent)` 只凭 socket 事件就能
建会话。真正"绑死 Claude"的只有它的钩子安装器和聊天记录读取。

所以本项目 = 一个**规范化 bridge 层**:把每个 agent 的钩子事件翻译成上面这段
JSON,喂给 `/tmp/claude-island.sock`。

```
Claude Code ──(App 自带钩子)──┐
                               ├──► /tmp/claude-island.sock ──► Agent Notch 刘海
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

- **Claude**:显示和审批继续使用 Agent Notch 自带钩子；另加
  `--lifecycle-only` 辅助钩子，只管理完成会话的定时清理，不重复发送 UI 事件。
- **Codex**:写入 `~/.codex/hooks.json`(自动备份、幂等)。**必须**再做
  `docs/codex-trust.md` 里的两步(重启 + 信任),否则不生效。
- **CodeBuddy**:写入 `~/.codebuddy/settings.json` 的 7 个观察钩子；不注册
  权限决策钩子，审批仍由 CodeBuddy 原生界面独占处理。安装后重启一次
  CodeBuddy/WorkBuddy，新会话即可进入刘海。

前提：`/Applications/Agent Notch.app` 已安装并运行。

## 能用 / 局限(MVP)

| 功能 | 状态 |
|---|---|
| 实时状态(处理中 / 运行工具 / 等待) | ✅ 全 agent |
| 多会话并存、终端定位 | ✅ |
| 权限 approve/deny | ✅ 官方格式已核对，已安装 bridge → 刘海按钮 → allow JSON 端到端通过；真实 agent 原生触发仍列入发布前验收 |
| **标题 + 任务行** | ✅ Codex 优先读取真实侧边栏标题与原生 rollout；其他 agent 可用合成 JSONL 回退 |
| 完整聊天记录面板 | ✅ Codex/CodeBuddy 只显示原生用户与助手消息，不显示 bridge 的 Bash/Shell 生命周期占位 |
| 从刘海向 Codex 发消息 | ✅ 直接 `codex exec resume` 续接同一 thread，stdout 即时显示并由原生 rollout 持久化 |
| 从刘海向 CodeBuddy 发消息 | ✅ Swift fork 通过 `codebuddy --resume <sessionId> --print` 从 stdin 继续会话 |
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

### 完成项目的定时清理

`Stop` 表示当前任务已经完成。bridge 默认让它继续在刘海保留 5 小时，方便查看结果，
随后发送 `ended` 将其移出刘海。若保留期内同一会话出现新 prompt、工具调用或审批，
旧清理任务会因 token 失效而自动取消。

- `.processing / .compacting / .waitingForApproval` 等正在工作的项目不设置过期时间，
  因此可以一直保留。
- 调整保留时间：在启动 agent 的环境中设置
  `NOTCH_COMPLETED_TTL=<秒数>`；例如 `60` 表示完成后保留一分钟。
- Claude 使用 lifecycle-only 钩子完成相同行为，不会和 Agent Notch 原生显示/审批钩子冲突。

### Swift 原生多 agent 主题

本机 fork 位于 `/Users/apple/project/vibe-notch`,已让 socket 正式解析 `source`,并将
agent 标签/主题色用于会话列表、聊天标题、助手消息标记和处理中动画。配色:
Claude 橙、Codex 绿、CodeBuddy 珊瑚红、Gemini 蓝、Cursor 紫。

Swift fork 的聊天输入也按来源分流：Claude/CLI agent 仍通过 tmux 发送，Codex Desktop
会话在 `.idle/.waitingForInput` 时运行
`codex exec resume --all --skip-git-repo-check <threadId> -`。消息从 stdin 传入，
CodeBuddy 会话运行 `codebuddy --resume <sessionId> --print`。两者的消息都从 stdin
传入，不会暴露在进程参数中；发送期间防重复提交，失败时保留输入并显示错误。
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

- Claude Code：从 `PermissionRequest` 精确迁出已知 Vibe Island 决策命令；其他
  Vibe Island 观察事件与 statusLine 默认保留。
- 默认:精确识别 AgentWatch 的通知钩子，将它改为 `async: true` 后共存（官方行为保证
  异步钩子不能审批/拒绝，因此也不会阻塞本次审批）。若存在其他未知钩子，则**不注册**
  本项目决策钩子并打印冲突命令。
- 显式迁移(只移除你指定的旧命令):
  ```bash
  ./install.sh --migrate-permission "<冲突命令原文>"   # 可重复
  ```
- `--take-permission`:接管审批,并**允许**与良性(纯观察、从不 deny)钩子共存
  (如 agentwatch 只推通知)。仅在真正的决策所有者已迁走后使用。
- `--replace-vibe-island`:**彻底替代 vibe-island** —— 从 Claude 与 Codex 配置中
  精确移除已知的 Vibe Island bridge 命令，并在精确命中时移除 Claude 的 Vibe Island
  statusLine。两份配置都会先备份；同名第三方 wrapper 不会被子串误删。

**替代 vibe-island 的一键命令**(本项目就是为此而生):
```bash
./install.sh --take-permission --replace-vibe-island
```

决策 wire 格式已按当前官方 Codex Hooks 文档核对，且与本机 codex 0.145.0 schema 一致:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest",
 "decision":{"behavior":"allow"}}}
```

其他 agent 若格式不同,在 `bin/notch-bridge.py` 的 `DECISION_FORMATTERS`
里按 `--source` 注册一个格式化函数即可。

## 刘海审批何时会弹(取决于 agent 的审批模式)

刘海展开界面的 approve/deny **只在 agent 真的"要问你"时出现**。是否询问由 agent 自己的
审批模式决定,与本 bridge 无关:

**Codex** `permission_mode`(以及全局 `approval_policy`):
| 模式 | 会不会问 | 刘海审批 |
|---|---|---|
| `default` / `acceptEdits` | 风险动作会问 | ✅ 弹,可在刘海批 |
| `plan` | 只读规划,基本不执行 | 视情况 |
| `dontAsk` / `bypassPermissions`、`--full-auto`、`--dangerously-bypass-approvals-and-sandbox` | **不问** | ❌ 不弹(无 PermissionRequest,符合预期) |

即:你若开了自动审批/绕过,就没有审批事件可批——这不是 bug。想用刘海审批,就让 agent
保持会询问的模式(Codex 默认即可)。

流程:agent 触发 PermissionRequest → bridge 阻塞 → 你在刘海点 allow/deny → bridge 用 agent
认的格式回写。你若 90s 内不点,bridge `exit 0`,agent 回退到它自己的终端提示；
Agent Notch 随后关闭过期 socket 并清除僵尸审批状态。

安装器的“独占”判断仅覆盖 `~/.codex/hooks.json`。Codex 插件、项目级或托管配置仍可能
提供额外 PermissionRequest 钩子；安装输出不会再把用户配置内独占表述成全局独占。

## 超时

Codex bridge 与 Claude 原生 hook 的 PermissionRequest 内层等待均为 90s，严格小于
外层 105s，确保 hook 自己先 `exit 0` 回退原生审批，而非被 agent 杀掉。
Codex 可用 `NOTCH_PERMISSION_TIMEOUT` 覆盖内层等待。
非权限事件的 socket 发送用短超时(`NOTCH_SEND_TIMEOUT`,默认 5s),避免卡住回合。

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
