# 给 Codex 的审查任务书 — Agent Notch Bridge

> 用途:按本仓库 `CLAUDE.md` 约定(Codex 负责 diff 审查),把本轮改动交 Codex 复核。
> 本轮由用户直接与 Claude Code 拍板并实现,Codex 未参与方向拆解,故补一次审查。

## 1. 本轮目标

这份文档记录 Agent Bridge 初版的审查背景。Bridge 现已并入 Agent Notch 主仓库，
并随应用资源一起发布。**初始范围：Claude + Codex。**

核心事实：Agent Notch 的 socket 服务器与 agent 无关，`/tmp/claude-island.sock`
只认一段 JSON(`session_id/cwd/event/status/tool/tool_input/tool_use_id`);
`SessionStore.createSession(from:HookEvent)` 仅凭 socket 事件即可建会话。故只需一个
"规范化 bridge",把各 agent 的钩子事件翻成该 JSON 转发即可。

## 2. 改了什么

### 仓库内
| 文件 | 说明 |
|---|---|
| `AgentBridge/bin/notch-bridge.py` | 核心：读 stdin 钩子 JSON → 规范化 → 发 socket；PermissionRequest 阻塞等待决策并回写 |
| `AgentBridge/install.sh` | 幂等安装：拷 bridge 到稳定路径、写 Codex `hooks.json`、备份、清理旧脚本 |
| `AgentBridge/uninstall.sh` | 反向卸载，保留 Claude 原生钩子 |
| `AgentBridge/docs/codex-trust.md` | Codex 信任与重载步骤 |
| `AgentBridge/README.md` | 架构、局限、扩展新 Agent 的方法 |

### 仓库外(运行时配置,已备份)
- `~/.codex/hooks.json`:观察事件 + 可选审批事件挂上
  `notch-bridge.py --source codex`；已知 AgentWatch 通知观察器可异步共存，未知决策钩子
  默认保持冲突并拒绝接管。安装时始终先备份。
- `~/.multiagent-notch/bin/notch-bridge.py`:稳定副本(hooks 指向此处,不依赖仓库位置)。
- **Claude 原生显示钩子保留**：避免重复 UI 事件。

## 3. 验收结果(已完成的自测)
- [x] 模拟 Codex 一整轮(SessionStart/UserPromptSubmit/PreToolUse/Stop)全部成功进 socket,exit 0。
- [x] 权限决策输出与当前官方 Codex Hooks 文档及本机二进制 schema 一致:
      `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow|deny"}}}`。
- [x] `hooks.json` 改后仍是合法 JSON;幂等(重复 install 不叠加)。
- [x] 旧 ad-hoc 脚本 `~/.codex/hooks/vibe-notch-bridge.py` 已清理。
- [x] 真实 Codex CLI 会话已通过 hooks 显示在刘海；完成状态与同 session resume 聊天均已验收。

## 4. 请 Codex 重点审的风险点
1. **与 vibe-island 钩子共存冲突**:`PermissionRequest` 现同时挂 vibe-island-bridge 和本 bridge。
   两者都可能返回 allow/deny 决策 → 多钩子决策合并语义未知,是否应改为二选一?
2. **`hooks.json` 幂等/去重逻辑**:`install.sh` 用子串 `notch-bridge.py` / `vibe-notch-bridge.py`
   匹配剥离旧条目,是否有误删/漏删风险?对非本项目条目是否绝对不动?
3. **PermissionRequest 阻塞**:bridge 等决策超时 300s,`hooks.json` 里该事件 timeout 也是 300。
   超时/socket 断开时是否稳妥 fail-open(exit 0,让 Codex 用自身 prompt)?会不会卡住 Codex 回合?
4. **决策格式假设**:allow/deny 格式基于从 codex 二进制抠出的 schema,未经真实 Codex 回合确认。
5. **stdin 事件名兜底**:优先读 `hook_event_name`,缺失时用 `--event` 兜底——Codex 实测发送
   `hook_event_name`,兜底路径未触发,是否保留?
