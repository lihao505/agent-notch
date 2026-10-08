# 同一回合的完成时间保持稳定

## 已证问题与实机观察的区别

原生超时允许验收中，最终回复为 UTC 18:51:09，而后续读取的会话快照
completedAt 为 18:52:09。这不是连续采样，不能证明等待态首次出现也晚了 60 秒。
本轮没有 GUI、完整 Hook 调试日志或统一日志中的完整状态时间线，不能确定
该实机差值来自哪个具体事件。详见[原生允许记录](2026-10-09-native-timeout-allow.md)。

独立源码检查发现 LifecycleReducer 的 completed Hook 路径每次都执行
`completedAt = max(previousCompletedAt, observedAt)`。SessionStore 将 Stop、
StopFailure 和 Notification / idle_prompt 都映射到该路径。
因此后续空闲通知或重复 Stop 可把同一回合的完成时间刷新到新时间；
保留和清理逻辑使用 completedAt，重复通知也会推后完成记录的保留截止时间。

## 最小修改

仅在 completed Hook 路径中保留首次接受的 completedAt；为空时才使用当前事件时间。
不改 Hook 安装、全局配置、审批队列、用户选择或页面布局。

- lastHookEventAt 和 lastActivity 仍接收新事件时间，旧事件排序和拒绝规则不变。
- 新回合的有效 active Hook 仍清空 completedAt；新一轮完成会得到新的完成边界。
- transcript 已先完成时，后到的 Stop 只刷新 Hook 元数据，不重写完成时间。
- SessionEnd 的移除和 ended 路径保持原有行为，本轮没有扩大修改范围。

此修改不是“所有状态触发延迟已解决”，也不证明上述实机分钟差的来源。
后续需在安装新版本后连续观察 Stop、idle_prompt、等待态首次出现和清理计数。

## 回归证据

新增 3 项测试，修复前全部失败（共 4 个断言）：

1. 先完成，再在 +60 秒收到 Notification、+120 秒收到重复 Stop：完成时间不后移，
   最新 Hook 时间仍前进。
2. transcript 已完成，+2 秒收到 Stop：完成边界保持原时间。
3. 通过真实 SessionStore 入口处理 Claude 提示、Stop、idle_prompt：完成时间稳定；
   随后新提示仍恢复工作态并清空旧边界，下一次 Stop 使用新完成时间。

修复后全套 Swift：276 passed、0 failed、0 skipped。
xcresult：`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_02-59-17-+0800.xcresult`。
Bridge 88 项、审批检查器 30 项及发布脚本闸门通过；它们不替代真实 Agent/UI 验收。
Release 无签名构建通过，日志 `/tmp/agent-notch-completion-boundary-release-build.log`。
当前安装版保持不变，本轮未替换运行中的 App。
