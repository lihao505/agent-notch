# Claude 审批预算结束后的原生允许验收

## 范围与安装态

2026-10-09 本地日期，Claude Code 2.1.195 的真实交互 CLI；当前已配置模型为
`deepseek-flash`，本轮未修改模型或服务商。应用全程在线，安装版仍是
68c8741 对应 Release，主进程 PID 62187，主二进制 SHA-256：
`cf36614872bd4bf93344c983f3b4f0dc88a4fc7614bf4a2ff73d80d2a075a5fb`。
后续源码修复尚未安装，不能用此次验收证明那些修改已在运行版生效。

隔离目录 `/private/tmp/agent-notch-same-session-fifo.xHwUP7` 中的 `alpha.txt`
由测试创建，内容为 `FIFO_ALPHA_READ_MARKER`。只暴露 Read 工具，子进程设置
`NOTCH_APPROVAL_MODE=ask` 和临时 `permissions.ask: ["Read"]`，禁用 slash commands。
唯一提示要求只读一次该文件、不调用其他工具、不重试。
没有覆盖应用 socket、伪造生产 Hook，也没有修改全局审批策略。

## 时间线

下表均为 2026-10-08 UTC；对应本地 2026-10-09。

| 时间 | 证据 |
| --- | --- |
| 18:48:15.206 | 真实用户提示写入自己的 CLI JSONL |
| 18:48:16.262 | 唯一 Read 请求，ID `call_00_R6bk0TwjYDbX51WUreP92906`，路径为上述隔离文件 |
| 审批等待中 | 原生终端显示 `Do you want to proceed?` 和 Yes / Yes during this session / No；未选择 |
| 18:49:48 | 已超过源码 90 秒审批预算；首次读取快照仍等待审批，后续异步更新需独立观察 |
| 18:50:47 | 同一会话快照已为空闲，最近 Hook 时间为 18:49:48；CLI PID 79584 无子进程，原生审批仍等待选择，无工具结果 |
| 18:51:08 | 在 CLI 默认选项 1 处按 Enter，只允许本次，不选“本会话允许” |
| 18:51:08.507 | 精确匹配请求 ID 的成功工具结果，内容含 `FIFO_ALPHA_READ_MARKER` |
| 18:51:09.214 | 最终回复说明读取成功，并含 `NATIVE_TIMEOUT_ALLOWED` |
| 18:51:09.292 | JSONL 的 `stop_hook_summary`：hookCount 6，hookErrors 空数组 |
| 后续读取快照 | 会话等待输入，completedAt / lastHookEventAt / lastActivity 为 18:52:09；应用不再持有该会话 JSONL 文件描述符 |

唯一请求与工具结果由只读 jq 断言检查通过，未删改日志。测试 CLI 后来通过终端提示的
两次 Ctrl-D 正常退出，exit 0；进程消失，同一会话不再出现在应用持久化数组中。
`--disable-slash-commands` 也会禁用 `/exit`，此前输入该命令只产生 unknown command，
没有新增模型工具调用；它不是退出成功证据。

本次未显式启用 CLI debug 文件，默认会话 debug 文件不存在，因此不声称取得了
PermissionRequest 调用与空 JSON 返回的精确调试时间差。可确认的是预算已经过去、
应用已清理该请求到空闲、原生审批仍可选择且随后实际成功；不是超时自动执行。
原生提示在预算结束前已出现，不能说它一定由超时后才展示。

原始 JSONL 位于本机：
`~/.claude/projects/-private-tmp-agent-notch-same-session-fifo-xHwUP7/9ca2e0dc-402a-49cb-a139-66720100cd48.jsonl`。
原始日志不提交仓库，避免带入 CLI 启动上下文和用户环境信息。

## 完成时间的观察边界

最终回复时间与后续快照的 completedAt 相差约 60 秒，但没有连续采样首次等待态，
也没有该会话完整 Hook 调试轨迹，不能据此认定 UI 晚一分钟才完成。
源码已确认重复 completed Hook 会通过 max 把 completedAt 后移，
而 idle_prompt 也映射为 completed；这是该观察的一种解释，不是实机已证根因。
后续独立修复见[稳定完成边界](2026-10-09-stable-completion-boundary.md)。

## 不变配置与未覆盖项

前后 SHA-256 相同：

- Claude 全局 settings：`1d98df5c9ed6d824ba42f500b6cdb8a53454d3bd02e81457f93c09e118102af4`。
- `~/.multiagent-notch/approval-policy.json`：`baf55a2aea3181b27538d5dc0999d90303eb309a4102f8a7aff37311679e0d2b`。
- 应用主二进制：上文校验值。

Mac 锁屏期间未操作刘海按钮，未绕过锁屏；本次终端证据不是刘海 UI 验收。
文件描述符清理不能替代诊断页全局待审批 / 监听器数归零。
此结果只补齐单会话 Read 的超时后原生允许分支，不证明同会话 FIFO、并行混合超时、
审批中重启、其他工具审批、完成瞬间 UI 时序或动画流畅度。