6. **稳定路径依赖**:hooks 指向 `~/.multiagent-notch/bin/`,若用户删该目录钩子命令会失败
   (bridge 已 fail-open,但 Codex 端命令 not found 的表现待确认)。

## 5. 建议下一步
- 发布前再用真实 Codex/Claude Code 原生 `PermissionRequest` 各触发一次，分别点击 allow/deny。
- 扩展 Gemini(`~/.gemini/settings.json`)/Cursor(`~/.cursor/hooks.json`):仅需在 install.sh 加注册。

## 6. 是否建议合入
结论：决策钩子采用独占策略，已知观察钩子异步共存；Vibe Island 决策条目已精确迁出。
真实 Codex 状态、完成边界和同会话 CLI 聊天均已验证，可以合入。原生 PermissionRequest
的 allow/deny 双分支仍保留为发布前人工验收项。

---

## 7. 修复回执(响应 Codex 首轮审查,待复核)

| 发现 | 处理 | 验证 |
|---|---|---|
| **[P1] PermissionRequest 需独占** | Codex 遇到未知 PR 钩子默认拒绝接管；显式 `--migrate-permission "<exact cmd>"` 才迁移。Claude Code 则从 PR 精确迁出已知 Vibe Island 决策命令，保留其观察事件/statusLine。已知观察钩子可异步共存。 | 实测：Claude/Codex 的 Vibe Island 决策钩子均已迁出；Codex AgentWatch 观察钩子 + Agent Notch 决策钩子各 1 条；单测覆盖冲突、迁移、共存、不误删与幂等 ✅ |
| **[P1] 子串去重误删** | 改为**完整命令精确匹配**(`OWNED_COMMANDS` 列出当前+遗留完整命令);install/uninstall 共用同一规则。 | 单测:第三方 `/opt/other-project/notch-bridge.py --foo` 保留不删 ✅;幂等不叠加 ✅ |
| **[P2] 审批长时间阻塞** | Codex bridge 与 Claude 原生 hook 内层均为 **90s**，外层 105s；超时先 fail-open 到原生审批，App 随后清理过期 socket/审批状态。非权限事件为 5s。 | bridge 单测 + Python 编译 + Swift 构建 |
| **[P2] Codex 不支持 Notification** | 从 Codex 注册表移除 `Notification`;观察类事件降为 **6 个**;README/文档口径同步。 | 实测:Notification 事件已无 ours(仅原 agentwatch)✅ |
| **README ✅ 过强** | 权限行改为「协议已验证(codex 0.145.0 schema 一致),真实回合待验收」。 | README 已改 |

**仍未验收(依赖运行时)**:真实 Codex 回合触发 hook 并显示于刘海(卡在 hook 信任+重载,
且 Claude Code 侧禁跑 `--dangerously-bypass-hook-trust`,须用户/CLI codex 完成)。

**未做**:正式测试套件(当前为一次性单测脚本)、知识图谱初始化、子仓库 git 化以获得真实 diff。

---

## 8. 第二轮修复回执

- `--replace-vibe-island` 现在同时处理 Claude 与 Codex：先备份配置，再按已知完整命令
  精确删除 Vibe Island bridge；Claude statusLine 也只在精确命中时删除。
- Claude 新增 `--lifecycle-only` 辅助钩子，不重复发送 UI 事件、不参与审批，只负责完成
  会话的延迟清理。
- Codex/Claude 的 `Stop` 默认保留 5 小时后移出刘海；期间出现任何新活动都会取消旧清理。
  运行中、压缩中、等待审批的项目不设过期时间。
- 合成 transcript 拒绝包含路径穿越字符的 session id；卸载器删除文件前强制验证目标位于
  `~/.claude/projects/`；全新 Codex 环境会先创建 `~/.codex`。
- 自动化测试现覆盖合成聊天、重复投递、清理 token 竞态、恢复会话取消清理和路径穿越。
