# 子 Agent 文件结果分类与不完整快照合并

日期：2026-10-10

## 背景与复现

参考[嵌套工具终止边界](2026-10-10-nested-tool-terminal-boundary.md)、
[子 Agent 失败收尾](2026-10-10-subagent-failure-tracking.md)及完整生命周期矩阵。
本轮是原生解析/状态逻辑，没有涉及页面、动效或图表，不引入专用 UI Skill 或新依赖。

子 Agent 的同步和异步解析各复制一套工具解析，只记录完成 ID，丢弃失败/中断类型；
Store 随后把所有完成项一律映射成 success。文件装饰整表替换，也会让缺少结果的行
覆盖已有的 Hook success / error，重新显示 running。

先新增 2 项生产 Store 回归，修正前 16 项针对性测试出现 4 项断言失败：
失败、中断、拒绝被误显示成功，以及无结果快照覆盖已知结束状态。
日志 `/tmp/agent-notch-child-results-before.log`。成功、无结果及未标记错误的
中断字样对照通过，避免把所有包含文字的结果都归为中断。
这是独立 JSONL / Hook 夹具复现，不是实际 Claude 子 Agent 验收。

初次修正后完整 359 项通过，但进一步扩展原快照回归，让文件缺少一条 Hook 已记录
的工具，仍出现该工具消失的单项断言失败。日志
`/tmp/agent-notch-child-results-missing-before.log`；这是额外确认的整表替换遗漏，
不能用第一次绿色结果宣称该边界已经通过。

## 实现边界

- 同步、异步读取共用一个内容解析器，保留工具顺序、ID 去重、输入、时间戳及路径兼容。
- 结果复用既有 `ToolResult` 与 `ToolCompletionResult.from` 分类，不复制中断识别规则。
  字符串和文本块数组均提取文本供已有分类器判断；`is_error` 仍是中断识别的必要条件。
- `SubagentToolInfo` 保存具体可选完成状态，`isCompleted` 作为兼容读取属性；
  没有结果时为 running，而不是虚构成功。
- 无结果文件行不覆盖同 ID 已知 success / error / interrupted；
  真正的文件结果仍能修正先前的终止占位，而不恢复已完成主回合。
- 快照没有的新 Hook 工具仍保留并按 ID 去重；只有既有父历史/clear 代次处理移除历史，
  不用一份不完整装饰列表代替删除证据。
- 不改主生命周期 reducer、审批身份、FIFO、回复连接、Hook 协议或超时预算。
- 同步读取增加可选测试根目录，生产默认调用不变；nested 优先、flat 回退保持。

## 回归范围

新增 4 项测试：

1. 文件 success / error / interrupted / 拒绝 / 未标记错误的文字 / 无结果分别映射。
2. 缺少结果的旧快照保留 Hook 已知结束状态及文件尚未记录的工具。
3. actor / sync 两条入口，nested / legacy flat 两种布局，数组文本中断、坏行、
   未完整尾行、重复工具 ID、顺序与完成属性对照。
4. Stop 后真实文件结果将占位修正为 success / error / interrupted，父回合仍等待输入，
   完成时间及父工具终止状态不变。

用例只读取 UUID 临时根目录，不连接生产 socket、不写用户配置、不启动真实 Agent。
串行快照合并不是所有读取期间 await 交错的强制竞态证明。

最终完整 Swift 359 项通过，0 失败、0 跳过，权威 xcresult 摘要已核实：
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.10_11-08-55-+0800.xcresult`。
日志 `/tmp/agent-notch-child-results-final-tests.log`。初次 359 项绿色结果不是扩展用例
的最终证据，额外单项失败已修正后重新完整运行。
Bridge 88、verifier 30 和发布检查通过，日志 `/tmp/agent-notch-child-results-gate.log`。
Release 无签名构建通过，日志 `/tmp/agent-notch-child-results-release.log`。
既有 TmuxTargetFinder 多余 await / AppIntents 元数据跳过警告仍在。

最终测试出现耗时异常：既有 `testSyncOutputCleanupHonorsDeadlineAfterRootHasExited`
被 XCTest 记录为 302.096 秒，期间有 Thread Performance Checker 的主线程等待 Utility
线程警告；同轮该用例的结果/耗时断言仍被记为通过，初次完整运行记录为 0.516 秒。
这不是性能改善证据，也尚未归因，不能只因绿色摘要而忽略。需继续独立复查。

同一源码与环境单独复跑该测试，1 项通过、0 失败，XCTest 记录 0.437 秒，
没有再次出现 302 秒耗时。日志 `/tmp/agent-notch-child-results-deadline-recheck.log`。
单次未复现不能排除异常；线程优先级等待提示仍出现，未改进程执行器，
所以不把复跑解释为修好了性能问题。

## 剩余边界

Mac 只读清单仍报告锁屏，无法继续原生操作与启动复查，没有绕过锁屏；本轮尚未安装。
安装二进制 SHA-256 再次核实仍为
`8804c0bb8fb28e1a91766c3ba9f3ecd4b22e4f95fdc9aea0e1d789e15df7ece1`（b410c80），
不将本轮源码或无签名构建说成已安装运行。
真实子 Agent、审批中重启、同会话双请求并存、全屏与动画继续保持原矩阵待验收项。
任意冲突完成结果的时间顺序及重用工具 ID 的不同执行身份，不由本轮结果分类保证。
Hook 对仅由文件发现的内部工具是否即时更新、两种来源的列表是否相互覆盖，
也需单独检查，不能外推本轮文件合并已解决所有双向同步问题。
