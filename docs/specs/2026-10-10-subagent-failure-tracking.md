# 子 Agent 失败事件的跟踪收尾

日期：2026-10-10

## 背景与已证问题

继续检查状态触发时序，而不是增加展示功能。本轮参考既有
[迟到子任务完成](2026-10-08-late-subagent-completion.md)、
[终止工具历史](2026-10-09-terminal-tool-history.md)与
[有界回复清理](2026-10-09-bounded-session-socket-cleanup.md)约定。
状态逻辑没有涉及页面、动效或图表；不引入 Web 组件，也没有适用的专用实现 Skill。

`processToolTracking` 已处理 `PostToolUseFailure`，但 `processSubagentTracking`
只处理 `PostToolUse` 成功，产生两个不一致：

1. Task / Agent 容器失败后，顶层工具虽然已 error，活动子任务仍保留。
   随后父回合的 Read 被当作该失败子任务的内部工具，缺少自己的顶层行。
2. 内部 Read 失败后，tracker 已结束工具，但嵌套工具状态仍 running，显示层未同步失败。

先新增两项生产 Store 回归，修复前 10 项针对性测试中出现 6 项断言失败，
都来自新增用例的失败分支；成功分支及原有 8 项测试通过。
日志 `/tmp/agent-notch-subagent-failure-before.log`。
这是隔离事件序列复现，不是实际 Claude 子 Agent 失败或界面录像。

## 最小修正

- 成功、失败共用既有子任务完成分支，只移除匹配 tool_use_id 的容器跟踪。
- 内部工具完成按事件类型设置 success / error，并同步现有父工具的嵌套列表。
- 容器内部工具失败不意味着整个子任务结束，父回合仍 processing。
- 没有改 reducer 接受规则、Hook 格式、审批队列、回复连接、监听器或超时预算。
- 不声称修复现有并行子任务工具归属的全部歧义；该逻辑仍需真实多任务验收。

## 回归覆盖

新增 3 项测试：

1. Task 与 Agent 两种容器，分别成功/失败完成后，后续父 Read 有独立 running 行，
   原容器不再活动，主回合不被提前完成。
2. 内部 Read 分别成功/失败，活动 context 与父工具嵌套列表同步状态，容器继续运行。
3. 一个容器失败不移除另一个活动容器；后续 Read 仍可归入唯一剩余的活动容器。

夹具使用独立 parser 根目录，关闭持久化、文件同步，不连接生产 socket，
不读取真实 Agent transcript，不修改用户全局设置。

完整 Swift 回归 352 项通过，0 失败、0 跳过；权威 xcresult 摘要已核实：
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.10_10-15-45-+0800.xcresult`。
日志 `/tmp/agent-notch-subagent-failure-tests.log`。
Bridge 88 项、verifier 30 项及发布元数据/脚本检查通过，
日志 `/tmp/agent-notch-subagent-failure-gate.log`。
Release 无签名构建通过，日志 `/tmp/agent-notch-subagent-failure-release.log`。
仍有既有 TmuxTargetFinder 多余 await 及 AppIntents 元数据跳过提示；
本轮没有新增该类警告，不宣称全项目无警告。

## 实机边界

本轮只读原生清单再次确认 Mac 锁屏，未绕过锁屏或覆盖运行中的应用。
本轮构建尚未签名安装；本机应用仍为上一轮的全屏策略修正版。
上一轮全屏策略修复 CI 已确认成功，但修正版全屏行为仍未实机验证。
本轮真实 CLI 子任务失败、动画、并行混合超时、审批中重启等仍保持待验收；
不能用上述隔离测试将整个生命周期矩阵改为通过。
